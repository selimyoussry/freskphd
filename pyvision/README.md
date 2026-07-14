# pyvision

OpenCV geometry detector for clean Mural fresk exports. Invoked as a sidecar by
the Elixir app (`Freskphd.Detection`), which passes an image and parses the JSON
on stdout. This tool owns the *precise geometry* (boxes, fill colors, arrow
style/color/endpoints); text reading and the semantic arrow graph are handled on
the Elixir side by the Mistral VLM.

## Usage

```bash
uv run pyvision detect <image.png> [--max-dim 2400] [--crops] [--debug overlay.png]
```

Outputs JSON on stdout with coordinates **normalized to 0..1** against the
original image size:

```json
{
  "image": {"width": 11051, "height": 6069},
  "cards":    [{"box": [x1,y1,x2,y2], "fill_hex": "#ffcf5c", "color_name": "orange", "confidence": 0.9}],
  "sections": [{"box": [x1,y1,x2,y2], "confidence": 0.7}],
  "arrows":   [{"points": [[x,y],...], "tail": [x,y], "head": [x,y],
                "style": "solid|dashed", "color_hex": "#1f7a3d", "color_name": "green", "confidence": 0.45}]
}
```

- `--crops` adds a base64-encoded PNG crop (`crop_b64`) to each card/section so
  the caller needs no image library of its own.
- `--debug PATH` writes an annotated overlay (blue = cards, red = sections,
  green = arrows) for eyeballing detection quality.

## How it works

1. Estimate the page background from the image border.
2. **Cards** — foreground (non-background) pixels, opened to drop thin lines,
   then solid card-shaped blobs. Merged stacks of touching same-color cards are
   split via edge projection profiles. Fill color = median of mid-tone pixels.
3. **Sections** — large rectangular outlines (Canny + `RETR_TREE`) whose interior
   is mostly background and which contain at least one card.
4. **Arrows** — thin connector strokes left after masking out cards, segmented by
   color (black/green/red), classified solid vs dashed by ink coverage, kept only
   when both endpoints land near a detected box.

## Develop

```bash
uv sync
uv run pytest
```
