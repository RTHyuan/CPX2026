#!/usr/bin/env python3
"""Serve the local map viewer and actual iPhone exports. Standard library only."""
from __future__ import annotations

import argparse
import copy
import hmac
import json
import math
import mimetypes
from pathlib import Path
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
MAX_BODY = 8 * 1024 * 1024
MAX_POINTS = 120_000
MAX_PATH = 10_000


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and abs(value) <= 1_000_000


def point(value):
    return isinstance(value, list) and len(value) == 3 and all(number(v) for v in value)


def position(value):
    return isinstance(value, dict) and all(number(value.get(k)) for k in ('x', 'y', 'z'))


def identifier(value):
    if not isinstance(value, dict):
        return None
    session, world = value.get('session'), value.get('world')
    if isinstance(session, str) and 0 < len(session) <= 80 and isinstance(world, int) and not isinstance(world, bool):
        return session, world
    return None


def frame_identifier(value):
    return (identifier(value) is not None and isinstance(value.get('frame'), int)
            and not isinstance(value.get('frame'), bool) and value['frame'] >= 0)


def world_of(snapshot):
    pose = snapshot.get('pose') or {}
    stamp = identifier(pose.get('id')) or identifier(pose.get('frame'))
    if stamp:
        return stamp
    for pose in reversed(snapshot.get('path', [])):
        if stamp := identifier(pose.get('frame')):
            return stamp
    return None


def decode(payload):
    """Keep snapshot fields intact, while checking the geometry drawn by the viewer."""
    if not isinstance(payload, dict):
        raise ValueError('Expected a JSON object containing a local-map snapshot.')
    snapshot = payload.get('snapshot', payload)
    if not isinstance(snapshot, dict):
        raise ValueError('snapshot must be an object.')
    path = snapshot.get('path', [])
    landmarks = snapshot.get('landmarks', [])
    points = payload.get('points', snapshot.get('points', []))
    if not isinstance(path, list) or not isinstance(landmarks, list) or not isinstance(points, list):
        raise ValueError('path, landmarks and points must be arrays.')
    if len(path) > MAX_PATH or len(landmarks) > 2048 or len(points) > MAX_POINTS:
        raise ValueError('Map exceeds the viewer input limit.')
    for item in path:
        if not isinstance(item, dict) or not position(item.get('position')):
            raise ValueError('Each path entry needs a finite position {x,y,z}.')
        if 'frame' in item and not frame_identifier(item['frame']):
            raise ValueError('Each frame needs session, world and an integer frame number.')
        if 'heading' in item and not number(item['heading']):
            raise ValueError('Path headings must be finite numbers.')
    for item in landmarks:
        if not isinstance(item, dict) or (item.get('point') is not None and not position(item['point'])):
            raise ValueError('Each positioned landmark needs a finite point {x,y,z}.')
    if not all(point(item) for item in points):
        raise ValueError('points must contain finite [x,y,z] coordinates in metres.')
    pose = snapshot.get('pose')
    if pose is not None:
        if not isinstance(pose, dict):
            raise ValueError('pose must be an object or null.')
        transform = pose.get('transform')
        if transform is not None and (not isinstance(transform, list) or len(transform) != 16 or not all(number(v) for v in transform)):
            raise ValueError('pose.transform must contain 16 finite numbers.')
        stamp = pose.get('id', pose.get('frame'))
        if stamp is not None and not frame_identifier(stamp):
            raise ValueError('pose.id needs session, world and an integer frame number.')
    result = {key: copy.deepcopy(snapshot[key]) for key in
              ('pose', 'path', 'landmarks', 'sectors', 'sectorPose', 'sectorExpiresAt', 'pointSource') if key in snapshot}
    result.setdefault('path', [])
    result.setdefault('landmarks', [])
    result['points'] = points
    if 'pointSource' in payload:
        result['pointSource'] = payload['pointSource']
    if result.get('pointSource') is not None and (not isinstance(result['pointSource'], str) or len(result['pointSource']) > 80):
        raise ValueError('pointSource must be a short string or null.')
    current_world = world_of(result)
    if any(identifier(item.get('frame')) not in (None, current_world) for item in path):
        raise ValueError('A snapshot cannot mix session/world coordinate systems.')
    return result


