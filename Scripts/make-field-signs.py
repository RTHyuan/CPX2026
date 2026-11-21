"""Make the six single-sided, A4 landscape signs used for the exhibit camera trial."""
from io import BytesIO
from pathlib import Path

from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4, landscape
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
PAGES = [('ROOM', '305'), ('ROOM', '3050'), ('', '301-310'),
         ('DIRECTORY', '303 / 305 / 307'), ('ROOM', '0305'), ('ROOM', 'B217')]


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
        size = min(163, (width - 170) / doc.stringWidth(sign, 'Helvetica-Bold', 1))
        doc.setFont('Helvetica-Bold', size)
        baseline = height * (0.44 if heading else 0.5) - size * 0.35
        doc.drawCentredString(width / 2, baseline, sign)
        doc.showPage()
    doc.save()
    return stream.getvalue()


if __name__ == '__main__':
    content = make_pdf()
    for destination in [ROOT / 'output/pdf/PathSense-展桌测试标牌.pdf', ROOT / 'docs/media/field-signs.pdf']:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
    print(f'{len(PAGES)} signs, {len(content):,} bytes')
