"""Geometry detection for clean Mural fresk exports.

Pipeline (all work happens on a downscaled copy; every coordinate returned is
normalized to 0..1 against the *original* image size, so it is resolution
independent):

  1. estimate the page background color
  2. cards    = solid, card-sized, filled blobs that differ from the background
  3. sections = large rectangular outlines whose interior is mostly background
                and which contain at least one card

Arrows are not detected: they are drawn by hand in the review workspace.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass
from typing import Any

import cv2
import numpy as np

# ---------------------------------------------------------------------------
# Loading / scaling
# ---------------------------------------------------------------------------


@dataclass
class Scene:
    bgr: np.ndarray  # downscaled working image (H, W, 3), BGR
    orig_w: int
    orig_h: int

    @property
    def h(self) -> int:
        return self.bgr.shape[0]

    @property
    def w(self) -> int:
        return self.bgr.shape[1]


def load_scene(path: str, max_dim: int) -> Scene:
    # cv2.imread struggles with very large PNGs on some builds; fall back to PIL.
    bgr = cv2.imread(path, cv2.IMREAD_COLOR)
    if bgr is None:
        from PIL import Image

        Image.MAX_IMAGE_PIXELS = None
        with Image.open(path) as im:
            rgb = np.array(im.convert("RGB"))
        bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)

    orig_h, orig_w = bgr.shape[:2]
    longest = max(orig_w, orig_h)
    if longest > max_dim:
        scale = max_dim / longest
        bgr = cv2.resize(
            bgr,
            (round(orig_w * scale), round(orig_h * scale)),
            interpolation=cv2.INTER_AREA,
        )
    return Scene(bgr=bgr, orig_w=orig_w, orig_h=orig_h)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def background_color(bgr: np.ndarray) -> np.ndarray:
    """Median color of the image border — the page background on a Mural export."""
    h, w = bgr.shape[:2]
    b = max(2, min(h, w) // 100)
    border = np.concatenate(
        [
            bgr[:b, :, :].reshape(-1, 3),
            bgr[-b:, :, :].reshape(-1, 3),
            bgr[:, :b, :].reshape(-1, 3),
            bgr[:, -b:, :].reshape(-1, 3),
        ]
    )
    return np.median(border, axis=0)


def bgr_to_hex(bgr: np.ndarray) -> str:
    b, g, r = (int(round(c)) for c in bgr[:3])
    return f"#{r:02x}{g:02x}{b:02x}"


def color_name(bgr: np.ndarray) -> str:
    """Coarse human-facing color bucket. The real category is resolved later."""
    b, g, r = (float(c) for c in bgr[:3])
    hsv = cv2.cvtColor(np.uint8([[[b, g, r]]]), cv2.COLOR_BGR2HSV)[0][0]
    hue, sat, val = int(hsv[0]), int(hsv[1]), int(hsv[2])
    if sat < 40:
        if val > 200:
            return "white"
        if val < 90:
            return "black"
        return "grey"
    if hue < 8 or hue >= 170:
        return "red"
    if hue < 20:
        return "orange"
    if hue < 34:
        return "yellow"
    if hue < 85:
        return "green"
    if hue < 100:
        return "teal"
    if hue < 130:
        return "blue"
    if hue < 160:
        return "purple"
    return "pink"


def _rect(contour) -> tuple[int, int, int, int]:
    x, y, w, h = cv2.boundingRect(contour)
    return x, y, x + w, y + h


def _extent(contour, x1: int, y1: int, x2: int, y2: int) -> float:
    box_area = max(1, (x2 - x1) * (y2 - y1))
    return cv2.contourArea(contour) / box_area


def _contains(outer: tuple, inner: tuple, pad: float = 0.0) -> bool:
    ox1, oy1, ox2, oy2 = outer
    ix1, iy1, ix2, iy2 = inner
    px = pad * (ox2 - ox1)
    py = pad * (oy2 - oy1)
    return (
        ox1 - px <= ix1
        and oy1 - py <= iy1
        and ix2 <= ox2 + px
        and iy2 <= oy2 + py
    )


def _iou(a: tuple, b: tuple) -> float:
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0, ix2 - ix1), max(0, iy2 - iy1)
    inter = iw * ih
    if inter == 0:
        return 0.0
    area_a = (ax2 - ax1) * (ay2 - ay1)
    area_b = (bx2 - bx1) * (by2 - by1)
    return inter / (area_a + area_b - inter)


# ---------------------------------------------------------------------------
# Cards
# ---------------------------------------------------------------------------


@dataclass
class Card:
    box: tuple[int, int, int, int]  # px in working image
    fill_bgr: np.ndarray
    confidence: float


def foreground_mask(bgr: np.ndarray, bg: np.ndarray) -> np.ndarray:
    """Pixels that differ from the page background (i.e. any drawn ink/fill)."""
    diff = np.linalg.norm(bgr.astype(np.int16) - bg.astype(np.int16), axis=2)
    return (diff > 26).astype(np.uint8) * 255


def detect_cards(scene: Scene, bg: np.ndarray) -> list[Card]:
    fg = foreground_mask(scene.bgr, bg)
    # Cards are *filled*; the page frame, section borders, arrows and text are
    # all *thin*. Opening erases anything thinner than the kernel, leaving only
    # solid card bodies — and, crucially, dissolving the outer page frame that
    # would otherwise swallow the whole image into a single contour.
    k = max(3, scene.w // 300)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    solid = cv2.morphologyEx(fg, cv2.MORPH_OPEN, kernel, iterations=1)
    # Fill the small dark-text holes back in so each card is one clean blob.
    solid = cv2.morphologyEx(solid, cv2.MORPH_CLOSE, kernel, iterations=2)

    # RETR_LIST (not RETR_EXTERNAL): a card enclosed by a section/page frame must
    # still be returned. Oversized frame/section contours are dropped by the card
    # size cap below.
    contours, _ = cv2.findContours(solid, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    img_area = scene.w * scene.h

    # First pass: keep solid, card-shaped blobs (some may be merged stacks of
    # same-color touching cards).
    blobs: list[tuple[int, int, int, int]] = []
    for c in contours:
        x1, y1, x2, y2 = _rect(c)
        w, h = x2 - x1, y2 - y1
        area = w * h
        if area < img_area * 0.00035 or area > img_area * 0.06:
            continue
        if not (0.15 < w / max(1, h) < 8):
            continue
        if _extent(c, x1, y1, x2, y2) < 0.72:
            continue
        blobs.append((x1, y1, x2, y2))

    # Split merged stacks: a blob much larger than the typical card is a grid of
    # touching same-color cards separated by their (thin, darker) borders.
    median_area = float(np.median([_box_area(b) for b in blobs])) if blobs else 0.0
    boxes: list[tuple] = []
    for b in blobs:
        if median_area and _box_area(b) > median_area * 1.7:
            boxes.extend(_split_into_cards(scene.bgr, b, median_area))
        else:
            boxes.append(b)

    cards: list[Card] = []
    for box in boxes:
        fill = _dominant_fill(scene.bgr, box)
        if np.linalg.norm(fill.astype(np.int16) - bg.astype(np.int16)) < 22:
            continue
        cards.append(Card(box=box, fill_bgr=fill, confidence=0.9))
    return _dedupe_cards(cards)


def _split_into_cards(bgr: np.ndarray, box: tuple, median_area: float) -> list[tuple]:
    """Split a merged blob into a grid of cards using edge projection profiles.

    Stacked/abutting cards share full-width (or full-height) border lines; those
    show up as strong peaks in the row/column edge-projection, which partition
    the blob into individual cards.
    """
    x1, y1, x2, y2 = box
    region = bgr[y1:y2, x1:x2]
    h, w = region.shape[:2]
    gray = cv2.cvtColor(region, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 40, 120)

    ys = _split_positions(edges.sum(axis=1), h, w)  # horizontal separators
    xs = _split_positions(edges.sum(axis=0), w, h)  # vertical separators

    if len(ys) <= 2 and len(xs) <= 2:
        return [box]  # nothing to split

    out: list[tuple] = []
    for ry1, ry2 in zip(ys, ys[1:]):
        for rx1, rx2 in zip(xs, xs[1:]):
            cw, ch = rx2 - rx1, ry2 - ry1
            if cw < 8 or ch < 8:
                continue
            cell = (x1 + rx1, y1 + ry1, x1 + rx2, y1 + ry2)
            if _box_area(cell) < median_area * 0.25:
                continue
            out.append(cell)
    return out or [box]


def _split_positions(profile: np.ndarray, length: int, span: int) -> list[int]:
    """Return cut positions (incl. 0 and length) at strong full-span edge lines."""
    thresh = span * 255 * 0.5
    peaks = [0]
    i = 0
    while i < length:
        if profile[i] > thresh:
            j = i
            while j < length and profile[j] > thresh:
                j += 1
            pos = (i + j) // 2
            if pos - peaks[-1] > max(8, length // 40):
                peaks.append(pos)
            i = j
        else:
            i += 1
    if length - peaks[-1] > max(8, length // 40):
        peaks.append(length)
    return peaks


def _dominant_fill(bgr: np.ndarray, box: tuple) -> np.ndarray:
    x1, y1, x2, y2 = box
    region = bgr[y1:y2, x1:x2].reshape(-1, 3)
    if region.size == 0:
        return np.array([0, 0, 0])
    # The fill is the *mid-tone* mass: drop dark text pixels and near-white
    # background/anti-aliased edge pixels, then take the median of what's left.
    lum = region @ np.array([0.114, 0.587, 0.299])
    keep = region[(lum > 32) & (lum < 232)]
    if keep.shape[0] < region.shape[0] * 0.15:
        keep = region  # near-uniform light card: fall back to the whole region
    return np.median(keep, axis=0)


def _dedupe_cards(cards: list[Card]) -> list[Card]:
    out: list[Card] = []
    for c in sorted(cards, key=lambda c: -_box_area(c.box)):
        if all(_iou(c.box, o.box) < 0.5 for o in out):
            out.append(c)
    return out


def _box_area(box: tuple) -> int:
    x1, y1, x2, y2 = box
    return (x2 - x1) * (y2 - y1)


# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------


@dataclass
class Section:
    box: tuple[int, int, int, int]
    confidence: float


def detect_sections(scene: Scene, bg: np.ndarray, cards: list[Card]) -> list[Section]:
    gray = cv2.cvtColor(scene.bgr, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 30, 100)
    # Close gaps so rounded-rectangle borders form a single closed contour.
    k = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
    edges = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, k, iterations=2)
    edges = cv2.dilate(edges, k, iterations=1)

    # RETR_TREE keeps nested rectangles (a section inside a section).
    contours, _ = cv2.findContours(edges, cv2.RETR_TREE, cv2.CHAIN_APPROX_SIMPLE)
    img_area = scene.w * scene.h
    card_boxes = [c.box for c in cards]

    candidates: list[tuple[int, int, int, int]] = []
    for c in contours:
        x1, y1, x2, y2 = _rect(c)
        w, h = x2 - x1, y2 - y1
        area = w * h
        if area < img_area * 0.007 or area > img_area * 0.9:
            continue
        peri = cv2.arcLength(c, True)
        approx = cv2.approxPolyDP(c, 0.02 * peri, True)
        if not (4 <= len(approx) <= 12):
            continue
        # Section = a frame: its interior is mostly background, not a solid fill.
        if _fill_ratio(scene.bgr, bg, (x1, y1, x2, y2)) > 0.6:
            continue
        inside = sum(1 for b in card_boxes if _contains((x1, y1, x2, y2), b, 0.02))
        if inside < 1:
            continue
        candidates.append((x1, y1, x2, y2))

    return [Section(box=b, confidence=0.7) for b in _dedupe_boxes(candidates)]


def _fill_ratio(bgr: np.ndarray, bg: np.ndarray, box: tuple) -> float:
    x1, y1, x2, y2 = box
    # Sample the interior only (avoid the border ring).
    mx = int((x2 - x1) * 0.08)
    my = int((y2 - y1) * 0.08)
    region = bgr[y1 + my : y2 - my, x1 + mx : x2 - mx].reshape(-1, 3)
    if region.size == 0:
        return 1.0
    diff = np.linalg.norm(region.astype(np.int16) - bg.astype(np.int16), axis=1)
    return float(np.mean(diff > 26))


def _dedupe_boxes(boxes: list[tuple]) -> list[tuple]:
    out: list[tuple] = []
    for b in sorted(boxes, key=lambda b: -_box_area(b)):
        if all(_iou(b, o) < 0.85 for o in out):
            out.append(b)
    return out


# ---------------------------------------------------------------------------
# Assembly / output
# ---------------------------------------------------------------------------


def _norm_box(box: tuple, scene: Scene) -> list[float]:
    x1, y1, x2, y2 = box
    return [x1 / scene.w, y1 / scene.h, x2 / scene.w, y2 / scene.h]


def _crop_b64(scene: Scene, box: tuple) -> str:
    x1, y1, x2, y2 = box
    crop = scene.bgr[max(0, y1) : y2, max(0, x1) : x2]
    ok, buf = cv2.imencode(".png", crop)
    if not ok:
        return ""
    return base64.b64encode(buf.tobytes()).decode("ascii")


def detect(
    path: str,
    max_dim: int = 2400,
    crops: bool = False,
    display: bool = False,
    debug_path: str | None = None,
) -> dict[str, Any]:
    scene = load_scene(path, max_dim)
    bg = background_color(scene.bgr)

    cards = detect_cards(scene, bg)
    sections = detect_sections(scene, bg, cards)

    if debug_path:
        _write_debug(scene, cards, sections, debug_path)

    def card_json(c: Card) -> dict:
        d = {
            "box": _norm_box(c.box, scene),
            "fill_hex": bgr_to_hex(c.fill_bgr),
            "color_name": color_name(c.fill_bgr),
            "confidence": round(c.confidence, 2),
        }
        if crops:
            d["crop_b64"] = _crop_b64(scene, c.box)
        return d

    def section_json(s: Section) -> dict:
        d = {"box": _norm_box(s.box, scene), "confidence": round(s.confidence, 2)}
        if crops:
            x1, y1, x2, y2 = s.box
            strip = int((y2 - y1) * 0.14)
            # A section's title sits in a strip at the top; crop just that so the
            # VLM reads the title, not every card inside the section.
            d["title_crop_b64"] = _crop_b64(scene, (x1, y1, x2, y1 + max(12, strip)))
        return d

    result = {
        "image": {"width": scene.orig_w, "height": scene.orig_h},
        "cards": [card_json(c) for c in cards],
        "sections": [section_json(s) for s in sections],
    }

    if display:
        ok, buf = cv2.imencode(".png", scene.bgr)
        result["display"] = {
            "width": scene.w,
            "height": scene.h,
            "png_b64": base64.b64encode(buf.tobytes()).decode("ascii") if ok else "",
        }

    return result


def _write_debug(scene, cards, sections, path) -> None:
    img = scene.bgr.copy()
    for s in sections:
        x1, y1, x2, y2 = s.box
        cv2.rectangle(img, (x1, y1), (x2, y2), (0, 0, 255), 3)
    for c in cards:
        x1, y1, x2, y2 = c.box
        cv2.rectangle(img, (x1, y1), (x2, y2), (255, 0, 0), 2)
    cv2.imwrite(path, img)
