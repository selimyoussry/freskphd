"""Smoke tests for pyvision.detect against a synthetic fresk.

The synthetic image mirrors the real Mural exports: a light background, a large
unfilled rounded rectangle (section) containing a row of filled colored cards,
so we can assert the detector's basic contract without shipping fixtures.
"""

import base64
import io

import cv2
import numpy as np
import pytest
from PIL import Image

from pyvision.detect import detect


@pytest.fixture
def fresk_png(tmp_path):
    img = np.full((1000, 1400, 3), 250, np.uint8)  # light background

    # A section: large rectangle outline, background interior, cards well inside.
    cv2.rectangle(img, (40, 40), (960, 900), (120, 120, 120), 3)

    # Three filled colored cards in a row inside the section.
    colors = [(219, 152, 40), (82, 158, 52), (255, 192, 97)]  # BGR blue/green/orange
    for i, color in enumerate(colors):
        x = 120 + i * 240
        cv2.rectangle(img, (x, 160), (x + 180, 280), color, -1)
        cv2.putText(img, f"C{i}", (x + 40, 230), cv2.FONT_HERSHEY_SIMPLEX, 1, (20, 20, 20), 2)

    # Two touching same-color cards (a merged stack that must be split), each the
    # same size as a row card so the merged blob is ~2x the median and splits.
    cv2.rectangle(img, (120, 420), (300, 540), (219, 152, 40), -1)
    cv2.rectangle(img, (120, 540), (300, 660), (219, 152, 40), -1)
    cv2.rectangle(img, (120, 420), (300, 660), (90, 90, 90), 2)
    cv2.line(img, (120, 540), (300, 540), (90, 90, 90), 2)

    path = tmp_path / "fresk.png"
    cv2.imwrite(str(path), img)
    return str(path)


def test_detects_cards_and_section(fresk_png):
    result = detect(fresk_png)
    assert result["image"] == {"width": 1400, "height": 1000}
    # Three row cards + a split stack of two => at least five cards.
    assert len(result["cards"]) >= 5
    assert len(result["sections"]) >= 1


def test_cards_have_normalized_boxes_and_colors(fresk_png):
    result = detect(fresk_png)
    for card in result["cards"]:
        x1, y1, x2, y2 = card["box"]
        assert 0.0 <= x1 < x2 <= 1.0
        assert 0.0 <= y1 < y2 <= 1.0
        assert card["fill_hex"].startswith("#") and len(card["fill_hex"]) == 7
        assert card["color_name"]


def test_crops_are_valid_png(fresk_png):
    result = detect(fresk_png, crops=True)
    assert result["cards"]
    for card in result["cards"]:
        raw = base64.b64decode(card["crop_b64"])
        im = Image.open(io.BytesIO(raw))
        assert im.format == "PNG"
        assert im.size[0] > 0 and im.size[1] > 0
