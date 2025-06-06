#!/bin/bash -x

OSP_TOKEN_PATH=/tmp/token
COMMON_DOCKER_ARGS="run --user osg
                        --detach
                        --security-opt apparmor=unconfined
                        --name backfill
                        -v $OSP_TOKEN_PATH:/etc/condor/tokens-orig.d/flock.opensciencegrid.org
                        -e GLIDEIN_Site='None'
                        -e GLIDEIN_ResourceName='None'
                        -e GLIDEIN_Start_Extra='True'
                        -e OSG_SQUID_LOCATION='None'"

function usage {
    echo "Usage: $0 <docker|singularity> <bindmount|cvmfsexec>"
}

ABORT_CODE=126
SINGULARITY_OUTPUT=$(mktemp)
PILOT_DIR=$(mktemp -d)
function start_singularity_backfill {
    useradd -mG docker testuser
    singularity=/cvmfs/oasis.opensciencegrid.org/mis/apptainer/bin/apptainer
    echo -n "Singularity version is: "
    $singularity version
    chown testuser: $SINGULARITY_OUTPUT $PILOT_DIR
    su - testuser -c \
       "APPTAINERENV_TOKEN=None \
       APPTAINERENV_GLIDEIN_Site=None \
       APPTAINERENV_GLIDEIN_ResourceName=None \
       APPTAINERENV_GLIDEIN_Start_Extra=True \
       $singularity \
          run \
            -B /cvmfs \
            -B $PILOT_DIR:/pilot \
            -cip \
            docker-daemon:$CONTAINER_IMAGE > $SINGULARITY_OUTPUT 2>&1 &"
}

function start_docker_backfill {
    touch $OSP_TOKEN_PATH
    docker $COMMON_DOCKER_ARGS \
           "$@" \
           "$CONTAINER_IMAGE"
}

function run_inside_backfill_container {
    if ! docker exec backfill /bin/true &>/dev/null; then
        return $ABORT_CODE
    else
        docker exec backfill "$@"
    fi
}

function debug_docker_backfill {
    docker ps -a
    docker logs backfill
}

function docker_exit_with_cleanup {
    ret=${1:-0}
    docker rm -f backfill || :
    exit $ret
}

function print_test_header {
    msg=$*
    sep=$(python -c "print ('=' * ${#msg})")
    echo -e "$sep\n$msg\n$sep"
}

function condor_version_in_range {
    local minimum maximum
    minimum=${1:?minimum not provided to condor_version_in_range}
    maximum=${2:-99.99.99}

    local condor_version
    condor_version=$(run_inside_backfill_container condor_version | awk '/CondorVersion/ {print $2}')
    python3 -c '
import sys
minimum = [int(x) for x in sys.argv[1].split(".")]
maximum = [int(x) for x in sys.argv[2].split(".")]
version = [int(x) for x in sys.argv[3].split(".")]
sys.exit(0 if minimum <= version <= maximum else 1)
' "$minimum" "$maximum" "$condor_version"
}

function wait_for_output {
    set +x
    maxtime="$1"
    shift
    for (( i=0; i<$maxtime; ++i )); do
        out=$("$@"); ret=$?
        if [[ -n $out ]]; then
            echo "$out"
            set -x
            if [[ $ret -eq $ABORT_CODE ]]; then
                return $ABORT_CODE
            else
                return 0
            fi
        fi
        if [[ $ret -eq $ABORT_CODE ]]; then
            return $ABORT_CODE
        fi
        sleep 1
    done
    set -x
    return 1
}

function test_docker_startup {
    print_test_header "Testing container startup"

    logfile=$(wait_for_output 600 run_inside_backfill_container find /pilot -name StartLog -size +1); ret=$?
    if [[ $ret -eq $ABORT_CODE ]]; then
        echo >&2 "Container check failed, aborting"
        debug_docker_backfill
        return $ABORT_CODE
    fi

    if [[ -z $logfile ]]; then
        debug_docker_backfill
        return 1
    fi

    wait_for_output 60 \
                    run_inside_backfill_container \
                        grep \
                        -- \
                        'Changing activity: Benchmarking -> Idle' \
                        $logfile; ret=$?
    if [[ $ret != 0 ]]; then
        run_inside_backfill_container tail -n 400 $logfile
        if [[ $ret -eq $ABORT_CODE ]]; then
            debug_docker_backfill
            return $ABORT_CODE
        else
            return 1
        fi
    fi
}

