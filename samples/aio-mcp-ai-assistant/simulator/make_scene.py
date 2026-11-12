from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

image = Image.new("RGB", (3840, 1080), "#FFFFFF")
draw = ImageDraw.Draw(image)
font = ImageFont.load_default(size=48)
for column in range(8):
    left = column * 480
    color = "#DEECF9" if column % 2 == 0 else "#E1DFDD"
    draw.rectangle((left, 0, left + 479, 1079), fill=color, outline="#605E5C", width=8)
    draw.text((left + 48, 390), f"PANEL {column + 1}", fill="#242424", font=font)
    draw.line((left + 240, 100, left + 240, 950), fill="#0078D4", width=6)
draw.rectangle((0, 0, 3839, 100), fill="#242424")
draw.text((60, 20), "SIMULATED CAMERA SCENE - NO REAL PEOPLE OR EQUIPMENT", fill="white", font=font)
destination = Path("/app/img")
destination.mkdir(parents=True, exist_ok=True)
image.save(destination / "scene.png")
