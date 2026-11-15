#!/usr/bin/env python3
"""fake-greetd.py SOCKET LOG - a stand-in for greetd with scripted PAM.

Speaks greetd's IPC (JSON, each message after a 32-bit native-endian
length) on a unix socket, one client at a time, and logs every request it
gets to LOG as one JSON line, so tests/greeter-flow.tcl can check what the
greeter really sent. The conversations, per user:

  alex   "Password:" (secret); "secret" succeeds, anything else is an
         auth_error
  sam    an info ("Place your finger on the reader"), then "Password:",
         then "Verification code:" (visible); succeeds with
         "pw" and "123456"
  locked an error message ("Your account has expired"), then auth_error
  ghost  create_session itself fails (error, not auth_error)
  guest  no authentication at all: success right away
"""
import json, os, socket, struct, sys

SCRIPTS = {
    "alex": [("secret", "Password:", "secret")],
    "sam": [("info", "Place your finger on the reader", None),
            ("secret", "Password:", "pw"),
            ("visible", "Verification code:", "123456")],
    "locked": [("error", "Your account has expired", None), ("fail", None, None)],
    "guest": [],
}


def recv(conn):
    head = b""
    while len(head) < 4:
        b = conn.recv(4 - len(head))
        if not b:
            return None
        head += b
    (n,) = struct.unpack("=I", head)
    data = b""
    while len(data) < n:
        b = conn.recv(n - len(data))
        if not b:
            return None
        data += b
    return json.loads(data.decode("utf-8"))


def send(conn, msg):
    data = json.dumps(msg).encode("utf-8")
    conn.sendall(struct.pack("=I", len(data)) + data)


def serve(conn, log):
    script, step, user = None, 0, None

    def ask():
        """The next step of the conversation, or success at its end."""
        nonlocal step
        if step >= len(script):
            return {"type": "success"}
        kind, text, _ = script[step]
        if kind == "fail":
            return {"type": "error", "error_type": "auth_error", "description": "pam_authenticate: AUTH_ERR"}
        return {"type": "auth_message", "auth_message_type": kind, "auth_message": text}

    while True:
        req = recv(conn)
        if req is None:
            return
        log.write(json.dumps(req) + "\n")
        log.flush()
        t = req.get("type")
        if t == "create_session":
            if script is not None:
                send(conn, {"type": "error", "error_type": "error", "description": "a session is already being configured"})
                continue
            user = req["username"]
            if user not in SCRIPTS:
                send(conn, {"type": "error", "error_type": "error", "description": "no such user"})
                continue
            script, step = SCRIPTS[user], 0
            send(conn, ask())
        elif t == "post_auth_message_response":
            if script is None or step >= len(script):
                send(conn, {"type": "error", "error_type": "error", "description": "no auth in progress"})
                continue
            kind, _, want = script[step]
            if kind in ("info", "error"):
                if "response" in req and req["response"] is not None:
                    send(conn, {"type": "error", "error_type": "error", "description": "unexpected response"})
                    continue
            elif req.get("response") != want:
                script = None
                send(conn, {"type": "error", "error_type": "auth_error", "description": "pam_authenticate: AUTH_ERR"})
                continue
            step += 1
            send(conn, ask())
        elif t == "start_session":
            if script is None or step < len(script):
                send(conn, {"type": "error", "error_type": "error", "description": "session not authenticated"})
                continue
            if not isinstance(req.get("cmd"), list) or not all(isinstance(s, str) for s in req.get("env", [])):
                send(conn, {"type": "error", "error_type": "error", "description": "bad start_session"})
                continue
            # (greetd now waits for the greeter to exit; the tests go on)
            script = None
            send(conn, {"type": "success"})
        elif t == "cancel_session":
            script = None
            send(conn, {"type": "success"})
        else:
            send(conn, {"type": "error", "error_type": "error", "description": "unknown request"})


def main():
    path, logpath = sys.argv[1], sys.argv[2]
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    s.listen(1)
    with open(logpath, "a") as log:
        while True:
            conn, _ = s.accept()
            with conn:
                serve(conn, log)


if __name__ == "__main__":
    main()
