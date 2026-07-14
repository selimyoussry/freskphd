# FreskPhD

A small, standalone Phoenix/LiveView app for annotating "fresk" images (workshop
posters/diagrams such as a Climate Fresk). Upload an image, draw rectangular
**cards** and **sections** on it, link annotations with **arrows**, and export
everything to XLSX.

This is a self-contained reconstruction of the `side-projects/phd` (Fresk)
feature that used to live in the main Sapiologie app (issue ISS-5606) and was
removed in ISS-6511. It was rebuilt here as an unauthenticated, dependency-free
app: SQLite instead of the graph event store, local disk instead of S3, and a
server-side XLSX controller instead of the JS export hook. The canvas hook and
the annotation/nesting/geometry logic are faithful ports of the originals.

## What it does

- **Home (`/`)** - lists fresks (title, date, annotation count, thumbnail),
  upload a new fresk image (PNG/JPEG), edit/delete, and **Export as XLSX**.
- **Fresk view (`/fresks/:id`)** - the image is drawn on an HTML5 canvas.
  - Pick a type (**card**, **section**, or **arrow**).
  - For a card/section: click two points on the canvas to define a rectangle,
    then give it a title/description and save. Cards are blue, sections red.
  - For an arrow: pick a source and target annotation and a kind
    (dependency / positive influence / negative influence).
  - Sections automatically **nest** the cards whose rectangle sits inside them
    (pure geometry, `Fresks.is_within?/2`); expand a section to see its children.
  - Edit/delete annotations and links.

## Domain model

- `fresks` - title, description, dt (date string), image_path
- `annotations` - type (`card`/`section`), title, description, x1/y1/x2/y2,
  fresk_width, belongs to a fresk
- `links` - kind, from one annotation to another (the "arrows")

## Running

```bash
mix setup            # deps, DB, assets (assets need a one-time binary download)
mix phx.server       # http://localhost:4049
```

The port defaults to **4049** (`config/runtime.exs`, override with `PORT`).
Uploaded images are stored under `priv/uploads/` and served at `/uploads`.

## Tests

```bash
mix test
```

Covers the home list/create/delete, the full canvas flow (two clicks -> pick
type -> save card, section nesting, arrow links) driven through LiveView
events, and the XLSX export.

## Notes

- Tailwind v4 and esbuild binaries are fetched from GitHub/npm on first
  `mix assets.setup`. In this environment OTP's TLS rejected GitHub's
  release-asset certificate, so the Tailwind binary was fetched with `curl`
  into `_build/tailwind-linux-x64-4.1.12`. If you wipe `_build`, re-fetch it:

  ```bash
  curl -sSL -o _build/tailwind-linux-x64-4.1.12 \
    https://github.com/tailwindlabs/tailwindcss/releases/download/v4.1.12/tailwindcss-linux-x64
  chmod +x _build/tailwind-linux-x64-4.1.12
  ```
