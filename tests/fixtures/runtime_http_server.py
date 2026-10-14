"""Real loopback HTTP fixtures whose startup does not depend on reverse DNS."""
from http.server import HTTPServer
from socketserver import TCPServer


class LoopbackHTTPServer(HTTPServer):
    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]
