#!/usr/bin/env python3
"""Attach locally reviewed observations to the exact source frames they describe."""
import argparse
import csv
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re

PRIVATE = Path(__file__).resolve().parents[1] / 'Submission/private/field-videos'


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def write_json(path, obj):
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def table_text(text):
    return text.replace('|', r'\|').replace('\n', '<br>')


def main():
    parser = argparse.ArgumentParser(description='将已完成的目视记录关联到原片及对应帧')
    parser.add_argument('run_id')
    args = parser.parse_args()
    if not re.fullmatch(r'\d{8}T\d{6}Z-[a-f0-9]{8}', args.run_id):
        parser.error('需要 runs 下的运行编号')
    run = PRIVATE / 'runs' / args.run_id
    manifest = read(run / 'manifest.json')
    notes = read(PRIVATE / 'reviewed' / (manifest['info_sha256'] + '.json'))
    assert notes['info_sha256'] == hashlib.sha256((run / 'info.txt').read_bytes()).hexdigest()
    is_first_review = notes.get('original_review_run') == args.run_id
    counts = []
    for folder in manifest['clip_dirs']:
        directory = run / folder
        clip = read(directory / 'frames.json')
        note = notes['clips'][clip['original']]
        if clip['source_sha256'] != note['source_sha256']:
            raise ValueError(f"原片已经变更 {clip['original']}")
        frame_for = {i: f for f in clip['frames'] for i in f['annotation_ids']}
        result = []
        for mark in clip['annotations']:
            f = frame_for[mark['id']]
            entry = note['marks'][mark['time_label']]
            if entry['jpeg_sha256'] != f['jpeg_sha256'] or f['jpeg_sha256'] != hashlib.sha256((directory / f['jpeg']).read_bytes()).hexdigest():
                raise ValueError(f"需重新目视核对 {clip['original']} {mark['time_label']}")
            value, scale = f['pts']['value'], f['pts']['timescale']
            delta = Fraction(value, scale) - Fraction(mark['requested_time'])
            result.append({'original': clip['original'], 'source_sha256': clip['source_sha256'], 'info_time': mark['time_label'],
                           'user_quote': mark['quote'], 'frame_index': f['frame_index'], 'pts_value': value, 'pts_timescale': scale,
                           'pts_seconds': f['pts']['seconds'], 'offset_from_mark_ms': round(float(delta * 1000), 4),
                           'jpeg': f['jpeg'], 'jpeg_sha256': f['jpeg_sha256'], 'visibility': entry['visibility'],
                           'visible_observation': entry['observation'], 'scope': entry['scope']})
        write_json(directory / 'annotations.json', {'original': clip['original'], 'source_sha256': clip['source_sha256'],
                   'info_sha256': manifest['info_sha256'], 'overview': note['overview'], 'timeline': note['timeline'],
                   'audio': note['audio'], 'observations': result})
        with (directory / 'annotations.csv').open('w', encoding='utf-8', newline='') as file:
            w = csv.DictWriter(file, fieldnames=list(result[0]))
            w.writeheader()
            w.writerows(result)
        lines = [f"# {clip['original']} · 目视复核", '', note['overview'], '',
                 f"全片时长 {clip['duration']['seconds']:.3f} 秒，编码与显示尺寸均为 {clip['encoded_width']} × {clip['encoded_height']} 像素。共 {clip['presentable_frame_count']:,} 个可显示源帧。", '',
                 f"名义间隔 {manifest['interval_seconds']} 秒，含片尾与说明指定时刻共 {len(clip['frames'])} 张 JPEG。", '',
                 (f'已查看本批全部采样缩略图及以下 {len(result)} 张指定时刻的原尺寸 JPEG。' if is_first_review else f"指定帧的 SHA-256 与[原复核批次](../../{notes['original_review_run']}/{folder}/review.md)一致。"), '',
                 f"原片 SHA-256 `{clip['source_sha256']}`", '', '[全部帧 CSV](frames.csv) · [精确时间与元数据 JSON](frames.json) · [逐项观察 CSV](annotations.csv) · [逐项观察 JSON](annotations.json)', '',
                 '## 画面经过', '', *[f'- {item}' for item in note['timeline']], '', '## 逐项核对', '',
                 '| 说明时间 | 实际 PTS（秒）与原帧 | 可见内容 | 辨认范围 |', '|---|---|---|---|']
        for row in result:
            desc = table_text(row['visible_observation'])
            detail = table_text(row['scope'])
            lines.append(f"| {row['info_time']} | [{row['pts_seconds']:.6f} · #{row['frame_index']}]({row['jpeg']}) | {desc} | {row['visibility']}。{detail} |")
        sheets = sorted((directory / 'contact-sheets').glob('*.jpg'))
        if sheets:
            lines += ['', '全片采样图按呈现时间排列，星号标记说明指定帧。', '',
                      ' · '.join(f'[{i}](contact-sheets/{p.name})' for i, p in enumerate(sheets, 1))]
        lines += ['', '## 音频与测量', '', note['audio'], '']
        if (directory / 'audio-levels.json').is_file():
            lines += ['[逐秒音频电平](audio-levels.json) · [本地回听 WAV](review-audio.wav)', '']
        lines += ['门牌内容与箭头来自带 PTS 的画面。计算 AR 位姿需要定位遥测，测量端到端提示延迟需要同一时钟下的触发与输出记录。', '']
        (directory / 'review.md').write_text('\n'.join(lines), encoding='utf-8')
        counts.append(len(result))
    report = run / 'REPORT.md'
    marker = '\n## 目视复核结论\n'
    base = report.read_text(encoding='utf-8').split(marker, 1)[0].rstrip().replace('目视结论和带时间的声音证据从每片的复核页查阅。', '逐片复核页列出画面观察与音轨检查范围。')
    summary = [marker, f"共复核 {sum(counts)} 个说明时刻。指定时刻均关联到目视核对的原尺寸 JPEG。", '',
               *[f"- {notes['clips'][read(run / d / 'frames.json')['original']]['overview']} [逐片记录]({d}/review.md)" for d in manifest['clip_dirs']], '',
               '两处吊牌上的箭头分别按各自牌面读取，路线方位与距离还需独立定位资料。落地自习牌、落地房号牌以及时段告示均记录拍摄时所见。储物柜在这里作为现场参照。', '',
               '既有录像 `视频-zhx.mp4` 独立登记于[来源清单](../../legacy.json)。', '']
    report.write_text(base + '\n' + '\n'.join(summary), encoding='utf-8')
    print(report)


if __name__ == '__main__':
    main()
