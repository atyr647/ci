/*
 * unix_extra: the Unix socket pieces Tcl and unix_sockets lack.
 *
 *   datagrams (sd_notify style, abstract "@names"), SCM_RIGHTS fd passing,
 *   SO_PEERCRED and socketpair. Works on any channel whose driver hands out
 *   its fd through Tcl_GetChannelHandle: Tcl's own file and pipe channels,
 *   unix_sockets channels and the channels made here.
 *
 *   Its own stream channel type ("unix_extra" channels from connect, listen,
 *   socketpair, adopt, fdopen and takeover) reads with recvmsg only, so no
 *   descriptor passed with SCM_RIGHTS is ever discarded: they are queued on
 *   the channel with the stream offset where the message that carried them
 *   ended (see StreamInput). handoff/takeover move such a connection, queue
 *   and unread bytes included, to another process (see HandoffCmd).
 *
 * Copyright (c) 2026 Ribbon OS contributors. MIT License, see LICENSE.
 */
#define _GNU_SOURCE
#include <tcl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef TCL_SIZE_MAX
typedef int Tcl_Size;
#endif

#define PKG_NAME    "unix_extra"
#define PKG_VERSION "0.3"
#define MAX_FDS     253 /* SCM_MAX_FD */

/* Set a "what: message" result with a POSIX errorCode from errno. */
static int posix_error(Tcl_Interp *interp, const char *what)
{
	int e = errno;
	Tcl_SetErrno(e);
	Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s: %s", what, Tcl_PosixError(interp)));
	return TCL_ERROR;
}

static int fail(Tcl_Interp *interp, const char *code, const char *fmt, const char *arg)
{
	Tcl_SetObjResult(interp, Tcl_ObjPrintf(fmt, arg));
	Tcl_SetErrorCode(interp, "UNIX_EXTRA", code, NULL);
	return TCL_ERROR;
}

/* The fd under a channel (the bottom of a stack), readable side first. */
static int chan_fd(Tcl_Interp *interp, Tcl_Obj *name, Tcl_Channel *chanPtr, int *fdPtr)
{
	ClientData h;
	Tcl_Channel chan = Tcl_GetChannel(interp, Tcl_GetString(name), NULL);
	if (chan == NULL)
		return TCL_ERROR;
	if (Tcl_GetChannelHandle(chan, TCL_READABLE, &h) != TCL_OK &&
	    Tcl_GetChannelHandle(chan, TCL_WRITABLE, &h) != TCL_OK)
		return fail(interp, "NOFD", "channel \"%s\" has no file descriptor", Tcl_GetString(name));
	if (chanPtr)
		*chanPtr = chan;
	*fdPtr = (int)(intptr_t)h;
	return TCL_OK;
}

/* "path" or "@abstract" into a sockaddr_un; returns the address length. */
static int make_addr(Tcl_Interp *interp, Tcl_Obj *pathObj, struct sockaddr_un *sa, socklen_t *lenPtr)
{
	Tcl_Size len;
	const char *path = Tcl_GetStringFromObj(pathObj, &len);
	memset(sa, 0, sizeof(*sa));
	sa->sun_family = AF_UNIX;
	if (len == 0)
		return fail(interp, "PATH", "empty socket path%s", "");
	if ((size_t)len > sizeof(sa->sun_path) - (path[0] == '@' ? 0 : 1))
		return fail(interp, "PATH", "socket path is too long: %s", path);
	memcpy(sa->sun_path, path, len);
	if (path[0] == '@') {
		sa->sun_path[0] = '\0';
		*lenPtr = offsetof(struct sockaddr_un, sun_path) + len;
	} else {
		*lenPtr = offsetof(struct sockaddr_un, sun_path) + len + 1;
	}
	return TCL_OK;
}

/* Is fd a connected unix stream socket? */
static int is_unix_stream(int fd)
{
	struct sockaddr_storage ss;
	socklen_t len = sizeof(ss);
	int type, listening;
	if (getsockname(fd, (struct sockaddr *)&ss, &len) == -1 || ss.ss_family != AF_UNIX)
		return 0;
	len = sizeof(type);
	if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) == -1 || type != SOCK_STREAM)
		return 0;
	len = sizeof(listening);
	return getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &listening, &len) == 0 && !listening;
}

/* Wrap an fd as a registered Tcl channel; on failure the fd is closed. */
static Tcl_Channel wrap_fd(Tcl_Interp *interp, int fd)
{
	int fl = fcntl(fd, F_GETFL), mode;
	Tcl_Channel chan;
	switch (fl & O_ACCMODE) {
	case O_RDONLY: mode = TCL_READABLE; break;
	case O_WRONLY: mode = TCL_WRITABLE; break;
	default:       mode = TCL_READABLE | TCL_WRITABLE; break;
	}
	chan = Tcl_MakeFileChannel((ClientData)(intptr_t)fd, mode);
	if (chan == NULL) {
		close(fd);
		return NULL;
	}
	Tcl_RegisterChannel(interp, chan);
	/* A passed fd shares its file status with the sender: match Tcl's view. */
	if (fl != -1 && (fl & O_NONBLOCK))
		Tcl_SetChannelOption(NULL, chan, "-blocking", "0");
	return chan;
}

/* The channel options adopt, handoff and takeover carry over, -blocking last. */
static const char *const stream_opts[] = {"-translation", "-encoding", "-eofchar",
	"-buffering", "-buffersize", "-blocking", NULL};
#define N_STREAM_OPTS 6

static void unlink_on_close(ClientData cd)
{
	unlink((char *)cd);
	ckfree(cd);
}

/* ---- unix_extra stream channels ----
 *
 * Every read is a recvmsg with room for SCM_RIGHTS, so passed descriptors
 * are never discarded, whatever Tcl reads (gets, read, fileevent, fcopy).
 * They wait in a FIFO on the channel, one FdMsg per message that carried
 * them, tagged with where in the stream that message ended.
 */

typedef struct FdMsg {
	struct FdMsg *next;
	Tcl_WideInt end;    /* stream offset just past the bytes they came with */
	int lost;           /* MSG_CTRUNC: the kernel dropped some of them */
	int nfd;
	int fds[];
} FdMsg;

/* Who a listener calls back. Shared with the interp's assoc data, so it
 * stays valid whichever of the interp and the listener goes first. */
typedef struct InterpRef {
	Tcl_Interp *interp; /* NULL once the interp is deleted */
	int refs;
} InterpRef;

typedef struct Stream {
	Tcl_Channel chan;
	int fd;
	Tcl_WideInt received; /* bytes handed to Tcl's input buffers so far */
	int closing;          /* Tcl_Close has started */
	FdMsg *head, *tail;
	/* listeners only */
	InterpRef *iref;
	Tcl_Obj *handler;
	char *path;           /* bound file to unlink on close */
} Stream;

static void free_msg(FdMsg *m)
{
	int i;
	for (i = 0; i < m->nfd; i++)
		close(m->fds[i]);
	ckfree(m);
}

static void free_msgs(FdMsg *m)
{
	while (m) {
		FdMsg *next = m->next;
		free_msg(m);
		m = next;
	}
}

static FdMsg *new_msg(Tcl_WideInt end, int lost, int nfd)
{
	FdMsg *m = (FdMsg *)ckalloc(offsetof(FdMsg, fds) + (nfd ? nfd : 1) * sizeof(int));
	m->next = NULL;
	m->end = end;
	m->lost = lost;
	m->nfd = 0;
	return m;
}

static void queue_msg(Stream *s, FdMsg *m)
{
	if (s->tail)
		s->tail->next = m;
	else
		s->head = m;
	s->tail = m;
}

static void iref_release(InterpRef *r)
{
	if (--r->refs == 0)
		ckfree(r);
}

static void iref_interp_deleted(ClientData cd, Tcl_Interp *interp)
{
	InterpRef *r = cd;
	(void)interp;
	r->interp = NULL;
	iref_release(r);
}

static InterpRef *iref_get(Tcl_Interp *interp)
{
	InterpRef *r = Tcl_GetAssocData(interp, PKG_NAME, NULL);
	if (r == NULL) {
		r = (InterpRef *)ckalloc(sizeof(*r));
		r->interp = interp;
		r->refs = 1; /* the assoc data's */
		Tcl_SetAssocData(interp, PKG_NAME, iref_interp_deleted, r);
	}
	r->refs++;
	return r;
}

