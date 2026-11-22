#!/usr/bin/env python3
"""Exercise real iPhone speech input. Use a button press or a nearby Mac speaker."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys
import time

BUNDLE = 'org.crosspointx.pathsense'
REPORT = 'Documents/PathSense-dictation-check.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='physical iPhone UDID')
    parser.add_argument('--output', type=Path, required=True, help='new local results directory')
    parser.add_argument('--audio', type=Path, help='play the known classroom-door phrase once through the Mac speaker; omit for a human button test')
    args = parser.parse_args()
    if args.audio and not args.audio.is_file():
        parser.error('The Mac audio sample does not exist.')
    args.output.mkdir(parents=True, exist_ok=False)
    ctl = ['xcrun', 'devicectl', '--quiet', '--timeout', '9']

    def read_report():
        local = args.output / 'device.json'
        cmd = ctl + ['device', 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer',
                     '--domain-identifier', BUNDLE, '--source', REPORT, '--destination', str(local)]
        if subprocess.run(cmd, capture_output=True).returncode != 0:
            return None
        try:
            return json.loads(local.read_text())
        except (OSError, ValueError):
            return None

    before = read_report()
    old_id = before.get('runID') if before else None
    if before:
        (args.output / 'device.json').rename(args.output / 'previous.json')
    opened = time.time()
    start = time.monotonic()
    flag = '--pathsense-dictation-check' if args.audio else '--pathsense-manual-input-check'
    subprocess.run(ctl + ['device', 'process', 'launch', '--device', args.device, '--terminate-existing', BUNDLE, flag], check=True)
    terminal = {'recognized_classroom_door', 'recognized_other_destination', 'ended_without_destination', 'timed_out'}
    timeline, player, phase = [], None, None
    played = False
    matched = False
    expected = 'diagnostic' if args.audio else 'button'
    while time.monotonic() - start < 100:
        sample = read_report()
        if sample and sample.get('runID') != old_id and sample.get('trigger') == expected:
            # Swift JSONEncoder stores seconds since 2001, not the Unix epoch.
            if not old_id and sample.get('startedAt', 0) + 978307200 < opened - 30:
                time.sleep(.3)
                continue
            now = time.monotonic() - start
            if sample['step'] != phase:
                phase = sample['step']
                timeline.append({'elapsed': round(now, 3), 'phase': phase})
                print(phase, flush=True)
            if phase == 'awaiting_recognition' and args.audio and not played:
                player = subprocess.Popen(['afplay', str(args.audio)])
                timeline.append({'elapsed': round(now, 3), 'event': 'Mac speaker playback started'})
                played = True
            if phase in terminal:
                matched = phase == 'recognized_classroom_door'
                break
        time.sleep(.3)
    if player is not None:
        player.wait(timeout=10)
    outcome = dict(source='Mac speaker' if args.audio else 'person using the app button',
                   startedAt=datetime.datetime.fromtimestamp(opened).astimezone().isoformat(timespec='seconds'),
                   played=played, playerExit=player.returncode if player else None,
                   matchedClassroomDoor=matched, lastPhase=phase, events=timeline)
    (args.output / 'result.json').write_text(json.dumps(outcome, ensure_ascii=False, indent=2) + '\n')
    return 0 if matched and (not args.audio or (played and player.returncode == 0)) else 1


if __name__ == '__main__':
    sys.exit(main())
