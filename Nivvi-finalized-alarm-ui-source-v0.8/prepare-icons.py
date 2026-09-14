"""Package the existing Nivvi logo at the required iPhone sizes; no redesign."""
from pathlib import Path
import json, shutil, subprocess
root = Path(__file__).resolve().parent
catalog = root / 'build' / 'Assets.xcassets'
icons = catalog / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
info = {'version': 1, 'author': 'xcode'}
(catalog / 'Contents.json').write_text(json.dumps({'info': info}))
images = []
for size in (20, 29, 40, 60):
    for scale in (2, 3):
        filename = f'icon-{size}@{scale}x.png'
        subprocess.run(['sips', '-z', str(size*scale), str(size*scale), str(root / 'Assets/Nivvi-icon-1024.png'), '--out', str(icons / filename)], check=True, stdout=subprocess.DEVNULL)
        images.append({'idiom': 'iphone', 'size': f'{size}x{size}', 'scale': f'{scale}x', 'filename': filename})
shutil.copyfile(root / 'Assets/Nivvi-icon-1024.png', icons / 'icon-1024.png')
images.append({'idiom': 'ios-marketing', 'size': '1024x1024', 'scale': '1x', 'filename': 'icon-1024.png'})
(icons / 'Contents.json').write_text(json.dumps({'images': images, 'info': info}, indent=2))
