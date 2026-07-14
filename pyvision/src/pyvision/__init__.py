"""pyvision — OpenCV-based geometry detector for Mural fresk exports.

Detects cards (filled colored rectangles), sections (large unfilled rounded
rectangles that contain cards) and arrows (solid/dashed colored connectors),
emitting normalized (0..1) coordinates as JSON on stdout. Text reading and the
semantic arrow graph are handled on the Elixir side by the Mistral VLM; this
tool owns the *precise geometry*.
"""

from pyvision.cli import main

__all__ = ["main"]
