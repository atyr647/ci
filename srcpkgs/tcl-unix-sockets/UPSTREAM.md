# Offering the patches upstream

The two patches in `patches/` are written against unix_sockets v0.7
(commit fb6b67bd) so they can go to
<https://github.com/cyanogilvie/unix_sockets> as they are. **Nothing has
been sent.** Whether and when to open the pull request is the
maintainers' call. Proposed text below. The patches are `git
format-patch` output, so `git am patches/*.patch` on a v0.7 checkout
gives the two commits.

- `0001-tests-wait-for-accept.patch`: a fix for a test race on its own.
  It can be a separate PR, or the first commit of the same one.
- `0002-passfds.patch`: the feature.

---

## PR title

Add -passfds: receive file descriptors passed with SCM_RIGHTS

## PR description

Unix sockets can carry open file descriptors (`sendmsg` with
`SCM_RIGHTS`): socket activation, a privileged helper handing out opened
files, Wayland, D-Bus. Today a unix_sockets channel can't receive them.
A passed descriptor travels with the bytes of the `sendmsg` that carried
it, and the kernel hands it to the first read that takes some of those
bytes. `inputProc` reads with `read()`, which can't take it, so the
kernel closes it. Tcl reads ahead, so this happens even before the
script has looked at those bytes. No layer above the driver can get the
descriptors back: a stacked transform only sees what `read()` returned.

This PR adds an opt-in mode in which the driver reads with `recvmsg`
instead and keeps the descriptors.

### API

```tcl
unix_sockets::connect path ?-passfds bool?
unix_sockets::listen path accept_handler ?-passfds bool?   ;# for every accepted connection
unix_sockets::fds channel ?-all? ?-messages?
```

- Each message's descriptors are queued on the channel, in order. Each
  batch is tagged with the stream offset (bytes since the connection was
  made) where the message that carried it ended. That offset is exact:
  the kernel ends a read right after a message that carries descriptors.
  The one exception is a message larger than `-buffersize`, whose
  descriptors arrive with its first part.
- `unix_sockets::fds` returns a new channel for each descriptor of the
  messages the script has read in full, so `gets`, `read` and
  `chan event` work exactly as before:

  ```tcl
  set con [unix_sockets::connect /run/files.sock -passfds 1]
  puts $con "OPEN image.squashfs"; flush $con
  gets $con status
  set image [lindex [unix_sockets::fds $con] 0]
  ```

  `-all` also takes the descriptors of a message still in Tcl's buffer.
  `-messages` returns `{offset {channel ...}}` pairs, one per message.
- Received descriptors are close-on-exec (`MSG_CMSG_CLOEXEC`, or
  `FD_CLOEXEC` where that flag doesn't exist). Descriptors never taken
  are closed with the channel.
- If the kernel could not pass all of a message's descriptors (the open
  file limit), `fds` fails once with errorCode `{UNIX_SOCKETS CTRUNC}`
  rather than losing them silently. Then it returns those that arrived.
  On a channel without `-passfds 1` it fails with
  `{UNIX_SOCKETS PASSFDS}`.
- `chan configure` gains two read-only options:
  - `-passfds`: 0 or 1.
  - `-fdqueue`: empty without `-passfds`. Otherwise the byte count read
    from the socket, then `{offset lost {fd ...}}` per queued message.
    The fds stay owned by the channel. This lets another extension take
    a connection over without linking against this one: it duplicates
    the descriptors and rebases the offsets. Ribbon's unix_extra::adopt
    uses it.

### Design notes

- **Opt-in, set at creation.** Without the option nothing changes:
  same code path (`read()`), same `wrong # args` messages as a prefix,
  and every existing test passes unchanged. It is a creation option, not
  a settable channel option, because it must be on before the first
  read. Descriptors read before it was turned on would already be gone,
  and a creation option makes that mistake impossible. Options go after
  the positional arguments so that the existing argument errors (and
  tests uds-2.*) stay as they are.
- **Offsets, not "descriptors per read".** Tying descriptors to Tcl reads
  would be meaningless, because Tcl reads ahead. The end offset of the
  carrying message is the one position the kernel actually guarantees.
  Where the message began can't be known (a read may start with earlier
  bytes), so it isn't claimed.
- **No sending side.** Sending needs no driver support (any code holding
  the fd can call `sendmsg`), so this PR stays about the part only the
  driver can do. A `unix_sockets::sendfds` could follow if wanted.
- **Portability.** The code is plain POSIX `recvmsg`/`CMSG_*`. The "a read
  ends after a message with descriptors" rule that makes offsets exact
  is Linux's (`unix_stream_read_generic`), and that is where it was
  tested. Elsewhere the descriptors are still kept, in order, but their
  offsets may be later than the message end.
- Channel transfer to another interp or thread (`interp transfer`,
  `thread::transfer`) moves the queue with the channel.

### Tests

New tests `uds-8.1` to `uds-8.10` cover:

- gets, blocking and non-blocking reads, `chan event` across messages
  sent with pauses, one big `read`, `-messages`, `-all`, and a message
  larger than the buffer;
- queued fds closed on close (counted in `/proc/self/fd`), `-fdqueue`,
  the default unchanged (the kernel discards, nothing leaks), transfer to
  a child interp, and argument and option errors.

The sending peer is python3 (`socket.send_fds`, 3.9+), so the suite
gains no C helper. Without it these tests are skipped (constraint
`sendfds`). All 34 tests pass, also with the extension built with
`-fsanitize=address,undefined`. The patched `main.c` builds with gcc
`-std=c11 -Wall -Wextra -Wpedantic -Werror`, which is what meson's
`warning_level=3` and `werror` ask for.

### Separate fix: racy tests uds-5.2 and uds-6.2

uds-5.2 and uds-6.2 call `update` once and then use `::accepted`. One
`update` does not always run the accept handler. In a loop of
`make test TESTFLAGS="-match uds-6.*"`, uds-6.2 failed 11 times out of
30 with `can not find channel named ""` on unmodified v0.7. It never
failed when run alone. Patch 0001 waits for `::accepted` instead (0 of
30 after).

The documentation (`doc/unix_sockets.md.in`, `README.md`) describes the
option and the semantics, under a new PASSING FILE DESCRIPTORS section.
Licence: contributed under the package's own terms (those of the Tcl
core).