/*
 * Unix stream sockets keep no message boundaries but one: the kernel ends a
 * read right after the message that carries fds (it may start the read with
 * older bytes, and a MSG_PEEK looks past message ends for fds, so where that
 * message starts can't be found out). So each batch is tagged with the
 * stream offset just past the bytes that came with it: the end of the
 * message that carried the fds, unless the message is larger than Tcl's
 * buffer, in which case it is a point inside that message.
 */
static int StreamInput(ClientData cd, char *buf, int bufSize, int *errorCodePtr)
{
	union { struct cmsghdr h; char buf[CMSG_SPACE(MAX_FDS * sizeof(int))]; } ctl;
	Stream *s = cd;
	struct msghdr msg;
	struct iovec iov;
	struct cmsghdr *cm;
	ssize_t n;
	int nfd = 0;
	FdMsg *fm;

	iov.iov_base = buf;
	iov.iov_len = bufSize;
	memset(&msg, 0, sizeof(msg));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = ctl.buf;
	msg.msg_controllen = sizeof(ctl.buf);
	if ((n = recvmsg(s->fd, &msg, MSG_CMSG_CLOEXEC)) == -1) {
		*errorCodePtr = errno;
		return -1;
	}
	s->received += n;
	for (cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm))
		if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
			nfd += (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
	if (nfd == 0 && !(msg.msg_flags & MSG_CTRUNC))
		return (int)n;
	/* One message's fds, in the order sent. */
	fm = new_msg(s->received, (msg.msg_flags & MSG_CTRUNC) != 0, nfd);
	for (cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm)) {
		if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS) {
			int c = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
			memcpy(fm->fds + fm->nfd, CMSG_DATA(cm), c * sizeof(int));
			fm->nfd += c;
		}
	}
	queue_msg(s, fm);
	return (int)n;
}

static int StreamOutput(ClientData cd, const char *buf, int toWrite, int *errorCodePtr)
{
	Stream *s = cd;
	ssize_t n = send(s->fd, buf, toWrite, MSG_NOSIGNAL);
	if (n == -1) {
		*errorCodePtr = errno;
		return -1;
	}
	return (int)n;
}

static int StreamClose2(ClientData cd, Tcl_Interp *interp, int flags)
{
	Stream *s = cd;
	int err = 0;
	(void)interp;
	/*
	 * close $chan read|write: a half-close of the socket. Tcl_Close also
	 * closes the read side first; that must not shut the socket down, as a
	 * child given it with exec <@ may still be using it.
	 */
	if (flags & (TCL_CLOSE_READ | TCL_CLOSE_WRITE)) {
		if (s->closing)
			return 0;
		return shutdown(s->fd, (flags & TCL_CLOSE_READ) ? SHUT_RD : SHUT_WR) == -1 ? errno : 0;
	}
	Tcl_DeleteFileHandler(s->fd);
	free_msgs(s->head); /* never taken: close them, no leaks */
	if (s->path) {
		unlink(s->path);
		ckfree(s->path);
	}
	if (s->handler)
		Tcl_DecrRefCount(s->handler);
	if (s->iref)
		iref_release(s->iref);
	if (close(s->fd) == -1)
		err = errno;
	ckfree(s);
	return err;
}

static void notify_channel(ClientData cd, int mask)
{
	Tcl_NotifyChannel((Tcl_Channel)cd, mask);
}

static void StreamWatch(ClientData cd, int mask)
{
	Stream *s = cd;
	if (s->handler) /* a listener's own handler does the accepting */
		return;
	if (mask)
		Tcl_CreateFileHandler(s->fd, mask, notify_channel, s->chan);
	else
		Tcl_DeleteFileHandler(s->fd);
}

static int StreamHandle(ClientData cd, int direction, ClientData *handlePtr)
{
	Stream *s = cd;
	(void)direction;
	*handlePtr = (ClientData)(intptr_t)s->fd;
	return TCL_OK;
}

static int StreamBlockMode(ClientData cd, int mode)
{
	Stream *s = cd;
	int fl = fcntl(s->fd, F_GETFL);
	if (fl == -1)
		return errno;
	fl = mode == TCL_MODE_NONBLOCKING ? (fl | O_NONBLOCK) : (fl & ~O_NONBLOCK);
	return fcntl(s->fd, F_SETFL, fl) == -1 ? errno : 0;
}

static Tcl_ChannelType StreamType = {
	.typeName      = PKG_NAME,
	.version       = TCL_CHANNEL_VERSION_5,
#if TCL_MAJOR_VERSION < 9
	.closeProc     = TCL_CLOSE2PROC,
#endif
	.inputProc     = StreamInput,
	.outputProc    = StreamOutput,
	.watchProc     = StreamWatch,
	.getHandleProc = StreamHandle,
	.close2Proc    = StreamClose2,
	.blockModeProc = StreamBlockMode,
};

/* Close handlers run in Tcl_Close just before its read-side half-close. */
static void mark_closing(ClientData cd)
{
	((Stream *)cd)->closing = 1;
}

/* A new, unregistered stream channel on fd ("uxstreamN" / "uxlistenN"). */
static Stream *new_stream(int fd, int mode, const char *prefix)
{
	char name[32];
	Stream *s = (Stream *)ckalloc(sizeof(*s));
	memset(s, 0, sizeof(*s));
	s->fd = fd;
	snprintf(name, sizeof(name), "%s%d", prefix, fd);
	s->chan = Tcl_CreateChannel(&StreamType, name, s, mode);
	Tcl_CreateCloseHandler(s->chan, mark_closing, s);
	return s;
}

/* The unix_extra stream under a channel name (Tcl_GetChannel gives the
 * bottom of a stack of transforms) and the top of its stack. */
static Stream *get_stream(Tcl_Interp *interp, Tcl_Obj *name, Tcl_Channel *topPtr)
{
	Tcl_Channel c = Tcl_GetChannel(interp, Tcl_GetString(name), NULL);
	Stream *s;
	if (c == NULL)
		return NULL;
	if (Tcl_GetChannelType(c) != &StreamType ||
	    (s = Tcl_GetChannelInstanceData(c))->handler != NULL) {
		fail(interp, "NOTSTREAM", "channel \"%s\" is not a unix_extra stream channel "
			"(see unix_extra::adopt)", Tcl_GetString(name));
		return NULL;
	}
	if (topPtr)
		*topPtr = Tcl_GetTopChannel(c);
	return s;
}

/* unix_extra::connect path */
static int ConnectCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	struct sockaddr_un sa;
	socklen_t salen;
	Stream *s;
	int fd, rc;
	(void)cd;
	if (objc != 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "path");
		return TCL_ERROR;
	}
	if (make_addr(interp, objv[1], &sa, &salen) != TCL_OK)
		return TCL_ERROR;
	if ((fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) == -1)
		return posix_error(interp, "socket");
	do
		rc = connect(fd, (struct sockaddr *)&sa, salen);
	while (rc == -1 && errno == EINTR);
	if (rc == -1) {
		posix_error(interp, "connect");
		close(fd);
		return TCL_ERROR;
	}
	s = new_stream(fd, TCL_READABLE | TCL_WRITABLE, "uxstream");
	Tcl_RegisterChannel(interp, s->chan);
	Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(s->chan), -1));
	return TCL_OK;
}

static void accept_proc(ClientData cd, int mask)
{
	Stream *l = cd, *s;
	Tcl_Interp *interp = l->iref->interp;
	Tcl_Obj *cmd;
	Tcl_Channel chan;
	int fd, code;
	(void)mask;
	if ((fd = accept4(l->fd, NULL, NULL, SOCK_CLOEXEC)) == -1) {
		if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR &&
		    errno != ECONNABORTED && interp != NULL) {
			Tcl_Preserve(interp);
			posix_error(interp, "accept");
			Tcl_BackgroundException(interp, TCL_ERROR);
			Tcl_Release(interp);
		}
		return;
	}
	if (interp == NULL || Tcl_InterpDeleted(interp)) {
		close(fd);
		return;
	}
	s = new_stream(fd, TCL_READABLE | TCL_WRITABLE, "uxstream");
	chan = s->chan;
	Tcl_Preserve(interp);
	Tcl_RegisterChannel(NULL, chan); /* ours, while the handler runs */
	Tcl_RegisterChannel(interp, chan);
	/* l may be closed by the handler: nothing of it is used after this */
	cmd = Tcl_DuplicateObj(l->handler);
	Tcl_IncrRefCount(cmd);
	Tcl_ListObjAppendElement(NULL, cmd, Tcl_NewStringObj(Tcl_GetChannelName(chan), -1));
	code = Tcl_EvalObjEx(interp, cmd, TCL_EVAL_GLOBAL);
	Tcl_DecrRefCount(cmd);
	if (code != TCL_OK) {
		Tcl_BackgroundException(interp, code);
		/* like socket -server: a failed handler's channel is closed */
		if (Tcl_GetChannel(interp, Tcl_GetChannelName(chan), NULL) == chan)
			Tcl_UnregisterChannel(interp, chan);
		Tcl_ResetResult(interp);
	}
	Tcl_UnregisterChannel(NULL, chan);
	Tcl_Release(interp);
}

