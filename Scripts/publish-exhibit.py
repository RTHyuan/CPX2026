"""Prepare the offline exhibit from a successful record-exhibit.py run on macOS."""
from argparse import ArgumentParser
from base64 import b64encode
import json
import math
from pathlib import Path
import re
import subprocess
import tempfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
STAGES = [
    ('01-home', '输入 402，开始持续扫描。', 'Enter room 402 and start continuous scanning.'),
    ('route-01-door', '发现疑似门，请核对门口与通道。', 'Check the possible doorway and the passage.'),
    ('route-origin', '门牌是 208。寻找楼层目录。', 'The starting room plate reads 208. Look for a directory.'),
    ('route-02-directory', '目录将目标列在四楼。寻找电梯指示。', 'The directory lists the destination on 4F. Look for a lift sign.'),
    ('route-floor', '楼层牌显示 4F，继续沿本层指示寻找 402。', 'The landing sign reads 4F. Follow the corridor signs to 402.'),
    ('route-verify', '镜头对准 402，核对独立门牌。', 'Scan and verify the standalone 402 plate.'),
    ('route-03-arrived', '使用者确认到达，摄像头停止。', 'The traveler confirms arrival and the camera stops.'),
]
# These stages can also be captioned when an editor has inspected their timing in the raw capture.
ADDITIONAL_CUES = [
    ('route-leave', '通过门后环顾，寻找刚经过的门牌。', 'After passing through the door, look for the room plate.'),
    ('route-lift', '电梯标识朝右。核对后前往四楼。', 'The lift sign points right. Check the lift and travel to 4F.'),
    ('route-turn', '本层的指示牌朝左，继续寻找 402。', 'The corridor sign points left toward room 402.'),
]


def stamp(seconds):
    n = round(seconds * 1000)
    return f'{n // 3600000:02}:{n // 60000 % 60:02}:{n // 1000 % 60:02}.{n % 1000:03}'


def publish(run, capture_offset, timeline=None):
    attachments = run / 'attachments'
    start = json.loads((run / 'start.json').read_text())['captureStart']
    files = {}
    for test in json.loads((attachments / 'manifest.json').read_text()):
        for item in test['attachments']:
            name = item['suggestedHumanReadableName'].split('_0_')[0]
            files[name] = attachments / item['exportedFileName']
    # The device clock and host capture start can differ. Check key frames before delivery.
    markers = {m['name']: m['time'] - start + capture_offset for m in json.loads(files['walkthrough-times'].read_text())}
    cut = max(0, markers['01-home'] - 1.6)
    length = markers['route-03-arrived'] + 1.9 - cut
    thresholds = [0] + [max(0, markers[name] - cut - 0.6) for name, _, _ in STAGES[1:]] + [length]
    cues = STAGES
    if timeline is not None:
        # Raw-video offsets let captions follow the visible cue rather than XCTest screenshot latency.
        edit = json.loads(timeline.read_text())
        cut = edit['start']
        length = edit['end'] - cut
        lookup = {row[0]: row for row in STAGES + ADDITIONAL_CUES}
        cues = [lookup[key] for key, _ in edit['cues']]
        thresholds = [seconds - cut for _, seconds in edit['cues']] + [length]
    if (not all(math.isfinite(t) for t in [cut, *thresholds]) or cut < 0 or thresholds[0] != 0
            or any(a >= b for a, b in zip(thresholds, thresholds[1:]))):
        raise ValueError('Inconsistent exhibit timestamps.')
    media = ROOT / 'docs/media'
    html = (ROOT / 'docs/index.html').read_text()
    with tempfile.TemporaryDirectory(dir=media) as temp:
        stage = Path(temp)
        cache = ROOT / '.build-local/exhibit-swift-cache'
        cache.mkdir(parents=True, exist_ok=True)
        subprocess.run(['xcrun', 'swift', '-module-cache-path', str(cache), str(ROOT / 'Scripts/export-exhibit.swift'),
                        str(run / 'raw.mp4'), str(stage / 'pathsense-demo.mp4'), f'{cut:.3f}', f'{length:.3f}'], check=True)
        for name in [s[0] for s in STAGES] + [n for n in ['home-dark', 'navigation-dark'] if n in files]:
            with Image.open(files[name]) as source:
                image = source.convert('RGB')
                image.thumbnail((1050, 2050))
                image.save(stage / f'{name}.jpg', quality=89, optimize=True)
        for index, (lang, tag) in enumerate([('zh', 'zh-Hans'), ('en', 'en')], 1):
            rows = [f'{stamp(thresholds[i])} --> {stamp(thresholds[i+1])}\n{row[index]}\n' for i, row in enumerate(cues)]
            content = 'WEBVTT\n\n' + '\n'.join(rows)
            (stage / f'captions-{lang}.vtt').write_text(content)
            uri = 'data:text/vtt;base64,' + b64encode(content.encode()).decode()
            html, count = re.subn(r'(<track [^>]*srclang="' + tag + r'"[^>]*src=")[^"]*', lambda m: m[1] + uri, html)
            if count != 1:
                raise ValueError(f'Missing subtitle track: {tag}')
        for asset in stage.iterdir():
            asset.replace(media / asset.name)
    (ROOT / 'docs/index.html').write_text(html)
    print(f'Exported {length:.3f} seconds, starting at {cut:.3f}.')
    print(dict(zip((row[0] for row in cues), (round(t, 3) for t in thresholds))))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--capture-offset', type=float, default=0, help='Measured adjustment to the recording clock in seconds.')
    parser.add_argument('--timeline', type=Path, help='Optional frame-reviewed JSON with raw start, end and [cue, seconds] pairs.')
    args = parser.parse_args()
    publish(args.run.resolve(), args.capture_offset, args.timeline)
