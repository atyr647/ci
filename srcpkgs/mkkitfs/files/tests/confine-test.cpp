// confine-test -- checks src/confine.cpp on its own (no Metakit, no FUSE): each profile is applied in
// a child process, which then tries what the profile must allow and what it must refuse.
//   confine-test WORKDIR        prints "  ok"/"  FAIL"/"  skip" lines; exit 1 if anything failed
// With CONFINE_TEST_MOUNT=1 (root, in a private mount namespace: tests/run.sh runs it under unshare)
// the unmount guard is checked too, on a tmpfs.
#include "../src/confine.h"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <netinet/in.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <spawn.h>
#include <stdexcept>
#include <string>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <termios.h>
#include <thread>
#include <unistd.h>

extern char **environ;
static int failures = 0;
static std::string work;

static void report(bool good, const std::string &what) {
  printf("  %s %s\n", good ? "ok  " : "FAIL", what.c_str());
  if (!good) failures++;
}

// errno of a call that returns -1 on failure; 0 when it succeeded
#define ERR(expr) ((expr) < 0 ? errno : 0)

static std::string status(const char *key) {
  std::ifstream in("/proc/self/status");
  std::string l;
  while (std::getline(in, l))
    if (!l.compare(0, strlen(key), key)) return l.substr(l.find(':') + 1).erase(0, l.substr(l.find(':') + 1).find_first_not_of(" \t"));
  return "";
}

static int spawnWait(const char *path, char *const argv[]) {
  pid_t pid;
  int rc = posix_spawn(&pid, path, nullptr, nullptr, argv, environ);
  if (rc) return -rc;
  int st = 0;
  waitpid(pid, &st, 0);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}

// run fn in a child: its lines go to our stdout, its failures come back in the exit status
template <class F> static void inChild(const char *name, F fn) {
  fflush(stdout);
  pid_t pid = fork();
  if (pid == 0) { failures = 0; fn(); fflush(stdout); _exit(failures ? 1 : 0); }
  int st = 0;
  waitpid(pid, &st, 0);
  if (!WIFEXITED(st)) report(false, std::string(name) + ": the child died (signal " + std::to_string(WTERMSIG(st)) + ")");
  else if (WEXITSTATUS(st)) failures++;
}

static confine::Result applyOrDie(confine::Profile p, const std::string &dir = "") {
  try { return confine::apply(p, dir); }
  catch (const std::exception &e) { report(false, std::string("apply: ") + e.what()); fflush(stdout); _exit(1); }
}

static void common(const char *name, const confine::Result &r) {
  std::string n = name;
  report(r.seccomp && status("Seccomp") == "2", n + ": seccomp filter mode (" + r.describe() + ")");
  report(status("NoNewPrivs") == "1", n + ": no_new_privs");
  int fd = open((work + "/readable").c_str(), O_RDONLY | O_CLOEXEC);
  char b[16] = {0};
  report(fd >= 0 && read(fd, b, sizeof b) == 5 && !memcmp(b, "hello", 5), n + ": reads files");
  if (fd >= 0) close(fd);
  int e = ERR(socket(AF_INET, SOCK_STREAM, 0));
  report(e == ENOSYS, n + ": no sockets (" + strerror(e) + ")");
  e = ERR(socket(AF_UNIX, SOCK_STREAM, 0));
  report(e == ENOSYS, n + ": no unix sockets either (" + strerror(e) + ")");
  e = ERR(mount("none", work.c_str(), "tmpfs", 0, nullptr));
  report(e == ENOSYS, n + ": no mount (" + strerror(e) + ")");
  e = ERR(umount2("/", MNT_DETACH));
  report(e == ENOSYS, n + ": no umount (" + strerror(e) + ")");
  e = ERR(ptrace(PTRACE_TRACEME, 0, nullptr, nullptr));
  report(e == ENOSYS, n + ": no ptrace (" + strerror(e) + ")");
  e = ERR(unshare(CLONE_NEWUSER));
  report(e == ENOSYS, n + ": no unshare (" + strerror(e) + ")");
  e = ERR(syscall(SYS_bpf, 0, nullptr, 0));
  report(e == ENOSYS, n + ": no bpf (" + strerror(e) + ")");
  e = ERR(syscall(SYS_clone3, nullptr, 0));
  report(e == ENOSYS, n + ": no clone3 (its flags are out of the filter's reach) (" + strerror(e) + ")");
  e = ERR(prctl(PR_SET_DUMPABLE, 1, 0, 0, 0));
  report(e == EPERM, n + ": prctl only for no_new_privs and names (" + strerror(e) + ")");
  char c = 'x';
  e = ERR(ioctl(0, TIOCSTI, &c));
  report(e == ENOTTY, n + ": no TIOCSTI (" + strerror(e) + ")");
  e = ERR(open((work + "/created-by-" + n).c_str(), O_WRONLY | O_CREAT | O_CLOEXEC, 0600));
  if (r.landlock) report(e == EACCES, n + ": cannot create files (" + strerror(e) + ")");
  else printf("  skip %s: file writes (no Landlock in this kernel)\n", name);
  e = ERR(open((work + "/readable").c_str(), O_WRONLY | O_CLOEXEC));
  if (r.landlock) report(e == EACCES, n + ": cannot write an existing file (" + strerror(e) + ")");
}

