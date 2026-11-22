#!/usr/bin/env python3
"""Index locally described field videos on macOS. Run with --help for usage."""
import argparse
import csv
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import unicodedata
import uuid

ROOT = Path(__file__).resolve().parents[1]
NATIVE = Path(__file__).with_suffix('.m')
PRIVATE = ROOT / 'Submission/private/field-videos'
LEGACY = '视频-zhx.mp4'
VIDEO_EXTS = {'.mp4', '.mov', '.m4v', '.3gp', '.3g2', '.mts', '.m2ts', '.avi', '.mkv', '.webm', '.mpg', '.mpeg', '.ts'}
CSV_FIELDS = ('original', 'source_sha256', 'container_duration_seconds', 'interval_seconds', 'encoded_width',
              'encoded_height', 'frame_index', 'pts_value', 'pts_timescale', 'pts_seconds',
              'sample_pts_value', 'sample_pts_timescale', 'sample_pts_seconds',
              'elapsed_seconds', 'target_elapsed_seconds', 'previous_gap_seconds', 'selection',
              'annotation_ids', 'width', 'height', 'jpeg', 'jpeg_sha256')


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def write_text(path, text):
    # Readers see one complete document even if an analysis is interrupted.
    with tempfile.NamedTemporaryFile('w', dir=path.parent, encoding='utf-8', delete=False) as f:
        f.write(text)
    Path(f.name).replace(path)


def write_json(path, data):
    write_text(path, json.dumps(data, indent=2, ensure_ascii=False) + '\n')


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


def checked_path(root, name):
    """Reject symlinks at every component, including dangling final symlinks."""
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts or not relative.parts:
        raise ValueError(f'需要目录内的相对路径 {name!r}')
    path = root
    for part in relative.parts:
        path = path / part
        if path.is_symlink():
            raise ValueError(f'跳过符号链接 {path}')
    return path


def inventory(source):
    entries = {}
    if source.is_dir():
        for directory, dirs, files in os.walk(source, followlinks=False):
            parent = Path(directory)
            dirs[:] = [d for d in dirs if not d.startswith('.') and not (parent / d).is_symlink()]
            for name in sorted(files):
                file = parent / name
                if (not name.startswith('.') and file.suffix.lower() in VIDEO_EXTS
                        and not file.is_symlink() and file.is_file()):
                    entries[file.relative_to(source).as_posix()] = file.stat().st_size
    return dict(sorted(entries.items()))


def read_info(path):
    if not path.is_file():
        return None, None, None
    raw = path.read_bytes()
    if raw.startswith((b'\xff\xfe', b'\xfe\xff')):
        choices = ('utf-16',)
    else:
        choices = ('utf-8-sig', 'gb18030')
    for enc in choices:
        try:
            return raw.decode(enc), raw, enc
        except UnicodeDecodeError:
            continue
    raise ValueError('info.txt 文本编码无法识别')


def folded(text):
    return unicodedata.normalize('NFC', text).casefold()


def automatic_bindings(text, entries):
    """Recognize filenames in source prose. Do not assign by file count, mtimes or listing order."""
    found = []
    lines = text.splitlines()
    for name in entries:
        if name == LEGACY:
            continue
        # A basename is usable in prose only when it identifies one path.
        aliases = [name]
        base = Path(name).name
        if name != base and sum(folded(Path(n).name) == folded(base) for n in entries) == 1:
            aliases.append(base)
        escaped = '|'.join(re.escape(folded(a)) for a in aliases)
        pattern = re.compile(r'(?<![a-z0-9_./-])(?:' + escaped + r')(?![a-z0-9_.-])')
        for line_idx, line in enumerate(lines):
            match = pattern.search(folded(line))
            if match:
                found.append((line_idx, match.start(), {'original': name, 'info_quote': line.strip(),
                                                         'match_basis': '说明按原文件名点名'}))
                break
    # Mixed exclusion or historic references need human interpretation of the prose.
    for _, _, binding in found:
        if re.search(r"排除|勿用|别用|跳过|不要|不纳入|原有|老片|旧片|旧视频|仅供参考|ignore|exclude|legacy", binding["info_quote"], re.I):
            return []
    found.sort(key=lambda x: (x[0], x[1]))
    return [entry for _, _, entry in found]


