/* kit-swapmount -- replace the mount at TARGET by the mount at STAGED, atomically for every new path
 * lookup, keeping the old one alive for whoever still uses it (SYSTEM-UPDATES.md 7.2 and 8.3, D57 C:
 * the merged erofs /usr view's live switch; kit/poc/19-compose/swapmount.c measured it at 0.16 ms).
 *
 *   1. move_mount(STAGED -> TARGET, MOVE_MOUNT_BENEATH): the new view is slid *under* the current top
 *      mount of TARGET (Linux 6.5+);
 *   2. umount2(TARGET, MNT_DETACH): the old top is detached.  Lookups now reach the new view; processes
 *      with open files, mappings or a cwd in the old one keep it, and the kernel frees it (and the
 *      loop devices under it, which kit's mount.tcl marks autoclear) when the last of them is gone.
 *
 * There is no instant at which TARGET is empty or half old, half new.
 *
 *   kit-swapmount STAGED TARGET
 * exit 0 switched; 1 nothing changed (the error is printed); 3 the new view is beneath the old one,
 * which could not be detached (the old one is still what lookups see: detach TARGET to finish);
 * 2 usage.  ribbon-kit's lib/mount.tcl runs this as root (kitd).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef MOVE_MOUNT_BENEATH
#define MOVE_MOUNT_BENEATH 0x00000200
#endif

int main(int argc, char **argv) {
	if (argc != 3) {
		fprintf(stderr, "usage: kit-swapmount STAGED TARGET\n");
		return 2;
	}
	if (syscall(SYS_move_mount, AT_FDCWD, argv[1], AT_FDCWD, argv[2], MOVE_MOUNT_BENEATH)) {
		fprintf(stderr, "kit-swapmount: moving %s beneath %s: %s\n", argv[1], argv[2], strerror(errno));
		return 1;
	}
	if (umount2(argv[2], MNT_DETACH)) {
		fprintf(stderr, "kit-swapmount: detaching the old view at %s: %s\n", argv[2], strerror(errno));
		return 3;
	}
	return 0;
}