function test_docker_HAS_SINGULARITY {
    print_test_header "Testing singularity detection inside the backfill container"

    # Condor 23.8 has a bug where condor_status -direct for startd ads still
    # attempts to contact the collector.  Hopefully it will be fixed in 23.10;
    # in the meantime, use -pool instead of -direct (which is a hack).
    local direct
    if condor_version_in_range 23.8.0 23.10.0; then
        direct="-pool"
    else
        direct="-direct"
    fi

    logdir=$(run_inside_backfill_container find /pilot -type d -name log); ret=$?
    [[ $ret -eq $ABORT_CODE ]] && { debug_docker_backfill; return $ABORT_CODE; }
    startd_addr=$(run_inside_backfill_container condor_who -log $logdir -dae | awk '/^Startd/ {print $6}'); ret=$?
    [[ $ret -eq $ABORT_CODE ]] && { debug_docker_backfill; return $ABORT_CODE; }
    echo "startd addr: $startd_addr"
    has_singularity=$(run_inside_backfill_container \
        env _CONDOR_SEC_CLIENT_AUTHENTICATION_METHODS=FS \
        condor_status -slot "$direct" "$startd_addr" -af HAS_SINGULARITY \
    ); ret=$?
    [[ $ret -eq $ABORT_CODE ]] && { debug_docker_backfill; return $ABORT_CODE; }
    if [[ $has_singularity == 'true' ]]; then
        return 0
    fi

    debug_docker_backfill
    return 1
}

function test_singularity_startup {
    print_test_header "Testing container startup"

    logfile=$(wait_for_output 1200 find $PILOT_DIR -name StartLog -size +1)
    if [[ -z $logfile ]]; then
        cat $SINGULARITY_OUTPUT
        return 1
    fi

    wait_for_output 60 \
                    grep \
                    -- \
                    'Changing activity: Benchmarking -> Idle' \
                    $logfile \
        || (tail -n 400 $logfile && return 1)
}

function test_singularity_HAS_SINGULARITY {
    print_test_header "Testing singularity detection inside the backfill container"

    egrep -i 'HAS_SINGULARITY *= *True' $SINGULARITY_OUTPUT; ret=$?
    if [[ $ret -ne 0 ]]; then
        cat $SINGULARITY_OUTPUT
    fi
    return $ret
}

if [[ $# -ne 3 ]] ||
       ! [[ $1 =~ ^(docker|singularity)$ ]] ||
       ! [[ $2 =~ ^(bindmount|cvmfsexec)$ ]]; then
    usage
    exit 1
fi

CONTAINER_RUNTIME="$1"
CVMFS_INSTALL="$2"
CONTAINER_IMAGE="$3"

case "$CVMFS_INSTALL" in
    bindmount)
        DOCKER_EXTRA_ARGS=(--security-opt seccomp=unconfined
                           --security-opt systempaths=unconfined
                           --security-opt no-new-privileges
                           -v "/cvmfs:/cvmfs:shared")
        ;;
    cvmfsexec)
        DOCKER_EXTRA_ARGS=(--privileged
                           -e CVMFSEXEC_REPOS='oasis.opensciencegrid.org singularity.opensciencegrid.org'
                           -e CVMFSEXEC_DEBUG=true)
        ;;
esac

case "$CONTAINER_RUNTIME" in
    docker)
        start_docker_backfill "${DOCKER_EXTRA_ARGS[@]}" || docker_exit_with_cleanup $?
        test_docker_startup                             || docker_exit_with_cleanup $?
        test_docker_HAS_SINGULARITY                     || docker_exit_with_cleanup $?
        docker stop backfill
        docker_exit_with_cleanup 0
        ;;
    singularity)
        # we only support Singularity + bind mounted CVMFS
        [[ "$CVMFS_INSTALL" == "bindmount" ]]           || exit 1
        start_singularity_backfill                      || exit 1
        test_singularity_startup                        || exit 1
        test_singularity_HAS_SINGULARITY                || exit 1
        ;;
esac
