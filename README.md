# OSGVO Pilot Container

A Docker container build emulating a worker node for the OSG VO, using token authentication.
See the official documentation for how to use this container:

- [Site backfill](https://opensciencegrid.org/docs/resource-sharing/os-backfill-containers/)
- [User allocations](https://opensciencegrid.org/docs/resource-sharing/user-containers/)

## `cvmfsexec` Notes

-  Note that cvmfsexec will not be run if CVMFS repos are already available in `/cvmfs` via bind-mount,
   regardless of the value of `CVMFSEXEC_REPOS`.
-  Using `cvmfsexec` takes place in the entrypoint, which means it will still happen
   even if you specify a different command to run, such as `bash`.
   You can bypass the entrypoint by passing `--entrypoint <cmd>` where `<cmd>` is some different command to run,
   e.g. `--entrypoint bash`.
   Setting the entrypoint this way clears the command.
