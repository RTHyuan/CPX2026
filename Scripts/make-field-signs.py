"""Print six identifier checks followed by three complete walk-throughs for the rear camera."""
from io import BytesIO
from pathlib import Path

from PIL import Image
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4, landscape
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
PAGES = [('ROOM', '305'), ('ROOM', '3050'), ('', '301-310'),
         ('DIRECTORY', '303 / 305 / 307'), ('ROOM', '0305'), ('ROOM', 'B217')]
ROUTES = [
    ('door', '208', 'campus-dir', 'lift', '4f', 'campus-turn', '402'),
    ('entrance', 'med-dir', 'lift', '3f', 'med-turn', 'med-plate'),
    ('entrance', 'mall-dir', 'lift', 'b1', 'mall-turn', 'mall-plate'),
]


def make_pdf():
    stream = BytesIO()
    width, height = landscape(A4)
    doc = canvas.Canvas(stream, pagesize=(width, height), invariant=1, pageCompression=1)
    doc.setTitle('PathSense | Camera trial signs')
    doc.setAuthor('PathSense')
    for heading, sign in PAGES:
        doc.setFillColor(HexColor('#182C2C'))
        doc.setStrokeColor(HexColor('#344D4A'))
        doc.setLineWidth(3)
        doc.roundRect(53, 72, width - 106, height - 144, 15)
        if heading:
            doc.setFont('Helvetica-Bold', 35)
            doc.drawCentredString(width / 2, height * 0.65, heading)
        # A slab serif distinguishes the left stem of a letter from adjacent digits on mixed identifiers.
        face = 'Courier-Bold' if any(ch.isalpha() for ch in sign) else 'Helvetica-Bold'
        size = min(163, (width - 170) / doc.stringWidth(sign, face, 1))
        doc.setFont(face, size)
        baseline = height * (0.44 if heading else 0.5) - size * 0.35
        doc.drawCentredString(width / 2, baseline, sign)
        doc.showPage()
    for route in ROUTES:
        for name in route:
            ext = 'jpg' if name == 'door' else 'png'
            image_path = ROOT / 'App/Resources/Practice' / f'route-{name}.{ext}'
            with Image.open(image_path) as image:
                scale = min(width / image.width, height / image.height)
                w, h = image.width * scale, image.height * scale
                bg = image.convert('RGB').getpixel((0, 0))
                doc.setFillColorRGB(*(value / 255 for value in bg))
                doc.rect(0, 0, width, height, fill=1, stroke=0)
                doc.drawImage(str(image_path), (width - w) / 2, (height - h) / 2, w, h)
            doc.showPage()
    doc.save()
    return stream.getvalue()


if __name__ == '__main__':
    content = make_pdf()
    for destination in [ROOT / 'output/pdf/PathSense-展桌测试标牌.pdf', ROOT / 'docs/media/field-signs.pdf']:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
    print(f'{len(PAGES) + sum(map(len, ROUTES))} signs, {len(content):,} bytes')
