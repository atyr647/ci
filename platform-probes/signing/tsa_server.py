#!/usr/bin/env python3
"""A local RFC 3161 time-stamping server (HTTP POST of application/timestamp-query, reply application/timestamp-reply) built on `openssl ts -reply`.
Lets the signing flow be exercised with a real time-stamp token without any network access. usage: tsa_server.py <pki dir> <port>"""
import http.server, subprocess, sys, tempfile, os
pki = os.path.abspath(sys.argv[1]); port = int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        q = self.rfile.read(int(self.headers['Content-Length']))
        with tempfile.TemporaryDirectory() as d:
            open(d + '/q.tsq', 'wb').write(q)
            r = subprocess.run(['openssl', 'ts', '-reply', '-config', pki + '/tsa.cnf', '-section', 'tsa_config1', '-queryfile', d + '/q.tsq', '-out', d + '/r.tsr'], capture_output=True)
            if r.returncode:
                sys.stderr.write(r.stderr.decode()); self.send_response(500); self.end_headers(); return
            out = open(d + '/r.tsr', 'rb').read()
        self.send_response(200); self.send_header('Content-Type', 'application/timestamp-reply'); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