/* unix_extra::listen path handler  (handler is called with the new channel) */
static int ListenCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	struct sockaddr_un sa;
	socklen_t salen;
	Stream *l;
	int fd;
	(void)cd;
	if (objc != 3) {
		Tcl_WrongNumArgs(interp, 1, objv, "path handler");
		return TCL_ERROR;
	}
	if (make_addr(interp, objv[1], &sa, &salen) != TCL_OK)
		return TCL_ERROR;
	if ((fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0)) == -1)
		return posix_error(interp, "socket");
	if (bind(fd, (struct sockaddr *)&sa, salen) == -1) {
		posix_error(interp, "bind");
		close(fd);
		return TCL_ERROR;
	}
	if (listen(fd, SOMAXCONN) == -1) {
		posix_error(interp, "listen");
		close(fd);
		if (sa.sun_path[0] != '\0')
			unlink(sa.sun_path);
		return TCL_ERROR;
	}
	l = new_stream(fd, 0, "uxlisten");
	l->handler = objv[2];
	Tcl_IncrRefCount(l->handler);
	l->iref = iref_get(interp);
	if (sa.sun_path[0] != '\0') {
		l->path = ckalloc(strlen(sa.sun_path) + 1);
		strcpy(l->path, sa.sun_path);
	}
	Tcl_CreateFileHandler(fd, TCL_READABLE, accept_proc, l);
	Tcl_RegisterChannel(interp, l->chan);
	Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(l->chan), -1));
	return TCL_OK;
}

/* unix_extra::fds channel ?-all? ?-messages?
 *   The queued fds whose message the script has read (end <= bytes
 *   consumed), or with -all every queued one, as new channels; with
 *   -messages as {end {channel ...}} per message. A unix_sockets channel
 *   opened with -passfds 1 keeps a queue of its own, with the same meaning:
 *   that is unix_sockets::fds, called here by name (no link dependency). */
static int FdsCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	static const char *const opts[] = {"-all", "-messages", NULL};
	int all = 0, messages = 0, i, idx;
	Tcl_Channel chan, top;
	Tcl_WideInt upto;
	Tcl_Obj *res;
	FdMsg *m;
	Stream *s;
	(void)cd;
	if (objc < 2 || objc > 4) {
		Tcl_WrongNumArgs(interp, 1, objv, "channel ?-all? ?-messages?");
		return TCL_ERROR;
	}
	for (i = 2; i < objc; i++) {
		if (Tcl_GetIndexFromObj(interp, objv[i], opts, "option", 0, &idx) != TCL_OK)
			return TCL_ERROR;
		*(idx ? &messages : &all) = 1;
	}
	if ((chan = Tcl_GetChannel(interp, Tcl_GetString(objv[1]), NULL)) != NULL &&
	    strcmp(Tcl_GetChannelType(chan)->typeName, "unix_socket") == 0) {
		Tcl_Obj *cmd = Tcl_NewListObj(objc, objv);
		int code;
		Tcl_IncrRefCount(cmd);
		Tcl_ListObjReplace(NULL, cmd, 0, 1, 1, (Tcl_Obj *[]){Tcl_NewStringObj("::unix_sockets::fds", -1)});
		code = Tcl_EvalObjEx(interp, cmd, TCL_EVAL_GLOBAL);
		Tcl_DecrRefCount(cmd);
		return code;
	}
	if ((s = get_stream(interp, objv[1], &top)) == NULL)
		return TCL_ERROR;
	/* Bytes the script has consumed; under a transform, all that was read. */
	upto = s->received - (top == s->chan ? Tcl_InputBuffered(top) : 0);
	for (m = s->head; m && (all || m->end <= upto); m = m->next) {
		if (m->lost) {
			/* Report once; the fds that did arrive stay queued. */
			m->lost = 0;
			Tcl_SetObjResult(interp, Tcl_ObjPrintf("file descriptors sent with the "
				"message ending at offset %" TCL_LL_MODIFIER "d were lost: the kernel "
				"could not pass them all (the open file limit?)", (Tcl_WideInt)m->end));
			Tcl_SetErrorCode(interp, "UNIX_EXTRA", "CTRUNC", NULL);
			return TCL_ERROR;
		}
	}
	res = Tcl_NewListObj(0, NULL);
	while ((m = s->head) && (all || m->end <= upto)) {
		Tcl_Obj *chans = messages ? Tcl_NewListObj(0, NULL) : res;
		for (i = 0; i < m->nfd; i++) {
			Tcl_Channel c = wrap_fd(interp, m->fds[i]);
			if (c != NULL)
				Tcl_ListObjAppendElement(NULL, chans, Tcl_NewStringObj(Tcl_GetChannelName(c), -1));
		}
		if (messages) {
			Tcl_Obj *pair[2];
			pair[0] = Tcl_NewWideIntObj(m->end);
			pair[1] = chans;
			Tcl_ListObjAppendElement(NULL, res, Tcl_NewListObj(2, pair));
		}
		m->nfd = 0; /* now owned by their channels */
		if ((s->head = m->next) == NULL)
			s->tail = NULL;
		free_msg(m);
	}
	Tcl_SetObjResult(interp, res);
	return TCL_OK;
}

/*
 * A driver that queues passed fds itself shows them in its read-only -fdqueue
 * option (unix_sockets with -passfds 1): {received {end lost {fd ...}} ...},
 * the fds still owned by that channel. Make copies of them, with each end
 * rebased so that offset 0 is the channel's first unread byte. *headPtr is
 * NULL when the channel has no such queue.
 */
static int copy_fdqueue(Tcl_Interp *interp, Tcl_Channel chan, FdMsg **headPtr)
{
	Tcl_DString ds;
	Tcl_Obj *q, **elems, **parts, **fdv;
	Tcl_Size n, np, nfd, i, j;
	Tcl_WideInt received, consumed, end;
	FdMsg *head = NULL, **tailp = &head;
	int lost, fd, ok = 1;
	*headPtr = NULL;
	Tcl_DStringInit(&ds);
	if (Tcl_GetChannelOption(NULL, chan, "-fdqueue", &ds) != TCL_OK) {
		Tcl_DStringFree(&ds);
		return TCL_OK; /* no such option: nothing queued anywhere but in the kernel */
	}
	q = Tcl_NewStringObj(Tcl_DStringValue(&ds), Tcl_DStringLength(&ds));
	Tcl_IncrRefCount(q);
	Tcl_DStringFree(&ds);
	if (Tcl_ListObjGetElements(NULL, q, &n, &elems) != TCL_OK)
		goto bad;
	if (n == 0)
		goto done;
	if (Tcl_GetWideIntFromObj(NULL, elems[0], &received) != TCL_OK)
		goto bad;
	/* Bytes the script has read: offset 0 of the new stream. */
	consumed = received - Tcl_InputBuffered(chan);
	for (i = 1; i < n; i++) {
		FdMsg *m;
		if (Tcl_ListObjGetElements(NULL, elems[i], &np, &parts) != TCL_OK || np != 3 ||
		    Tcl_GetWideIntFromObj(NULL, parts[0], &end) != TCL_OK ||
		    Tcl_GetBooleanFromObj(NULL, parts[1], &lost) != TCL_OK ||
		    Tcl_ListObjGetElements(NULL, parts[2], &nfd, &fdv) != TCL_OK || nfd > MAX_FDS)
			goto bad;
		m = new_msg(end - consumed, lost, (int)nfd);
		*tailp = m;
		tailp = &m->next;
		for (j = 0; j < nfd; j++) {
			if (Tcl_GetIntFromObj(NULL, fdv[j], &fd) != TCL_OK || fd < 0)
				goto bad;
			if ((m->fds[m->nfd] = fcntl(fd, F_DUPFD_CLOEXEC, 3)) == -1) {
				posix_error(interp, "dup");
				ok = 0;
				goto out;
			}
			m->nfd++;
		}
	}
done:
	*headPtr = head;
	head = NULL;
	goto out;
bad:
	fail(interp, "FDQUEUE", "channel \"%s\" reports a malformed -fdqueue", Tcl_GetChannelName(chan));
	ok = 0;
out:
	free_msgs(head);
	Tcl_DecrRefCount(q);
	return ok ? TCL_OK : TCL_ERROR;
}

