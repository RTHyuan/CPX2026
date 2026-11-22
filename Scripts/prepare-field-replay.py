#!/usr/bin/env python3
"""Restore field replay pixels from the original RTR/ZHX recordings and the original room photograph."""
import argparse
import json
import os
from pathlib import Path
import runpy
import shutil
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


def prepare_navigation(reader, photos, output, stage):
    reference = SCRIPTS / 'navigation-field-replay.json'
    data = json.loads(reference.read_bytes())
    source = checked_path(photos, data['source'])
    verify_sha(source, data['sourceSHA256'])
    rows = data['captures']
    if not rows or any(b['sourceFrame'] <= a['sourceFrame'] or b['pts'] <= a['pts'] for a, b in zip(rows, rows[1:])):
        raise ValueError('录像帧序号和展示时间必须严格递增')
    directory = stage / 'navigation'
    directory.mkdir()
    marks = json.dumps([[row['pts'], data['timescale']] for row in rows])
    actual = analysis['native'](reader, 'extract', source, directory, 10000, 1, marks)
    frames = {r['frame_index']: r for r in actual['frames'] if r['annotation_ids']}
    if len(frames) != len(rows):
        raise ValueError('录像帧数量与时间清单不符')
    files = []
    for row in rows:
        got = frames[row['sourceFrame']]
        if got['pts']['value'] != row['pts'] or got['pts']['timescale'] != data['timescale'] or any(got[key] != n for key, n in data['size'].items()):
            raise ValueError('录像帧号、展示时间或像素尺寸不符')
        jpeg = checked_path(directory, Path(got['jpeg']).name)
        verify_sha(jpeg, row['sha256'])
        files.append((jpeg, row['frame']))
    for photo in data['photos']:
        original = checked_path(photos, photo['source'])
        verify_sha(original, photo['sha256'])
        staged = checked_path(directory, photo['frame'])
        shutil.copyfile(original, staged)
        files.append((staged, photo['frame']))
    for jpeg, name in files:
        if name != Path(name).name or not name.endswith('.jpg'):
            raise ValueError('无效的文件名')
        jpeg.replace(checked_path(output, name))
    manifest = checked_path(directory, 'navigation-manifest.json')
    manifest.write_bytes(reference.read_bytes())
    manifest.replace(checked_path(output, manifest.name))
    print(f"{len(frames)} 张连续视频帧与 {len(data['photos'])} 张原始照片校验通过，包含源帧号、PTS 和 SHA-256")


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

        prepare_navigation(reader, photos, output, stage)

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
