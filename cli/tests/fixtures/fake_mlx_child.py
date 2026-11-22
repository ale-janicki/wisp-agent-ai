import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PATH = sys.argv[1]
LOG = os.environ.get("FAKE_CHILD_LOG")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = json.dumps({"data": [{"id": "default_model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if LOG:
            with open(LOG, "a") as out:
                out.write(json.dumps({"body": body, "offline": os.environ.get("HF_HUB_OFFLINE")}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for chunk in ({"choices": [{"delta": {"content": "oi do mlx"}}]}, {"choices": [{"delta": {}}], "usage": {"prompt_tokens": 3, "completion_tokens": 2}}):
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")


class UnixServer(HTTPServer):
    address_family = socket.AF_UNIX

    def server_bind(self):
        self.socket.bind(PATH)
        self.server_address = PATH
        self.server_name = "unix"
        self.server_port = 0

    def get_request(self):
        connection, _ = super().get_request()
        return connection, ("unix", 0)


UnixServer(PATH, Handler).serve_forever()
