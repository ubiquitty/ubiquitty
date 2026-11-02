#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""export-app-icon.py — the app icon's derived files, from the Icon Composer document.

Resources/Icon/Ubiquitty.icon is the one source of the mark. macOS and iOS
compile it with actool at build time. Linux and the browser frontend cannot run
actool, so this script writes what they ship, and the results are committed:

    Resources/Icon/Ubiquitty.svg          the document flattened: the ground's
                                          gradient on a rounded square and each
                                          layer in its fill. Linux installs it as
                                          the scalable icon; the web page serves
                                          it as its favicon.
    Resources/Icon/Raster/Ubiquitty-N.png the Default appearance from ictool at
                                          every hicolor size Linux installs.
    Resources/Icon/Raster/favicon.ico     16, 32 and 48 from the same renders.
    Resources/Icon/Raster/apple-touch-icon.png
                                          180, the iOS render on its ground,
                                          opaque because iOS masks it itself.

The flat SVG has no glass: lighting, shadow and translucency are system
materials with no SVG equivalent. The rasters do carry them.

    Scripts/export-app-icon.py

Needs Xcode's Icon Composer (ictool) and Pillow. Run it after changing the
document, and commit what it writes.
"""

import io
import json
import pathlib
import re
import subprocess
import sys
import tempfile

from PIL import Image

repository = pathlib.Path(__file__).resolve().parent.parent
document = repository / "Resources/Icon/Ubiquitty.icon"
flatOutput = repository / "Resources/Icon/Ubiquitty.svg"
rasterDirectory = repository / "Resources/Icon/Raster"
ictool = pathlib.Path(
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
)

hicolorSizes = (16, 24, 32, 48, 64, 128, 256)
faviconSizes = (16, 32, 48)
touchIconSize = 180


def colourHex(specification):
    """`srgb:r,g,b,a` or `display-p3:r,g,b,a` as #rrggbb. The document's
    colours are neutral greys, which read the same in either space."""
    channels = specification.split(":", 1)[1].split(",")[:3]
    return "#" + "".join(f"{round(float(channel) * 255):02x}" for channel in channels)


def layerPath(imageName):
    text = (document / "Assets" / imageName).read_text()
    match = re.search(r'<path d="([^"]+)"', text)
    if not match or 'viewBox="0 0 1024 1024"' not in text:
        raise SystemExit(f"export-app-icon: {imageName} is not one path on the 1024 canvas")
    return match.group(1)


def flatSVG(configuration):
    ground = configuration["fill"]["linear-gradient"]
    orientation = configuration["fill"]["orientation"]
    layers = [layer for group in configuration["groups"] for layer in group["layers"]]
    for layer in layers:
        position = layer.get("position", {})
        if position.get("scale", 1) != 1 or any(position.get("translation-in-points", [0, 0])):
            raise SystemExit(f"export-app-icon: layer {layer['name']} is positioned; draw it in place instead")
    # Icon Composer lists the front layer first; SVG paints the last one on top.
    paths = "\n".join(
        f'    <path d="{layerPath(layer["image-name"])}" fill="{colourHex(layer["fill"]["solid"])}"/>'
        for layer in reversed(layers)
    )
    return f"""<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 1024 1024">
  <!-- Written by Scripts/export-app-icon.py from Resources/Icon/Ubiquitty.icon. -->
  <defs>
    <linearGradient id="ground" x1="{orientation['start']['x']}" y1="{orientation['start']['y']}" x2="{orientation['stop']['x']}" y2="{orientation['stop']['y']}">
      <stop offset="0" stop-color="{colourHex(ground[0])}"/>
      <stop offset="1" stop-color="{colourHex(ground[1])}"/>
    </linearGradient>
  </defs>
  <!-- The document's canvas is the icon's shape; it is inset here by the
       margin a desktop icon keeps, so the mark keeps its share of the shape. -->
  <g transform="translate(48 48) scale(0.90625)">
    <rect width="1024" height="1024" rx="230" fill="url(#ground)"/>
{paths}
  </g>
</svg>
"""


def render(scratch, platform, size):
    output = pathlib.Path(scratch) / f"{platform}-{size}.png"
    subprocess.run(
        [
            str(ictool), str(document), "--export-image", "--output-file", str(output),
            "--platform", platform, "--rendition", "Default",
            "--width", str(size), "--height", str(size), "--scale", "1",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return Image.open(output).convert("RGBA")


def groundImage(configuration, size):
    """The ground's gradient across a full square, for the opaque touch icon."""
    top, bottom = (
        tuple(int(colourHex(stop)[index:index + 2], 16) for index in (1, 3, 5))
        for stop in configuration["fill"]["linear-gradient"]
    )
    orientation = configuration["fill"]["orientation"]
    start = orientation["start"]["y"] * size
    stop = orientation["stop"]["y"] * size
    image = Image.new("RGBA", (size, size))
    for row in range(size):
        fraction = min(1.0, max(0.0, (row + 0.5 - start) / (stop - start)))
        colour = tuple(round(a + (b - a) * fraction) for a, b in zip(top, bottom))
        image.paste(colour + (255,), (0, row, size, row + 1))
    return image


def main():
    if not ictool.exists():
        print(f"export-app-icon: no ictool at {ictool}; this needs Xcode", file=sys.stderr)
        return 1
    configuration = json.loads((document / "icon.json").read_text())
    flatOutput.write_text(flatSVG(configuration))
    rasterDirectory.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        renders = {size: render(scratch, "macOS", size) for size in sorted(set(hicolorSizes) | set(faviconSizes))}
        for size in hicolorSizes:
            renders[size].save(rasterDirectory / f"Ubiquitty-{size}.png", optimize=True)
        # Pillow's ICO writer resizes one image to each size; append_images
        # hands it the size-specific renders instead.
        icon = io.BytesIO()
        largest = renders[max(faviconSizes)]
        largest.save(
            icon,
            format="ICO",
            sizes=[(size, size) for size in faviconSizes],
            append_images=[renders[size] for size in faviconSizes if size != max(faviconSizes)],
        )
        (rasterDirectory / "favicon.ico").write_bytes(icon.getvalue())
        touch = groundImage(configuration, touchIconSize)
        touch.alpha_composite(render(scratch, "iOS", touchIconSize))
        touch.convert("RGB").save(rasterDirectory / "apple-touch-icon.png", optimize=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
