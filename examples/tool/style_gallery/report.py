"""Pairs the native and web renders of the style gallery in an HTML report.

Run with `python3 -I tool/style_gallery/report.py` from `examples/`.

It first copies the native renders of the macOS example app (or the folder in
GALLERY_NATIVE_DIR) into build/style_gallery/native. The mean absolute RGB
difference is for review only, not a gate: the web references have a sky and
fog that the native engine cannot draw yet.
"""
import html
import json
import os
import shutil
import sys

from PIL import Image, ImageChops, ImageStat

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "../../build/style_gallery"))
SOURCE = os.environ.get(
    "GALLERY_NATIVE_DIR",
    os.path.expanduser(
        "~/Library/Containers/com.github.josxha.maplibreExample/Data/tmp/gallery"
    ),
)


def collect_native():
    dest = os.path.join(OUT, "native")
    os.makedirs(dest, exist_ok=True)
    for name in os.listdir(SOURCE):
        if name.endswith(".png"):
            shutil.copy2(os.path.join(SOURCE, name), os.path.join(dest, name))
    shutil.copy2(os.path.join(SOURCE, "manifest.json"), os.path.join(OUT, "manifest.json"))


def mean_difference(a_path, b_path):
    a = Image.open(a_path).convert("RGB")
    b = Image.open(b_path).convert("RGB")
    if a.size != b.size:
        b = b.resize(a.size, Image.LANCZOS)
    diff = ImageChops.difference(a, b)
    return sum(ImageStat.Stat(diff).mean) / 3


def main():
    collect_native()
    with open(os.path.join(OUT, "manifest.json")) as f:
        manifest = json.load(f)
    rows, diffs = [], []
    for entry in manifest:
        name = entry["name"]
        native = f"native/{name}.png"
        web = f"web/{name}.png"
        if not (os.path.exists(os.path.join(OUT, native)) and os.path.exists(os.path.join(OUT, web))):
            print("missing pair", name, file=sys.stderr)
            continue
        d = mean_difference(os.path.join(OUT, native), os.path.join(OUT, web))
        diffs.append((name, d))
        rows.append(
            f"<section><h2>{html.escape(entry['place'])} &middot; {html.escape(entry['look'])}</h2>"
            f"<p>mean abs RGB difference: <b>{d:.2f}</b> / 255 &middot; zoom {entry['zoom']}, "
            f"pitch {entry['pitch']}, bearing {entry['bearing']}</p>"
            f"<div class=pair><figure><img src='{web}'><figcaption>web (gl-js)</figcaption></figure>"
            f"<figure><img src='{native}'><figcaption>native</figcaption></figure></div></section>"
        )
        print(f"{name}\t{d:.2f}")
    page = (
        "<!doctype html><meta charset=utf-8><title>Style gallery</title>"
        "<style>body{font:14px system-ui;margin:16px;background:#fafafa}"
        ".pair{display:flex;gap:12px}figure{margin:0}img{width:430px;height:auto;display:block}"
        "figcaption{color:#555}</style><h1>Style gallery</h1>" + "".join(rows)
    )
    with open(os.path.join(OUT, "index.html"), "w") as f:
        f.write(page)
    print("wrote", os.path.join(OUT, "index.html"))


main()
