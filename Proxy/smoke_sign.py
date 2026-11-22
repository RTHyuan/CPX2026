#!/usr/bin/env python3
"""Blind relay check on one operator-supplied camera JPEG. Add --live to submit it."""
import argparse
import base64
import copy
import http.client
import json
import os
from pathlib import Path
import subprocess
import threading
import uuid

import server


# ImageIO applies all eight EXIF orientations before resizing. Re-encoding fresh sRGB pixels excludes
# the source's EXIF/GPS, thumbnails, filename, comments, and original color profile from the request.
PHOTO_PREPROCESSOR = '''
import Foundation
import CoreGraphics
import ImageIO

let data = FileHandle.standardInput.readDataToEndOfFile()
let jpeg = "public.jpeg" as CFString
let native = ProcessInfo.processInfo.environment["PATHSENSE_SMOKE_NATIVE"] == "1"
let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: native ? 16384 : 960]
guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(src) == jpeg,
      CGImageSourceGetStatus(src) == .statusComplete,
      let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
      let rgb = CGColorSpace(name: CGColorSpace.sRGB),
      let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: rgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { exit(1) }
canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
guard let pixels = canvas.makeImage() else { exit(1) }
for quality in [0.72, 0.55, 0.38] {
    let output = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(output, jpeg, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, pixels, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    if CGImageDestinationFinalize(dest), output.length <= (native ? 8 * 1024 * 1024 : 360_000) {
        FileHandle.standardOutput.write(output as Data)
        exit(0)
    }
}
exit(1)
'''


def prepare_photo(path, native=False):
    if path.suffix.lower() not in ('.jpeg', '.jpg') or not path.is_file():
        raise ValueError('invalid_photo')
    with path.open('rb') as stream:
        # A positional read leaves the inherited stdin descriptor at byte zero for ImageIO.
        fd = stream.fileno()
        if os.fstat(fd).st_size > 64 * 1024**2 or os.pread(fd, 2, 0) != b'\xff\xd8':
            raise ValueError('invalid_photo')
        # Cache compiled SDK modules, never the operator's input pixels.
        cache = Path(__file__).resolve().parents[1] / '.build-local' / 'clang-module-cache'
        cache.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(['/usr/bin/swift', '-module-cache-path', str(cache), '-e', PHOTO_PREPROCESSOR],
                                env={**os.environ, 'PATHSENSE_SMOKE_NATIVE':'1' if native else '0'},
                                stdin=stream, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=120, check=True)
    return result.stdout


def make_context(width, height, session):
    # JPEG-only replay has no AR measurement. Pose values are fixed stand-ins, independent of scene content.
    pose = {'sample': {'id': {'session': session, 'world': 1, 'frame': 18}, 'time': 4.0,
                       'transform': [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,1.4,0,1],
                       'intrinsics': [550,0,0, 0,550,0, width/2,height/2,1], 'width': width, 'height': height,
                       'tracking': 'normal', 'exif': 1, 'headingDelta': 0, 'horizontalDelta': 0},
            'position': {'x': 0, 'y': 1.4, 'z': 0}, 'heading': 0}
    request = copy.deepcopy(pose)
    request['sample']['id']['frame'] += 1
    request['sample']['time'] += 0.1
    return {'utterance': '请帮我辨认眼前的线索。', 'destination': '眼前的线索', 'stage': '环顾四周',
            'trigger': 'first_observation', 'capture': pose, 'request': request, 'history': [],
            'image_width': width, 'image_height': height, 'image_transform': 'full upright, no crop',
            'features': [], 'known': [], 'scanned_bins': [], 'recent_hazards': [], 'sign_history': [],
            'last_instruction': '', 'moved_since_instruction': 0, 'turned_since_instruction': 0}