/*
 * unix_extra::adopt channel  -> a unix_extra channel on the same socket
 *
 * Takes over a connected unix stream socket from another channel (one from
 * unix_sockets, or a Tcl file channel from fds/recvfds): pending output is
 * flushed, bytes Tcl had buffered are moved over unread, options carry over,
 * and the old channel is closed. Its fd is first pointed at a dead socket
 * (dup2), so even if something else still holds the old channel (another
 * interp, or unix_sockets during its accept handler) no byte or fd can be
 * read from the real socket through it any more: reads see EOF and writes
 * fail with EPIPE. Fds the old driver queued itself (-fdqueue) come along.
 */
static int AdoptCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	const char *const *opts = stream_opts;
	Tcl_DString vals[N_STREAM_OPTS];
	Tcl_Channel chan;
	ClientData h;
	Stream *s;
	FdMsg *queue = NULL;
	int fd, newfd, dead[2], mode, i, off = 0;
	Tcl_Size n;
	(void)cd;
	if (objc != 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "channel");
		return TCL_ERROR;
	}
	if ((chan = Tcl_GetChannel(interp, Tcl_GetString(objv[1]), NULL)) == NULL)
		return TCL_ERROR;
	if (Tcl_GetChannelType(chan) == &StreamType &&
	    ((Stream *)Tcl_GetChannelInstanceData(chan))->handler == NULL) {
		Tcl_SetObjResult(interp, objv[1]); /* already one of ours */
		return TCL_OK;
	}
	if (Tcl_GetTopChannel(chan) != chan)
		return fail(interp, "STACKED", "channel \"%s\" has a transform stacked on it",
			Tcl_GetString(objv[1]));
	if (Tcl_GetChannelHandle(chan, TCL_READABLE, &h) != TCL_OK &&
	    Tcl_GetChannelHandle(chan, TCL_WRITABLE, &h) != TCL_OK)
		return fail(interp, "NOFD", "channel \"%s\" has no file descriptor", Tcl_GetString(objv[1]));
	fd = (int)(intptr_t)h;
	mode = Tcl_GetChannelMode(chan) & (TCL_READABLE | TCL_WRITABLE);
	if (!is_unix_stream(fd) || mode == 0)
		return fail(interp, "NOTSTREAM", "channel \"%s\" is not a connected unix stream socket",
			Tcl_GetString(objv[1]));
	if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, dead) == -1)
		return posix_error(interp, "socketpair");
	close(dead[1]); /* dead[0] now reads EOF and fails writes with EPIPE */
	if ((newfd = fcntl(fd, F_DUPFD_CLOEXEC, 3)) == -1) {
		posix_error(interp, "dup");
		close(dead[0]);
		return TCL_ERROR;
	}
	for (i = 0; opts[i]; i++) {
		Tcl_DStringInit(&vals[i]);
		Tcl_GetChannelOption(NULL, chan, opts[i], &vals[i]);
	}
	/* All output goes out through the old channel first, in order. */
	if (Tcl_SetChannelOption(NULL, chan, "-blocking", "1") != TCL_OK || Tcl_Flush(chan) != TCL_OK ||
	    Tcl_OutputBuffered(chan) > 0) {
		Tcl_SetErrno(Tcl_GetErrno() ? Tcl_GetErrno() : EIO);
		Tcl_SetChannelOption(NULL, chan, "-blocking", Tcl_DStringValue(&vals[5]));
		posix_error(interp, "flush");
		goto fail;
	}
	/* Fds the old driver already took from the kernel (unix_sockets -passfds). */
	if ((mode & TCL_READABLE) && copy_fdqueue(interp, chan, &queue) != TCL_OK) {
		Tcl_SetChannelOption(NULL, chan, "-blocking", Tcl_DStringValue(&vals[5]));
		goto fail;
	}
	/* The fds come back as SCM_RIGHTS, not as credentials: keep it so. */
	setsockopt(newfd, SOL_SOCKET, SO_PASSCRED, &off, sizeof(off));
	s = new_stream(newfd, mode, "uxstream");
	newfd = -1;
	for (s->head = queue; queue; queue = queue->next)
		s->tail = queue;
	/* Move what Tcl read ahead, as raw bytes, to the new channel. */
	if ((mode & TCL_READABLE) && (n = Tcl_InputBuffered(chan)) > 0) {
		char *buf = ckalloc(n);
		Tcl_SetChannelOption(NULL, chan, "-translation", "binary");
		n = Tcl_Read(chan, buf, n);
		if (n > 0) {
			Tcl_Ungets(s->chan, buf, n, 0);
			s->received = n;
		}
		ckfree(buf);
	}
	for (i = 0; opts[i]; i++)
		Tcl_SetChannelOption(NULL, s->chan, opts[i], Tcl_DStringValue(&vals[i]));
	/* Retire the old channel: first cut it off the socket, then close it. */
	dup2(dead[0], fd);
	close(dead[0]);
	dead[0] = -1;
	Tcl_RegisterChannel(interp, s->chan);
	Tcl_UnregisterChannel(interp, chan);
	Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(s->chan), -1));
	for (i = 0; opts[i]; i++)
		Tcl_DStringFree(&vals[i]);
	return TCL_OK;
fail:
	for (i = 0; opts[i]; i++)
		Tcl_DStringFree(&vals[i]);
	if (newfd != -1)
		close(newfd);
	if (dead[0] != -1)
		close(dead[0]);
	return TCL_ERROR;
}

/* ---- handoff / takeover ----
 *
 * One sendmsg on the target socket carries a whole connection: SCM_RIGHTS
 * with the connection's socket followed by every fd still queued on it, and
 * these bytes (integers big-endian):
 *
 *   0  "UXHO"   magic
 *   4  u8       version (1)
 *   5  u8       flags: 1 readable, 2 writable (the channel's mode)
 *   6  u16      0
 *   8  u32      nmsg: queued fd batches
 *  12  u32      nopt: bytes of channel options (a Tcl list: name value ...)
 *  16  u32      nbuf: bytes Tcl had read ahead that the script had not read
 *  20  u32      ndata: bytes of application data
 *  24  nmsg * { i64 end, u32 nfd, u32 lost }, in queue order; end is
 *      relative to the first unread byte (<= 0: the script had read it)
 *      then the options, the unread bytes and the data.
 *
 * The fds ride on the first bytes of the message, so the receiver finds them
 * as the first batch its own unix_extra channel queued past the header's
 * start, whatever it had read ahead.
 */
#define HANDOFF_MAGIC   "UXHO"
#define HANDOFF_VERSION 1
#define HANDOFF_HDR     24
#define HANDOFF_ENTRY   16
#define HANDOFF_MAX     (64 * 1024 * 1024) /* bytes of options, unread input or data */

