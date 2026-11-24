// confine -- seccomp, Landlock and no_new_privs for mkkitfs (confine.h).
//
// seccomp: an allowlist built by hand as classic BPF (no libseccomp at build or run time).  Anything
// not on the list fails with ENOSYS (what a kernel without the call says, so library fallbacks still
// work); a foreign architecture or an x32 call kills the process.  clone3 is left off on purpose: its
// flags live in memory a filter cannot read, and glibc falls back to clone, whose flags are checked
// (no new namespaces).  ioctl is limited to the few requests mkkitfs makes.
//
// Landlock: built for the newest ABI the kernel offers (1 to 6 are known here); the domain handles
// every file right of that ABI and grants read access to everything, execute only on this
// executable and its ELF interpreter (the server's checker is this program), /dev/fuse for the
// server, and the create rights beneath one directory for extract.  ABI 4 adds TCP bind/connect
// (handled, never granted), ABI 6 scopes abstract unix sockets and signals to the domain.
#include "confine.h"

#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <link.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sched.h>
#include <signal.h>
#include <stdexcept>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <vector>

namespace confine {
namespace {

// ---- Landlock (constants from linux/landlock.h; older headers lack the newer ones) ----------------
constexpr uint64_t FS_EXECUTE = 1ULL << 0, FS_WRITE_FILE = 1ULL << 1, FS_READ_FILE = 1ULL << 2, FS_READ_DIR = 1ULL << 3,
                   FS_REMOVE_DIR = 1ULL << 4, FS_REMOVE_FILE = 1ULL << 5, FS_MAKE_CHAR = 1ULL << 6, FS_MAKE_DIR = 1ULL << 7,
                   FS_MAKE_REG = 1ULL << 8, FS_MAKE_SOCK = 1ULL << 9, FS_MAKE_FIFO = 1ULL << 10, FS_MAKE_BLOCK = 1ULL << 11,
                   FS_MAKE_SYM = 1ULL << 12, FS_REFER = 1ULL << 13, FS_TRUNCATE = 1ULL << 14, FS_IOCTL_DEV = 1ULL << 15;
constexpr uint64_t NET_BIND_TCP = 1ULL << 0, NET_CONNECT_TCP = 1ULL << 1;
constexpr uint64_t SCOPE_ABSTRACT_UNIX = 1ULL << 0, SCOPE_SIGNAL = 1ULL << 1;
constexpr uint32_t CREATE_RULESET_VERSION = 1U << 0;
constexpr int RULE_PATH_BENEATH = 1;

struct RulesetAttr { uint64_t fs, net, scoped; };
struct __attribute__((packed)) PathBeneath { uint64_t allowed; int32_t fd; };

#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#define __NR_landlock_add_rule 445
#define __NR_landlock_restrict_self 446
#endif

uint64_t fsRights(int abi) {
  uint64_t r = (FS_MAKE_SYM << 1) - 1;   // ABI 1: bits 0..12
  if (abi >= 2) r |= FS_REFER;
  if (abi >= 3) r |= FS_TRUNCATE;
  if (abi >= 5) r |= FS_IOCTL_DEV;
  return r;
}

constexpr uint64_t kFileRights = FS_EXECUTE | FS_WRITE_FILE | FS_READ_FILE | FS_TRUNCATE | FS_IOCTL_DEV;

void addRule(int ruleset, const char *path, uint64_t allowed, uint64_t handled, bool optional) {
  int fd = open(path, O_PATH | O_CLOEXEC);
  if (fd < 0) {
    if (optional) return;
    throw std::runtime_error(std::string("landlock: cannot open ") + path + ": " + strerror(errno));
  }
  struct stat sb;
  if (fstat(fd, &sb) == 0 && !S_ISDIR(sb.st_mode)) allowed &= kFileRights;   // files take file rights only
  PathBeneath pb = {allowed & handled, fd};
  long rc = syscall(__NR_landlock_add_rule, ruleset, RULE_PATH_BENEATH, &pb, 0);
  int e = errno;
  close(fd);
  if (rc) throw std::runtime_error(std::string("landlock: rule for ") + path + ": " + strerror(e));
}

// the program's ELF interpreter (PT_INTERP), which execve opens with execute access too
std::string interpreter() {
  std::string out;
  dl_iterate_phdr([](struct dl_phdr_info *info, size_t, void *data) -> int {
    for (int i = 0; i < info->dlpi_phnum; ++i)
      if (info->dlpi_phdr[i].p_type == PT_INTERP) *(std::string *)data = (const char *)(info->dlpi_addr + info->dlpi_phdr[i].p_vaddr);
    return 1;   // the first object is the program itself
  }, &out);
  return out;
}

int landlock(Profile p, const std::string &dir) {
  long abi = syscall(__NR_landlock_create_ruleset, nullptr, 0, CREATE_RULESET_VERSION);
  if (abi < 0) {
    if (errno == ENOSYS || errno == EOPNOTSUPP) return 0;   // not built in, or not in the LSM list
    throw std::runtime_error(std::string("landlock: ") + strerror(errno));
  }
  if (abi > 6) abi = 6;   // what this code knows; a newer kernel takes the known part
  RulesetAttr attr = {fsRights((int)abi), 0, 0};
  size_t size = sizeof attr.fs;
  if (abi >= 4) { attr.net = NET_BIND_TCP | NET_CONNECT_TCP; size = offsetof(RulesetAttr, scoped); }
  if (abi >= 6) { attr.scoped = SCOPE_ABSTRACT_UNIX | SCOPE_SIGNAL; size = sizeof attr; }
  int rs = (int)syscall(__NR_landlock_create_ruleset, &attr, size, 0);
  if (rs < 0) throw std::runtime_error(std::string("landlock: cannot create a ruleset: ") + strerror(errno));
  try {
    addRule(rs, "/", FS_READ_FILE | FS_READ_DIR, attr.fs, false);
    if (p == Profile::Extract)
      addRule(rs, dir.c_str(), FS_READ_FILE | FS_READ_DIR | FS_WRITE_FILE | FS_TRUNCATE | FS_MAKE_DIR | FS_MAKE_REG | FS_MAKE_SYM | FS_REMOVE_FILE,
              attr.fs, false);
    if (p == Profile::Server) {
      addRule(rs, "/proc/self/exe", FS_EXECUTE | FS_READ_FILE, attr.fs, false);
      std::string interp = interpreter();
      if (!interp.empty()) addRule(rs, interp.c_str(), FS_EXECUTE | FS_READ_FILE, attr.fs, false);
      addRule(rs, "/dev/fuse", FS_READ_FILE | FS_WRITE_FILE | FS_IOCTL_DEV, attr.fs, false);
    }
    if (syscall(__NR_landlock_restrict_self, rs, 0)) throw std::runtime_error(std::string("landlock: ") + strerror(errno));
  } catch (...) {
    close(rs);
    throw;
  }
  close(rs);
  return (int)abi;
}

// ---- seccomp ----------------------------------------------------------------------------------
#if defined(__x86_64__)
constexpr uint32_t kArch = AUDIT_ARCH_X86_64;
#elif defined(__aarch64__)
constexpr uint32_t kArch = AUDIT_ARCH_AARCH64;
#elif defined(__riscv) && __riscv_xlen == 64
constexpr uint32_t kArch = AUDIT_ARCH_RISCV64;
#else
#error "confine.cpp: add this architecture's AUDIT_ARCH"
#endif

struct Bpf {
  std::vector<sock_filter> f;
  void stmt(uint16_t code, uint32_t k) { f.push_back(BPF_STMT(code, k)); }
  void jump(uint16_t code, uint32_t k, uint8_t jt, uint8_t jf) { f.push_back(BPF_JUMP(code, k, jt, jf)); }
  void loadNr() { stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)); }
  void loadArg(int i) { stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args) + 8 * i); }   // low word (little-endian)
  void allow(long nr) { jump(BPF_JMP | BPF_JEQ | BPF_K, (uint32_t)nr, 0, 1); stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW); }
  // nr: an argument (low 32 bits) must be one of vals, else ERRNO(err)
  void allowArgIn(long nr, int arg, std::initializer_list<uint32_t> vals, int err) {
    jump(BPF_JMP | BPF_JEQ | BPF_K, (uint32_t)nr, 0, (uint8_t)(2 * vals.size() + 2));
    loadArg(arg);
    for (uint32_t v : vals) { jump(BPF_JMP | BPF_JEQ | BPF_K, v, 0, 1); stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW); }
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (uint32_t)err);
    loadNr();
  }
  // nr: allowed unless an argument (low 32 bits) has one of the bits in mask, which is ERRNO(err)
  void allowArgNoBits(long nr, int arg, uint32_t mask, int err) {
    jump(BPF_JMP | BPF_JEQ | BPF_K, (uint32_t)nr, 0, 4);
    loadArg(arg);
    jump(BPF_JMP | BPF_JSET | BPF_K, mask, 0, 1);
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (uint32_t)err);
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
  }
};