def redacted_summary(reply):
    # Remap even the validated refs: they are model-supplied strings and can contain a name or room number.
    result = {'status':'ok', 'frame_match':True, 'action':reply['action'], 'uncertain':reply['uncertain'], 'target_ref':None}
    for section, prefix in [('observations','o'), ('hazards','h')]:
        result[section] = []
        for index, item in enumerate(reply[section], 1):
            ref = prefix + str(index)
            safe = {'ref':ref, 'kind':item['kind'], 'box':[round(x, 4) for x in item['box']]}
            if item.get('sign') is not None:
                meaning = item['sign']
                safe['sign'] = {'symbol':meaning['symbol'], 'arrow':meaning.get('arrow'),
                                'text_chars':len(meaning.get('text') or '')}
            result[section].append(safe)
            if item['ref'] == reply['target_ref']:
                result['target_ref'] = ref
    return result


def relay_error(body):
    code = body.get('error') if isinstance(body, dict) else None
    allowed = server.UPSTREAM_ERRORS | {'busy', 'invalid_request'}
    return {'status':'error', 'error':code if isinstance(code, str) and code in allowed else 'relay_http'}


def exchange(relay, packet):
    conn = http.client.HTTPConnection('127.0.0.1', relay.server_port, timeout=15)
    try:
        conn.request('POST', f'/{relay.pair}/next', json.dumps(packet).encode(), {'Content-Type': 'application/json'})
        response = conn.getresponse()
        data = response.read(24577)
        server.require(len(data) <= 24576)
        reply = json.loads(data, object_pairs_hook=server.json_object)
        if response.status != 200:
            return relay_error(reply)
        capture = packet['context']['capture']['sample']['id']
        sources = None
        if packet.get('version') == 2:
            sources = {capture['frame'], *(frame['pose']['sample']['id']['frame'] for frame in packet['historical_frames'])}
        server.validate_reply(reply, capture, sources)
        summary = redacted_summary(reply)
        if sources is not None:
            summary.update(protocol=2, pose='injected', scene=reply['plan']['scene'],
                           task=reply['plan']['task'], completion=reply['plan']['completion'])
        return summary
    finally:
        conn.close()


def live(packet):
    try:
        key = server.demo_key()
    except (Exception, SystemExit):
        return {'status':'error', 'error':'configuration'}
    try:
        with server.Server(('127.0.0.1', 0), key) as relay:
            worker = threading.Thread(target=relay.serve_forever, daemon=True)
            worker.start()
            try:
                return exchange(relay, packet)
            finally:
                relay.shutdown()
                worker.join()
    except (OSError, http.client.HTTPException):
        return {'status':'error', 'error':'relay_transport'}
    except (ValueError, KeyError, TypeError, IndexError, RecursionError):
        return {'status':'error', 'error':'relay_schema'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', '--photo', dest='image', type=Path, required=True, metavar='PHOTO.jpg',
                        help='one real camera JPEG selected by the operator')
    parser.add_argument('--live', action='store_true', help='submit it once via the paired relay and demo_key()')
    parser.add_argument('--planner', action='store_true', help='use the production v2 task planner with an injected pose')
    args = parser.parse_args(argv)
    try:
        jpeg = prepare_photo(args.image, native=args.planner)
        width, height = server.jpeg_size(jpeg)
        ctx = make_context(width, height, str(uuid.uuid4()).upper())
        packet = {'context':ctx, 'image':base64.b64encode(jpeg).decode('ascii')}
        if args.planner:
            ctx.update(utterance='带我去厕所', destination='洗手间')
            packet.update(version=2, historical_frames=[], execution_state='observing',
                          planning={'scene':'unknown', 'task':'observe', 'version':0, 'requires_exit':False})
        server.validate_input(packet)
    except (OSError, ValueError, subprocess.SubprocessError, server.struct.error):
        result = {'status':'error', 'error':'invalid_photo'}
    else:
        result = live(packet) if args.live else {'status':'ready_offline', 'width':width, 'height':height}
    print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))
    return int(result['status'] == 'error')


if __name__ == '__main__':
    raise SystemExit(main())
