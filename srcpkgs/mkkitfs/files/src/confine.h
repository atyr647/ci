// confine -- what mkkitfs may still do once it starts reading kits (docs/MKKITFS.md section 10,
// KIT-round2.md section 2.4 item 4): no_new_privs, a Landlock domain (read-only file access, no TCP,
// no signals or abstract sockets outside the domain) and a seccomp allowlist.  The parser of
// untrusted kits runs only after apply(); a bug in it can then read files, but not write, execute,
// connect, mount, trace or load anything.
#pragma once
#include <string>

namespace confine {

enum class Profile {
  Reader,    // the command-line readers and the server's isolated first parse: read files, write stdout
  Extract,   // Reader, plus creating files, directories and links beneath one directory
  Server,    // the FUSE data path: /dev/fuse, threads, and starting its own checker (this executable only)
};

struct Result {
  bool seccomp = false;   // the seccomp filter is in place (apply fails otherwise)
  int landlock = 0;       // the Landlock ABI the domain was built for; 0: the kernel has none (or it is off)
  std::string describe() const;   // "seccomp landlock-6", or "seccomp no-landlock"
};

// Confine this process (and everything it starts) for good.  dir: the directory Extract may write
// beneath.  Throws std::runtime_error when the confinement cannot be put in place; a kernel without
// Landlock is not an error (Result::landlock is then 0), a kernel that refuses seccomp is.
Result apply(Profile p, const std::string &dir = "");

// Before the server confines itself: a small process that unmounts MOUNTPOINT once the server is
// gone, however it ends (a confined server can neither call umount2 nor run fusermount3).  It holds
// nothing but the read end of a pipe; the server keeps the write end open for its whole life.
// Returns false (errno set) if it could not be started.
bool unmountGuard(const std::string &mountpoint);

}  // namespace confine