static void put32(unsigned char *p, uint32_t v)
{
	p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static uint32_t get32(const unsigned char *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* Put back what handoff changed on a channel it did not hand off. */
static void handoff_undo(Tcl_Channel chan, char *buf, Tcl_Size nbuf, Tcl_DString *vals)
{
	int i;
	if (nbuf > 0)
		Tcl_Ungets(chan, buf, nbuf, 0);
	for (i = 0; stream_opts[i]; i++)
		Tcl_SetChannelOption(NULL, chan, stream_opts[i], Tcl_DStringValue(&vals[i]));
}

/* unix_extra::handoff channel target ?data? */
static int HandoffCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	union { struct cmsghdr h; char buf[CMSG_SPACE(MAX_FDS * sizeof(int))]; } ctl;
	Tcl_DString vals[N_STREAM_OPTS];
	Tcl_Channel chan, top, tchan;
	Tcl_Obj *opts = NULL;
	Stream *s;
	FdMsg *m;
	struct msghdr msg;
	struct iovec iov;
	struct cmsghdr *cm;
	const unsigned char *data = (const unsigned char *)"";
	unsigned char *wire = NULL, *p;
	const char *optstr;
	char *buf = NULL;
	Tcl_Size ndata = 0, nbuf = 0, nopt, total, sent;
	Tcl_WideInt consumed;
	int tfd, nfd = 1, nmsg = 0, dead[2], mode, i, fl, *fdp, err;
	ssize_t n;
	(void)cd;
	if (objc != 3 && objc != 4) {
		Tcl_WrongNumArgs(interp, 1, objv, "channel target ?data?");
		return TCL_ERROR;
	}
	if ((s = get_stream(interp, objv[1], &top)) == NULL)
		return TCL_ERROR;
	chan = s->chan;
	if (top != chan)
		return fail(interp, "STACKED", "channel \"%s\" has a transform stacked on it", Tcl_GetString(objv[1]));
	if (chan_fd(interp, objv[2], &tchan, &tfd) != TCL_OK)
		return TCL_ERROR;
	if (tchan == chan || tfd == s->fd)
		return fail(interp, "TARGET", "can't hand channel \"%s\" off over itself", Tcl_GetString(objv[1]));
	for (m = s->head; m; m = m->next) {
		nfd += m->nfd;
		nmsg++;
	}
	if (nfd > MAX_FDS)
		return fail(interp, "NFDS", "channel \"%s\" has too many queued file descriptors to hand "
			"off (at most 252)", Tcl_GetString(objv[1]));
	if (objc == 4)
		data = Tcl_GetByteArrayFromObj(objv[3], &ndata);
	if (ndata > HANDOFF_MAX)
		return fail(interp, "DATA", "handoff data is too large%s", "");
	/* What the old fd becomes once handed off: made now, so that nothing
	 * after the send can fail. */
	if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, dead) == -1)
		return posix_error(interp, "socketpair");
	close(dead[1]);
	mode = Tcl_GetChannelMode(chan) & (TCL_READABLE | TCL_WRITABLE);
	for (i = 0; stream_opts[i]; i++) {
		Tcl_DStringInit(&vals[i]);
		Tcl_GetChannelOption(NULL, chan, stream_opts[i], &vals[i]);
	}
	/* The target's pending output goes first, as with sendfds... */
	if (Tcl_Flush(tchan) != TCL_OK) {
		posix_error(interp, "flush");
		goto fail;
	}
	if (Tcl_OutputBuffered(tchan) > 0) {
		errno = EAGAIN;
		posix_error(interp, "handoff");
		goto fail;
	}
	/* ...and everything written to the channel reaches its peer from here. */
	if ((mode & TCL_WRITABLE) && (Tcl_SetChannelOption(NULL, chan, "-blocking", "1") != TCL_OK ||
	    Tcl_Flush(chan) != TCL_OK || Tcl_OutputBuffered(chan) > 0)) {
		Tcl_SetErrno(Tcl_GetErrno() ? Tcl_GetErrno() : EIO);
		posix_error(interp, "flush");
		goto restore;
	}
	/* The bytes Tcl read ahead that the script hasn't, raw. */
	if (mode & TCL_READABLE)
		nbuf = Tcl_InputBuffered(chan);
	consumed = s->received - nbuf;
	if (nbuf > 0) {
		Tcl_Size want = nbuf;
		buf = ckalloc(nbuf);
		Tcl_SetChannelOption(NULL, chan, "-translation", "binary");
		if ((nbuf = Tcl_Read(chan, buf, want)) != want) {
			nbuf = nbuf < 0 ? 0 : nbuf;
			Tcl_SetErrno(EIO);
			posix_error(interp, "handoff");
			goto restore;
		}
	}
	opts = Tcl_NewListObj(0, NULL);
	Tcl_IncrRefCount(opts);
	for (i = 0; stream_opts[i]; i++) {
		Tcl_ListObjAppendElement(NULL, opts, Tcl_NewStringObj(stream_opts[i], -1));
		Tcl_ListObjAppendElement(NULL, opts, Tcl_NewStringObj(Tcl_DStringValue(&vals[i]), -1));
	}
	optstr = Tcl_GetStringFromObj(opts, &nopt);
	total = HANDOFF_HDR + (Tcl_Size)nmsg * HANDOFF_ENTRY + nopt + nbuf + ndata;
	p = wire = (unsigned char *)ckalloc(total);
	memcpy(p, HANDOFF_MAGIC, 4);
	p[4] = HANDOFF_VERSION;
	p[5] = ((mode & TCL_READABLE) ? 1 : 0) | ((mode & TCL_WRITABLE) ? 2 : 0);
	p[6] = p[7] = 0;
	put32(p + 8, nmsg);
	put32(p + 12, nopt);
	put32(p + 16, nbuf);
	put32(p + 20, ndata);
	p += HANDOFF_HDR;
	memset(&ctl, 0, sizeof(ctl));
	memset(&msg, 0, sizeof(msg));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = ctl.buf;
	msg.msg_controllen = CMSG_SPACE(nfd * sizeof(int));
	cm = CMSG_FIRSTHDR(&msg);
	cm->cmsg_level = SOL_SOCKET;
	cm->cmsg_type = SCM_RIGHTS;
	cm->cmsg_len = CMSG_LEN(nfd * sizeof(int));
	fdp = (int *)CMSG_DATA(cm);
	*fdp++ = s->fd;
	for (m = s->head; m; m = m->next) {
		uint64_t end = (uint64_t)(m->end - consumed);
		put32(p, end >> 32);
		put32(p + 4, (uint32_t)end);
		put32(p + 8, m->nfd);
		put32(p + 12, m->lost);
		p += HANDOFF_ENTRY;
		memcpy(fdp, m->fds, m->nfd * sizeof(int));
		fdp += m->nfd;
	}
	memcpy(p, optstr, nopt);
	if (nbuf)
		memcpy(p + nopt, buf, nbuf);
	if (ndata)
		memcpy(p + nopt + nbuf, data, ndata);
	iov.iov_base = wire;
	iov.iov_len = total;
	do
		n = sendmsg(tfd, &msg, MSG_NOSIGNAL);
	while (n == -1 && errno == EINTR);
	if (n == -1) {
		posix_error(interp, "handoff");
		goto restore;
	}
	if (n < total) {
		/* The fds went with the first part: the rest has to follow, so
		 * finish in blocking mode even on a non-blocking target. */
		fl = fcntl(tfd, F_GETFL);
		if (fl != -1 && (fl & O_NONBLOCK))
			fcntl(tfd, F_SETFL, fl & ~O_NONBLOCK);
		for (sent = n; sent < total; sent += n) {
			do
				n = send(tfd, wire + sent, total - sent, MSG_NOSIGNAL);
			while (n == -1 && errno == EINTR);
			if (n == -1)
				break;
		}
		err = errno;
		if (fl != -1 && (fl & O_NONBLOCK))
			fcntl(tfd, F_SETFL, fl);
		if (sent < total) {
			/* The receiver gets a truncated message, which takeover refuses. */
			errno = err;
			posix_error(interp, "handoff");
			goto restore;
		}
	}
	/* Handed off. The receiver holds the socket and the queued fds now:
	 * close ours, cutting the channel off the socket first (as adopt does),
	 * so the socket is never shut down and nothing that still holds the
	 * channel can read from or write to it. */
	free_msgs(s->head);
	s->head = s->tail = NULL;
	dup2(dead[0], s->fd);
	close(dead[0]);
	dead[0] = -1;
	Tcl_UnregisterChannel(interp, chan);
	Tcl_ResetResult(interp);
	err = TCL_OK;
	goto done;
restore:
	handoff_undo(chan, buf, nbuf, vals);
fail:
	err = TCL_ERROR;
done:
	for (i = 0; stream_opts[i]; i++)
		Tcl_DStringFree(&vals[i]);
	if (dead[0] != -1)
		close(dead[0]);
	if (opts)
		Tcl_DecrRefCount(opts);
	if (buf)
		ckfree(buf);
	if (wire)
		ckfree(wire);
	return err;
}

/* Read exactly len bytes from a blocking channel. */
static int read_exact(Tcl_Interp *interp, Tcl_Channel chan, unsigned char *buf, Tcl_Size len)
{
	Tcl_Size n = len ? Tcl_Read(chan, (char *)buf, len) : 0;
	if (n == -1)
		return posix_error(interp, "takeover");
	if (n < len)
		return fail(interp, "HANDOFF", "takeover: %s", n == 0 && len == HANDOFF_HDR ?
			"end of stream, no handoff message" : "the handoff message is truncated");
	return TCL_OK;
}

