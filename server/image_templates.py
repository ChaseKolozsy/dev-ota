#!/usr/bin/env python3
"""Create bounded, portable DevOTA tap templates from device screenshots."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps


TEMPLATE_FORMAT = "devota-image-template"
TEMPLATE_VERSION = 1
MAX_TEMPLATE_SIDE = 512
MAX_TEMPLATE_BYTES = 384 * 1024


def _clamp(value: int, lower: int, upper: int) -> int:
    return max(lower, min(upper, value))


def create_tap_template(
    screenshot: Image.Image,
    *,
    click_x: int,
    click_y: int,
    bounds: tuple[int, int, int, int] | None = None,
    padding: int = 24,
    threshold: float = 0.84,
) -> tuple[dict[str, Any], bytes]:
    """Return template metadata and PNG bytes without retaining the full frame."""
    source = ImageOps.exif_transpose(screenshot).convert("RGB")
    width, height = source.size
    if width < 1 or height < 1:
        raise ValueError("screenshot dimensions must be positive")
    click_x = _clamp(int(click_x), 0, width - 1)
    click_y = _clamp(int(click_y), 0, height - 1)
    padding = _clamp(int(padding), 0, 128)

    if bounds is None:
        half_width = min(160, max(72, width // 8))
        half_height = min(112, max(56, height // 12))
        left, top, right, bottom = (
            click_x - half_width,
            click_y - half_height,
            click_x + half_width,
            click_y + half_height,
        )
    else:
        left, top, right, bottom = map(int, bounds)
        if right <= left or bottom <= top:
            raise ValueError("template bounds must have positive area")
        left -= padding
        top -= padding
        right += padding
        bottom += padding

    left = _clamp(left, 0, width - 1)
    top = _clamp(top, 0, height - 1)
    right = _clamp(right, left + 1, width)
    bottom = _clamp(bottom, top + 1, height)
    crop = source.crop((left, top, right, bottom))
    if max(crop.size) > MAX_TEMPLATE_SIDE:
        scale = MAX_TEMPLATE_SIDE / max(crop.size)
        resized = (
            max(1, round(crop.width * scale)),
            max(1, round(crop.height * scale)),
        )
        crop = crop.resize(resized, Image.Resampling.LANCZOS)

    output = io.BytesIO()
    crop.save(output, format="PNG", optimize=True)
    png = output.getvalue()
    if len(png) > MAX_TEMPLATE_BYTES:
        raise ValueError(
            f"tap template is too large ({len(png)} bytes; max {MAX_TEMPLATE_BYTES})"
        )

    # The click offset is measured against the original crop rectangle, so it
    # remains stable even when the template itself was downscaled for storage.
    crop_source_width = right - left
    crop_source_height = bottom - top
    metadata: dict[str, Any] = {
        "format": TEMPLATE_FORMAT,
        "version": TEMPLATE_VERSION,
        "pngBase64": base64.b64encode(png).decode("ascii"),
        "sha256": hashlib.sha256(png).hexdigest(),
        "width": crop.width,
        "height": crop.height,
        "sourceWidth": width,
        "sourceHeight": height,
        "expectedCenterX": ((left + right) / 2) / width,
        "expectedCenterY": ((top + bottom) / 2) / height,
        "clickOffsetX": (click_x - left) / crop_source_width,
        "clickOffsetY": (click_y - top) / crop_source_height,
        "searchRadiusX": 0.42,
        "searchRadiusY": 0.42,
        "threshold": max(0.5, min(0.99, float(threshold))),
    }
    return metadata, png


def create_from_path(
    screenshot_path: Path,
    *,
    output_path: Path,
    click_x: int,
    click_y: int,
    bounds: tuple[int, int, int, int] | None,
    padding: int,
) -> dict[str, Any]:
    with Image.open(screenshot_path) as screenshot:
        metadata, png = create_tap_template(
            screenshot,
            click_x=click_x,
            click_y=click_y,
            bounds=bounds,
            padding=padding,
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(png)
    output_path.chmod(0o600)
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--x", required=True, type=int)
    parser.add_argument("--y", required=True, type=int)
    parser.add_argument("--bounds", nargs=4, type=int)
    parser.add_argument("--padding", type=int, default=24)
    args = parser.parse_args()
    metadata = create_from_path(
        args.input,
        output_path=args.output,
        click_x=args.x,
        click_y=args.y,
        bounds=tuple(args.bounds) if args.bounds else None,
        padding=args.padding,
    )
    print(json.dumps(metadata, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
