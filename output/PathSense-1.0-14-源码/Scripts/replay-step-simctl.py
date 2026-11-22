#!/usr/bin/env python3
"""Run the real one-step player on an already booted simulator, without XCTest UI or another device."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'org.crosspointx.pathsense'
REFERENCE = ROOT / 'Scripts/navigation-field-replay.json'
DEFAULT_FRAMES = ROOT / '.build-local/field-feedback/real-frames'


def require(value, message):
    if not value:
        raise ValueError(message)


def records(folder):
    reference = REFERENCE.read_bytes()
    require((folder / 'navigation-manifest.json').read_bytes() == reference,
            'The prepared recording differs from Scripts/navigation-field-replay.json')
    spec = json.loads(reference)
    source = ROOT / '照片' / spec['source']
    with source.open('rb') as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            digest.update(chunk)
    require(digest.hexdigest() == spec['sourceSHA256'], 'Original recording SHA-256 mismatch')
    pictures, still, move = [], [], []
    for row in spec['captures']:
        filename = row['frame']
        require(Path(filename).name == filename, 'Invalid frame path')
        pixel = (folder / filename).read_bytes()
        require(hashlib.sha256(pixel).hexdigest() == row['sha256'], 'Frame SHA-256 mismatch: ' + filename)
        pts = row['pts'] / spec['timescale']
        (still if pts < 104 else move).append({'picture': len(pictures), 'sourceFrame': row['sourceFrame'], 'pts': pts})
        pictures.append(pixel)
    require(len(still) >= 8 and len(move) >= 12, 'Too few timestamped captures to run both permits')
    door = {'kind':'door','box':[0.43,0.16,0.57,0.60],'confidence':0.91,'appearance':42}
    def scene(checked=False, z=0, **params):
        return dict(heading=0, pitchDown=28, position={'x':0,'y':1.4,'z':z}, tracking='normal',world=1,
                    sectors=[0], occupied=False, features=[door], checkedStepSectors=[0] if checked else [], readSigns=False, **params)
    phases = [scene(picture=0), scene(True, captures=still),
              scene(True, captures=move, positionOffsets=[{'x':0,'y':0,'z':z} for z in [0,-0.045,-0.11,-0.18,-0.25,-0.31,-0.34]]),
              scene(z=-0.34, picture=len(pictures)-1, freezeCapture=True)]
    return spec, pictures, phases


def simctl(*args, env=None, timeout=180):
    return subprocess.run(['xcrun','simctl',*map(str,args)], env=env, timeout=timeout,
                          check=True, text=True, stdout=subprocess.PIPE).stdout.strip()


def validate(spec, status, measures):
    require(status.get('state') == 'finished', f"Replay failed: {status.get('reason')}. See progress.json and walk-measures.json")
    require(status['actualStepPlayerStarts'] == 2, 'Expected two physical AVAudioPlayer cursor starts in the simulator')
    audit = measures['stepEvents']
    started = [e for e in audit if e['type'] == 'speechStarted']
    require(len(started) == 2, 'Expected two matching live executor callbacks')
    manifest = {row['sourceFrame']:row for row in spec['captures']}
    accepted = []
    for e in started:
        permit = e['permit']
        frames = permit['spokenCheck']['frames']
        checked = permit['spokenCheck']['times']
        delay = e['time'] - checked[-1]
        require(0 <= delay <= 0.55 and len(checked) == 3, 'Speech did not start inside its checked time window')
        numbers = [f['frame'] for f in frames]
        require(len(set(numbers)) == 3 and set(numbers) <= manifest.keys(), 'Proof missing three distinct original captures')
        require(all(f['session'] == e['frame']['session'] and f['world'] == e['frame']['world'] for f in frames), 'Wrong proof coordinate epoch')
        require(all(c['source'] == 'controlledReplay' and c['nearGround'] and c['landing'] and c['body']
                    for c in permit['spokenCheck']['coverage']), 'Evidence not identified as injected full step geometry')
        accepted.append({'id':permit['id'],'startedAt':e['time'],'checkedAt':checked,'audioDelaySeconds':delay,
                         'captures':[manifest[n] for n in numbers]})
    first, second = accepted
    require(first['id'] != second['id'], 'The same permit was used twice')
    first_ids = {r['sourceFrame'] for r in first['captures']}
    require(first_ids.isdisjoint(r['sourceFrame'] for r in second['captures']), 'Reused checked capture after movement')
    motion = next((e for e in audit if e['type']=='motionStarted' and e['permit']['id'] == first['id']), None)
    end = next((e for e in audit if e['type']=='completed' and e['permit']['id'] == first['id']), None)
    require(motion and end and end['settled'] and end['time'] < min(second['checkedAt']), 'Second proof did not follow a completed, settled step')
    require(any(e['type'] in ('revoked','expired') and e['permit']['id'] == second['id'] for e in audit), 'The second permit was not withdrawn on freeze or pause')
    return {'source':spec['source'], 'sourceSHA256':spec['sourceSHA256'], 'sourceTimescale':spec['timescale'],
            'sensorInputs':'controlled poses, door box/identity and ground, landing and body geometry; original JPEGs and PTS; this tape does not run Vision',
            'playback':'AVAudioPlayer starts observed through its advancing cursor and accepted by the production executor',
            'firstStepCompletedAt':end['time'], 'permits':accepted}


def launch(args, spec, pictures, phases):
    run = str(uuid.uuid4())
    out = (args.output or ROOT / '.build-local/headless-step-replay' / run).resolve()
    out.mkdir(parents=True, exist_ok=False)
    selection = json.loads(simctl('list','devices','--json'))['devices']
    device = next((d for ds in selection.values() for d in ds if d['udid'] == args.simulator), None)
    require(device and device['state'] == 'Booted', 'Pass the UDID of the already booted and available simulator')
    if args.app:
        info = plistlib.loads((args.app / 'Info.plist').read_bytes())
        require(info['CFBundleIdentifier'] == BUNDLE and 'iPhoneSimulator' in info['CFBundleSupportedPlatforms'], 'Select the simulator PathSense.app')
        simctl('install',args.simulator,args.app)
    container = Path(simctl('get_app_container',args.simulator,BUNDLE,'data'))
    results = container / 'Library/Caches/PathSenseReplay' / run
    path = '/' + secrets.token_urlsafe(32)
    payload = plistlib.dumps(pictures, fmt=plistlib.FMT_BINARY)
    class LocalPixels(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != path:
                self.send_error(404); return
            self.send_response(200); self.send_header('Content-Type','application/x-plist')
            self.send_header('Content-Length',str(len(payload))); self.end_headers(); self.wfile.write(payload)
        def log_message(self, *ignored):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),LocalPixels)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = os.environ.copy()
    settings = {'PATHSENSE_HEADLESS_STEP_REPLAY':run,'PATHSENSE_TEST_CAMERA':'replay','PATHSENSE_TEST_FEEDBACK':'1',
                'PATHSENSE_TEST_FRAME_SOURCE':f'http://127.0.0.1:{server.server_port}{path}',
                'PATHSENSE_TEST_PHASE':'org.crosspointx.pathsense.headless.'+run,'PATHSENSE_TEST_EVIDENCE':json.dumps(phases,separators=(',',':'))}
    env.update({'SIMCTL_CHILD_'+k:v for k,v in settings.items()})
    try:
        print(f'Running on {device["name"]}. Reports: {out}',flush=True)
        simctl('launch','--terminate-running-process',args.simulator,BUNDLE,env=env)
        limit = time.monotonic() + 125
        while not (results/'result.json').exists() and time.monotonic() < limit:
            time.sleep(0.35)
        for filename in ('walk-measures.json','progress.json','result.json'):
            if (results/filename).is_file():
                shutil.copyfile(results/filename,out/filename)
        require((out/'result.json').is_file(), 'No response from the explicit Debug replay entry. Inspect progress.json and app state.')
        result = json.loads((out/'result.json').read_text())
        require(result['run']==run,'Unexpected run output')
        summary=validate(spec,result,json.loads((out/'walk-measures.json').read_text()) if (out/'walk-measures.json').is_file() else {})
        summary.update({'simulatorUDID':device['udid'],'simulatorName':device['name'],'run':run})
        (out/'validated.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
        print('Both recorded permits passed. '+str(out/'validated.json'))
    finally:
        server.shutdown(); server.server_close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare-only',action='store_true',help='verify original pixels, recording and evidence without touching a simulator')
    mode.add_argument('--simulator',metavar='UDID',help='explicitly take the already booted simulator for this run')
    parser.add_argument('--app',type=Path,help='install this current Debug simulator build before launch')
    parser.add_argument('--frames',type=Path,default=DEFAULT_FRAMES)
    parser.add_argument('--output',type=Path,help='new output directory for the run')
    args=parser.parse_args()
    spec,pictures,phases=records(args.frames)
    if args.prepare_only:
        print(f'{len(pictures)} original JPEG hashes and the original recording verified. {len(phases[1]["captures"])} observation frames, {len(phases[2]["captures"])} motion frames.')
        return
    launch(args,spec,pictures,phases)

if __name__=='__main__':
    try:
        main()
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
        sys.exit(str(error))
