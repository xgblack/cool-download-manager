#!/usr/bin/env python3
import argparse
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Metrics:
    def __init__(self):
        self.lock = threading.Lock()
        self.requests = 0
        self.head_requests = 0
        self.body_bytes = 0
        self.active = 0
        self.max_active = 0

    def begin(self):
        with self.lock:
            self.requests += 1
            self.active += 1
            self.max_active = max(self.max_active, self.active)

    def end(self):
        with self.lock:
            self.active -= 1

    def add_bytes(self, count):
        with self.lock:
            self.body_bytes += count

    def snapshot(self):
        with self.lock:
            return {
                "requests": self.requests,
                "head_requests": self.head_requests,
                "body_bytes": self.body_bytes,
                "active": self.active,
                "max_active": self.max_active,
            }


def make_handler(size, mode, bytes_per_second, first_byte_delay):
    metrics = Metrics()
    range_pattern = re.compile(r"bytes=(\d+)-(\d+)$")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, _format, *_args):
            pass

        def do_HEAD(self):
            if self.path != "/file":
                self.send_error(404)
                return
            with metrics.lock:
                metrics.head_requests += 1
            if mode == "ignore":
                self.send_response(405)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Length", str(size))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", '"fixture-v1"')
            self.end_headers()

        def do_GET(self):
            if self.path == "/metrics":
                payload = json.dumps(metrics.snapshot(), sort_keys=True).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                return
            if self.path != "/file":
                self.send_error(404)
                return

            start, end, status = 0, size - 1, 200
            requested_range = self.headers.get("Range")
            match = range_pattern.fullmatch(requested_range or "")
            if mode == "range" and match:
                start, end = int(match.group(1)), int(match.group(2))
                if start < 0 or end < start or end >= size:
                    self.send_error(416)
                    return
                status = 206

            length = end - start + 1
            self.send_response(status)
            self.send_header("Content-Length", str(length))
            self.send_header("ETag", '"fixture-v1"')
            if status == 206:
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()

            metrics.begin()
            try:
                if first_byte_delay:
                    time.sleep(first_byte_delay)
                remaining = length
                chunk = b"x" * (64 * 1024)
                while remaining:
                    output = chunk[: min(len(chunk), remaining)]
                    self.wfile.write(output)
                    self.wfile.flush()
                    metrics.add_bytes(len(output))
                    remaining -= len(output)
                    if bytes_per_second:
                        time.sleep(len(output) / bytes_per_second)
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                metrics.end()

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--size-mib", type=int, required=True)
    parser.add_argument("--mode", choices=("range", "ignore"), default="range")
    parser.add_argument("--per-connection-mib", type=float, default=0)
    parser.add_argument("--first-byte-ms", type=float, default=0)
    args = parser.parse_args()

    handler = make_handler(
        args.size_mib * 1024 * 1024,
        args.mode,
        args.per_connection_mib * 1024 * 1024,
        args.first_byte_ms / 1000,
    )
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    server.daemon_threads = True
    print(f"READY port={args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
