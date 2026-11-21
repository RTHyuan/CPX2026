"""Produce the project PDF and project image from the official AMD original and matching Gallery proof."""
import argparse
import hashlib
import io
import json
from pathlib import Path
from shutil import copyfile
from PIL import Image, ImageDraw, ImageFont, ImageOps
from reportlab.lib.pagesizes import A3
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen.canvas import Canvas

NAVY = '#12362F'
INK = '#192F2C'
PAPER = '#F5F5EB'
GREEN = '#D9EFAA'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw', type=Path, required=True, help='Original bytes downloaded from AMD Creative Factory')
    parser.add_argument('--gallery', type=Path, required=True, help='Screenshot from Image → My work → Gallery containing the same work')
    parser.add_argument('--out', type=Path, required=True, help='New output directory for the submission bundle')
    parser.add_argument('--font', default='/System/Library/Fonts/STHeiti Medium.ttc', help='A Chinese TrueType/OpenType font')
    args = parser.parse_args()
    if digest(args.raw) == digest(args.gallery):
        parser.error('Provide two distinct files: the original artwork and its matching Gallery screenshot.')
    with Image.open(args.raw) as original, Image.open(args.gallery) as proof:
        artwork = ImageOps.exif_transpose(original).convert('RGB')
        raw_format, gallery_format = original.format, proof.format
        proof.verify()
    extensions = {'PNG': '.png', 'JPEG': '.jpg', 'WEBP': '.webp'}
    if raw_format not in extensions or gallery_format not in extensions:
        parser.error('Use original PNG, JPEG or WebP assets. Keep the original AMD download unchanged.')
    args.out.mkdir(parents=True, exist_ok=False)
    width, height = 1748, 2480
    poster = Image.new('RGB', (width, height), PAPER)
    original_height = 1350
    poster.paste(ImageOps.fit(artwork, (width, original_height), centering=(.5,.5)), (0, 0))
    g = ImageDraw.Draw(poster)
    def font(size): return ImageFont.truetype(args.font, size, index=1 if 'STHeiti' in args.font else 0)
    def text(x, y, label, size, color): g.text((x, y), label, font=font(size), fill=color, anchor='lt')
    g.rectangle((0,original_height,width,1690), fill=NAVY)
    text(96,1400,'PathSense',108,'white')
    text(100,1545,'帮助低视力使用者在陌生楼层核对标牌',52,GREEN)
    text(98,1770,'要找 305，手机该说什么？',66,INK)
    for i,(evidence,summary) in enumerate([('301–310','范围包含目标号码'),('3050','读到其他房号，继续查找'),('305','读到目标号码，请确认门牌')]):
        top=1910+i*114
        text(100,top,evidence,55,NAVY); text(580,top+4,summary,49,INK)
        g.line((100,top+78,width-100,top+78),fill='#C3CEC2',width=3)
    text(100,2300,'站定扫描，用语音和触觉核对眼前的线索。',43,NAVY)
    text(100,2394,'SwiftUI  /  Apple Vision  /  Core ML                    CrossPointX 2026',31,INK)
    final_png=args.out/'PathSense-poster.png'; poster.save(final_png,optimize=True)
    pdf = Canvas(str(args.out/'PathSense-poster.pdf'), pagesize=A3)
    pdf.setTitle('PathSense · 室内标识辅助导航'); pdf.drawImage(ImageReader(poster),0,0,*A3); pdf.showPage(); pdf.save()
    raw_path=args.out/('AMD-original'+extensions[raw_format]); gallery_path=args.out/('AMD-gallery'+extensions[gallery_format])
    copyfile(args.raw,raw_path); copyfile(args.gallery,gallery_path)
    files=[raw_path,gallery_path,final_png,args.out/'PathSense-poster.pdf']
    (args.out/'sha256.json').write_text(json.dumps({p.name:digest(p) for p in files},indent=2)+'\n')

if __name__ == '__main__':
    main()
