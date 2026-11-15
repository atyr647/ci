/* kit-landlock: the Landlock layer of kit run's sandbox (docs/KIT.md D6 C: bubblewrap now, a
 * small Landlock helper on top).  kit runs it inside the bubblewrap sandbox as the first program;
 * it restricts itself and then executes the kit's entry point, which inherits the restriction
 * and can never lift it.
 *
 *   kit-landlock --abi                         print the kernel's Landlock ABI (0: none), exit 0
 *   kit-landlock [--rw PATH]... [--no-tcp] -- PROGRAM [ARG]...
 *   kit-landlock --no-landlock -- PROGRAM [ARG]...
 *
 * Either way the program holds no descriptor but 0, 1 and 2: every other one this helper
 * inherited (from bubblewrap, and through it from whatever started kit) is closed before the
 * exec, so nothing open outside the sandbox (a directory, a socket) reaches the app.  kit passes
 * nothing else to an app on purpose.  --no-landlock does only that, for a kernel without
 * Landlock.
 *
 * What the program gets from the Landlock layer:
 *   - reading and executing anywhere in the sandbox (bubblewrap decides what is there);
 *   - writing (creating, removing, renaming, truncating) only beneath each --rw PATH; a PATH that
 *     does not exist is skipped (a folder grant whose folder is missing);
 *   - device ioctls only beneath a --rw PATH (ABI 5), so /dev is passed as one;
 *   - never creating device nodes;
 *   - with --no-tcp, no TCP bind or connect at all (ABI 4; the sandbox also has no network);
 *   - no connecting to abstract UNIX sockets made outside the sandbox (an X server's or a bus's
 *     "@" address, reachable through a shared network namespace) and no signals to processes
 *     outside it (ABI 6).
 * Rights the kernel's ABI does not know are left out, so on an older kernel the layer is weaker,
 * never refused.  Where the kernel has no Landlock at all kit does not run this helper (--abi
 * says 0).  Any failure to restrict is fatal (exit 126): a program never runs less confined
 * than kit asked for.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SYS_landlock_create_ruleset
#define SYS_landlock_create_ruleset 444
#define SYS_landlock_add_rule 445
#define SYS_landlock_restrict_self 446
#endif

/* the kernel's ABI, spelled out here so the helper does not depend on the build host's headers */
#define CREATE_RULESET_VERSION (1U << 0)
#define RULE_PATH_BENEATH 1

#define FS_EXECUTE (1ULL << 0)
#define FS_WRITE_FILE (1ULL << 1)
#define FS_READ_FILE (1ULL << 2)
#define FS_READ_DIR (1ULL << 3)
#define FS_REMOVE_DIR (1ULL << 4)
#define FS_REMOVE_FILE (1ULL << 5)
#define FS_MAKE_CHAR (1ULL << 6)
#define FS_MAKE_DIR (1ULL << 7)
#define FS_MAKE_REG (1ULL << 8)
#define FS_MAKE_SOCK (1ULL << 9)
#define FS_MAKE_FIFO (1ULL << 10)
#define FS_MAKE_BLOCK (1ULL << 11)
#define FS_MAKE_SYM (1ULL << 12)
#define FS_REFER (1ULL << 13)    /* ABI 2 */
#define FS_TRUNCATE (1ULL << 14) /* ABI 3 */
#define FS_IOCTL_DEV (1ULL << 15) /* ABI 5 */

#define NET_BIND_TCP (1ULL << 0)    /* ABI 4 */
#define NET_CONNECT_TCP (1ULL << 1) /* ABI 4 */

#define SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0) /* ABI 6 */
#define SCOPE_SIGNAL (1ULL << 1)               /* ABI 6 */

struct ruleset_attr {
	uint64_t handled_access_fs;
	uint64_t handled_access_net; /* ABI 4 */
	uint64_t scoped;             /* ABI 6 */
};

struct path_beneath_attr {
	uint64_t allowed_access;
	int32_t parent_fd;
} __attribute__((packed));

static int abi(void)
{
	long v = syscall(SYS_landlock_create_ruleset, NULL, 0, CREATE_RULESET_VERSION);
	return v < 0 ? 0 : (int)v;
}

static void die(const char *what)
{
	fprintf(stderr, "kit-landlock: %s: %s\n", what, strerror(errno));
	exit(126);
}

/* Close every descriptor above 2: close_range where the kernel has it (5.9), else each one
 * /proc/self/fd lists.  Failing to is fatal, like failing to restrict. */
