#!/usr/bin/env python3
"""Debug simulator transport for the real DeepSeek demo request.

Usage:
  python3 Scripts/simulator-demo-relay.py --port 0 --state-file .build-local/simulator-relay.json
  python3 Scripts/simulator-demo-relay.py --self-test

Set SIMCTL_CHILD_PATHSENSE_SIMULATOR_DEMO_RELAY to the state's endpoint before
launching the debug simulator app. The state contains no provider credential.
Stop the process in its terminal (or send SIGTERM to the state's pid) after use.
The production prompt, image, provider response and app parser remain in use.
"""

import argparse
import base64
import binascii
import hmac
import http.client
import json
import os
from pathlib import Path
import secrets
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Proxy"))
from server import demo_key, frame_id, json_object, provider_tls_context, validate_image

MAX_BODY = 12 * 1024 * 1024
MAX_RESPONSE = 131_072


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def validate_request(packet):
    if not isinstance(packet, dict) or set(packet) != {
        "model", "thinking", "response_format", "stream", "max_tokens", "messages"
    }:
        raise ValueError("packet")
    if (packet["model"] != "deepseek-flash" or packet["thinking"] != {"type": "disabled"}
            or packet["response_format"] != {"type": "json_object"}
            or packet["stream"] is not False or packet["max_tokens"] != 350):
        raise ValueError("configuration")
    messages = packet["messages"]
    if not isinstance(messages, list) or len(messages) != 2:
        raise ValueError("messages")
    system, user = messages
    if (not isinstance(system, dict) or set(system) != {"role", "content"} or system["role"] != "system"
            or not isinstance(system["content"], str) or not isinstance(user, dict)
            or set(user) != {"role", "content"} or user["role"] != "user"):
        raise ValueError("roles")
    content = user["content"]
    if not isinstance(content, list) or len(content) != 2:
        raise ValueError("content")
    text, photo = content
    if not isinstance(text, dict) or set(text) != {"type", "text"} or text["type"] != "text":
        raise ValueError("text")
    context = json.loads(text["text"], object_pairs_hook=json_object)
    if not isinstance(context, dict) or set(context) != {
        "protocol_version", "output_language", "locale", "destination", "capture",
        "image_width", "image_height", "previous", "walking_ready"
    } or context["protocol_version"] != "demo-v1":
        raise ValueError("context")
    language = context["locale"]
    if (language, context["output_language"]) not in (("en-US", "English"), ("zh-CN", "简体中文")):
        raise ValueError("language")
    destination = context["destination"]
    previous = context["previous"]
    if (not isinstance(destination, str) or not destination.strip() or len(destination) > 160
            or not isinstance(previous, list) or len(previous) > 2
            or any(not isinstance(item, str) or len(item) > 160 for item in previous)
            or type(context["walking_ready"]) is not bool):
        raise ValueError("demo context")
    stamp = context["capture"]["sample"]["id"]
    frame_id(stamp)
    resource = "deepseek-demo-en-v1.txt" if language == "en-US" else "deepseek-demo-v1.txt"
    template = (ROOT / "App/Resources" / resource).read_text(encoding="utf-8")
    prefix, suffix = template.split("__PATHSENSE_CAPTURE_ID__")
    prompt = system["content"]
    if not prompt.startswith(prefix) or not prompt.endswith(suffix):
        raise ValueError("prompt")
    stamp_text = prompt[len(prefix):len(prompt) - len(suffix)] if suffix else prompt[len(prefix):]
    if json.loads(stamp_text, object_pairs_hook=json_object) != stamp:
        raise ValueError("prompt capture")
    if not isinstance(photo, dict) or set(photo) != {"type", "image_url"} or photo["type"] != "image_url":
        raise ValueError("photo")
    image = photo["image_url"]
    if not isinstance(image, dict) or set(image) != {"url"} or not isinstance(image["url"], str):
        raise ValueError("photo url")
    prefix = "data:image/jpeg;base64,"
    if not image["url"].startswith(prefix):
        raise ValueError("photo encoding")
    width, height = context["image_width"], context["image_height"]
    if type(width) is not int or type(height) is not int or not (1 <= width <= 16384 and 1 <= height <= 16384):
        raise ValueError("photo size")
    validate_image(image["url"][len(prefix):], width, height, 8 * 1024 * 1024)
    return context


