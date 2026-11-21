"""Package a clean public-source snapshot, including the self-contained exhibit."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Public code and generated exhibits only. Do not collect the working directory or private submissions.
PUBLIC_FILES = (
    '.gitignore', 'LICENSE', 'Package.swift', 'README.md',
    'PathSense.xcodeproj/project.pbxproj',
    'PathSense.xcodeproj/xcshareddata/xcschemes/PathSense.xcscheme',
    'App/*.swift', 'App/Resources/Assets.xcassets/**/Contents.json',
    'App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png',
    'App/Resources/Practice/*.png', 'App/Resources/SignContext.mlmodel',
    'Core/*.swift', 'Training/sign-layout.csv', 'Tests/PathSenseCoreTests/*.swift',
    'UITests/*.swift', 'Scripts/*.swift', 'Scripts/*.sh', 'Scripts/*.py',
    'docs/index.html', 'docs/media/*.jpg', 'docs/media/captions-*.vtt', 'docs/media/pathsense-demo.mp4', 'docs/media/field-signs.pdf',
)


def main():
    output = ROOT / 'output' / 'PathSense-public-source.zip'
    output.parent.mkdir(exist_ok=True)
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
