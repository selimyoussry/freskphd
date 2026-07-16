# Development

## Prerequisites

- Elixir/Erlang (see `.tool-versions`/mise), Node not required (esbuild/tailwind are managed).
- [`uv`](https://docs.astral.sh/uv/) on `PATH` for the `pyvision/` Python project.
- A Mistral API key.

## Configuration

Secrets come from `.env` at the repo root (loaded in `config/runtime.exs` for dev/test; real
environment variables win):

```
LLM_URI=https://api.mistral.ai/v1/
LLM_API_KEY=…
```

Tunables in `config/config.exs`:

- `:freskphd, :vision` — `model` (`mistral-large-2512`), `receive_timeout`,
  `max_crops_per_call` (**must be ≤ 8** — Mistral's per-request image cap).
- `:freskphd, :detection` — `uv_bin`, `pyvision_dir`, `display_max_dim`, `detect_max_dim`.

## Running the app

```bash
mix setup            # deps, DB create/migrate, assets
mix phx.server       # http://localhost:4049  (PORT overrides; default 4049)
```

Uploading a fresk on the home page stores it and kicks off detection automatically; watch the
live progress on the review page.

## The Python detector (`pyvision/`)

```bash
cd pyvision
uv sync
uv run pyvision detect ../data/fresk_exports/001_*.png --debug /tmp/overlay.png   # inspect JSON + overlay
uv run pytest                                                                     # smoke tests
```

Overlay colors: blue = cards, red = sections. (Arrows are drawn by hand, not detected.)

## Importing the real exports

`data/fresk_exports/` holds the 18 real Mural PNGs. Batch-import + detect:

```bash
mix freskphd.import_exports                 # all files in data/fresk_exports/
mix freskphd.import_exports DIR --no-detect # import images only
mix freskphd.import_exports --reset         # delete existing fresks first
```

Filenames are parsed as `NNN_Title_DDMMYYYY.png`.

> Note: run this when the Phoenix server is **stopped**, or drive detection through the running
> server (e.g. Tidewave `project_eval` calling `Freskphd.Detection.detect_async/1`) — two BEAM
> processes writing the same SQLite file can contend for locks.

## Database

SQLite, self-contained (image bytes included). Schema is a single migration; the DB carries no
production data, so structural changes are made by editing that migration and resetting:

```bash
mix ecto.reset                     # drop, create, migrate, seed (dev)
MIX_ENV=test mix ecto.drop         # if the test schema drifts
```

## Tests

```bash
mix test          # 28 tests: context, export, Vision (Req-stubbed), LiveViews
mix precommit     # compile --warnings-as-errors, deps.unlock --unused, format, test
```

The Mistral client is stubbed in tests via `plug: {Req.Test, Freskphd.VisionStub}`
(`config/test.exs`); tests never hit the network. Detection's sidecar/VLM path is exercised via
seeded data and the public `Fresks.replace_detection/4`, not by invoking the real pipeline.

## Debugging detection

- `uv run pyvision detect <img> --debug overlay.png` to see what CV found.
- `Freskphd.Detection.run/1` returns `{:ok, fresk}` / `{:error, _}`; failures set the fresk
  `status: "failed"` with `detection_error` and broadcast `{:detection, :failed, text}`.
- Progress and results are observable live in the review page, or via the Tidewave MCP
  (`execute_sql_query`, `get_logs`, `project_eval`).
