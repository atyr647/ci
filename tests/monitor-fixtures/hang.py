# A display stand-in and a client that hangs: the parent listens on the unix socket given, the child connects
# and never reads, the parent sends to it twice a second. The child's pid is written to the file given.
#   python3 hang.py SOCKET PIDFILE SECONDS
import os, socket, sys, time
path, pidfile, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(4)
pid = os.fork()
if pid == 0:
    srv.close()
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.connect(path)
    time.sleep(secs)
    os._exit(0)
conn, _ = srv.accept()
with open(pidfile + ".part", "w") as f:
    f.write(str(pid))
os.rename(pidfile + ".part", pidfile)
end = time.time() + secs
try:
    while time.time() < end:
        conn.send(b"x" * 64)
        time.sleep(0.5)
finally:
    os.kill(pid, 9)
