import os
import socket
import sys
from http.server import ThreadingHTTPServer


def serve(model: str, path: str) -> int:
    from mlx_lm import server as mlx_server

    class UnixServer(ThreadingHTTPServer):
        def __init__(self, address, handler):
            type(self).address_family = socket.AF_UNIX
            super().__init__(path, handler)

        def server_bind(self):
            self.socket.bind(path)
            os.chmod(path, 0o600)
            self.server_address = path
            self.server_name = "unix"
            self.server_port = 0

        def get_request(self):
            connection, _ = super().get_request()
            return connection, ("unix", 0)

    mlx_server._run_http_server.__defaults__ = (UnixServer, mlx_server.APIHandler)
    sys.argv = ["mlx_lm.server", "--model", model, "--host", "127.0.0.1", "--port", "0"]
    mlx_server.main()
    return 0
