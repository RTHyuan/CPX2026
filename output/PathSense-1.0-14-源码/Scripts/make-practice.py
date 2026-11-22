"""Draw original, reproducible test signs and the square viewfinder app mark (macOS + Pillow)."""
from pathlib import Path
import sys
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1] / 'App' / 'Resources'
regular = '/System/Library/Fonts/Supplemental/Arial Bold.ttf'
chinese = '/System/Library/Fonts/STHeiti Medium.ttc'

def sign(key, rows, paper, ink):
    image = Image.new('RGB', (1120, 680), paper)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((44, 44, 1076, 636), radius=28, outline=ink, width=7)
    for content, y, size, face in rows:
        font = ImageFont.truetype(face, size, index=1 if face == chinese else 0)
        draw.text((560, y), content, font=font, fill=ink, anchor='mm')
    image.save(root / 'Practice' / (key + '.png'), optimize=True)

if '--icon-only' not in sys.argv:
    for key, text in [('nearby', '303'), ('similar', '3050'), ('target', '305')]:
        sign(key, [('ROOM', 204, 58, regular), (text, 385, 206, regular)], '#e5ebe5', '#172f32')
    sign('span', [('301–310', 350, 175, regular)], '#193e39', '#f5f4df')
    sign('index', [('DIRECTORY', 204, 65, regular), ('303 / 305 / 307', 380, 104, regular)], '#fbefcb', '#382c20')
    sign('facility', [('电梯', 272, 144, chinese), ('ELEVATOR', 454, 70, regular)], '#16374a', '#f3faf6')
    Image.new('RGB', (1120, 680), '#d6d6c9').save(root / 'Practice' / 'blank.png', optimize=True)
# A white direction sign on a blue gradient, drawn as native-resolution geometry.
icon = Image.new('RGB', (1024, 1024))
draw = ImageDraw.Draw(icon)
for y in range(1024):
    t = y / 1023
    color = tuple(round(a + (b - a) * t) for a, b in zip((61, 166, 255), (0, 69, 196)))
    draw.line((0, y, 1023, y), fill=color)
for x, y, dx, dy in [(188, 190, 1, 1), (836, 190, -1, 1), (188, 834, 1, -1), (836, 834, -1, -1)]:
    draw.line([(x + dx * 127, y), (x, y), (x, y + dy * 127)], fill='#EBF5FF', width=34, joint='curve')
draw.rounded_rectangle((475, 355, 517, 735), radius=17, fill='white')
draw.polygon([(325, 341), (617, 341), (714, 425), (617, 509), (325, 509)], fill='white')
icon.save(root/'Assets.xcassets'/'AppIcon.appiconset'/'AppIcon.png', optimize=True)