/* unix_extra::takeover target ?dataVar?  -> the handed-off connection */
static int TakeoverCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	static const char *const topts[] = {"-translation", "-encoding", "-eofchar", "-blocking", NULL};
	Tcl_DString vals[4];
	unsigned char hdr[HANDOFF_HDR], *body = NULL, *p;
	Stream *t, *ns;
	Tcl_Channel top;
	FdMsg *m, *prev = NULL, *e;
	Tcl_WideInt pos0, pos1;
	uint32_t nmsg, nopt, nbuf, ndata, k, nfd = 1;
	Tcl_Size total, nelem;
	Tcl_Obj *optobj = NULL, **elems;
	int i, j, mode, used = 1, code = TCL_ERROR;
	(void)cd;
	if (objc != 2 && objc != 3) {
		Tcl_WrongNumArgs(interp, 1, objv, "target ?dataVar?");
		return TCL_ERROR;
	}
	if ((t = get_stream(interp, objv[1], &top)) == NULL)
		return TCL_ERROR;
	if (top != t->chan)
		return fail(interp, "STACKED", "channel \"%s\" has a transform stacked on it", Tcl_GetString(objv[1]));
	for (i = 0; topts[i]; i++) {
		Tcl_DStringInit(&vals[i]);
		Tcl_GetChannelOption(NULL, t->chan, topts[i], &vals[i]);
	}
	/* The message comes in one piece: wait for all of it, bytes as sent. */
	Tcl_SetChannelOption(NULL, t->chan, "-translation", "binary");
	Tcl_SetChannelOption(NULL, t->chan, "-blocking", "1");
	pos0 = t->received - Tcl_InputBuffered(t->chan);
	if (read_exact(interp, t->chan, hdr, HANDOFF_HDR) != TCL_OK)
		goto out;
	if (memcmp(hdr, HANDOFF_MAGIC, 4) != 0) {
		fail(interp, "HANDOFF", "takeover: not a handoff message%s", "");
		goto out;
	}
	if (hdr[4] != HANDOFF_VERSION) {
		Tcl_SetObjResult(interp, Tcl_ObjPrintf("takeover: handoff message version %d is not supported", hdr[4]));
		Tcl_SetErrorCode(interp, "UNIX_EXTRA", "HANDOFF", NULL);
		goto out;
	}
	mode = ((hdr[5] & 1) ? TCL_READABLE : 0) | ((hdr[5] & 2) ? TCL_WRITABLE : 0);
	nmsg = get32(hdr + 8);
	nopt = get32(hdr + 12);
	nbuf = get32(hdr + 16);
	ndata = get32(hdr + 20);
	if (nmsg > MAX_FDS || nopt > HANDOFF_MAX || nbuf > HANDOFF_MAX || ndata > HANDOFF_MAX) {
		fail(interp, "HANDOFF", "takeover: malformed handoff message%s", "");
		goto out;
	}
	total = (Tcl_Size)nmsg * HANDOFF_ENTRY + nopt + nbuf + ndata;
	body = (unsigned char *)ckalloc(total ? total : 1);
	if (read_exact(interp, t->chan, body, total) != TCL_OK)
		goto out;
	pos1 = pos0 + HANDOFF_HDR + total;
	/* Its fds: the first batch queued past where the message began. */
	for (m = t->head; m && m->end <= pos0; m = m->next)
		prev = m;
	if (m == NULL || m->end > pos1) {
		fail(interp, "HANDOFF", "takeover: no file descriptors came with the handoff message%s", "");
		goto out;
	}
	if (prev)
		prev->next = m->next;
	else
		t->head = m->next;
	if (t->tail == m)
		t->tail = prev;
	m->next = NULL;
	for (k = 0, p = body; k < nmsg; k++, p += HANDOFF_ENTRY)
		nfd += get32(p + 8) <= MAX_FDS ? get32(p + 8) : MAX_FDS + 1;
	if (m->lost) {
		fail(interp, "CTRUNC", "takeover: the kernel could not pass all file descriptors "
			"of the handoff message (the open file limit?)%s", "");
		goto drop;
	}
	if ((uint32_t)m->nfd != nfd || !is_unix_stream(m->fds[0])) {
		fail(interp, "HANDOFF", "takeover: malformed handoff message%s", "");
		goto drop;
	}
	optobj = Tcl_NewStringObj((char *)body + nmsg * HANDOFF_ENTRY, nopt);
	Tcl_IncrRefCount(optobj);
	if (Tcl_ListObjGetElements(NULL, optobj, &nelem, &elems) != TCL_OK || nelem % 2) {
		fail(interp, "HANDOFF", "takeover: malformed handoff message%s", "");
		goto drop;
	}
	if (objc == 3 && Tcl_ObjSetVar2(interp, objv[2], NULL, Tcl_NewByteArrayObj(body + total - ndata,
	    ndata), TCL_LEAVE_ERR_MSG) == NULL)
		goto drop;
	ns = new_stream(m->fds[0], mode, "uxstream");
	for (k = 0, p = body; k < nmsg; k++, p += HANDOFF_ENTRY) {
		uint64_t end = (uint64_t)get32(p) << 32 | get32(p + 4);
		int c = (int)get32(p + 8);
		e = new_msg((Tcl_WideInt)end, get32(p + 12) != 0, c);
		memcpy(e->fds, m->fds + used, c * sizeof(int));
		e->nfd = c;
		used += c;
		queue_msg(ns, e);
	}
	m->nfd = 0; /* all moved */
	free_msg(m);
	m = NULL;
	if (nbuf > 0) {
		Tcl_Ungets(ns->chan, (char *)body + nmsg * HANDOFF_ENTRY + nopt, nbuf, 0);
		ns->received = nbuf;
	}
	/* The sender's options, those this package carries and nothing else. */
	for (i = 0; i < nelem; i += 2)
		for (j = 0; stream_opts[j]; j++)
			if (strcmp(Tcl_GetString(elems[i]), stream_opts[j]) == 0)
				Tcl_SetChannelOption(NULL, ns->chan, stream_opts[j], Tcl_GetString(elems[i + 1]));
	Tcl_RegisterChannel(interp, ns->chan);
	Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(ns->chan), -1));
	code = TCL_OK;
drop:
	if (m)
		free_msg(m);
out:
	for (i = 0; topts[i]; i++) {
		Tcl_SetChannelOption(NULL, t->chan, topts[i], Tcl_DStringValue(&vals[i]));
		Tcl_DStringFree(&vals[i]);
	}
	if (optobj)
		Tcl_DecrRefCount(optobj);
	if (body)
		ckfree(body);
	return code;
}

/* unix_extra::inheritfd channel  -> its fd number, close-on-exec cleared */
static int InheritfdCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	int fd, fl;
	(void)cd;
	if (objc != 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "channel");
		return TCL_ERROR;
	}
	if (chan_fd(interp, objv[1], NULL, &fd) != TCL_OK)
		return TCL_ERROR;
	if ((fl = fcntl(fd, F_GETFD)) == -1 || fcntl(fd, F_SETFD, fl & ~FD_CLOEXEC) == -1)
		return posix_error(interp, "inheritfd");
	Tcl_SetObjResult(interp, Tcl_NewIntObj(fd));
	return TCL_OK;
}