#ifndef FUSE_DEV_IOC_CLONE
#define FUSE_DEV_IOC_CLONE _IOR(229, 0, uint32_t)
#endif

void seccompFilter(Profile p) {
  Bpf b;
  b.stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
  b.jump(BPF_JMP | BPF_JEQ | BPF_K, kArch, 1, 0);
  b.stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
  b.loadNr();
#if defined(__x86_64__)
  b.jump(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1);   // the x32 ABI
  b.stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
#endif
  const long common[] = {
    SYS_read, SYS_write, SYS_readv, SYS_writev, SYS_pread64, SYS_preadv, SYS_lseek, SYS_close, SYS_openat, SYS_fstat,
    SYS_newfstatat, SYS_readlinkat, SYS_getcwd, SYS_faccessat, SYS_fcntl, SYS_mmap, SYS_munmap, SYS_mremap, SYS_mprotect,
    SYS_madvise, SYS_brk, SYS_futex, SYS_set_robust_list, SYS_set_tid_address, SYS_exit, SYS_exit_group, SYS_rt_sigaction,
    SYS_rt_sigprocmask, SYS_rt_sigreturn, SYS_sigaltstack, SYS_getpid, SYS_gettid, SYS_getppid, SYS_getuid, SYS_geteuid,
    SYS_getgid, SYS_getegid, SYS_prlimit64, SYS_getrandom, SYS_clock_gettime, SYS_clock_getres, SYS_gettimeofday,
    SYS_nanosleep, SYS_clock_nanosleep, SYS_sched_yield, SYS_sched_getaffinity, SYS_uname, SYS_ppoll, SYS_dup, SYS_dup3,
    SYS_tgkill, SYS_getdents64, SYS_membarrier, SYS_seccomp,
    SYS_pipe2,   // also how the sanitizers probe whether memory is readable (make fuzz runs them confined)
    __NR_landlock_create_ruleset, __NR_landlock_add_rule, __NR_landlock_restrict_self,
#ifdef SYS_rseq
    SYS_rseq,
#endif
#ifdef SYS_statx
    SYS_statx,
#endif
#ifdef SYS_preadv2
    SYS_preadv2,
#endif
#ifdef SYS_faccessat2
    SYS_faccessat2,
#endif
#ifdef SYS_fadvise64
    SYS_fadvise64,
#endif
#if defined(__x86_64__)
    SYS_open, SYS_stat, SYS_lstat, SYS_readlink, SYS_access, SYS_poll, SYS_dup2, SYS_time, SYS_arch_prctl, SYS_pipe,
#endif
  };
  for (long nr : common) b.allow(nr);
  // prctl: no_new_privs (a later, stricter confinement) and the thread name
  b.allowArgIn(SYS_prctl, 0, {PR_SET_NO_NEW_PRIVS, PR_GET_NO_NEW_PRIVS, PR_SET_NAME, PR_GET_NAME}, EPERM);
  if (p == Profile::Extract) {
    const long ex[] = {SYS_mkdirat, SYS_symlinkat, SYS_unlinkat, SYS_fchmod, SYS_fchmodat, SYS_utimensat,
#if defined(__x86_64__)
                       SYS_mkdir, SYS_symlink, SYS_unlink, SYS_chmod,
#endif
#ifdef SYS_fchmodat2
                       SYS_fchmodat2,
#endif
    };
    for (long nr : ex) b.allow(nr);
  }
  if (p == Profile::Server) {
    const long sv[] = {SYS_execve, SYS_wait4, SYS_waitid, SYS_kill};
    for (long nr : sv) b.allow(nr);
    // threads and the checker's vfork-style spawn, never with new namespaces
    b.allowArgNoBits(SYS_clone, 0, CLONE_NEWNS | CLONE_NEWCGROUP | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNET, EPERM);
    b.allowArgIn(SYS_ioctl, 1, {(uint32_t)TCGETS, (uint32_t)FUSE_DEV_IOC_CLONE}, ENOTTY);
  } else {
    b.allowArgIn(SYS_ioctl, 1, {(uint32_t)TCGETS}, ENOTTY);   // isatty() on stdout
  }
  b.stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS);
  if (b.f.size() > BPF_MAXINSNS) throw std::runtime_error("seccomp: the filter is too long");
  struct sock_fprog prog = {(unsigned short)b.f.size(), b.f.data()};
  if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog))
    throw std::runtime_error(std::string("seccomp: cannot install the filter: ") + strerror(errno));
}

}  // namespace

