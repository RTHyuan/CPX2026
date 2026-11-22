#!/usr/bin/env python3
"""Record the dedicated iOS simulator; stop with --stop and the same metadata path."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--device', default='BD1C56CB-5B44-4EFD-845C-93805BC25666')
p.add_argument('--metadata', type=Path, required=True)
p.add_argument('--output', type=Path)
p.add_argument('--stop', action='store_true')
a = p.parse_args()
if a.stop:
    state = json.loads(a.metadata.read_text())
    os.kill(state['recorder_pid'], signal.SIGINT)
    print('Requested normal recording finalization.', flush=True)
    raise SystemExit()
assert a.output and not a.output.exists(), 'Choose a new output file.'
a.output.parent.mkdir(parents=True, exist_ok=True)
state = {'device': a.device, 'output': str(a.output.resolve()), 'audio': 'Narration mixed from actual player events.'}
proc = subprocess.Popen(['xcrun', 'simctl', 'io', a.device, 'recordVideo', '--codec=h264', str(a.output.resolve())],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
state['recorder_pid'] = proc.pid
for line in proc.stdout:
    if 'Recording started' in line and 'capture_start_walltime' not in state:
        state['capture_start_walltime'] = time.time()
        a.metadata.write_text(json.dumps(state, indent=2) + '\n')
    print(line.rstrip(), flush=True)
code = proc.wait()
state['capture_end_walltime'] = time.time()
state['recorder_exit_code'] = code
a.metadata.write_text(json.dumps(state, indent=2) + '\n')
print('Recording finalized.', flush=True)