def annotation_sections(text, names):
    sections = {name: [] for name in names}
    current = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped in sections:
            current = sections[stripped]
            continue
        if current is None:
            continue
        match = re.fullmatch(r'(\d+):([0-5]\d(?:\.\d+)?)\s*[｜|](.*)', stripped)
        if match:
            minute, second, description = match.groups()
            t = 60 * int(minute) + Fraction(second)
            current.append({'id': len(current) + 1, 'time_label': f'{minute}:{second}', 'requested_time': str(t),
                            'description': description.strip(), 'quote': stripped})
        elif line[:1].isspace() and stripped and current:
            current[-1]['description'] += '\n' + stripped
            current[-1]['quote'] += '\n' + line
    for marks in sections.values():
        if [Fraction(m['requested_time']) for m in marks] != sorted(Fraction(m['requested_time']) for m in marks):
            raise ValueError('请核对说明中标注的时间顺序')
    return sections


def select(source, output):
    entries = inventory(source)
    text, raw, encoding = read_info(checked_path(source, 'info.txt'))
    info_sha = hashlib.sha256(raw).hexdigest() if raw is not None else None
    obj = {'checked_at_utc': now(), 'source_directory': str(source), 'info_encoding': encoding,
           'info_sha256': info_sha, 'info_text': text, 'video_files_bytes': entries,
           'legacy_separate': [LEGACY] if LEGACY in entries else [], 'clips': []}
    if not text or not text.strip():
        obj.update(state='waiting_for_info', reason='等候用户的 info.txt 描述。')
        return obj
    bindings_file = checked_path(output, 'bindings.json')
    if bindings_file.is_file():
        bindings = read_json(bindings_file)
        if bindings.get('info_sha256') != info_sha:
            obj.update(state='needs_mapping', reason='info.txt 已更新，需要按新原文复核已有对应表。')
            return obj
        clips = bindings['clips']
        for c in clips:
            if (not c.get('info_quote', '').strip() or c['info_quote'] not in text
                    or not c.get('match_basis', '').strip()):
                raise ValueError('对应表需含 info.txt 逐字摘录和辨认依据')
    else:
        clips = automatic_bindings(text, entries)
    names = [c['original'] for c in clips]
    obj['matched_names'] = names
    if not any(name != LEGACY and size for name, size in entries.items()):
        obj.update(state='waiting_for_files', reason='等待说明中提及的录像。')
    elif not names or len(names) != len(set(names)) or LEGACY in names:
        obj.update(state='needs_mapping', reason='需要按说明核对文件对应关系。')
    elif any(n not in entries or entries[n] == 0 for n in names):
        obj.update(state='waiting_for_files', reason='说明中点名的素材尚未全部落盘。')
    else:
        sections = annotation_sections(text, names)
        for c in clips:
            c['annotations'] = sections.get(c['original'], [])
        obj.update(state='ready', reason=f'已按说明对应 {len(clips)} 段录像。', clips=clips)
    return obj


def record_status(output, plan):
    pointer = checked_path(output, 'latest-reviewed.json')
    if pointer.is_file():
        reviewed = read_json(pointer)
        if (reviewed['info_sha256'] == plan['info_sha256']
                and [c['original'] for c in reviewed['clips']] == [c['original'] for c in plan['clips']]
                and all(digest(checked_path(Path(plan['source_directory']), c['original'])) == c['source_sha256']
                        for c in reviewed['clips'])):
            plan['reviewed_report'] = reviewed['report']
    write_json(output / 'status.json', plan)
    lines = ['# 现场视频状态', '', plan['reason'], '', f"核对时间（UTC） {plan['checked_at_utc']}", '',
             f"匹配状态 `{plan['state']}` · 已对应 {len(plan['clips'])} 段。", '', '## 视频清单', '']
    for name, size in plan['video_files_bytes'].items():
        role = '既有录像，单列' if name == LEGACY else '说明已对应' if name in [c['original'] for c in plan['clips']] else '待核对'
        lines.append(f'- `{name}` · {size:,} 字节 · {role}')
    if 'reviewed_report' in plan:
        lines += ['', f"[已完成的抽帧与目视报告]({plan['reviewed_report']})"]
    if plan['info_text'] is not None:
        lines += ['', '## 用户说明原文', '', *(f'> {line}' for line in plan['info_text'].splitlines())]
    write_text(output / 'STATUS.md', '\n'.join(lines) + '\n')


