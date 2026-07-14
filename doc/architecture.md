# Architecture

Phoenix 1.8 · LiveView · SQLite (ecto_sqlite3) · Bandit · daisyUI/Tailwind v4 · Req ·
a standalone Python `uv` project (OpenCV) · Mistral vision API.

## Data flow

1. **Upload** (`FreskphdWeb.FreskHomeLive`) — the PNG bytes are stored in the DB and a
   background detection job is started.
2. **Detection** (`Freskphd.Detection`, under `Freskphd.TaskSupervisor`) — orchestrates the
   sidecar + VLM + reconciliation, broadcasting progress on PubSub.
3. **Review** (`FreskphdWeb.FreskShowLive`) — renders overlays on a pan/zoom canvas and lets the
   reviewer correct them.
4. **Export** (`FreskphdWeb.ExportController`) — flattens everything to XLSX.

## Components

### 1. `pyvision/` — OpenCV geometry (uv sidecar)

A standalone `uv` project at the repo root. It is **not** embedded via pythonx; the Elixir side
shells out with `System.cmd("uv", ["run", "--project", pyvision_dir, "pyvision", "detect", …])`
and parses JSON on stdout. This isolates native OpenCV crashes from the BEAM and keeps the
detector independently runnable/testable.

```
uv run pyvision detect <image> [--max-dim 2400] [--crops] [--display] [--debug overlay.png]
```

Returns coordinates **normalized to 0..1** against the original image:

```json
{
  "image": {"width": W, "height": H},
  "cards":    [{"box":[x1,y1,x2,y2], "fill_hex":"#ffcf5c", "color_name":"orange",
                "confidence":0.9, "crop_b64":"…"}],
  "sections": [{"box":[…], "confidence":0.7, "title_crop_b64":"…"}],
  "display":  {"width":…, "height":…, "png_b64":"…"}
}
```

Detection strategy (`pyvision/src/pyvision/detect.py`):
- **Background** estimated from the image border.
- **Cards** = solid non-background blobs. `MORPH_OPEN` erases thin lines (page frame, section
  borders, arrows, text) leaving filled card bodies. Fill color = median of mid-tone pixels
  (drops dark text and near-white edges). Blobs much larger than the median card are **merged
  stacks of touching same-color cards**, split by row/column **edge-projection profiles**.
  `RETR_LIST` (not `RETR_EXTERNAL`) so cards enclosed by a section/frame are still found.
- **Sections** = large rectangular outlines (Canny + `RETR_TREE`) whose interior is mostly
  background and which contain ≥1 card.
- **Arrows are not detected.** Automated arrow detection (both CV stroke-tracing and a VLM
  "set of marks" pass) proved unreliable, so arrows are drawn by hand in the review workspace.

`--crops` adds a base64 PNG per card (and a top-strip `title_crop_b64` per section) so the Elixir
side needs no image library. `--display` returns the downscaled PNG used for storage + the VLM.

### 2. `Freskphd.Vision` — Mistral VLM client

`lib/freskphd/vision.ex`, Req-based, model **`mistral-large-2512`**, structured outputs
(`response_format: json_schema`), images as base64 `data:` URIs.

- `read_crops(crops_b64, on_progress \\ nil)` → one exact text per crop, in order.
  Batched (**Mistral allows max 8 images/request** → `max_crops_per_call: 8`). The optional
  callback reports `(done, total)` for progress. This is the only VLM call — arrows are manual,
  so there is no arrow-reading entry point.
- `configured?/0` — false when no API key; detection then degrades to CV-only (no text).
- Testable via `plug: {Req.Test, …}` (set in `config/test.exs`); no network in tests.

### 3. `Freskphd.Detection` — orchestrator

`lib/freskphd/detection.ex`.

- `detect_async/1` runs `run/1` under `Freskphd.TaskSupervisor`.
- `run/1`: write original bytes to a temp file → `pyvision` → store the display BLOB + set image
  dims → `Vision.read_crops` for card texts and section titles → `Fresks.replace_detection/4`
  (with **no links** — arrows are manual) → status `review`.
- **Reconcile**: each CV card box gets its VLM text + exact fill hex. A section title is blanked
  if it equals a card's text (the top strip caught a card).
- **Progress**: broadcasts `{:detection, stage, text}` on `topic("fresk:<id>")` and
  `{:fresk_updated, id}` on `index_topic()` ("fresks"). Stages:
  `:started → :opencv → :cards → :sections → :saving → :done` (or `:failed`).

### 4. Web

- `FreskHomeLive` — gallery grid (thumbnail via image route, status badge, card/arrow counts),
  drag-drop upload (≤60 MB), subscribes to the index topic for live status.
