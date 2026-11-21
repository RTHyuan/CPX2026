"""Capture the real simulator UI test and its screenshots. Pass an available iPhone simulator UDID."""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator')
    parser.add_argument('--derived', default='.build-local/simulator')
    parser.add_argument('--all-tests', action='store_true', help='Verify the full UI suite in the same capture.')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    run = root / '.build-local' / ('exhibit-' + str(int(time.time())))
    run.mkdir(parents=True)
    shared = ['xcodebuild', '-project', 'PathSense.xcodeproj', '-scheme', 'PathSense', '-destination', f'platform=iOS Simulator,id={args.simulator}', '-derivedDataPath', args.derived, '-parallel-testing-enabled', 'NO', '-quiet']
    subprocess.run(shared + ['build-for-testing'], cwd=root, check=True)
    start = time.time()
    with (run/'capture.log').open('w') as log:
        video = subprocess.Popen(['xcrun', 'simctl', 'io', args.simulator, 'recordVideo', '--codec=h264', str(run/'raw.mp4')], cwd=root, stdout=log, stderr=log)
        try:
            selection = [] if args.all_tests else ['-only-testing:PathSenseUITests/PathSenseUITests/testExhibitWalkthrough']
            subprocess.run(shared + ['-resultBundlePath', str(run/'capture.xcresult'), *selection, 'test-without-building'], cwd=root, check=True)
        finally:
            if video.poll() is None:
                video.send_signal(signal.SIGINT)
            video.wait(timeout=40)
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(run/'capture.xcresult'), '--output-path', str(run/'attachments')], check=True)
    (run/'start.json').write_text(json.dumps({'captureStart': start}))
    print(run)

if __name__ == '__main__':
    main()
