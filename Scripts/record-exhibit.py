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
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    run = root / '.build-local' / ('exhibit-' + str(int(time.time())))
    run.mkdir(parents=True)
    shared = ['xcodebuild', '-project', 'PathSense.xcodeproj', '-scheme', 'PathSense', '-destination', f'platform=iOS Simulator,id={args.simulator}', '-derivedDataPath', '.build-local/simulator', '-parallel-testing-enabled', 'NO', '-quiet']
    subprocess.run(shared + ['build-for-testing'], cwd=root, check=True)
    start = time.time()
    with (run/'capture.log').open('w') as log:
        video = subprocess.Popen(['xcrun', 'simctl', 'io', args.simulator, 'recordVideo', '--codec=h264', str(run/'raw.mp4')], cwd=root, stdout=log, stderr=log)
        try:
            subprocess.run(shared + ['-resultBundlePath', str(run/'capture.xcresult'), '-only-testing:PathSenseUITests/PathSenseUITests/testExhibitWalkthrough', 'test-without-building'], cwd=root, check=True)
        finally:
            if video.poll() is None:
                video.send_signal(signal.SIGINT)
            video.wait(timeout=40)
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(run/'capture.xcresult'), '--output-path', str(run/'attachments')], check=True)
    (run/'start.json').write_text(json.dumps({'captureStart': start}))
    print(run)

if __name__ == '__main__':
    main()
