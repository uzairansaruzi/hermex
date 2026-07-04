#!/usr/bin/env python3
"""
Generate Android-specific image assets from the iOS source art.

1. Onboarding hero: 512px lossless WebP from 1024px app icon.
2. Adaptive-icon foreground PNGs at each density
   (art scaled into the 66/108 safe zone, centred on transparent canvas).

Usage:
    python scripts/android-assets.py
"""

import hashlib
import os
import sys
from pathlib import Path

from PIL import Image

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
RES_DIR = REPO_ROOT / "app" / "src" / "main" / "res"
# iOS source icon — try repo first, then temp locations.
_ICON_CANDIDATES = [
    REPO_ROOT / "HermesMobile" / "Resources" / "Assets.xcassets" / "HermesAppIcon.imageset" / "hermes_mobile_dark_icon.png",
    Path("C:/tmp/hermes_icon_source.png"),
    Path("/tmp/hermes_icon_source.png"),
]
ICON_SRC = next((p for p in _ICON_CANDIDATES if p.exists()), _ICON_CANDIDATES[0])

# Adaptive-icon canvas sizes per density bucket.
DENSITIES = {
    "drawable-mdpi":    108,
    "drawable-hdpi":    162,
    "drawable-xhdpi":   216,
    "drawable-xxhdpi":  324,
    "drawable-xxxhdpi": 432,
}

# The visible circle/squircle in adaptive icons is 66/108 of the canvas.
# We use a slightly larger ratio (70%) to fill a bit more while staying
# within the safe zone on all launcher shapes.
SAFE_RATIO = 0.70


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


def generate_hero(src: Path) -> None:
    """512px lossless WebP for the onboarding hero."""
    dst = RES_DIR / "drawable-nodpi" / "hermes_app_icon.webp"
    dst.parent.mkdir(parents=True, exist_ok=True)
    img = Image.open(src).convert("RGBA")
    img = img.resize((512, 512), Image.LANCZOS)
    img.save(str(dst), format="WEBP", lossless=True)
    print(f"  hero  {dst.relative_to(REPO_ROOT)}  512x512  sha256={sha256(dst)}")


def generate_launcher_foregrounds(src: Path) -> None:
    """Adaptive-icon foreground PNGs at every density."""
    img = Image.open(src).convert("RGBA")
    for bucket, canvas_px in DENSITIES.items():
        dst_dir = RES_DIR / bucket
        dst_dir.mkdir(parents=True, exist_ok=True)
        dst = dst_dir / "ic_launcher_foreground.png"

        art_px = int(canvas_px * SAFE_RATIO)
        offset = (canvas_px - art_px) // 2

        canvas = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
        art = img.resize((art_px, art_px), Image.LANCZOS)
        canvas.paste(art, (offset, offset), art)
        canvas.save(str(dst), format="PNG")
        print(f"  icon  {dst.relative_to(REPO_ROOT)}  {canvas_px}x{canvas_px}  art={art_px}  sha256={sha256(dst)}")


def main() -> None:
    if not ICON_SRC.exists():
        print(f"ERROR: source icon not found at {ICON_SRC}", file=sys.stderr)
        sys.exit(1)

    print("Generating Android assets from iOS source art...")
    generate_hero(ICON_SRC)
    generate_launcher_foregrounds(ICON_SRC)
    print("Done.")


if __name__ == "__main__":
    main()
