"""Verify the actual PathSense build product before installing it on a phone."""
import argparse
import plistlib
from pathlib import Path


def verify(app: Path) -> None:
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'org.crosspointx.pathsense' or not (app / info['CFBundleExecutable']).is_file():
        raise ValueError('expected a built PathSense application')
    for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription', 'NSLocalNetworkUsageDescription'):
        if not str(info.get(key, '')).strip():
            raise ValueError(f'missing {key}')
    for resource in app.rglob('*'):
        if resource.suffix.lower() in {'.mlmodel', '.mlmodelc', '.mlpackage'} or resource.name.startswith('SignContext.'):
            raise ValueError(f'unexpected model resource: {resource.relative_to(app)}')
    print(f'PASS {app.name} ({info.get("DTPlatformName", "?")}): permissions and executable present; model assets absent')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    try:
        verify(parser.parse_args().app)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'FAIL {error}\n')