def provider(body, key):
    connection = http.client.HTTPSConnection("api.deepseek.com", timeout=24, context=provider_tls_context())
    try:
        connection.request("POST", "/chat/completions", body,
                           {"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        response = connection.getresponse()
        if response.status != 200:
            # Provider error bodies and headers may contain sensitive diagnostics.
            return response.status, compact({"error": "upstream_http"}).encode()
        data = response.read(MAX_RESPONSE + 1)
        if len(data) > MAX_RESPONSE:
            raise ValueError("response size")
        envelope = json.loads(data, object_pairs_hook=json_object)
        if not isinstance(envelope, dict) or not isinstance(envelope.get("choices"), list):
            raise ValueError("provider envelope")
        return 200, data
    finally:
        connection.close()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def send_body(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.wfile.write(body)

    def error(self, status, reason):
        self.send_body(status, compact({"error": reason}).encode())

    def do_GET(self):
        self.error(404, "not_found")

    def do_POST(self):
        if not hmac.compare_digest(self.path, self.server.route):
            return self.error(404, "not_found")
        if (self.headers.get("Origin") is not None or self.headers.get("Authorization") is not None
                or self.headers.get("Host") != "127.0.0.1:" + str(self.server.server_port)):
            return self.error(403, "invalid_origin")
        if not self.server.slot.acquire(blocking=False):
            return self.error(429, "busy")
        started = time.monotonic()
        try:
            if started - self.server.last_request < self.server.minimum_interval:
                return self.error(429, "upstream_rate_limit")
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY or self.headers.get_content_type() != "application/json":
                    raise ValueError("body")
                raw = self.rfile.read(length)
                if len(raw) != length:
                    raise ValueError("truncated")
                packet = json.loads(raw, object_pairs_hook=json_object)
                context = validate_request(packet)
            except (ValueError, TypeError, KeyError, IndexError, binascii.Error, RecursionError):
                return self.error(400, "invalid_request")
            self.server.last_request = started
            self.server.event({"event": "ds_request", "capture": context["capture"]["sample"]["id"],
                               "destination": context["destination"], "language": context["output_language"],
                               "walking_ready": context["walking_ready"], "image_bytes": len(raw)})
            try:
                status, body = self.server.provider(raw, self.server.key)
                if status == 200:
                    envelope = json.loads(body, object_pairs_hook=json_object)
                    choice = envelope["choices"][0]
                    reply = json.loads(choice["message"]["content"], object_pairs_hook=json_object)
                    # Text-only scene/action evidence is useful when preparing the recording.
                    fields = {name: reply.get(name) for name in
                              ("frame_id", "action", "scene_zh", "speech_zh", "target_kind", "target_box")}
                    self.server.event({"event": "ds_reply", "seconds": round(time.monotonic() - started, 2), **fields})
                else:
                    self.server.event({"event": "ds_error", "http_status": status})
                self.send_body(status, body)
            except ssl.SSLError:
                self.error(502, "upstream_tls")
            except TimeoutError:
                self.error(504, "upstream_timeout")
            except (OSError, http.client.HTTPException):
                self.error(502, "upstream_transport")
            except (ValueError, TypeError, KeyError, IndexError, RecursionError):
                self.error(502, "upstream_schema")
        finally:
            self.server.slot.release()


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, key, upstream=provider, minimum_interval=1.0, logging=True):
        self.key = key
        self.route = "/" + secrets.token_urlsafe(24) + "/demo"
        self.slot = threading.BoundedSemaphore(1)
        self.provider = upstream
        self.last_request = float("-inf")
        self.minimum_interval = minimum_interval
        self.logging = logging
        super().__init__(("127.0.0.1", port), Handler)

    @property
    def endpoint(self):
        return "http://127.0.0.1:" + str(self.server_port) + self.route

    def event(self, event):
        if self.logging:
            print(compact(event), flush=True)

    def handle_error(self, *args):
        pass


def self_test():
    # A minimal valid JPEG shape for transport validation; no external network calls.
    jpeg = bytes.fromhex("ffd8ffc00011080001000103012200021101031100") + bytes(20) + bytes.fromhex("ffd9")
    stamp = {"session": "11111111-1111-4111-8111-111111111111", "world": 1, "frame": 1}
    context = {"protocol_version": "demo-v1", "output_language": "English", "locale": "en-US", "destination": "door",
               "capture": {"sample": {"id": stamp}}, "image_width": 1, "image_height": 1, "previous": [], "walking_ready": False}
    template = (ROOT / "App/Resources/deepseek-demo-en-v1.txt").read_text(encoding="utf-8")
    packet = {"model": "deepseek-flash", "thinking": {"type": "disabled"}, "response_format": {"type": "json_object"},
              "stream": False, "max_tokens": 350, "messages": [
                  {"role": "system", "content": template.replace("__PATHSENSE_CAPTURE_ID__", compact(stamp))},
                  {"role": "user", "content": [{"type": "text", "text": compact(context)},
                   {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(jpeg).decode()}}]}]}
    raw = compact(packet).encode()
    calls = []
    def fake(body, key):
        calls.append(body)
        return 200, compact({"choices": [{"message": {"role": "assistant", "content": compact({"action": "look"})}, "finish_reason": "stop"}]}).encode()
    with Server(0, "test-only", fake, minimum_interval=0, logging=False) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def post(path, body, extra=None):
            conn = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
            conn.request("POST", path, body, {"Content-Type": "application/json", **(extra or {})})
            response = conn.getresponse()
            result = response.status, response.read()
            conn.close()
            return result
        assert post("/wrong/demo", raw)[0] == 404
        assert post(server.route, raw, {"Origin": "http://example.com"})[0] == 403
        assert post(server.route, b"{}")[0] == 400
        assert post(server.route, raw)[0] == 200
        assert calls == [raw]
        packet["messages"][0]["content"] = "different prompt"
        assert post(server.route, compact(packet).encode())[0] == 400
        assert len(calls) == 1
        server.shutdown()
    print("simulator relay self-test passed: loopback, capability, origin, production prompt, image, unchanged request")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    with Server(args.port, demo_key()) as server:
        state = {"pid": os.getpid(), "endpoint": server.endpoint, "transport": "debug-simulator-only"}
        if args.state_file:
            args.state_file.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.state_file.with_suffix(args.state_file.suffix + ".tmp")
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                output.write(compact(state) + "\n")
            os.replace(temporary, args.state_file)
            print("Simulator DS relay ready; state: " + str(args.state_file), flush=True)
        else:
            print(compact(state), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