static void close_inherited(void)
{
#ifdef SYS_close_range
	if (syscall(SYS_close_range, 3U, ~0U, 0U) == 0) return;
#endif
	DIR *d = opendir("/proc/self/fd");
	if (!d) die("/proc/self/fd");
	int self = dirfd(d), fds[1024], n = 0, more = 1;
	while (more) {
		struct dirent *e;
		more = 0;
		n = 0;
		rewinddir(d);
		while ((e = readdir(d)) != NULL) {
			char *end;
			long fd = strtol(e->d_name, &end, 10);
			if (*end || end == e->d_name || fd <= 2 || fd == self) continue;
			if (n == (int)(sizeof fds / sizeof fds[0])) { more = 1; break; }
			fds[n++] = (int)fd;
		}
		for (int k = 0; k < n; k++) close(fds[k]);
	}
	closedir(d);
}

static void usage(void)
{
	fputs("usage: kit-landlock --abi | kit-landlock [--rw PATH]... [--no-tcp] -- PROGRAM [ARG]...\n"
	      "       kit-landlock --no-landlock -- PROGRAM [ARG]...\n", stderr);
	exit(2);
}

static void allow(int rs, const char *path, uint64_t access)
{
	struct path_beneath_attr pb;
	int fd = open(path, O_PATH | O_CLOEXEC);
	if (fd < 0) {
		if (errno == ENOENT || errno == ENOTDIR) return; /* nothing there to allow */
		die(path);
	}
	pb.allowed_access = access;
	pb.parent_fd = fd;
	/* a rule on a file (not a directory) may only carry file rights */
	if (syscall(SYS_landlock_add_rule, rs, RULE_PATH_BENEATH, &pb, 0) != 0) {
		if (errno == EINVAL) {
			pb.allowed_access = access & (FS_EXECUTE | FS_WRITE_FILE | FS_READ_FILE | FS_TRUNCATE | FS_IOCTL_DEV);
			if (syscall(SYS_landlock_add_rule, rs, RULE_PATH_BENEATH, &pb, 0) == 0) { close(fd); return; }
		}
		die(path);
	}
	close(fd);
}

int main(int argc, char **argv)
{
	const char *rw[256];
	int nrw = 0, notcp = 0, nolandlock = 0, i;

	if (argc == 2 && strcmp(argv[1], "--abi") == 0) {
		printf("%d\n", abi());
		return 0;
	}
	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--") == 0) { i++; break; }
		if (strcmp(argv[i], "--rw") == 0 && i + 1 < argc) {
			if (nrw == (int)(sizeof rw / sizeof rw[0])) { fputs("kit-landlock: too many --rw paths\n", stderr); return 2; }
			rw[nrw++] = argv[++i];
		} else if (strcmp(argv[i], "--no-tcp") == 0) {
			notcp = 1;
		} else if (strcmp(argv[i], "--no-landlock") == 0) {
			nolandlock = 1;
		} else {
			usage();
		}
	}
	if (i >= argc || (nolandlock && (nrw || notcp))) usage();

	close_inherited();
	if (nolandlock) {
		execvp(argv[i], argv + i);
		fprintf(stderr, "kit-landlock: %s: %s\n", argv[i], strerror(errno));
		return 127;
	}

	int v = abi();
	if (v < 1) { errno = EOPNOTSUPP; die("Landlock"); }

	uint64_t rd = FS_EXECUTE | FS_READ_FILE | FS_READ_DIR;
	uint64_t wr = FS_WRITE_FILE | FS_REMOVE_DIR | FS_REMOVE_FILE | FS_MAKE_DIR | FS_MAKE_REG | FS_MAKE_SOCK |
	                 FS_MAKE_FIFO | FS_MAKE_SYM;
	uint64_t never = FS_MAKE_CHAR | FS_MAKE_BLOCK;
	if (v >= 2) wr |= FS_REFER;
	if (v >= 3) wr |= FS_TRUNCATE;
	if (v >= 5) wr |= FS_IOCTL_DEV;

	struct ruleset_attr attr = {0};
	size_t size = sizeof attr.handled_access_fs;
	attr.handled_access_fs = rd | wr | never;
	if (v >= 4) {
		size = offsetof(struct ruleset_attr, scoped);
		if (notcp) attr.handled_access_net = NET_BIND_TCP | NET_CONNECT_TCP;
	}
	if (v >= 6) {
		size = sizeof attr;
		attr.scoped = SCOPE_ABSTRACT_UNIX_SOCKET | SCOPE_SIGNAL;
	}
	int rs = (int)syscall(SYS_landlock_create_ruleset, &attr, size, 0);
	if (rs < 0) die("landlock_create_ruleset");
	allow(rs, "/", rd);
	for (int k = 0; k < nrw; k++) allow(rs, rw[k], rd | wr);
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) die("no_new_privs");
	if (syscall(SYS_landlock_restrict_self, rs, 0) != 0) die("landlock_restrict_self");
	close(rs);
	execvp(argv[i], argv + i);
	fprintf(stderr, "kit-landlock: %s: %s\n", argv[i], strerror(errno));
	return 127;
}
