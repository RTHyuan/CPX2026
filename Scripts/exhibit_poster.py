"""Lay out the PathSense exhibit poster from an actual, full-screen app capture."""
from pathlib import Path
import subprocess
import tempfile

from PIL import Image
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A3
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen.canvas import Canvas

PAPER = '#F5F5F7'
FOREST = '#1C263A'
INK = '#1D1D1F'
MUTED = '#4B4D53'
LIME = '#8AC1FF'
WHITE = '#FFFFFF'
LINE = '#C9CBD1'


def build(screenshot: Path, out: Path, chinese_font: str) -> None:
    """A3 portrait with embedded vector type. PNG and PDF share the same page."""
    fonts = Path('/System/Library/Fonts')
    pdfmetrics.registerFont(TTFont('PosterZH', chinese_font, subfontIndex=1 if 'STHeiti' in chinese_font else 0))
    pdfmetrics.registerFont(TTFont('PosterSans', str(fonts / 'Avenir Next.ttc'), subfontIndex=2))
    pdfmetrics.registerFont(TTFont('PosterHeavy', str(fonts / 'Avenir Next.ttc'), subfontIndex=0))
    with Image.open(screenshot) as source:
        screen = source.convert('RGB')
    if screen.height <= screen.width:
        raise ValueError('Use a portrait screenshot of the target result.')

    out.mkdir(exist_ok=True, parents=True)
    # Generate both formats successfully before replacing a previous set of exhibit files.
    with tempfile.TemporaryDirectory(dir=out) as directory:
        stage = Path(directory)
        pdf = stage / 'PathSense-poster.pdf'
        canvas = Canvas(str(pdf), pagesize=A3, pageCompression=1)
        canvas.setTitle('PathSense · 核对眼前的标牌')
        canvas.setAuthor('PathSense')
        canvas.setCreator('PathSense / ReportLab')
        canvas.setSubject('CrossPointX 2026 · Apple Human-Centered Care · iPhone 标牌识读')
        canvas.scale(A3[0] / 840, A3[1] / 1188)
        height = 1188

        def text(x, baseline, value, face, size, color=INK, right=False):
            canvas.setFont(face, size)
            canvas.setFillColor(HexColor(color))
            draw = canvas.drawRightString if right else canvas.drawString
            draw(x, height - baseline, value)

        def line(x1, x2, y, color, width=1):
            canvas.setStrokeColor(HexColor(color))
            canvas.setLineWidth(width)
            canvas.line(x1, height - y, x2, height - y)

        def shape(x, y, w, h, radius):
            # Same two curvature-continuous Beziers as the device's G2Rectangle.
            path = canvas.beginPath()
            r = min(radius, w / 2, h / 2)
            path.moveTo(x + r, height - y)
            turns = [(x + w - r, y, 1, 0, 0, 1), (x + w, y + h - r, 0, 1, -1, 0),
                     (x + r, y + h, -1, 0, 0, -1), (x, y + r, 0, -1, 1, 0)]
            for sx, sy, ux, uy, vx, vy in turns:
                def point(a, b):
                    return sx + r * (a * ux + b * vx), height - (sy + r * (a * uy + b * vy))
                path.lineTo(*point(0, 0))
                path.curveTo(*point(.2, 0), *point(.6, 0), *point(.8, .2))
                path.curveTo(*point(1, .4), *point(1, .8), *point(1, 1))
            path.close()
            return path

        def panel(x, y, w, h, radius, color):
            canvas.setFillColor(HexColor(color))
            canvas.drawPath(shape(x, y, w, h, radius), fill=1, stroke=0)

        canvas.setFillColor(HexColor(PAPER))
        canvas.rect(0, 0, 840, height, stroke=0, fill=1)
        text(43, 49, 'CrossPointX 2026', 'PosterHeavy', 15)
        text(797, 49, 'TRACK 01  /  APPLE HUMAN-CENTERED CARE', 'PosterSans', 12, MUTED, right=True)
        line(43, 797, 66, LINE)
        text(39, 151, 'PathSense', 'PosterHeavy', 88)
        text(43, 208, '我要去 402，先找哪块牌？', 'PosterZH', 40)
        text(45, 248, '为低视力访客持续读取门牌、导览和方向标识。', 'PosterZH', 18, MUTED)

        panel(42, 274, 756, 519, 47, FOREST)
        text(72, 321, '目标房号 402', 'PosterZH', 19, LIME)
        rows = [('208', '出门后扫到起点门牌，接着寻找目录。'),
                ('401–420', '楼层目录把这段房号列在四楼。'),
                ('4F', '换层后扫描楼层牌，核对当前位置。'),
                ('ROOM 402', '读到独立标识，使用者核对并确认到达。')]
        for row, (sign, interpretation) in enumerate(rows):
            baseline = 391 + row * 107
            text(72, baseline, sign, 'PosterHeavy', 43 if row < 3 else 34, LIME if row == 2 else WHITE)
            text(73, baseline + 32, interpretation, 'PosterZH', 17, WHITE)
            if row < 3:
                line(73, 448, baseline + 53, '#52617A', .85)
        width = 203
        sh = width * screen.height / screen.width
        x, y = 536, 298
        # Preserve the entire result screen including status bar, target and source. The
        # paper margin/frame avoids cropping UI pixels and separates it from the dark panel.
        panel(x - 5, y - 5, width + 10, sh + 10, 20, '#A7B4C8')
        canvas.drawImage(ImageReader(screen), x, height - y - sh, width, sh)
        text(x - 3, 768, 'iPhone Air 模拟器 · 连续镜头回放', 'PosterZH', 12, WHITE)

        text(43, 854, '拿起 iPhone 试一次', 'PosterZH', 32)
        steps = [(43, '设定目标', '输入房号、科室、', '店名或公共设施。'),
                 (302, '站定取景', '缓慢转向门和路牌，', '在新线索前稍作停留。'),
                 (561, '听后核对', '听提示，按需要重听，', '再结合现场门牌确认。')]
        for x, title, first, second in steps:
            line(x, x + 234, 878, LINE)
            text(x, 918, title, 'PosterZH', 24)
            text(x, 954, first, 'PosterZH', 17, MUTED)
            text(x, 980, second, 'PosterZH', 17, MUTED)
        panel(42, 1009, 756, 93, 28, '#E4EFFF')
        text(65, 1046, '在 iPhone 上识字', 'PosterZH', 20)
        text(65, 1078, '两次一致的观察用于更新引导。重听、暂停或重新定位都保留在本次行程中。', 'PosterZH', 16, INK)
        line(43, 797, 1125, LINE)
        text(43, 1158, '行走与避障请继续使用惯常的出行辅助。', 'PosterZH', 15, MUTED)
        text(797, 1158, 'SwiftUI   /   Vision   /   Core ML', 'PosterSans', 13, MUTED, right=True)
        canvas.showPage()
        canvas.save()

        subprocess.run(['pdftoppm', '-singlefile', '-png', '-r', '300', str(pdf), str(stage / 'PathSense-poster')], check=True)
        for name in ('PathSense-poster.pdf', 'PathSense-poster.png'):
            (stage / name).replace(out / name)
