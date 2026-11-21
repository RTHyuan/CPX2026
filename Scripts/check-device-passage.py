#!/usr/bin/env python3
"""Read an observation from an unlocked iPhone after a DEBUG --pathsense-passage-check launch.

The companion can stay in place. Pause or end navigation to flush the final report.
Use --list to find the run UUID, then --run-id UUID --output NEW_FILE to copy it.
A run still marked 'observing' contains the most recent checkpoint.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from uuid import UUID


FOLDER = 'Documents/PathSense-passage-check'
BUNDLE = 'org.crosspointx.pathsense'


def fetch(device, run_id, output):
    if os.path.lexists(output):
        raise FileExistsError(f'Output already exists: {output}')
    # Stage on the destination volume. Publish only a checked report, without replacing any prior file.
    with tempfile.TemporaryDirectory(dir=output.parent) as staging:
        local = Path(staging) / 'report.json'
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', *device,
                        '--quiet', '--source', f'{FOLDER}/{run_id}.json', '--destination', str(local)], check=True)
        report = json.loads(local.read_bytes())
        if (not isinstance(report, dict) or report.get('schemaVersion') != 1 or
                not isinstance(report.get('runID'), str) or report['runID'].lower() != str(run_id) or
                not isinstance(report.get('sensorEvidence'), dict) or not isinstance(report.get('issuedCues'), dict) or
                report.get('walkAcceptance') != {'status': 'not_assessed', 'method': 'separate_accompanied_walk'}):
            raise ValueError('Unexpected passage report schema or run ID')
        sensors = report['sensorEvidence']
        near, depth, confidence = (sensors[key] for key in ('nearFrames', 'depthMapFrames', 'confidenceMapFrames'))
        if any(type(n) is not int or n < 0 for n in (near, depth, confidence)) or max(depth, confidence) > near:
            raise ValueError('Invalid near-frame counts')
        state = report['status']
        model = report['modelIdentifier']
        local.chmod(0o600)
        os.link(local, output)
    print(f'{run_id}  {state}  {model}\nNear frames {near}, with depth {depth}, with confidence {confidence}'
          f'\nAccompanied walk assessment pending\n{output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--device', required=True, help='paired physical iPhone identifier')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--list', action='store_true', help='list only the passage report directory')
    mode.add_argument('--run-id', type=UUID, help='UUID from the report filename')
    parser.add_argument('--output', type=Path, help='new local JSON file in an existing directory')
    args = parser.parse_args()
    if bool(args.run_id) != bool(args.output):
        parser.error('Use --output with --run-id only.')
    device = ['--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
              '--timeout', '15']
    try:
        if args.list:
            subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'files', *device,
                            '--subdirectory', FOLDER, '--no-recurse'], check=True)
        else:
            fetch(device, args.run_id, args.output)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Passage report unavailable: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