/* unix_extra::fdopen fd  -> a unix_extra channel on an inherited socket */
static int FdopenCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	Tcl_Obj *names, **nv;
	Tcl_Size nn, i;
	Stream *s;
	int fd, fl;
	(void)cd;
	if (objc != 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "fd");
		return TCL_ERROR;
	}
	if (Tcl_GetIntFromObj(interp, objv[1], &fd) != TCL_OK)
		return TCL_ERROR;
	if (fd >= 0 && fd < 3)
		return fail(interp, "STDIO", "fd %s is a standard channel: use unix_extra::adopt on it",
			Tcl_GetString(objv[1]));
	if (fd < 0 || (fl = fcntl(fd, F_GETFD)) == -1) {
		errno = fd < 0 ? EBADF : errno;
		return posix_error(interp, "fdopen");
	}
	if (!is_unix_stream(fd))
		return fail(interp, "NOTSTREAM", "fd %s is not a connected unix stream socket", Tcl_GetString(objv[1]));
	/* Two channels must not own one fd. */
	if (Tcl_GetChannelNamesEx(interp, NULL) == TCL_OK) {
		names = Tcl_GetObjResult(interp);
		Tcl_IncrRefCount(names);
		Tcl_ResetResult(interp);
		Tcl_ListObjGetElements(NULL, names, &nn, &nv);
		for (i = 0; i < nn; i++) {
			Tcl_Channel c = Tcl_GetChannel(interp, Tcl_GetString(nv[i]), NULL);
			ClientData h;
			if (c && (Tcl_GetChannelHandle(c, TCL_READABLE, &h) == TCL_OK ||
			    Tcl_GetChannelHandle(c, TCL_WRITABLE, &h) == TCL_OK) && (int)(intptr_t)h == fd) {
				Tcl_SetObjResult(interp, Tcl_ObjPrintf("fd %d already belongs to channel \"%s\"",
					fd, Tcl_GetString(nv[i])));
				Tcl_SetErrorCode(interp, "UNIX_EXTRA", "INUSE", NULL);
				Tcl_DecrRefCount(names);
				return TCL_ERROR;
			}
		}
		Tcl_DecrRefCount(names);
	}
	fcntl(fd, F_SETFD, fl | FD_CLOEXEC); /* not passed on any further */
	s = new_stream(fd, TCL_READABLE | TCL_WRITABLE, "uxstream");
	Tcl_RegisterChannel(interp, s->chan);
	Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(s->chan), -1));
	return TCL_OK;
}

/* unix_extra::dgram ?path? */
static int DgramCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	struct sockaddr_un sa;
	socklen_t salen;
	Tcl_Channel chan;
	int fd;
	(void)cd;
	if (objc > 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "?path?");
		return TCL_ERROR;
	}
	if (objc == 2 && make_addr(interp, objv[1], &sa, &salen) != TCL_OK)
		return TCL_ERROR;
	if ((fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0)) == -1)
		return posix_error(interp, "socket");
	if (objc == 2 && bind(fd, (struct sockaddr *)&sa, salen) == -1) {
		posix_error(interp, "bind");
		close(fd);
		return TCL_ERROR;
	}
	if ((chan = wrap_fd(interp, fd)) == NULL)
		return posix_error(interp, "channel");
	if (objc == 2 && sa.sun_path[0] != '\0') {
		char *p = ckalloc(strlen(sa.sun_path) + 1);
		strcpy(p, sa.sun_path);
		Tcl_CreateCloseHandler(chan, unlink_on_close, p);
	}
	Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(chan), -1));
	return TCL_OK;
}

/* unix_extra::sendto chan path data  (path "" = the connected peer) */
static int SendtoCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	struct sockaddr_un sa;
	socklen_t salen = 0;
	int fd;
	Tcl_Size len;
	unsigned char *data;
	ssize_t n;
	(void)cd;
	if (objc != 4) {
		Tcl_WrongNumArgs(interp, 1, objv, "channel path data");
		return TCL_ERROR;
	}
	if (chan_fd(interp, objv[1], NULL, &fd) != TCL_OK)
		return TCL_ERROR;
	if (Tcl_GetCharLength(objv[2]) > 0 && make_addr(interp, objv[2], &sa, &salen) != TCL_OK)
		return TCL_ERROR;
	data = Tcl_GetByteArrayFromObj(objv[3], &len);
	n = sendto(fd, data, len, MSG_NOSIGNAL, salen ? (struct sockaddr *)&sa : NULL, salen);
	if (n == -1)
		return posix_error(interp, "sendto");
	Tcl_SetObjResult(interp, Tcl_NewWideIntObj(n));
	return TCL_OK;
}

/* unix_extra::recv chan  -> the next datagram, whole */
static int RecvCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	int fd;
	ssize_t size, n;
	Tcl_Obj *res;
	(void)cd;
	if (objc != 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "channel");
		return TCL_ERROR;
	}
	if (chan_fd(interp, objv[1], NULL, &fd) != TCL_OK)
		return TCL_ERROR;
	/* Linux reports the real datagram size with MSG_TRUNC. */
	if ((size = recv(fd, NULL, 0, MSG_PEEK | MSG_TRUNC)) == -1)
		return posix_error(interp, "recv");
	res = Tcl_NewByteArrayObj(NULL, 0);
	n = recv(fd, Tcl_SetByteArrayLength(res, size), size, 0);
	if (n == -1) {
		Tcl_DecrRefCount(res);
		return posix_error(interp, "recv");
	}
	Tcl_SetByteArrayLength(res, n);
	Tcl_SetObjResult(interp, res);
	return TCL_OK;
}

/* unix_extra::notify state ?path?  -> 1 sent, 0 no $NOTIFY_SOCKET */
static int NotifyCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	struct sockaddr_un sa;
	socklen_t salen;
	Tcl_Obj *path;
	const char *env;
	unsigned char *data;
	int fd;
	Tcl_Size len;
	(void)cd;
	if (objc != 2 && objc != 3) {
		Tcl_WrongNumArgs(interp, 1, objv, "state ?path?");
		return TCL_ERROR;
	}
	if (objc == 3) {
		path = objv[2];
	} else if ((env = Tcl_GetVar2(interp, "env", "NOTIFY_SOCKET", TCL_GLOBAL_ONLY)) && *env) {
		path = Tcl_NewStringObj(env, -1);
	} else {
		Tcl_SetObjResult(interp, Tcl_NewIntObj(0));
		return TCL_OK;
	}
	Tcl_IncrRefCount(path);
	if (make_addr(interp, path, &sa, &salen) != TCL_OK) {
		Tcl_DecrRefCount(path);
		return TCL_ERROR;
	}
	Tcl_DecrRefCount(path);
	if ((fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0)) == -1)
		return posix_error(interp, "socket");
	data = Tcl_GetByteArrayFromObj(objv[1], &len);
	if (sendto(fd, data, len, MSG_NOSIGNAL, (struct sockaddr *)&sa, salen) == -1) {
		posix_error(interp, "notify");
		close(fd);
		return TCL_ERROR;
	}
	close(fd);
	Tcl_SetObjResult(interp, Tcl_NewIntObj(1));
	return TCL_OK;
}

/* unix_extra::sendfds chan channels ?data? */
static int SendfdsCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	union { struct cmsghdr h; char buf[CMSG_SPACE(MAX_FDS * sizeof(int))]; } ctl;
	struct msghdr msg;
	struct iovec iov;
	struct cmsghdr *cm;
	Tcl_Channel chan;
	Tcl_Obj **elems;
	int fd, i, fds[MAX_FDS];
	Tcl_Size nfd, len;
	ssize_t n;
	(void)cd;
	if (objc != 3 && objc != 4) {
		Tcl_WrongNumArgs(interp, 1, objv, "channel channels ?data?");
		return TCL_ERROR;
	}
	if (chan_fd(interp, objv[1], &chan, &fd) != TCL_OK ||
	    Tcl_ListObjGetElements(interp, objv[2], &nfd, &elems) != TCL_OK)
		return TCL_ERROR;
	if (nfd < 1 || nfd > MAX_FDS)
		return fail(interp, "NFDS", "need 1 to 253 channels to send%s", "");
	for (i = 0; i < nfd; i++)
		if (chan_fd(interp, elems[i], NULL, &fds[i]) != TCL_OK)
			return TCL_ERROR;
	iov.iov_base = (char *)"";
	iov.iov_len = 1; /* a stream message needs at least one byte */
	if (objc == 4) {
		iov.iov_base = Tcl_GetByteArrayFromObj(objv[3], &len);
		iov.iov_len = len;
		if (len == 0)
			return fail(interp, "DATA", "data must not be empty%s", "");
	}
	/* Keep the byte order: anything Tcl still buffers goes out first. */
	if (Tcl_Flush(chan) != TCL_OK)
		return posix_error(interp, "flush");
	if (Tcl_OutputBuffered(chan) > 0) {
		/* non-blocking and the socket is full: sending now would overtake */
		errno = EAGAIN;
		return posix_error(interp, "sendfds");
	}
	memset(&msg, 0, sizeof(msg));
	memset(&ctl, 0, sizeof(ctl));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = ctl.buf;
	msg.msg_controllen = CMSG_SPACE(nfd * sizeof(int));
	cm = CMSG_FIRSTHDR(&msg);
	cm->cmsg_level = SOL_SOCKET;
	cm->cmsg_type = SCM_RIGHTS;
	cm->cmsg_len = CMSG_LEN(nfd * sizeof(int));
	memcpy(CMSG_DATA(cm), fds, nfd * sizeof(int));
	if ((n = sendmsg(fd, &msg, MSG_NOSIGNAL)) == -1)
		return posix_error(interp, "sendmsg");
	Tcl_SetObjResult(interp, Tcl_NewWideIntObj(n));
	return TCL_OK;
}

