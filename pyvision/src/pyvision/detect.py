"""Geometry detection for clean Mural fresk exports.

Pipeline (all work happens on a downscaled copy; every coordinate returned is
normalized to 0..1 against the *original* image size, so it is resolution
independent):

  1. estimate the page background color
  2. cards    = solid, card-sized, filled blobs that differ from the background
  3. sections = large rectangular outlines whose interior is mostly background
                and which contain at least one card
  4. arrows   = thin connector strokes (black / colored, solid / dashed) left
                over once cards and sections are masked out
"""

from __future__ import annotations

import base64
from dataclasses import dataclass, field
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
# Arrows
# ---------------------------------------------------------------------------


@dataclass
class Arrow:
    points: list[tuple[int, int]]
    style: str  # "solid" | "dashed"
    color_bgr: np.ndarray
    tail: tuple[int, int]
    head: tuple[int, int]
    confidence: float


# Connector colors seen on the exports: black, green, red.
_ARROW_COLORS = {
    "black": None,  # handled via darkness
    "green": (35, 85),  # HSV hue range
    "red": None,  # handled via two-sided hue
}


def detect_arrows(
    scene: Scene, bg: np.ndarray, cards: list[Card], sections: list[Section]
) -> list[Arrow]:
    bgr = scene.bgr
    fg = foreground_mask(bgr, bg)

    # Remove card fills (dilated) so only inter-card strokes remain.
    occupied = np.zeros(fg.shape, np.uint8)
    for c in cards:
        x1, y1, x2, y2 = c.box
        pad = max(2, (x2 - x1) // 20)
        cv2.rectangle(occupied, (x1 - pad, y1 - pad), (x2 + pad, y2 + pad), 255, -1)
    strokes = cv2.bitwise_and(fg, cv2.bitwise_not(occupied))

    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]

    masks: dict[str, np.ndarray] = {}
    masks["black"] = ((v < 110) & (s < 90)).astype(np.uint8) * 255
    masks["green"] = ((h >= 35) & (h < 90) & (s > 60)).astype(np.uint8) * 255
    masks["red"] = (((h < 10) | (h >= 165)) & (s > 60)).astype(np.uint8) * 255

    # An arrow must land on real elements: keep only strokes whose endpoints are
    # both near a detected card/section box (drops titles, jokes, page frame).
    boxes = [c.box for c in cards] + [sec.box for sec in sections]

    arrows: list[Arrow] = []
    section_boxes = [sec.box for sec in sections]
    for name, mask in masks.items():
        mask = cv2.bitwise_and(mask, strokes)
        # Drop section borders: they are long but form closed rectangles.
        for sx1, sy1, sx2, sy2 in section_boxes:
            t = max(2, (sx2 - sx1) // 60)
            cv2.rectangle(mask, (sx1, sy1), (sx2, sy2), 0, t * 3)
        arrows.extend(_arrows_from_mask(mask, name, scene, boxes))
    return arrows


def _point_near_box(pt: tuple, box: tuple, tol: float) -> bool:
    x, y = pt
    x1, y1, x2, y2 = box
    dx = max(x1 - x, 0, x - x2)
    dy = max(y1 - y, 0, y - y2)
    return (dx * dx + dy * dy) ** 0.5 <= tol


def _arrows_from_mask(
    mask: np.ndarray, name: str, scene: Scene, boxes: list[tuple]
) -> list[Arrow]:
    # Bridge dashes so a dashed line is one component, then measure how much of
    # that span was actually ink to decide solid vs dashed.
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    linked = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)

    n, labels, stats, _ = cv2.connectedComponentsWithStats(linked, 8)
    img_diag = (scene.w**2 + scene.h**2) ** 0.5
    margin = max(4, int(min(scene.w, scene.h) * 0.01))
    out: list[Arrow] = []
    for i in range(1, n):
        x, y, w, h, area = stats[i]
        span = (w**2 + h**2) ** 0.5
        if span < img_diag * 0.04:
            continue
        # Skip components hugging the image edge (the page frame / export margin).
        if x <= margin and y <= margin and x + w >= scene.w - margin and y + h >= scene.h - margin:
            continue
        # Elongated, thin -> a connector, not a text blob.
        thickness = area / max(1.0, span)
        if thickness > max(6.0, img_diag * 0.01):
            continue
        comp = (labels == i).astype(np.uint8)
        raw_ink = int(cv2.countNonZero(cv2.bitwise_and(mask, mask, mask=comp)))
        filled = float(raw_ink) / max(1.0, area)
        style = "dashed" if filled < 0.55 else "solid"

        ys, xs = np.nonzero(comp)
        pts = np.column_stack([xs, ys]).astype(np.float32)
        tail, head = _endpoints(pts)
        tol = img_diag * 0.03
        if not (
            any(_point_near_box(tail, b, tol) for b in boxes)
            and any(_point_near_box(head, b, tol) for b in boxes)
        ):
            continue
        color = _median_color_at(scene.bgr, mask, comp)
        out.append(
            Arrow(
                points=[tuple(map(int, tail)), tuple(map(int, head))],
                style=style,
                color_bgr=color,
                tail=tuple(map(int, tail)),
                head=tuple(map(int, head)),
                confidence=0.45,
            )
        )
    return out


