// server.h -- the per-session FUSE server and its control socket (docs/MKKITFS.md).
#pragma once
namespace srv {
int serveMain(int argc, char **argv);   // mkkitfs serve --mountpoint DIR ...: orders on stdin (from mkkitfsd)

}