int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--exit-7")) return 7;   // the "checker" the server profile starts
  if (argc != 2) { fprintf(stderr, "usage: confine-test WORKDIR\n"); return 2; }
  work = argv[1];
  mkdir((work + "/out").c_str(), 0700);
  { std::ofstream(work + "/readable") << "hello"; }

  inChild("reader", [] {
    confine::Result r = applyOrDie(confine::Profile::Reader);
    common("reader", r);
    char a0[] = "true";
    char *av[] = {a0, nullptr};
    int rc = spawnWait("/bin/true", av);
    report(rc != 0, "reader: cannot start programs (spawn: " + std::to_string(rc) + ")");
    // a second, stricter confinement on top still works (the server's checker does this)
    try { confine::apply(confine::Profile::Reader); report(true, "reader: confines again on top"); }
    catch (const std::exception &e) { report(false, std::string("reader: confining again: ") + e.what()); }
  });

  inChild("extract", [] {
    confine::Result r = applyOrDie(confine::Profile::Extract, work + "/out");
    common("extract", r);
    int fd = open((work + "/out/file").c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    report(fd >= 0 && write(fd, "x", 1) == 1, "extract: creates files beneath its directory");
    if (fd >= 0) { report(fchmod(fd, 0644) == 0, "extract: sets modes"); close(fd); }
    report(mkdir((work + "/out/dir").c_str(), 0700) == 0, "extract: creates directories beneath it");
    report(symlink("file", (work + "/out/link").c_str()) == 0, "extract: creates links beneath it");
    report(unlink((work + "/out/link").c_str()) == 0, "extract: removes what it made (a failed file)");
    int e = ERR(mkdir((work + "/outside").c_str(), 0700));
    if (r.landlock) report(e == EACCES, std::string("extract: nothing outside it (") + strerror(e) + ")");
  });

  inChild("server", [] {
    confine::Result r = applyOrDie(confine::Profile::Server);
    common("server", r);
    bool ran = false;
    std::thread t([&] { ran = true; });
    t.join();
    report(ran, "server: starts threads (clone, after clone3's ENOSYS)");
    char a0[] = "confine-test", a1[] = "--exit-7";
    char *av[] = {a0, a1, nullptr};
    int rc = spawnWait("/proc/self/exe", av);
    report(rc == 7, "server: starts its own executable, the checker (exit " + std::to_string(rc) + ")");
    char b0[] = "true";
    char *bv[] = {b0, nullptr};
    rc = spawnWait("/bin/true", bv);
    if (r.landlock) report(rc != 0, "server: cannot start any other program (spawn: " + std::to_string(rc) + ")");
    int e = ERR(syscall(SYS_clone, CLONE_NEWUSER | SIGCHLD, nullptr, nullptr, nullptr, nullptr));
    report(e == EPERM, std::string("server: no new namespaces through clone (") + strerror(e) + ")");
    if (r.landlock >= 6) {
      e = ERR(kill(getppid(), 0));
      report(e == EPERM, std::string("server: no signals outside its domain (") + strerror(e) + ")");
    }
  });

  if (getenv("CONFINE_TEST_MOUNT") && geteuid() == 0) {
    // the server's mount is a FUSE mount (made here without libfuse) on top of a tmpfs, which is not
    // the server's and must survive it; this process reaps the guard (a subreaper), so a check waits
    // for the guard itself, not for a time
    std::string mp = work + "/mnt";
    mkdir(mp.c_str(), 0700);
    prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
    auto mounted = [&](const char *type) {
      std::ifstream m("/proc/self/mounts");
      std::string l;
      while (std::getline(m, l)) if (l.find(" " + mp + " " + type) != std::string::npos) return true;
      return false;
    };
    auto reapAll = [] { int st; while (waitpid(-1, &st, 0) > 0 || errno == EINTR) {} };
    if (mount("tmpfs", mp.c_str(), "tmpfs", 0, "size=1m")) { report(false, std::string("guard: cannot mount a tmpfs: ") + strerror(errno)); }
    else {
      for (int outside = 0; outside < 2; ++outside) {
        int sync[2];
        if (pipe(sync)) { report(false, "guard: pipe"); break; }
        fflush(stdout);
        pid_t pid = fork();
        if (pid == 0) {
          close(sync[0]);
          if (!confine::unmountGuard(mp)) _exit(3);
          int fd = open("/dev/fuse", O_RDWR | O_CLOEXEC);
          if (fd < 0) _exit(5);
          std::string o = "fd=" + std::to_string(fd) + ",rootmode=40000,user_id=0,group_id=0";
          if (mount("mkkitfs-test", mp.c_str(), "fuse.mkkitfs-test", MS_NOSUID | MS_NODEV, o.c_str())) _exit(6);
          try { confine::apply(confine::Profile::Server); } catch (...) { _exit(4); }
          if (write(sync[1], "m", 1) != 1) _exit(7);
          if (outside) for (;;) ppoll(nullptr, 0, nullptr, nullptr);   // until the parent kills it (pause is not on the list)
          raise(SIGKILL);   // a crash: no clean shutdown at all
        }
        close(sync[1]);
        char c = 0;
        bool up = read(sync[0], &c, 1) == 1;
        close(sync[0]);
        if (outside && up) umount2(mp.c_str(), MNT_DETACH);   // the FUSE mount taken away from outside, as fusermount -u would
        if (outside) kill(pid, SIGKILL);
        int st = 0;
        waitpid(pid, &st, 0);
        reapAll();   // the guard, reparented here
        if (!outside) {
          report(up && WIFSIGNALED(st) && !mounted("fuse") && mounted("tmpfs"),
                 "guard: the FUSE mount goes when a confined server is killed, the mount beneath it stays");
        } else {
          report(up && mounted("tmpfs"), "guard: a server whose mount was already taken away leaves the mount beneath alone");
        }
        while (mounted("fuse")) umount2(mp.c_str(), MNT_DETACH);
      }
      umount2(mp.c_str(), MNT_DETACH);
    }
  } else {
    printf("  skip guard (needs root and CONFINE_TEST_MOUNT=1 in a private mount namespace)\n");
  }
  return failures ? 1 : 0;
}
