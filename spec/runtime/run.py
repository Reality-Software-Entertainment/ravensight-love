"""No external connections, credentials, TLS exemptions or production requests."""
import argparse
import http.server
import pathlib
import subprocess
import threading
import time


class Fixture(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def respond(self, code, body=b'', headers=None, length=None):
        self.send_response(code)
        self.send_header('Content-Length', str(len(body) if length is None else length))
        self.send_header('Connection', 'close')
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        assert 0 <= size <= 1024
        body = self.rfile.read(size)
        self.server.paths.append(self.path)
        if self.path != '/echo?part=one%20two&n=2':
            self.respond(400)
        else:
            self.respond(200, body)

    def do_GET(self):
        self.server.paths.append(self.path)
        if self.path == '/redirect':
            self.respond(302, headers={'Location': '/must-not-follow'})
        elif self.path == '/large':
            self.respond(200, b'x' * 4096)
        elif self.path == '/headers':
            self.respond(200, headers={'X-Large': 'x' * 4096})
        elif self.path == '/truncated':
            self.respond(200, b'partial', length=100)
        elif self.path == '/slow':
            time.sleep(1)
            self.respond(200, b'late')
        else:
            self.respond(404)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--lua', default='luajit')
    parser.add_argument('--transport', required=True, choices=['winhttp', 'libcurl'])
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture) as server:
        server.paths = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.run([
                args.lua, 'spec/runtime/transport.lua',
                'http://127.0.0.1:' + str(server.server_port), args.transport,
            ], cwd=root, timeout=25, check=False)
            assert '/must-not-follow' not in server.paths, 'native transport followed redirect'
            if result.returncode:
                raise SystemExit(result.returncode)
            assert len(server.paths) == 6, 'unexpected retries or missing requests'
        finally:
            server.shutdown()
            thread.join(timeout=2)


if __name__ == '__main__':
    main()