std::string Result::describe() const {
  return std::string(seccomp ? "seccomp" : "no-seccomp") + (landlock ? " landlock-" + std::to_string(landlock) : " no-landlock");
}

Result apply(Profile p, const std::string &dir) {
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) throw std::runtime_error(std::string("no_new_privs: ") + strerror(errno));
  Result r;
  r.landlock = landlock(p, dir);
  seccompFilter(p);
  r.seccomp = true;
  return r;
}

constexpr long kFuseMagic = 0x65735546;   // FUSE_SUPER_MAGIC

bool unmountGuard(const std::string &mountpoint) {
  int pfd[2];
  if (pipe2(pfd, O_CLOEXEC)) return false;
  pid_t pid = fork();
  if (pid < 0) { int e = errno; close(pfd[0]); close(pfd[1]); errno = e; return false; }
  if (pid == 0) {
    // the guard: nothing but the pipe's read end (stdin and stdout are mkkitfsd's pipe; holding
    // them would hide the server's exit from it), out of the mount point, in its own process group
    // so a terminal's ^C reaches the server only
    setpgid(0, 0);
    if (chdir("/")) {}
    int nul = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (nul >= 0) { dup2(nul, 0); dup2(nul, 1); }
    if (dup2(pfd[0], 3) < 0) _exit(1);
    for (int fd = 4; fd < 1024; ++fd) close(fd);
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
    char c;
    while (read(3, &c, 1) < 0 && errno == EINTR) {}   // EOF: the server is gone
    if (geteuid() == 0) {
      // only a FUSE mount, dead (ENOTCONN) or not: if the server's mount was already taken away, what
      // is at the mount point now (the mount it sat on, or another one) is not this guard's to remove.
      // fusermount3 below makes the same check for itself.
      struct statfs sf;
      bool fuse = statfs(mountpoint.c_str(), &sf) ? errno == ENOTCONN : sf.f_type == kFuseMagic;
      if (fuse) umount2(mountpoint.c_str(), MNT_DETACH);
      _exit(0);
    }
    execlp("fusermount3", "fusermount3", "-u", "-q", "-z", "--", mountpoint.c_str(), (char *)nullptr);
    _exit(127);
  }
  close(pfd[0]);
  // the write end stays open as long as the server runs; CLOEXEC keeps it out of the checker
  // processes, so only the server's own end decides
  return true;
}

}  // namespace confine
