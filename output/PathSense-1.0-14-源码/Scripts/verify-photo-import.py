"""Test the real Photos picker in a newly created iPhone simulator (macOS, Xcode, Pillow)."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
SIMCTL = ['xcrun', 'simctl']


def make_sign(path):
    # The photographed-style fixture is outside the seven practice cards. Store the pixels
    # sideways and set EXIF orientation so decoding also exercises the import transform.
    sign = Image.new('RGB', (1160, 760), '#dfded4')
    draw = ImageDraw.Draw(sign)
    draw.rounded_rectangle((108, 90, 1052, 670), radius=14, fill='#163a52')
    font = '/System/Library/Fonts/Supplemental/Arial Bold.ttf'
    draw.text((580, 265), 'ROOM', fill='#fdf3d7', font=ImageFont.truetype(font, 72), anchor='mm')
    draw.text((580, 467), '418', fill='#fdf3d7', font=ImageFont.truetype(font, 195), anchor='mm')
    exif = Image.Exif()
    exif[274] = 6
    sign.transpose(Image.Transpose.ROTATE_90).save(path, quality=89, exif=exif)


def verify(base):
    inventory = json.loads(subprocess.check_output(SIMCTL + ['list', 'devices', 'available', '--json']))['devices']
    for runtime, devices in inventory.items():
        match = next((device for device in devices if device['udid'].upper() == base.upper()), None)
        if match:
            break
    else:
        raise SystemExit('Pass the UDID of an available iPhone simulator.')
    if 'iPhone' not in match['deviceTypeIdentifier']:
        raise SystemExit('Choose an iPhone simulator.')
    output = ROOT / '.build-local'
    output.mkdir(exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='photo-import-', dir=output))
    photo = run / 'PathSense-418.jpg'
    make_sign(photo)
    name = 'PathSense Picker QA ' + uuid.uuid4().hex[:8]
    device = subprocess.check_output(SIMCTL + ['create', name, match['deviceTypeIdentifier'], runtime], text=True).strip()
    print(f'Using new test simulator {name}. Evidence: {run}', flush=True)
    try:
        subprocess.run(SIMCTL + ['boot', device], check=True)
        subprocess.run(SIMCTL + ['bootstatus', device, '-b'], check=True)
        subprocess.run(SIMCTL + ['addmedia', device, str(photo)], check=True)
        # TEST_RUNNER_ keys are passed to the UI test runner. Normal tests skip this one
        # unless its isolated, library has been prepared with the test sign as its most recent asset.
        environment = dict(os.environ, TEST_RUNNER_PATHSENSE_PICKER_SIMULATOR=device)
        with (run / 'xcodebuild.log').open('w') as log:
            result = subprocess.run(['xcodebuild', '-project', 'PathSense.xcodeproj', '-scheme', 'PathSense',
                '-destination', f'platform=iOS Simulator,id={device}', '-derivedDataPath', str(output / 'simulator'),
                '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(run / 'tests.xcresult'), 'test'],
                cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
        summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(run / 'tests.xcresult')]))
        (run / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
        print(f"UI tests: {summary['passedTests']} passed, {summary['failedTests']} failed, {summary['skippedTests']} skipped", flush=True)
        result.check_returncode()
        if summary['skippedTests'] or summary['passedTests'] < 8:
            raise SystemExit('The isolated picker test did not run. Inspect the result bundle.')
    finally:
        subprocess.run(SIMCTL + ['shutdown', device], check=False)
        # Only the new device created by this process is removed. Leave test evidence on disk.
        subprocess.run(SIMCTL + ['delete', device], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('example_simulator', help='Existing simulator to use for its device type and runtime only')
    verify(parser.parse_args().example_simulator)
