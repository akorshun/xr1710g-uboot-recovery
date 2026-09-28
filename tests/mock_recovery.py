#!/usr/bin/env python3
"""Мок HTTP-рекавери XR1710G для тестов upload.sh / upload.ps1.

Повторяет то, что делает настоящий загрузчик:
  GET  /about               -> версия U-Boot, раскладка, (для wiro) ui_build
  GET  /status              -> прогресс стирания/записи
  GET  /status-ack/<gen>    -> подтверждение завершения
  POST /upload/uboot        -> проверка legacy-заголовка uImage и размера <= 1 МиБ
  POST /upload/firmware     -> проверка размера и параметра layout
"""

import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

UIMAGE_MAGIC = b"\x27\x05\x19\x56"
SLOT_MAX = 1024 * 1024

state = {
    "in_progress": 0,
    "erase_done": 0,
    "erase_total": 0,
    "write_done": 0,
    "write_total": 0,
    "ok": 0,
    "error": 0,
    "error_stage": "",
    "validation_detail": "",
    "completion_generation": 0,
    "target": "",
    "acked": 0,
    "uploads": 0,
}
lock = threading.Lock()
opts = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # тише в логах теста
        sys.stderr.write("mock: " + (fmt % args) + "\n")

    def _json(self, code, payload):
        # как на устройстве: компактный JSON без пробелов
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _text(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/about":
            about = {
                "u_boot": "U-Boot 2026.07-xr1710g-mock (Aug 05 2026 - 00:00:00 +0000)",
                "detected_layout": "UBI 2.0",
            }
            if opts.flavor == "wiro":
                about["ui_build"] = "xr1710g-wiro-recovery-20260902-r2"
            self._json(200, about)
            return
        if path == "/status":
            with lock:
                payload = dict(state)
            if opts.flavor == "new":
                # сборка YYH2913 отдаёт короткий JSON без подтверждения
                payload = {
                    key: payload[key]
                    for key in (
                        "in_progress",
                        "erase_done",
                        "erase_total",
                        "write_done",
                        "write_total",
                        "ok",
                        "error",
                    )
                }
            self._json(200, payload)
            return
        if path.startswith("/status-ack/"):
            gen = path.rsplit("/", 1)[-1]
            with lock:
                ok = gen == str(state["completion_generation"]) and gen != "0"
                if ok:
                    state["acked"] = 1
            self._json(200, {"acknowledged": 1 if ok else 0})
            return
        self._text(404, "not found\n")

    def do_POST(self):
        url = urlparse(self.path)
        path = url.path
        query = parse_qs(url.query)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)

        if path not in ("/upload/uboot", "/upload/firmware"):
            self._text(404, "not found\n")
            return
        target = path.rsplit("/", 1)[-1]

        if opts.flavor == "wiro" and "ui_build" not in query and opts.require_ui_build:
            self._text(400, "ui_build missing\n")
            return

        if target == "uboot":
            if len(body) > SLOT_MAX or not body.startswith(UIMAGE_MAGIC):
                self._reject("slot-validate", "legacy prefix invalid")
                return
        else:
            if len(body) < SLOT_MAX:
                self._reject("fit-validate", "image too small")
                return
            if "layout" not in query:
                self._text(400, "layout missing\n")
                return

        if opts.out:
            with open(opts.out, "wb") as handle:
                handle.write(body)
        if opts.query_log:
            with open(opts.query_log, "a", encoding="utf-8") as handle:
                handle.write(self.path + "\n")

        if opts.fail:
            self._reject("write", "simulated write failure")
            return

        with lock:
            state.update(
                in_progress=0,
                erase_done=8,
                erase_total=8,
                write_done=len(body),
                write_total=len(body),
                ok=1,
                error=0,
                target=target,
                completion_generation=7,
                uploads=state["uploads"] + 1,
            )
        self._text(200, "upload accepted\n")

    def _reject(self, stage, detail):
        with lock:
            state.update(
                in_progress=0, ok=0, error=7, error_stage=stage, validation_detail=detail
            )
        self._text(400, "rejected: %s\n" % detail)


def main():
    global opts
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--flavor", choices=["wiro", "new"], default="wiro")
    parser.add_argument("--out", help="куда сохранить принятое тело запроса")
    parser.add_argument("--query-log", help="куда дописывать запрошенные URL")
    parser.add_argument("--port-file", help="куда записать выбранный порт")
    parser.add_argument("--fail", action="store_true", help="эмулировать ошибку записи")
    parser.add_argument("--require-ui-build", action="store_true")
    parser.add_argument(
        "--lifetime",
        type=float,
        default=180.0,
        help="через сколько секунд выключиться, чтобы не оставаться в системе",
    )
    opts = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", opts.port), Handler)
    server.daemon_threads = True
    if opts.lifetime > 0:
        timer = threading.Timer(opts.lifetime, server.shutdown)
        timer.daemon = True
        timer.start()
    port = server.server_address[1]
    if opts.port_file:
        with open(opts.port_file, "w", encoding="utf-8") as handle:
            handle.write(str(port))
    sys.stderr.write("mock: listening on 127.0.0.1:%d (%s)\n" % (port, opts.flavor))
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