def _endpoints(pts: np.ndarray) -> tuple[tuple, tuple]:
    mean = pts.mean(axis=0)
    centered = pts - mean
    _, _, vt = np.linalg.svd(centered, full_matrices=False)
    axis = vt[0]
    proj = centered @ axis
    return tuple(pts[proj.argmin()]), tuple(pts[proj.argmax()])


def _median_color_at(bgr: np.ndarray, mask: np.ndarray, comp: np.ndarray) -> np.ndarray:
    sel = cv2.bitwise_and(mask, mask, mask=comp)
    ys, xs = np.nonzero(sel)
    if len(xs) == 0:
        return np.array([0, 0, 0])
    return np.median(bgr[ys, xs], axis=0)


# ---------------------------------------------------------------------------
# Assembly / output
# ---------------------------------------------------------------------------


def _norm_box(box: tuple, scene: Scene) -> list[float]:
    x1, y1, x2, y2 = box
    return [x1 / scene.w, y1 / scene.h, x2 / scene.w, y2 / scene.h]


def _norm_pt(pt: tuple, scene: Scene) -> list[float]:
    return [pt[0] / scene.w, pt[1] / scene.h]


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
    arrows = detect_arrows(scene, bg, cards, sections)

    if debug_path:
        _write_debug(scene, cards, sections, arrows, debug_path)

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

    def arrow_json(a: Arrow) -> dict:
        return {
            "points": [_norm_pt(p, scene) for p in a.points],
            "tail": _norm_pt(a.tail, scene),
            "head": _norm_pt(a.head, scene),
            "style": a.style,
            "color_hex": bgr_to_hex(a.color_bgr),
            "color_name": color_name(a.color_bgr),
            "confidence": round(a.confidence, 2),
        }

    result = {
        "image": {"width": scene.orig_w, "height": scene.orig_h},
        "cards": [card_json(c) for c in cards],
        "sections": [section_json(s) for s in sections],
        "arrows": [arrow_json(a) for a in arrows],
    }

    if display:
        ok, buf = cv2.imencode(".png", scene.bgr)
        result["display"] = {
            "width": scene.w,
            "height": scene.h,
            "png_b64": base64.b64encode(buf.tobytes()).decode("ascii") if ok else "",
        }

    return result


def _write_debug(scene, cards, sections, arrows, path) -> None:
    img = scene.bgr.copy()
    for s in sections:
        x1, y1, x2, y2 = s.box
        cv2.rectangle(img, (x1, y1), (x2, y2), (0, 0, 255), 3)
    for c in cards:
        x1, y1, x2, y2 = c.box
        cv2.rectangle(img, (x1, y1), (x2, y2), (255, 0, 0), 2)
    for a in arrows:
        cv2.line(img, a.tail, a.head, (0, 200, 0), 2)
        cv2.circle(img, a.head, 6, (0, 0, 255), -1)
    cv2.imwrite(path, img)
