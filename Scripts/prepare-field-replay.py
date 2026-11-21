#!/usr/bin/env python3
"""Restore the eight integration replay JPEGs from the local RTR recordings."""
import argparse
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
REFERENCE = SCRIPTS / 'analyze-field-videos.replay.json'
SOURCE_SHA256 = {
    '视频-rtr1.mp4': 'de455c6cecf68155a10b0c6514afe60611ebfd3774d3c34330356467b142b4e3',
    '视频-rtr2.mp4': 'aab204942b38d43eedb916fe0de8d6092db418628d890b7b4b46a488997a6b8c',
}
# Load the evidence CLI as a library so both workflows use the same native reader.
analysis = runpy.run_path(str(SCRIPTS / 'analyze-field-videos.py'))
checked_path = analysis['checked_path']


def verify_sha(path, expected):
    actual = analysis['digest'](path)
    if actual != expected:
        raise ValueError(f'{path.name} SHA-256 校验失败（预期 {expected}，实得 {actual}）')
    return actual


def prepare():
    photos = checked_path(ROOT, '照片')
    output = checked_path(ROOT, '.build-local/field-feedback/real-frames')
    manifest = checked_path(output, 'manifest.json')
    reference = REFERENCE.read_bytes()
    rows = json.loads(reference)
    if manifest.exists() and analysis['read_json'](manifest) != rows:
        raise ValueError(f'{manifest} 与 {REFERENCE} 的八帧记录不一致')

    sources = {name: checked_path(photos, name) for name in SOURCE_SHA256}
    for name, source in sources.items():
        verify_sha(source, SOURCE_SHA256[name])
    names = [row['frame'] for row in rows]
    if len(names) != 8 or len(set(names)) != 8:
        raise ValueError('集成回放清单需要八个不同的 JPEG 文件名')
    for name in names:
        if Path(name).name != name or not name.endswith('.jpg'):
            raise ValueError(f'清单中的 JPEG 名称无效 {name!r}')
        target = checked_path(output, name)
        if target.exists() and not target.is_file():
            raise ValueError(f'目标路径应为 JPEG 文件 {target}')

    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.replay-', dir=output) as tmp:
        stage = Path(tmp)
        reader = analysis['build_reader'](stage)
        for row in rows:
            jpeg = stage / row['frame']
            pts = row['actual']
            size = analysis['native'](reader, 'frame', sources[row['source']], jpeg, pts['value'], pts['timescale'])
            if size != row['size']:
                raise ValueError(f"{jpeg.name} 尺寸校验失败（预期 {row['size']}，实得 {size}）")
            verify_sha(jpeg, row['sha256'])

        # Publish only after every fresh decode has matched the original manifest.
        for name in names:
            (stage / name).replace(output / name)
        if not manifest.exists():
            staged_manifest = stage / 'manifest.json'
            staged_manifest.write_bytes(reference)
            staged_manifest.replace(manifest)

    for row in rows:
        sha = verify_sha(output / row['frame'], row['sha256'])
        pts = row['actual']
        print(f"OK  {row['frame']}  PTS {pts['value']}/{pts['timescale']}  SHA-256 {sha}")
    print(f'{len(rows)}/{len(rows)} 张 JPEG 已从原片重建并校验  {output}')


if __name__ == '__main__':
    argparse.ArgumentParser(description=__doc__).parse_args()
    os.umask(0o077)
    try:
        prepare()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        sys.exit(f'回放帧重建停止 — {exc}')
