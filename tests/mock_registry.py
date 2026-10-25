#!/usr/bin/env python3
"""mock_registry.py — offline web-registry mock server (for rack regression tests)

Simulates the RGC web registry endpoints used by rack:

    PUT  /api/v1/packages/new                     publish (JSON body, module as UTF-8 text)
    POST /api/v1/auth/cli/token                   one-time login code -> API token (§10)
    DELETE /api/v1/packages/{s}/{n}/{v}/yank      yank a version (§4.7)

The mock mirrors the backend error contract:
    400 invalid_name            flat package name (hints at scope/name)
    400 repository_required       missing repository field
    400 invalid_repository       repository is not a GitHub owner/repo
    400 invalid_code             login code invalid/expired/used
    403 repo_not_owned           repository belongs to someone else
    403 github_app_not_installed App not installed on the repository
    409 version_exists           the version already exists
    201 created                  successful publish

After startup the listening port is written to --port-file; --log records every
request line (method, path, Authorization header) for token assertions."""

import argparse
import hashlib
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

LOG_PATH = ""
log_lock = threading.Lock()


def log_request(line: str) -> None:
    if not LOG_PATH:
        return
    with log_lock:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def send_json(handler, obj, status: int = 200) -> None:
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def error_body(code: str, message: str) -> dict:
    return {"error": {"code": code, "message": message}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # silent: access logs go to --log
        pass

    def do_PUT(self):
        parsed = urlparse(self.path)
        auth = self.headers.get("Authorization", "-")
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length)
        log_request(
            "PUT " + self.path + " auth=" + auth
        )

        if parsed.path != "/api/v1/packages/new":
            send_json(self, error_body("not_found", "unknown endpoint"), 404)
            return
        if not auth.startswith("Bearer ") or len(auth[len("Bearer "):]) == 0:
            send_json(self, error_body("missing_token", "authentication required"), 401)
            return

        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            send_json(self, error_body("invalid_json", "invalid JSON body"), 400)
            return

        name = body.get("name", "")
        version = body.get("version", "")
        repository = body.get("repository", "")
        module = body.get("module", "")

        if "/" not in name:
            send_json(
                self,
                error_body(
                    "invalid_name",
                    "package name must be `scope/name` (e.g. `alice/calcx`), got `%s`" % name,
                ),
                400,
            )
            return
        if not repository:
            send_json(
                self,
                error_body(
                    "repository_required",
                    "publishing to the web registry requires a `repository` GitHub URL in rack.toml",
                ),
                400,
            )
            return
        owner = repository.strip().rstrip("/").split("/")[-2] if "/" in repository else ""
        scope = name.split("/")[0]
        if "nosuch" in repository:
            send_json(
                self,
                error_body(
                    "github_app_not_installed",
                    "the GitHub App is not installed on `%s`; install the RGC Registry App and try again" % repository,
                ),
                403,
            )
            return
        if owner and owner != scope:
            send_json(
                self,
                error_body(
                    "repo_not_owned",
                    "repository `%s` is not owned by `%s`" % (repository, scope),
                ),
                403,
            )
            return
        if version == "9.9.9":
            send_json(self, error_body("version_exists", "%s@9.9.9 already exists" % name), 409)
            return

        cksum = hashlib.sha256(module.encode("utf-8")).hexdigest()
        send_json(
            self,
            {
                "name": name,
                "vers": version,
                "cksum": cksum,
                "dl": "http://127.0.0.1:%d/api/v1/packages/%s/%s/%s/download"
                % (self.server.server_address[1], scope, name.split("/")[1], version),
                "yanked": False,
            },
            201,
        )


    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length)
        log_request("POST " + self.path + " auth=-")

        # §10 Device Flow（OAuth Device Grant）：codes 发放设备码，token 立即视为已确认。
        if parsed.path == "/api/v1/auth/device/codes":
            send_json(
                self,
                {
                    "device_code": "rgcd_mock_0001",
                    "user_code": "MOCK-0001",
                    "verification_uri": "http://127.0.0.1:%d/device"
                    % self.server.server_address[1],
                    "verification_uri_complete": "http://127.0.0.1:%d/device?code=MOCK-0001"
                    % self.server.server_address[1],
                    "expires_in": 30,
                    "interval": 1,
                },
                200,
            )
            return
        if parsed.path == "/api/v1/auth/device/token":
            try:
                body = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                send_json(self, error_body("invalid_json", "invalid JSON body"), 400)
                return
            device_code = body.get("device_code", "")
            if device_code.startswith("rgcd_mock_bad"):
                send_json(
                    self,
                    error_body(
                        "expired_token",
                        "the device code expired; start `rack login` again",
                    ),
                    400,
                )
                return
            if device_code != "rgcd_mock_0001":
                send_json(
                    self,
                    error_body("invalid_device_code", "unknown device code"),
                    400,
                )
                return
            if LOG_PATH:
                with log_lock:
                    with open(LOG_PATH, "a", encoding="utf-8") as f:
                        f.write("ISSUED-TOKEN rgc_mock_device\n")
            send_json(
                self,
                {"access_token": "rgc_mock_device", "token_type": "Bearer", "scope": "publish"},
                200,
            )
            return

        if parsed.path != "/api/v1/auth/cli/token":
            send_json(self, error_body("not_found", "unknown endpoint"), 404)
            return
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            send_json(self, error_body("invalid_json", "invalid JSON body"), 400)
            return
        code = body.get("code", "")
        # 与后端一致的取值空间：任何以 "bad" 开头的 code 视为无效，其余一律换成功。
        if not code or code.startswith("bad"):
            send_json(
                self,
                error_body("invalid_code", "CLI login code is invalid, expired, or already used"),
                400,
            )
            return
        if LOG_PATH:
            with log_lock:
                with open(LOG_PATH, "a", encoding="utf-8") as f:
                    f.write("ISSUED-TOKEN rgc_mock_%s\n" % code)
        send_json(
            self,
            {"token": "rgc_mock_" + code, "name": "cli-mock", "scope": "publish"},
            200,
        )

    def do_DELETE(self):
        parsed = urlparse(self.path)
        auth = self.headers.get("Authorization", "-")
        log_request("DELETE " + self.path + " auth=" + auth)

        # /api/v1/packages/{scope}/{name}/{version}/yank
        parts = parsed.path.strip("/").split("/")
        if (
            len(parts) == 7
            and parts[0] == "api"
            and parts[1] == "v1"
            and parts[2] == "packages"
            and parts[6] == "yank"
        ):
            if not auth.startswith("Bearer ") or len(auth[len("Bearer "):]) == 0:
                send_json(self, error_body("missing_token", "authentication required"), 401)
                return
            if parts[5] == "0.0.0":
                send_json(
                    self,
                    error_body("version_not_found", "version `0.0.0` does not exist"),
                    404,
                )
                return
            send_json(
                self,
                {"name": "%s/%s" % (parts[3], parts[4]), "vers": parts[5], "yanked": True},
                200,
            )
            return
        send_json(self, error_body("not_found", "unknown endpoint"), 404)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log", default="")
    args = parser.parse_args()

    global LOG_PATH
    LOG_PATH = args.log

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w", encoding="utf-8") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()