def build_reader(output):
    build = checked_path(output, '.build')
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=build) as tmp:
        binary = Path(tmp) / 'field-reader'
        args = ['/usr/bin/xcrun', 'clang', '-O2', '-fobjc-arc', '-Wno-deprecated-declarations', str(NATIVE), '-o', str(binary)]
        for framework in ('AVFoundation', 'CoreMedia', 'CoreGraphics', 'Foundation', 'ImageIO'):
            args.extend(['-framework', framework])
        subprocess.run(args, check=True)
        target = build / ('reader-' + digest(NATIVE)[:16])
        binary.replace(target)
    return target


def native(binary, *args):
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f'本地解码进程退出码 {result.returncode}')
    return json.loads(result.stdout)


def csv_text(clip):
    s = io.StringIO(newline='')
    w = csv.DictWriter(s, fieldnames=CSV_FIELDS, lineterminator='\n')
    w.writeheader()
    for frame in clip['frames']:
        row = {k: frame.get(k) for k in CSV_FIELDS}
        pts = frame['pts']
        row.update(original=clip['original'], source_sha256=clip['source_sha256'],
                   container_duration_seconds=clip['duration']['seconds'], interval_seconds=clip['interval']['seconds'],
                   encoded_width=clip['encoded_width'], encoded_height=clip['encoded_height'], pts_value=pts['value'],
                   pts_timescale=pts['timescale'], pts_seconds=pts['seconds'], sample_pts_value=frame['sample_pts']['value'],
                   sample_pts_timescale=frame['sample_pts']['timescale'], sample_pts_seconds=frame['sample_pts']['seconds'])
        row['annotation_ids'] = ','.join(str(i) for i in frame.get('annotation_ids', []))
        w.writerow(row)
    return s.getvalue()


def verify_clip(directory, source, binary):
    c = read_json(directory / 'frames.json')
    original = checked_path(source, c['original'])
    if digest(original) != c['source_sha256']:
        raise ValueError(f"{c['original']} 原片 SHA-256 不匹配")
    csv_file = directory / 'frames.csv'
    if csv_file.read_text(encoding='utf-8') != csv_text(c):
        raise ValueError(f'{csv_file} 与 JSON 不符')
    with csv_file.open(encoding='utf-8', newline='') as f:
        rows = list(csv.DictReader(f))
    for row in rows:
        if digest(checked_path(directory, row['jpeg'])) != row['jpeg_sha256']:
            raise ValueError(f"JPEG SHA-256 不符 {row['jpeg']}")
    # Pick from the CSV. A digest-derived seed keeps the check repeatable; prefer an interior frame.
    pool = rows[1:-1] or rows
    row = pool[int(c['source_sha256'][:16], 16) % len(pool)]
    with tempfile.TemporaryDirectory(dir=directory) as tmp:
        replay = Path(tmp) / 'replay.jpg'
        size = native(binary, 'frame', original, replay, row['pts_value'], row['pts_timescale'])
        if digest(replay) != row['jpeg_sha256'] or size != {'width': int(row['width']), 'height': int(row['height'])}:
            raise ValueError(f"回到源片重抽时，JPEG 或尺寸不符 {row['jpeg']}")
    return {'original': c['original'], 'verified_frames': len(rows), 'redecoded_frame_index': int(row['frame_index']),
            'redecoded_pts': f"{row['pts_value']}/{row['pts_timescale']}", 'redecoded_jpeg_sha256': row['jpeg_sha256']}


