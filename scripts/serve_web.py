#!/usr/bin/env python3
"""Serves the Web export (build/web) on localhost for testing.

The export is single-threaded (variant/thread_support=false), which needs no
special headers. This still sends the cross-origin isolation pair, so a
threaded export (SharedArrayBuffer) runs here unchanged:

    Cross-Origin-Opener-Policy: same-origin
    Cross-Origin-Embedder-Policy: require-corp

Binds to 127.0.0.1 only. Browsers treat localhost as a secure context, which
the Gamepad API and cross-origin isolation both require.

    python3 scripts/serve_web.py [--port 8060] [--root build/web]
"""

import argparse
import functools
import http.server
import os
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".pck": "application/octet-stream",
        ".js": "text/javascript",
    }

    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8060)
    parser.add_argument("--root", default="build/web")
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    if not os.path.isfile(os.path.join(root, "index.html")):
        print(f"No index.html in {root}: run `make export-web` first.", file=sys.stderr)
        return 1
    handler = functools.partial(Handler, directory=root)
    with http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler) as server:
        print(f"Serving {root} at http://127.0.0.1:{args.port}/ (Ctrl+C stops)")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
