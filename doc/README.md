# FreskPhD — documentation

FreskPhD turns **PNG exports of fresks** (Mural diagrams of cards, sections and arrows —
Climate-Fresk style) into structured, exportable data. An **automated first pass** detects
the cards and sections and reads their text; a human then **validates and corrects** the
result — and **draws the arrows by hand** — in a review workspace; everything exports to XLSX.

> This folder is the living documentation. Keep it in sync when the pipeline or data model
> changes. See also:
> - [`architecture.md`](architecture.md) — components, data flow, data model
> - [`development.md`](development.md) — run, test, import, debug, configure

## At a glance

```
Upload PNG ─► store original + display preview as BLOBs in SQLite
           ─► background Detection job (Task + PubSub progress)
                 ├─ pyvision  (OpenCV uv sidecar) : precise card/section boxes, fill colors,
                 │                                    per-crop images, downscaled display image
                 └─ Freskphd.Vision (Mistral VLM) : reads card/section text from the crops
                 └─ reconcile: attach VLM text to CV boxes
           ─► cards + sections persisted (source: "auto", status: "pending"); NO arrows
Review workspace (pan/zoom canvas + inspector)
   ─► human corrects, draws arrows by hand, validates items individually ─► status "validated"
Export XLSX (one flat table of fresks / annotations / links)
```

## Why this shape

- **Clean Mural exports** (crisp fills, printed text) make OpenCV geometry reliable, so CV owns
  the part it is best at: exact rectangles and fill colors.
- **The VLM owns text** — reading the French card/section titles off each crop.
- **Arrows are drawn by hand.** Automated arrow detection (CV tracing and a VLM numbered-overlay
  pass) was tried and proved unreliable, so the review workspace makes manual wiring fast: Link
  mode with per-endpoint card/section targeting, plus select/recolor/restyle/delete.
- **Everything lives in one SQLite file** (including image bytes) so the app is self-contained
  and portable.
- **Human-in-the-loop by design**: detection is a first pass with confidences; the reviewer
  corrects and **validates each item** (or the whole fresk) before export.

## Status

Rebuilt 2026-07-13 from the original manual two-click annotation tool; detection now covers
cards + sections only (arrows are manual as of 2026-07-14). 27 tests pass; verified end-to-end
on the 18 real exports in `data/fresk_exports/`.

Known rough edge: **section detection** (titles sometimes blank or duplicated) — finished during
human review. See [`architecture.md`](architecture.md#known-limitations).