def parse_bytes(data):
    def finite_float(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError('Non-finite JSON number.')
        return result
    return decode(json.loads(data, parse_float=finite_float,
                             parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Non-finite JSON number.'))))


class MapStore:
    def __init__(self, source=None, watch=None):
        self.lock = threading.RLock()
        self.snapshot = {'path': [], 'landmarks': [], 'points': []}
        self.revision = 0
        self.received_at = None
        self.source = 'No map loaded'
        self.source_path = source
        self.watch = watch
        self.file_stamp = None
        self.load_error = None

    def replace(self, snapshot, source):
        with self.lock:
            self.snapshot = snapshot
            self.revision += 1
            self.received_at = time.time()
            self.source = source
            self.load_error = None

    def load_latest(self):
        with self.lock:
            source = self.source_path
            try:
                if self.watch:
                    candidates = [p for p in self.watch.glob('*.json') if p.is_file() and not p.is_symlink()]
                    source = max(candidates, key=lambda p: p.stat().st_mtime_ns) if candidates else None
                if source is None:
                    return
                stat = source.stat()
                stamp = (str(source), stat.st_mtime_ns, stat.st_size)
                if stamp == self.file_stamp:
                    return
                if stat.st_size > MAX_BODY:
                    raise ValueError('JSON file exceeds 8 MB.')
                snapshot = parse_bytes(source.read_bytes())
                self.replace(snapshot, 'Mac file: ' + source.name)
                self.file_stamp = stamp
            except (OSError, ValueError, TypeError) as error:
                self.load_error = str(error)

    def merge(self, incoming):
        with self.lock:
            old_world, new_world = world_of(self.snapshot), world_of(incoming)
            if old_world is not None and new_world is None:
                raise ValueError('A live frame needs session/world identifiers.')
            if new_world != old_world and (new_world is not None or self.revision == 0):
                self.snapshot = {'path': [], 'landmarks': [], 'points': []}
            old = self.snapshot
            path = []
            seen = set()
            for pose in old.get('path', []) + incoming.get('path', []):
                stamp = pose.get('frame') or {}
                key = (stamp.get('session'), stamp.get('world'), stamp.get('frame')) if stamp else tuple(pose['position'][k] for k in ('x', 'y', 'z'))
                if key not in seen:
                    seen.add(key)
                    path.append(pose)
            # The latest frame can carry only a raw AR pose, rather than a path delta.
            pose = incoming.get('pose') or {}
            transform = pose.get('transform')
            if transform:
                entry = {'frame': pose.get('id', pose.get('frame', {})), 'time': pose.get('time'),
                         'position': dict(zip(('x', 'y', 'z'), transform[12:15])),
                         'heading': math.degrees(math.atan2(-transform[8], transform[10]))}
                stamp = entry['frame']
                key = (stamp.get('session'), stamp.get('world'), stamp.get('frame'))
                if key not in seen:
                    path.append(entry)
            voxels = {}
            previous_points = old.get('points', []) if old.get('pointSource') == incoming.get('pointSource') else []
            for p in previous_points + incoming.get('points', []):
                voxels[tuple(math.floor(v / .08) for v in p)] = p
            landmarks = {str(p.get('id', i)): p for i, p in enumerate(old.get('landmarks', []))}
            landmarks.update({str(p.get('id', i)): p for i, p in enumerate(incoming.get('landmarks', []))})
            merged = {**old, **incoming, 'path': path[-MAX_PATH:],
                      'points': list(voxels.values())[-MAX_POINTS:], 'landmarks': list(landmarks.values())[-2048:]}
            self.replace(merged, 'HTTP /frame — received device data')
            return self.revision

    def state(self):
        self.load_latest()
        with self.lock:
            return {'revision': self.revision, 'receivedAt': self.received_at, 'source': self.source,
                    'snapshot': copy.deepcopy(self.snapshot), 'error': self.load_error}


def make_handler(store, token):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'PathSenseMap/1'

        def reply(self, status, body, kind='application/json; charset=utf-8'):
            if not isinstance(body, bytes):
                body = json.dumps(body, ensure_ascii=False, allow_nan=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urlsplit(self.path)
            if url.path in ('/state', '/api/state'):
                return self.reply(200, store.state())
            if url.path == '/download.json':
                return self.reply(200, store.state()['snapshot'])
            if url.path == '/data':
                if not store.watch:
                    return self.reply(400, {'error': 'Start with --watch DIRECTORY to select exported files.'})
                name = parse_qs(url.query).get('file', [''])[0]
                if not name or Path(name).name != name or not name.endswith('.json'):
                    return self.reply(400, {'error': 'Use a JSON filename from /files.'})
                target = store.watch / name
                if target.is_symlink() or not target.is_file():
                    return self.reply(404, {'error': 'File not found.'})
                try:
                    if target.stat().st_size > MAX_BODY:
                        raise ValueError('JSON file exceeds 8 MB.')
                    return self.reply(200, parse_bytes(target.read_bytes()))
                except (OSError, ValueError) as error:
                    return self.reply(400, {'error': str(error)})
            if url.path == '/files':
                files = sorted(p.name for p in store.watch.glob('*.json') if p.is_file() and not p.is_symlink()) if store.watch else []
                return self.reply(200, {'files': files})
            if url.path in ('/', '/viewer.html'):
                return self.reply(200, (ROOT / 'MappingData/viewer.html').read_bytes(), 'text/html; charset=utf-8')
            # Serve floor-plan assets only, never the repository or user directories.
            if url.path.startswith('/floorplans/'):
                base = (ROOT / 'MappingData/floorplans').resolve()
                target = (base / unquote(url.path.removeprefix('/floorplans/'))).resolve()
                if not target.is_relative_to(base) or not target.is_file() or target.is_symlink():
                    return self.reply(404, {'error': 'Floor-plan asset not found.'})
                return self.reply(200, target.read_bytes(), mimetypes.guess_type(target.name)[0] or 'application/octet-stream')
            return self.reply(404, {'error': 'Not found.'})

        def do_POST(self):
            if urlsplit(self.path).path != '/frame':
                return self.reply(404, {'error': 'Use POST /frame.'})
            if token and not hmac.compare_digest(self.headers.get('X-Map-Token', ''), token):
                return self.reply(401, {'error': 'Missing or invalid X-Map-Token.'})
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= MAX_BODY:
                    return self.reply(413, {'error': 'Send a JSON body of at most 8 MB.'})
                data = self.rfile.read(length)
                snapshot = parse_bytes(data)
                payload = json.loads(data)
                store.load_latest()
                if payload.get('mode') == 'append':
                    revision = store.merge(snapshot)
                else:
                    store.replace(snapshot, 'HTTP /frame — received device snapshot')
                    revision = store.revision
                return self.reply(200, {'ok': True, 'revision': revision})
            except (ValueError, TypeError, OSError) as error:
                return self.reply(400, {'error': str(error)})

        def log_message(self, fmt, *args):
            # Avoid writing per-frame payloads or tokens into logs.
            if str(args[1]) not in ('200', '304'):
                super().log_message(fmt, *args)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1', help='Default: loopback. Use 0.0.0.0 explicitly for trusted LAN reception.')
    parser.add_argument('--port', type=int, default=8765)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument('--json', type=Path, help='Open an actual App export and reload when that file changes.')
    inputs.add_argument('--file', type=Path, help='Load an actual App JSON export once at startup.')
    inputs.add_argument('--watch', type=Path, help='Follow the newest *.json in a Mac export directory.')
    parser.add_argument('--token', help='Optional POST /frame authentication via X-Map-Token.')
    args = parser.parse_args()
    if args.watch and not args.watch.is_dir():
        parser.error('--watch must be an existing directory.')
    if args.json and not args.json.is_file():
        parser.error('--json must be an existing JSON file.')
    store = MapStore(args.json.resolve() if args.json else None, args.watch.resolve() if args.watch else None)
    if args.file:
        try:
            if args.file.stat().st_size > MAX_BODY:
                raise ValueError('JSON file exceeds 8 MB.')
            store.replace(parse_bytes(args.file.read_bytes()), 'Mac file: ' + args.file.name)
        except (OSError, ValueError, TypeError) as error:
            parser.error(str(error))
    store.load_latest()
    server = ThreadingHTTPServer((args.host, args.port), make_handler(store, args.token))
    print(f'Map viewer: http://127.0.0.1:{server.server_port}/', flush=True)
    if args.host not in ('127.0.0.1', 'localhost', '::1'):
        print(f'LAN reception enabled on {args.host}:{server.server_port}; use your Mac LAN IP on the iPhone.', flush=True)
    print('Displays input data only; no sample map is generated. Import an App export or send a snapshot to POST /frame.', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