/* unix_extra::recvfds chan ?maxbytes?  -> {data {channel ...}} */
static int RecvfdsCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	union { struct cmsghdr h; char buf[CMSG_SPACE(MAX_FDS * sizeof(int))]; } ctl;
	struct msghdr msg;
	struct iovec iov;
	struct cmsghdr *cm;
	Tcl_Channel chan;
	Tcl_Obj *data, *chans, *res;
	int fd, max = 4096, i, nfd = 0, fds[MAX_FDS];
	ssize_t n;
	(void)cd;
	if (objc != 2 && objc != 3) {
		Tcl_WrongNumArgs(interp, 1, objv, "channel ?maxbytes?");
		return TCL_ERROR;
	}
	if (chan_fd(interp, objv[1], &chan, &fd) != TCL_OK)
		return TCL_ERROR;
	if (objc == 3 && (Tcl_GetIntFromObj(interp, objv[2], &max) != TCL_OK || max < 1))
		return fail(interp, "MAXBYTES", "maxbytes must be a positive integer%s", "");
	/* Bytes Tcl already read ahead lost their fds in the kernel. */
	if (Tcl_InputBuffered(chan) > 0)
		return fail(interp, "BUFFERED", "channel \"%s\" has buffered input; "
			"use recvfds before reading the message through Tcl", Tcl_GetString(objv[1]));
	data = Tcl_NewByteArrayObj(NULL, 0);
	iov.iov_base = Tcl_SetByteArrayLength(data, max);
	iov.iov_len = max;
	memset(&msg, 0, sizeof(msg));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = ctl.buf;
	msg.msg_controllen = sizeof(ctl.buf);
	if ((n = recvmsg(fd, &msg, MSG_CMSG_CLOEXEC)) == -1) {
		Tcl_DecrRefCount(data);
		return posix_error(interp, "recvmsg");
	}
	Tcl_SetByteArrayLength(data, n);
	/* On a unix_extra channel these bytes still count in the stream offsets. */
	if (Tcl_GetChannelType(chan) == &StreamType)
		((Stream *)Tcl_GetChannelInstanceData(chan))->received += n;
	for (cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm)) {
		if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS) {
			int k = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
			if (k > MAX_FDS - nfd)
				k = MAX_FDS - nfd;
			memcpy(fds + nfd, CMSG_DATA(cm), k * sizeof(int));
			nfd += k;
		}
	}
	if (msg.msg_flags & MSG_CTRUNC) {
		/* The kernel dropped some fds: close the rest and say so. */
		for (i = 0; i < nfd; i++)
			close(fds[i]);
		Tcl_DecrRefCount(data);
		return fail(interp, "CTRUNC", "file descriptors were truncated%s", "");
	}
	chans = Tcl_NewListObj(0, NULL);
	for (i = 0; i < nfd; i++) {
		Tcl_Channel c = wrap_fd(interp, fds[i]);
		if (c != NULL)
			Tcl_ListObjAppendElement(NULL, chans, Tcl_NewStringObj(Tcl_GetChannelName(c), -1));
	}
	res = Tcl_NewListObj(0, NULL);
	Tcl_ListObjAppendElement(NULL, res, data);
	Tcl_ListObjAppendElement(NULL, res, chans);
	Tcl_SetObjResult(interp, res);
	return TCL_OK;
}

/* unix_extra::peercred chan  -> {pid P uid U gid G} */
static int PeercredCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	struct ucred uc;
	struct sockaddr_storage ss;
	socklen_t len = sizeof(ss);
	Tcl_Obj *res;
	int fd;
	(void)cd;
	if (objc != 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "channel");
		return TCL_ERROR;
	}
	if (chan_fd(interp, objv[1], NULL, &fd) != TCL_OK)
		return TCL_ERROR;
	if (getsockname(fd, (struct sockaddr *)&ss, &len) == -1)
		return posix_error(interp, "peercred");
	if (ss.ss_family != AF_UNIX)
		return fail(interp, "NOTUNIX", "channel \"%s\" is not a unix domain socket", Tcl_GetString(objv[1]));
	len = sizeof(uc);
	if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &uc, &len) == -1)
		return posix_error(interp, "peercred");
	if (uc.pid == 0)
		return fail(interp, "NOPEER", "channel \"%s\" has no connected peer", Tcl_GetString(objv[1]));
	res = Tcl_NewListObj(0, NULL);
	Tcl_ListObjAppendElement(NULL, res, Tcl_NewStringObj("pid", -1));
	Tcl_ListObjAppendElement(NULL, res, Tcl_NewWideIntObj(uc.pid));
	Tcl_ListObjAppendElement(NULL, res, Tcl_NewStringObj("uid", -1));
	Tcl_ListObjAppendElement(NULL, res, Tcl_NewWideIntObj(uc.uid));
	Tcl_ListObjAppendElement(NULL, res, Tcl_NewStringObj("gid", -1));
	Tcl_ListObjAppendElement(NULL, res, Tcl_NewWideIntObj(uc.gid));
	Tcl_SetObjResult(interp, res);
	return TCL_OK;
}

/* unix_extra::socketpair ?stream|dgram? */
static int SocketpairCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	static const char *const types[] = {"stream", "dgram", NULL};
	int idx = 0, sv[2];
	Tcl_Channel a, b;
	Tcl_Obj *res;
	(void)cd;
	if (objc > 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "?stream|dgram?");
		return TCL_ERROR;
	}
	if (objc == 2 && Tcl_GetIndexFromObj(interp, objv[1], types, "type", 0, &idx) != TCL_OK)
		return TCL_ERROR;
	if (socketpair(AF_UNIX, (idx ? SOCK_DGRAM : SOCK_STREAM) | SOCK_CLOEXEC, 0, sv) == -1)
		return posix_error(interp, "socketpair");
	if (idx == 0) {
		/* stream: unix_extra channels, which queue passed fds */
		a = new_stream(sv[0], TCL_READABLE | TCL_WRITABLE, "uxstream")->chan;
		b = new_stream(sv[1], TCL_READABLE | TCL_WRITABLE, "uxstream")->chan;
		Tcl_RegisterChannel(interp, a);
		Tcl_RegisterChannel(interp, b);
	} else {
		if ((a = wrap_fd(interp, sv[0])) == NULL) {
			close(sv[1]);
			return posix_error(interp, "channel");
		}
		if ((b = wrap_fd(interp, sv[1])) == NULL) {
			Tcl_UnregisterChannel(interp, a);
			return posix_error(interp, "channel");
		}
	}
	res = Tcl_NewListObj(0, NULL);
	Tcl_ListObjAppendElement(NULL, res, Tcl_NewStringObj(Tcl_GetChannelName(a), -1));
	Tcl_ListObjAppendElement(NULL, res, Tcl_NewStringObj(Tcl_GetChannelName(b), -1));
	Tcl_SetObjResult(interp, res);
	return TCL_OK;
}

int Unix_extra_Init(Tcl_Interp *interp)
{
	static const struct { const char *name; Tcl_ObjCmdProc *proc; } cmds[] = {
		{"dgram", DgramCmd},       {"sendto", SendtoCmd},
		{"recv", RecvCmd},         {"notify", NotifyCmd},
		{"sendfds", SendfdsCmd},   {"recvfds", RecvfdsCmd},
		{"peercred", PeercredCmd}, {"socketpair", SocketpairCmd},
		{"connect", ConnectCmd},   {"listen", ListenCmd},
		{"fds", FdsCmd},           {"adopt", AdoptCmd},
		{"handoff", HandoffCmd},   {"takeover", TakeoverCmd},
		{"inheritfd", InheritfdCmd}, {"fdopen", FdopenCmd},
	};
	size_t i;
	if (Tcl_InitStubs(interp, "8.6", 0) == NULL)
		return TCL_ERROR;
	for (i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++) {
		char name[64];
		snprintf(name, sizeof(name), "::" PKG_NAME "::%s", cmds[i].name);
		Tcl_CreateObjCommand(interp, name, cmds[i].proc, NULL, NULL);
	}
	return Tcl_PkgProvide(interp, PKG_NAME, PKG_VERSION);
}
