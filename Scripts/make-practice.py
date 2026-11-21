"""Draw original, reproducible test signs and the square viewfinder app mark (macOS + Pillow)."""
from pathlib import Path
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

for key, text in [('nearby', '303'), ('similar', '3050'), ('target', '305')]:
    sign(key, [('ROOM', 204, 58, regular), (text, 385, 206, regular)], '#e5ebe5', '#172f32')
sign('span', [('301–310', 350, 175, regular)], '#193e39', '#f5f4df')
sign('index', [('DIRECTORY', 204, 65, regular), ('303 / 305 / 307', 380, 104, regular)], '#fbefcb', '#382c20')
sign('facility', [('电梯', 272, 144, chinese), ('ELEVATOR', 454, 70, regular)], '#16374a', '#f3faf6')
Image.new('RGB', (1120, 680), '#d6d6c9').save(root / 'Practice' / 'blank.png', optimize=True)
icon = Image.new('RGB', (1024,1024), '#103e35')
draw = ImageDraw.Draw(icon)
for x, y, dx, dy in [(188,190,1,1),(836,190,-1,1),(188,834,1,-1),(836,834,-1,-1)]:
    draw.line([(x+dx*127,y),(x,y),(x,y+dy*127)], fill='#ddf1a4', width=37, joint='curve')
draw.rounded_rectangle((464,345,509,736), radius=16, fill='#f0f4da')
draw.polygon([(315,340),(625,340),(726,425),(625,510),(315,510)],fill='#f0f4da')
icon.save(root/'Assets.xcassets'/'AppIcon.appiconset'/'AppIcon.png', optimize=True)
