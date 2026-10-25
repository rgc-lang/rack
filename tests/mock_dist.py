#!/usr/bin/env python3
"""mock_dist.py — static download-center mock (for rack self regression tests)

Serves a directory over HTTP exactly like the real rgc-dev.tensorplay.cn/dist
layout:

    dist/channels/stable.json
    dist/versions/<version>/manifest.json
    dist/files/<asset>

The listening port is written to --port-file after startup so the test can use
an ephemeral port.
"""

import argparse
import functools
import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", required=True, help="Directory to serve")
    parser.add_argument("--port-file", required=True, help="Write the listening port here")
    args = parser.parse_args()

    handler = functools.partial(SimpleHTTPRequestHandler, directory=args.dir)
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    port = server.server_address[1]
    tmp = args.port_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(str(port))
    os.replace(tmp, args.port_file)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
