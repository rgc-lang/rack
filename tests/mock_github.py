#!/usr/bin/env python3
"""mock_github.py — offline GitHub API / raw mock server (for rack regression tests)

Directory layout (the root pointed to by --fixtures):
    repos/<owner>/<repo>/tags.txt         tag list (falls back to scanning version directories)
    repos/<owner>/<repo>/<tag>/rack.toml
    repos/<owner>/<repo>/<tag>/<name>.rg
    search.json                           candidate entries for /search/repositories

Routes:
    GET /repos/<owner>/<repo>/tags?per_page=&page=   paginated tag list
    GET /search/repositories?q=                      filters search.json by term
    GET /raw/<owner>/<repo>/<tag>/<path>             repository files

After startup the listening port is written to --port-file; the test script
polls that file. --log records every request (including whether an Authorization
header was present) to verify tokens are only sent to the API."""

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

FIXTURES = ""
LOG_PATH = ""
log_lock = threading.Lock()


def repo_dir(owner: str, repo: str) -> str:
    return os.path.join(FIXTURES, "repos", owner, repo)


def log_request(line: str) -> None:
    if not LOG_PATH:
        return
    with log_lock:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def list_tags(directory: str) -> list:
    tags = []
    seen = set()
    tags_file = os.path.join(directory, "tags.txt")
    if os.path.isfile(tags_file):
        with open(tags_file, encoding="utf-8") as f:
            for raw in f:
                name = raw.strip()
                if name and name not in seen:
                    tags.append(name)
                    seen.add(name)
    if os.path.isdir(directory):
        for name in sorted(os.listdir(directory), reverse=True):
            if name not in seen and os.path.isdir(os.path.join(directory, name)):
                tags.append(name)
                seen.add(name)
    return tags


def search_items(query: str) -> list:
    path = os.path.join(FIXTURES, "search.json")
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as f:
        items = json.load(f)
    terms = [t.lower() for t in query.split() if t and not t.startswith("topic:")]
    if not terms:
        return items
    out = []
    for item in items:
        hay = (item.get("full_name", "") + " " + item.get("description", "")).lower()
        if all(term in hay for term in terms):
            out.append(item)
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # silent: access logs go to the --log file
        pass

    def send_body(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, status: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_body(status, body, "application/json")

    def not_found(self) -> None:
        self.send_body(404, b"404: Not Found", "text/plain; charset=utf-8")

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        auth = self.headers.get("Authorization", "-")
        log_request("GET " + self.path + " auth=" + auth)

        if path.startswith("/repos/"):
            parts = path.strip("/").split("/")
            if len(parts) == 4 and parts[3] == "tags":
                directory = repo_dir(parts[1], parts[2])
                if not os.path.isdir(directory):
                    self.not_found()
                    return
                tags = list_tags(directory)
                try:
                    page = int(query.get("page", ["1"])[0])
                    per_page = int(query.get("per_page", ["30"])[0])
                except ValueError:
                    page, per_page = 1, 30
                per_page = max(1, min(100, per_page))
                start = (max(1, page) - 1) * per_page
                items = [
                    {"name": name, "commit": {"sha": "0" * 40}}
                    for name in tags[start:start + per_page]
                ]
                self.send_json(items)
                return
            self.not_found()
            return

        if path == "/search/repositories":
            q = query.get("q", [""])[0]
            items = search_items(q)
            self.send_json({"total_count": len(items), "items": items})
            return

        if path.startswith("/raw/"):
            parts = path.strip("/").split("/")
            if len(parts) < 5:
                self.not_found()
                return
            owner, repo, tag = parts[1], parts[2], parts[3]
            rel = "/".join(parts[4:])
            base = os.path.normpath(repo_dir(owner, repo))
            target = os.path.normpath(os.path.join(base, tag, rel))
            if not target.startswith(base + os.sep) or not os.path.isfile(target):
                self.not_found()
                return
            with open(target, "rb") as f:
                data = f.read()
            self.send_body(200, data, "text/plain; charset=utf-8")
            return

        self.not_found()


def main() -> int:
    global FIXTURES, LOG_PATH
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log", default="")
    args = parser.parse_args()
    FIXTURES = os.path.abspath(args.fixtures)
    LOG_PATH = args.log

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w", encoding="utf-8") as f:
        f.write(str(server.server_address[1]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
