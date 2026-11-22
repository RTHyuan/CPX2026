#!/usr/bin/env python3
"""Copy the app's live map over USB and post it to a local map viewer."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_DEVICE = "00008150-001E481E1183C01C"
SOURCE = "Documents/LocalMaps/PathSense-live-map.json"
BUNDLE = "org.crosspointx.pathsense"
MAX_BYTES = 32 * 1024 * 1024


def local_url(value):
    try:
        url = urllib.parse.urlsplit(value)
        port = url.port
    except ValueError as error:
        raise argparse.ArgumentTypeError("URL has an invalid host or port") from error
    if (url.scheme not in ("http", "https") or url.hostname not in ("localhost", "127.0.0.1")
            or url.username is not None or url.password is not None or url.fragment
            or (port is not None and not 1 <= port <= 65535)):
        raise argparse.ArgumentTypeError("URL must use http(s) on localhost or 127.0.0.1, without credentials or fragments")
    return value


def positive_interval(value):
    try:
        interval = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("interval must be a positive number") from error
    if not 0 < interval < float("inf"):
        raise argparse.ArgumentTypeError("interval must be a finite positive number")
    return interval


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise urllib.error.HTTPError(request.full_url, code, "redirect refused", headers, response)


def reject_nonfinite(value):
    raise ValueError("nonfinite JSON number: " + value)


def transfer(device, url, opener):
    # This directory belongs only to this script. The iPhone source is read, never removed.
    with tempfile.TemporaryDirectory(prefix="pathsense-usb-map-") as temporary:
        destination = Path(temporary) / "live-map.json"
        command = ["xcrun", "devicectl", "device", "copy", "from", "--device", device,
                   "--source", SOURCE, "--domain-type", "appDataContainer",
                   "--domain-identifier", BUNDLE, "--destination", str(destination), "--timeout", "15"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
        if result.returncode:
            raise RuntimeError("USB copy unavailable (device locked, disconnected, or snapshot not yet saved)")
        if not destination.is_file():
            raise RuntimeError("USB copy did not produce a snapshot file")
        if destination.stat().st_size > MAX_BYTES:
            raise ValueError("snapshot exceeds the 32 MiB upload limit")
        snapshot = json.loads(destination.read_text(encoding="utf-8"), parse_constant=reject_nonfinite)
        if not isinstance(snapshot, dict):
            raise ValueError("snapshot must be a JSON object")
        payload = json.dumps(snapshot, ensure_ascii=False, allow_nan=False).encode("utf-8")
        request = urllib.request.Request(url, data=payload, method="POST",
                                         headers={"Content-Type": "application/json", "Accept": "application/json"})
        with opener.open(request, timeout=10) as response:
            if not 200 <= response.status < 300:
                raise RuntimeError("viewer rejected the snapshot")
            response.read(4096)
        return len(payload)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default=DEFAULT_DEVICE, help="paired iPhone identifier (default: %(default)s)")
    parser.add_argument("--url", default="http://127.0.0.1:8765/frame", type=local_url,
                        help="local viewer POST endpoint (default: %(default)s)")
    parser.add_argument("--interval", default=3.0, type=positive_interval,
                        help="seconds between copy attempts (default: %(default)s)")
    parser.add_argument("--once", action="store_true", help="try one transfer and exit; return 1 on failure")
    args = parser.parse_args(argv)
    if not args.device.strip():
        parser.error("--device must not be blank")
    # Bypass proxy settings and refuse redirects, so snapshots stay on the local endpoint.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    failures = 0
    try:
        while True:
            started = time.monotonic()
            try:
                size = transfer(args.device, args.url, opener)
                if failures:
                    print("USB map stream recovered.", flush=True)
                failures = 0
                print(f"Updated local viewer ({size:,} bytes).", flush=True)
                if args.once:
                    return 0
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, urllib.error.URLError) as error:
                failures += 1
                # Show the first error and occasional reminders without flooding the terminal.
                if args.once or failures == 1 or failures % 10 == 0:
                    print(f"Waiting for map: {error}", file=sys.stderr, flush=True)
                if args.once:
                    return 1
            time.sleep(max(0, args.interval - (time.monotonic() - started)))
    except KeyboardInterrupt:
        print("\nUSB map bridge stopped.", flush=True)
        return 0


if __name__ == "__main__":
    sys.exit(main())