- `FreskShowLive` — review workspace: toolbar (**Pan** / Select / Card / Section / Link modes +
  **Show** layer toggles + per-endpoint **From/To Card|Section** targeting in Link mode), pan/zoom
  canvas, inspector for the selected card/section (edit text/type/category/color, **per-item
  validate**, delete) *or* the selected arrow (solid/dashed toggle, **Green/Red** color, delete),
  and a **tabbed** Cards / Sections / Arrows panel with per-row validate toggles and
  `n of total validated` counts. Cards list in reading order (row by row, left→right); sections in
  **quadrant order** (top-left → top-right → bottom-left → bottom-right by box center). Live
  progress panel, Re-detect, and **Validate / Invalidate** (whole fresk). Create/save/link actions
  flash a confirmation. Subscribes to the fresk topic.
- `assets/js/hooks/fresk_canvas.js` — renders the display image + overlays from server state
  (cards = translucent category-color fill, sections = dashed outline, arrows = colored
  solid/dashed with box-clipped arrowheads + contrast casing; a green dot marks validated boxes,
  amber marks pending/low-confidence; the selected box shows its **title label**); wheel-zoom,
  **Pan mode** (drag always pans; per-mode cursor), select box **or arrow**, move, resize, draw
  box, and link by **clicking the tail box then the head box** (or dragging between them — each end
  targets the chosen card/section type; `Esc` cancels), `Del` to remove the selection. **Layer
  toggles** hide/show each overlay type (hidden layers are also non-interactive). Server↔hook
  events: `canvas:set`, `canvas:mode`, `canvas:layers`, `canvas:link-endpoints`, `canvas:focus`,
  `canvas:focus-link` (down); `canvas:select`, `link:select`, `annotation:{create,move,delete}`,
  `link:{create,delete}` (up).
- `ImageController` — `GET /fresks/:id/image/:kind` (`original`|`display`) streams the BLOB.
- `ExportController` — `GET /export.xlsx` via `Freskphd.Fresks.export_header/0` + `export_rows/0`.

## Data model

Everything is in SQLite. Migration: `priv/repo/migrations/20260713000001_create_fresks.exs`.

| table | key columns |
|---|---|
| `fresks` | `title`, `dt`, `description`, `image_width`, `image_height`, `status` (`pending`/`processing`/`review`/`validated`/`failed`), `detection_error` |
| `fresk_images` | `fresk_id`, `kind` (`original`/`display`), `content_type`, `width`, `height`, `byte_size`, `data` (**BLOB**); unique on `(fresk_id, kind)` |
| `annotations` | `type` (`card`/`section`), `title`, `description`, `x1,y1,x2,y2` (**normalized 0..1**), `fresk_width`, `color` (fill hex), `category`, `source` (`auto`/`human`), `confidence`, `status` (`pending`/`validated`), `fresk_id` |
| `links` (arrows) | `kind` (nullable, derived downstream), `line_style` (`solid`/`dashed`), `color` (hex), `origin` (always `human` — arrows are drawn by hand), `confidence`, `source_annotation_id`, `target_annotation_id` |

Context module `Freskphd.Fresks` (`lib/freskphd/fresks.ex`) holds all queries plus:
`create_fresk_with_image/2`, `put_image/3`, `get_image/2`, `set_status/3`,
`replace_detection/4` (index-based link specs, transactional), `canvas_data/1`,
geometry `get_sorted_coordinates/1` + `is_within?/2` (section→card nesting by containment),
and the XLSX `export_header/0` + `export_rows/0` (coords **denormalized to pixels**, section
nesting via containment, all attributes appended).

## Design decisions

- **Sidecar, not pythonx**: matches "a uv project with deps installed there", isolates native
  crashes, independently testable.
- **Arrows are manual, not auto-detected**: both approaches tried — CV stroke-tracing (rough on
  crossing/dashed lines) and a VLM "set of marks" pass (numbered boxes → arrow list) — were
  unreliable in practice, so arrows are drawn by hand. The review workspace makes this fast:
  Link mode with per-endpoint card/section targeting, plus select/recolor/restyle/delete.
- **Normalized coordinates**: resolution-independent; the canvas maps them to the display image
  and the export denormalizes to original pixels.
- **Images in the DB**: one portable file; served via a controller with long cache headers.
- **Per-item validation**: each card/section carries its own `status`; the reviewer accepts them
  individually (green marker) rather than only rubber-stamping the whole fresk.

## Known limitations

- **Section detection** is the weakest: some sections come back untitled or duplicated (the
  title strip can catch a card, or a container border is faint). Left for human review.
- Overlapping/duplicate card boxes (e.g. a tall stacked block) can be over-split; the reviewer
  deletes/merges by hand.
- Rotated cards get an axis-aligned bounding box (loose fit); the reviewer can adjust.

## Future work ideas

- Canonical card dictionary (the ~40 standard cards recur across fresks) to normalize text and
  auto-assign categories/colors.
- Optional arrow *suggestions* (not auto-commit): propose likely arrows for the reviewer to
  accept, keeping humans in control.
- Better section titling (mask cards out of the title strip before OCR).
