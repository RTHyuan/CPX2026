"""Draw reproducible wayfinding exhibits. A row can carry a separate graphical arrow."""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
CJK = '/System/Library/Fonts/STHeiti Medium.ttc'
LATIN = '/System/Library/Fonts/Supplemental/Arial Bold.ttf'


def card(folder, name, rows, color='#143934', ink='#fff9e5'):
    width, height = 1200, 680
    im = Image.new('RGB', (width, height), color)
    draw = ImageDraw.Draw(im)
    for i, (text, arrow) in enumerate(rows):
        y = (i+1)*height/(len(rows)+1)
        size = min(142 if len(rows) == 1 else 88, int(850 / max(1, sum(0.67 if ch.isascii() else 1 for ch in text))))
        font = ImageFont.truetype(LATIN if text.isascii() else CJK, size, index=0 if text.isascii() else 1)
        draw.text((565 if arrow else 600, y), text, fill=ink, font=font, anchor='mm')
        if arrow:
            cx = 840 if arrow == 'right' else 290
            if len(text) > 7: cx = 1030 if arrow == 'right' else 150
            points = [(-45,-10),(2,-10),(2,-29),(45,0),(2,29),(2,10),(-45,10)]
            draw.polygon([(cx+(x if arrow=='right' else -x),y+dy) for x,dy in points], fill=ink)
    im.save(folder/(name+'.png'), optimize=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--external',type=Path)
    args=parser.parse_args(); folder=args.external or ROOT/'App'/'Resources'/'Practice'; folder.mkdir(exist_ok=True,parents=True)
    if args.external:
        # Extra images are only in the test directory, never in the app's image bundle.
        card(folder,'unseen-index',[('DIRECTORY',None),('6F   水杉琴房',None),('3F   山川画室',None)])
        card(folder,'unseen-turn',[('水杉琴房','left'),('山川画室','right')], '#e7eacb','#193338')
        card(folder,'unseen-front',[('水杉琴房',None)])
        return
    signs={'exit':[('EXIT',None)], '208':[('ROOM 208',None)], 'campus-dir':[('DIRECTORY',None),('2F   201 - 220',None),('4F   401 - 420',None)],
           'lift':[('LIFT','right')], '4f':[('4F',None)], 'campus-turn':[('401 - 410','left')], '402':[('ROOM 402',None)],
           'entrance':[('ENTRANCE',None)],'med-dir':[('门诊目录',None),('2F   放射科',None),('3F   眼科',None)], '3f':[('3F',None)],
           'med-turn':[('眼科','right'),('耳鼻喉科','left')], 'med-plate':[('眼科',None)],
           'mall-dir':[('商场导览',None),('L2   月岛茶社',None),('B1   松间书屋',None)], 'b1':[('B1',None)],
           'mall-turn':[('松间书屋','left'),('月岛茶社','right')], 'mall-plate':[('松间书屋',None)]}
    for name,rows in signs.items(): card(folder,'route-'+name,rows)

if __name__=='__main__': main()
