/*
 * ribbon-fswatch: inotify on the folders the Files windows show.
 *
 * Commands on stdin, one per line:
 *   watch PATH        watch the folder (idempotent)
 *   unwatch PATH      stop watching it
 * Replies on stdout, one per line, fields separated by a tab:
 *   watching TAB PATH   the folder is watched
 *   refused  TAB PATH   it isn't: no inotify, the watch limit, no such folder
 *   lost     TAB PATH   the folder went away, or the kernel dropped the watch
 *   changed  TAB PATH   something in it was created, removed, renamed or written
 *
 * It keeps no state on disk and exits when stdin closes. Build with:
 *   cc -O2 -Wall -Wextra -Werror -o ribbon-fswatch ribbon-fswatch.c
 */
#define _DEFAULT_SOURCE

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <unistd.h>

#define MAX_PATHS 256
#define IN_BUF 4096
#define LINE_MAX_BYTES 8192

struct entry {
	int wd;          /* inotify watch descriptor; several paths may share one */
	char *path;
	int dirty;       /* something changed since the last reply */
};

static struct entry ents[MAX_PATHS];
static int nents;
static int ifd = -1;

static int find_path(const char *p)
{
	for (int i = 0; i < nents; i++)
		if (strcmp(ents[i].path, p) == 0)
			return i;
	return -1;
}

/* Is WD still used by an entry other than entry SKIP? */
static int wd_used_elsewhere(int wd, int skip)
{
	for (int i = 0; i < nents; i++)
		if (i != skip && ents[i].wd == wd)
			return 1;
	return 0;
}

static void reply(const char *what, const char *p)
{
	printf("%s\t%s\n", what, p);
	fflush(stdout);
}

static void remove_at(int i)
{
	if (!wd_used_elsewhere(ents[i].wd, i))
		inotify_rm_watch(ifd, ents[i].wd);
	free(ents[i].path);
	ents[i] = ents[--nents];
}

static void do_watch(const char *p)
{
	if (strchr(p, '\t') || strchr(p, '\n') || ifd < 0) {
		reply("refused", p);
		return;
	}
	if (find_path(p) >= 0) {
		reply("watching", p);
		return;
	}
	if (nents == MAX_PATHS) {
		reply("refused", p);
		return;
	}
	int wd = inotify_add_watch(ifd, p,
	    IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_MODIFY |
	    IN_CLOSE_WRITE | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF |
	    IN_ONLYDIR);
	if (wd < 0) {
		reply("refused", p);
		return;
	}
	char *copy = strdup(p);
	if (!copy) {
		reply("refused", p);
		return;
	}
	ents[nents].wd = wd;
	ents[nents].path = copy;
	ents[nents].dirty = 0;
	nents++;
	reply("watching", p);
}

static void do_unwatch(const char *p)
{
	int i = find_path(p);
	if (i < 0)
		return;
	remove_at(i);
}

static void handle_line(char *line)
{
	if (strncmp(line, "watch ", 6) == 0)
		do_watch(line + 6);
	else if (strncmp(line, "unwatch ", 8) == 0)
		do_unwatch(line + 8);
}

/* Read what is on stdin and handle the complete lines. Returns 0 at EOF. */
static int read_commands(char *buf, size_t *len)
{
	ssize_t n = read(0, buf + *len, LINE_MAX_BYTES - *len - 1);
	if (n < 0 && errno == EINTR)
		return 1;
	if (n <= 0)
		return 0;
	*len += (size_t)n;
	size_t start = 0;
	for (;;) {
		char *nl = memchr(buf + start, '\n', *len - start);
		if (!nl)
			break;
		*nl = '\0';
		handle_line(buf + start);
		start = (size_t)(nl - buf) + 1;
	}
	if (start > 0) {
		memmove(buf, buf + start, *len - start);
		*len -= start;
	}
	if (*len == LINE_MAX_BYTES - 1) /* a line too long to be a path: drop it */
		*len = 0;
	return 1;
}

static void mark_wd(int wd)
{
	for (int i = 0; i < nents; i++)
		if (ents[i].wd == wd)
			ents[i].dirty = 1;
}

/* Read the kernel's events and report each changed folder once. */
static void read_events(void)
{
	char buf[IN_BUF] __attribute__((aligned(__alignof__(struct inotify_event))));
	for (;;) {
		ssize_t n = read(ifd, buf, sizeof buf);
		if (n <= 0)
			break;
		for (char *p = buf; p < buf + n;) {
			const struct inotify_event *ev = (const struct inotify_event *)(const void *)p;
			if (ev->mask & IN_Q_OVERFLOW) {
				for (int i = 0; i < nents; i++)
					ents[i].dirty = 1;
			} else if (ev->mask & IN_IGNORED) {
				/* the folder is gone or the kernel dropped the watch */
				for (int i = 0; i < nents;) {
					if (ents[i].wd == ev->wd) {
						reply("changed", ents[i].path);
						reply("lost", ents[i].path);
						free(ents[i].path);
						ents[i] = ents[--nents];
					} else {
						i++;
					}
				}
			} else {
				mark_wd(ev->wd);
			}
			p += sizeof(struct inotify_event) + ev->len;
		}
	}
	for (int i = 0; i < nents; i++) {
		if (ents[i].dirty) {
			ents[i].dirty = 0;
			reply("changed", ents[i].path);
		}
	}
}

int main(void)
{
	ifd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
	char inbuf[LINE_MAX_BYTES];
	size_t inlen = 0;

	for (;;) {
		struct pollfd pf[2];
		pf[0].fd = 0;
		pf[0].events = POLLIN;
		pf[1].fd = ifd;
		pf[1].events = POLLIN;
		int n = poll(pf, ifd >= 0 ? 2 : 1, -1);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return 1;
		}
		if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
			if (!read_commands(inbuf, &inlen))
				break;
		}
		if (ifd >= 0 && (pf[1].revents & POLLIN))
			read_events();
		fflush(stdout);
	}
	for (int i = 0; i < nents; i++)
		free(ents[i].path);
	if (ifd >= 0)
		close(ifd);
	return 0;
}
