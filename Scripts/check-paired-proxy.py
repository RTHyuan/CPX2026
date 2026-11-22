#!/usr/bin/env python3
"""Check the deployed LAN relay with the project's single public CC0 door photograph."""
import argparse
import base64
import http.client
import ipaddress
import json
import re
import sys
import uuid
from pathlib import Path
from time import monotonic
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Proxy'))
import smoke_sign
import server


def check(pairing_file):
    # Use a numeric, local address. Never echo the capability URL, response body or exception.
    url = urlsplit(pairing_file.read_text().strip())
    ip = ipaddress.IPv4Address(url.hostname)
    allowed = any(ip in ipaddress.ip_network(block) for block in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))
    if not (allowed and url.scheme == 'http' and url.port and not url.username and not url.password
            and not url.query and not url.fragment and re.fullmatch(r'/[A-Za-z0-9_-]{16,80}', url.path)):
        raise ValueError('invalid local endpoint')
    image = smoke_sign.prepare_photo(ROOT / 'App/Resources/Practice/route-door.jpg')
    width, height = server.jpeg_size(image)
    ctx = smoke_sign.make_context(width, height, str(uuid.uuid4()).upper())
    packet = {'context': ctx, 'image': base64.b64encode(image).decode('ascii')}
    server.validate_input(packet)
    conn = http.client.HTTPConnection(str(ip), url.port, timeout=18)
    start = monotonic()
    try:
        conn.request('POST', url.path + '/next', json.dumps(packet).encode(), {'Content-Type': 'application/json'})
        r = conn.getresponse()
        buf = r.read(24577)
        server.require(len(buf) <= 24576)
        body = json.loads(buf, object_pairs_hook=server.json_object)
        if r.status == 200:
            server.validate_reply(body, ctx['capture']['sample']['id'])
            result = smoke_sign.redacted_summary(body)
        else:
            result = smoke_sign.relay_error(body)
        return {'source': 'public CC0 door photo', 'client': 'Mac on Wi-Fi', 'model': server.MODEL,
                'http': r.status, 'seconds': round(monotonic() - start, 3), **result}
    finally:
        conn.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pairing_file', type=Path)
    try:
        result = check(parser.parse_args().pairing_file)
    except (OSError, TypeError, ValueError, KeyError, http.client.HTTPException):
        result = {'status': 'error', 'error': 'local_probe_failed'}
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(result.get('status') != 'ok')
