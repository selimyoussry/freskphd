import argparse
import json
import sys

from pyvision.detect import detect


def main() -> None:
    parser = argparse.ArgumentParser(prog="pyvision")
    sub = parser.add_subparsers(dest="command", required=True)

    d = sub.add_parser("detect", help="Detect cards/sections/arrows in a fresk image")
    d.add_argument("image", help="Path to the fresk PNG/JPG")
    d.add_argument(
        "--max-dim",
        type=int,
        default=2400,
        help="Downscale so the longest side is at most this many px for detection",
    )
    d.add_argument(
        "--crops",
        action="store_true",
        help="Include a base64 PNG crop for each card/section",
    )
    d.add_argument(
        "--display",
        action="store_true",
        help="Include a base64 PNG of the downscaled display image + its dimensions",
    )
    d.add_argument(
        "--debug",
        metavar="PATH",
        default=None,
        help="Write an annotated overlay PNG to PATH for eyeballing",
    )

    args = parser.parse_args()

    if args.command == "detect":
        result = detect(
            args.image,
            max_dim=args.max_dim,
            crops=args.crops,
            display=args.display,
            debug_path=args.debug,
        )
        json.dump(result, sys.stdout)
        sys.stdout.write("\n")


if __name__ == "__main__":
    main()