def review_sheet(directory, clip):
    rows = clip['frames']
    indices = sorted({0, len(rows) // 2, len(rows) - 1})
    lines = [f"# {clip['original']} · 证据复核", '', '## 用户说明', '', f"> {clip['info_quote']}", '',
             f"文件对应依据　{clip['match_basis']}", '', '## 画面', '', '待目视核对。可逐项注明画面动作、文字、遮挡和源 PTS。', '']
    for i in indices:
        r = rows[i]
        lines += [f"帧 {r['frame_index']} · PTS {r['pts']['value']}/{r['pts']['timescale']} 秒 · 相对首帧 {r['elapsed_seconds']:.3f} 秒", '',
                  f"![关键帧]({r['jpeg']})", '']
    lines += ['## 声音', '', '有音轨，待复听。如有可辨认的口令或提示音，记录所听内容及媒体时间。' if clip['audio_tracks'] else '本片未检出音轨。', '',
              '## 测量边界', '', '普通录像可记录画面或声音事件出现的媒体时间。AR 位姿需要跟踪遥测。端到端提示延迟还需同步记录触发与输出时间。', '']
    write_text(directory / 'review.md', '\n'.join(lines))


def make_report(run, manifest):
    lines = [f"# {manifest['dataset']} · {len(manifest['clip_dirs'])} 段抽帧报告", '',
             f"用户描述快照 [info 原文](info.txt) · SHA-256 `{manifest['info_sha256']}`", '',
             f"名义间隔 {manifest['interval_seconds']} 秒，从首个可显示帧开始，在各采样点选其时刻或之后的首个源帧，并保留尾帧。", '',
             'CSV 中 pts 是可回放的影片呈现时间，sample_pts 是编码样本时间。两者都保留整数分数。另列相对首帧秒数、采样目标和实际相邻样本间隔。JPEG 采用源显示方向。', '',
             '| 原文件 | 编码尺寸 → JPEG 尺寸 | 容器时长 | 采样数 / 可显示帧数 | 资料 |',
             '|---|---|---:|---:|---|']
    for folder in manifest['clip_dirs']:
        c = read_json(run / folder / 'frames.json')
        r = c['frames'][0]
        lines.append(f"| {c['original']} | {c['encoded_width']}×{c['encoded_height']} → {r['width']}×{r['height']} | {c['duration']['seconds']:.3f} s | {len(c['frames'])} / {c['presentable_frame_count']} | [CSV]({folder}/frames.csv) · [JSON]({folder}/frames.json) · [关键帧与复核]({folder}/review.md) |")
    lines += ['', '## 来源与核验', '']
    for folder in manifest['clip_dirs']:
        clip = read_json(run / folder / 'frames.json')
        lines += [f"- `{clip['original']}` · {clip['size_bytes']:,} 字节 · SHA-256 `{clip['source_sha256']}`"]
    lines += ['', '[逐片核验记录](verification.json) 含所有 JPEG 校验数及从 CSV 指定 PTS 回到原片的抽检结果。', '',
              '目视结论和带时间的声音证据从每片的复核页查阅。完整位姿和系统提示延迟需要独立的同步测量记录。', '']
    write_text(run / 'REPORT.md', '\n'.join(lines))


def extract(source, output, plan, interval, fixture):
    if plan['state'] != 'ready':
        raise ValueError(plan['reason'])
    binary = build_reader(output)
    runs = checked_path(output, 'runs')
    runs.mkdir(exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8]
    final = runs / run_id
    legacy = checked_path(source, LEGACY)
    used = {digest(legacy)} if legacy.is_file() else set()
    manifest = {'schema_version': 1, 'dataset': '合成自检短片' if fixture else '用户现场录像', 'run_id': run_id,
                'created_at_utc': now(), 'info_sha256': plan['info_sha256'], 'interval_seconds': str(interval),
                'python_version': platform.python_version(), 'macos_version': platform.mac_ver()[0],
                'script_sha256': digest(Path(__file__)), 'native_source_sha256': digest(NATIVE), 'clip_dirs': []}
    baseline = checked_path(output, 'legacy.json')
    if baseline.is_file():
        used.add(read_json(baseline)['sha256'])
    checks = []
    with tempfile.TemporaryDirectory(prefix='.pending-', dir=runs) as tmp:
        work = Path(tmp)
        info = checked_path(source, 'info.txt')
        raw = info.read_bytes()
        if hashlib.sha256(raw).hexdigest() != plan['info_sha256']:
            raise ValueError('处理期间 info.txt 已更新，请重新运行以匹配新版。')
        (work / 'info.txt').write_bytes(raw)
        for idx, binding in enumerate(plan['clips'], 1):
            original = checked_path(source, binding['original'])
            source_hash = digest(original)
            if source_hash in used:
                raise ValueError(f'{original.name} 与旧片或另一新片的内容重复，需复核对应关系。')
            used.add(source_hash)
            folder = f'clip-{idx:02d}'
            directory = work / folder
            frames = directory / 'frames'
            frames.mkdir(parents=True)
            try:
                targets = [Fraction(a['requested_time']) for a in binding['annotations']]
                target_json = json.dumps([[t.numerator, t.denominator] for t in targets])
                data = native(binary, 'extract', original, frames, interval.numerator, interval.denominator, target_json)
            except ValueError as exc:
                raise ValueError(f'{original.name} · {exc}') from exc
            data.update(binding, source_sha256=source_hash, size_bytes=original.stat().st_size, info_sha256=plan['info_sha256'])
            for f in data['frames']:
                f['jpeg_sha256'] = digest(checked_path(directory, f['jpeg']))
            write_json(directory / 'frames.json', data)
            write_text(directory / 'frames.csv', csv_text(data))
            review_sheet(directory, data)
            checks.append(verify_clip(directory, source, binary))
            manifest['clip_dirs'].append(folder)
        if digest(info) != plan['info_sha256']:
            raise ValueError('抽帧期间 info.txt 已更新，请按新说明重新运行。')
        write_json(work / 'manifest.json', manifest)
        write_json(work / 'verification.json', {'verified_at_utc': now(), 'clips': checks})
        make_report(work, manifest)
        work.rename(final)
    return final


def main():
    parser = argparse.ArgumentParser(description='在本机核对照片/info.txt，按原片 PTS 采样说明中点名的视频。')
    parser.add_argument('command', nargs='?', choices=('status', 'run', 'verify'), default='status')
    parser.add_argument('--interval', default='1', metavar='SECONDS', help='采样间隔，默认 1 秒，接受小数或分数')
    parser.add_argument('--run-id', help='verify 使用对应 runs 目录下的运行编号')
    parser.add_argument('--fixture', action='store_true', help='仅使用私有 tests/fixture 下的合成数据')
    args = parser.parse_args()
    os.umask(0o077)
    checked_path(ROOT, 'Submission/private/field-videos')
    output = checked_path(PRIVATE, 'tests/fixture/output') if args.fixture else PRIVATE
    source = checked_path(PRIVATE, 'tests/fixture/照片') if args.fixture else checked_path(ROOT, '照片')
    output.mkdir(parents=True, exist_ok=True)
    if args.command == 'verify':
        if not args.run_id or not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}', args.run_id):
            parser.error('verify 需要 --run-id 并指定现有报告的编号')
        run = checked_path(output, 'runs/' + args.run_id)
        manifest = read_json(run / 'manifest.json')
        if digest(run / 'info.txt') != manifest['info_sha256']:
            raise ValueError('归档说明的 SHA-256 校验失败')
        binary = build_reader(output)
        checks = [verify_clip(checked_path(run, f), source, binary) for f in manifest['clip_dirs']]
        write_json(run / 'verification.json', {'verified_at_utc': now(), 'clips': checks})
        print(run / 'verification.json')
        return 0
    plan = select(source, output)
    record_status(output, plan)
    if args.command == 'status' or plan['state'] != 'ready':
        print(plan['state'], plan['reason'], output / 'STATUS.md', sep='\n')
        return 0 if args.command == 'status' else 2
    interval = Fraction(args.interval)
    if interval <= 0 or interval.numerator >= 2**63 or interval.denominator >= 2**31:
        raise ValueError('间隔超出正的 CMTime 分数范围')
    print(extract(source, output, plan, interval, args.fixture) / 'REPORT.md')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, ZeroDivisionError) as exc:
        print(f'现场视频处理停止 — {exc}', file=sys.stderr)
        sys.exit(1)
