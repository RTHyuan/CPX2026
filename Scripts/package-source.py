"""Package a clean public-source snapshot, including the self-contained exhibit."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import argparse
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Public code and generated exhibits only. Do not collect the working directory or private submissions.
PUBLIC_FILES = (
    '.gitignore', 'LICENSE', 'Package.swift', 'README.md',
    'PathSense.xcodeproj/project.pbxproj',
    'PathSense.xcodeproj/xcshareddata/xcschemes/PathSense.xcscheme',
    'App/*.swift', 'App/Navigation-Info.plist', 'App/Resources/Assets.xcassets/**/Contents.json',
    'App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png',
    'App/Resources/Practice/*.png', 'App/Resources/Practice/route-door.jpg', 'ASSET-CREDITS.md', 'App/Resources/SignContext.mlmodel',
    'Core/*.swift', 'Training/sign-layout.csv', 'Training/ArchivedSignContext.swift', 'Tests/PathSenseCoreTests/*.swift', 'Tests/Fixtures/demo-floor.json',
    'Proxy/server.py', 'Proxy/test_relay.py', 'Proxy/smoke_sign.py', 'Scripts/start-navigation-proxy.sh', 'Scripts/check-app-bundle.py',
    'UITests/*.swift', 'Scripts/*.swift', 'Scripts/verify-vision.sh',
    'Scripts/compose-poster.py', 'Scripts/exhibit_poster.py', 'Scripts/make-field-signs.py',
    'Scripts/make-practice.py', 'Scripts/make-route-signs.py', 'Scripts/package-source.py',
    'Scripts/publish-exhibit.py', 'Scripts/record-exhibit.py',
    'docs/index.html', 'docs/wayfinding.md', 'docs/air-field.md', 'docs/field-feedback.md',
    'docs/media/01-home.jpg', 'docs/media/home-dark.jpg', 'docs/media/navigation-dark.jpg',
    'docs/media/route-01-door.jpg', 'docs/media/route-origin.jpg', 'docs/media/route-02-directory.jpg',
    'docs/media/route-floor.jpg', 'docs/media/route-verify.jpg', 'docs/media/route-03-arrived.jpg',
    'docs/media/captions-zh.vtt', 'docs/media/captions-en.vtt', 'docs/media/pathsense-demo.mp4',
    'docs/media/field-signs.pdf', 'docs/media/pathsense-poster.pdf',
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'output' / 'PathSense-public-source.zip')
    output = parser.parse_args().output
    output.parent.mkdir(parents=True, exist_ok=True)
    files = set()
    for pattern in PUBLIC_FILES:
        matches = list(ROOT.glob(pattern))
        if not matches:
            raise SystemExit(f'Missing public source input: {pattern}')
        for path in matches:
            if path.is_symlink() or path.resolve() != path or not path.is_file():
                raise SystemExit(f'Unexpected public source input: {path.relative_to(ROOT)}')
            files.add(path)
    with tempfile.NamedTemporaryFile(dir=output.parent, suffix='.zip') as temporary:
        with ZipFile(temporary.name, 'w', compression=ZIP_DEFLATED, compresslevel=6) as bundle:
            for path in sorted(files):
                bundle.write(path, path.relative_to(ROOT).as_posix())
        with ZipFile(temporary.name) as bundle:
            if bundle.testzip() is not None:
                raise SystemExit('Archive failed its integrity check')
        # Write only after all inputs are packaged and verified. Preserve executable mode in ZIP entries.
        with output.open('wb') as destination:
            from shutil import copyfileobj
            copyfileobj(temporary, destination)
    print(f'{output.name}: {len(files)} files, {output.stat().st_size:,} bytes')


if __name__ == '__main__':
    main()
