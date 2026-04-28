"""
convert_poly.py — Convert CHS polygon description files to coordinate lists.

Reads a CHS polygon file (whitespace-separated columns: index, latitude,
longitude, ...) and prints the closed polygon ring in one of three formats:
decimal degrees (default), DMS, or UTM.

Datum: WGS84 only. If the input mentions NAD83 or CSRS, the script aborts
rather than silently produce wrong coordinates.

Output streams:
  - The format header (e.g. "Format: UTM Zone 9N — WGS84") goes to STDERR.
  - The coordinate data goes to STDOUT.
This way `convert_poly.py file.txt | clip` puts only the data on the
clipboard, while running interactively shows both header and data on the
terminal. When STDOUT is a terminal, the data is also auto-copied to the
clipboard via pyperclip.

To change how a format looks, edit the corresponding function below:
  - format_decimal()  — decimal degrees
  - format_dms()      — degrees-minutes-seconds
  - format_utm()      — UTM easting/northing
The three functions deliberately repeat structure so each can be edited in
isolation without understanding the others.
"""

import argparse
import re
import sys

try:
    import utm
except ImportError:
    sys.stderr.write(
        "error: this script needs the 'utm' package, which doesn't appear "
        "to be installed.\n"
        "\n"
        "Open cmd.exe and run:\n"
        "\n"
        "    pip install utm pyperclip\n"
        "\n"
        "then try again.\n"
    )
    sys.exit(1)

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

_COORD_RE = re.compile(r"^(\d+(?:\.\d+)?)([NSEW])$")
_DATUM_RE = re.compile(r"NAD\s?83|CSRS", re.IGNORECASE)


def parse_lat_lon(token: str) -> tuple[float, int]:
    """Parse a coordinate token like '53.363333N' or '129.788333W'.

    Returns (decimal_value, decimal_places). The caller uses decimal_places
    to round-trip the input precision in decimal-degree output.
    """
    m = _COORD_RE.match(token)
    if not m:
        raise ValueError(f"could not parse coordinate {token!r}")
    number, hemi = m.group(1), m.group(2)
    value = float(number)
    if hemi in ("S", "W"):
        value = -value
    decimals = len(number.split(".", 1)[1]) if "." in number else 0
    return value, decimals


def parse_file(path: str) -> list[tuple[int, float, float, int, int]]:
    """Read a CHS polygon file. Returns list of (idx, lat, lon, lat_dec, lon_dec).

    Skips blank lines and any line whose first token is not an integer (this
    skips the header row). Raises ValueError on datum mismatch, parse error,
    or out-of-range / wrong-hemisphere coordinates.
    """
    # utf-8-sig strips the BOM that Windows tools sometimes prepend.
    with open(path, encoding="utf-8-sig") as f:
        text = f.read()

    if _DATUM_RE.search(text):
        raise ValueError(
            "input file mentions NAD83 or CSRS; this tool only handles WGS84"
        )

    points: list[tuple[int, float, float, int, int]] = []
    for line in text.splitlines():
        tokens = line.split()
        if not tokens:
            continue
        try:
            idx = int(tokens[0])
        except ValueError:
            # header row or other non-data line
            continue
        if len(tokens) < 3:
            raise ValueError(
                f"row {idx}: expected at least 3 columns, got {len(tokens)}"
            )

        lat_token, lon_token = tokens[1], tokens[2]
        # Hemisphere-suffix sanity: catches transposed-column files early.
        if not lat_token.endswith(("N", "S")):
            raise ValueError(
                f"row {idx}: latitude {lat_token!r} must end in N or S"
            )
        if not lon_token.endswith(("E", "W")):
            raise ValueError(
                f"row {idx}: longitude {lon_token!r} must end in E or W"
            )

        lat, lat_dec = parse_lat_lon(lat_token)
        lon, lon_dec = parse_lat_lon(lon_token)

        if not -90.0 <= lat <= 90.0:
            raise ValueError(
                f"row {idx}: latitude {lat} out of range [-90, 90]"
            )
        if not -180.0 <= lon <= 180.0:
            raise ValueError(
                f"row {idx}: longitude {lon} out of range [-180, 180]"
            )

        points.append((idx, lat, lon, lat_dec, lon_dec))

    if not points:
        raise ValueError("no data rows found in input")
    return points


def close_ring(
    points: list[tuple[int, float, float, int, int]],
) -> list[tuple[int, float, float, int, int]]:
    """Append a copy of the first vertex if the ring isn't already closed."""
    if not points:
        return points
    first, last = points[0], points[-1]
    if abs(first[1] - last[1]) < 1e-9 and abs(first[2] - last[2]) < 1e-9:
        return points
    return points + [first]


# ---------------------------------------------------------------------------
# DMS helper
# ---------------------------------------------------------------------------


def to_dms(dd: float, is_lat: bool) -> str:
    """Format a signed decimal degree value as e.g. '53-21-48.00N'.

    Longitude gets a 3-digit degree pad; latitude gets 2. Seconds are
    rounded to 2 decimals; the function rebalances any 60.00 carry so the
    output never reads '...-59-60.00'.
    """
    sign_pos = dd >= 0
    a = abs(dd)
    deg = int(a)
    rem = (a - deg) * 60.0
    mins = int(rem)
    secs = (rem - mins) * 60.0

    # Carry: if rounding seconds to 2dp pushes us to 60.00, bubble up.
    secs_rounded = round(secs, 2)
    if secs_rounded >= 60.0:
        secs_rounded = 0.0
        mins += 1
    if mins >= 60:
        mins = 0
        deg += 1

    if is_lat:
        hemi = "N" if sign_pos else "S"
        return f"{deg:02d}-{mins:02d}-{secs_rounded:05.2f}{hemi}"
    else:
        hemi = "E" if sign_pos else "W"
        return f"{deg:03d}-{mins:02d}-{secs_rounded:05.2f}{hemi}"


# ---------------------------------------------------------------------------
# Format functions — edit these to change output appearance.
# Each returns (header_line, body_text). main() writes header to stderr and
# body to stdout.
# ---------------------------------------------------------------------------


def format_decimal(points: list[tuple[int, float, float, int, int]]) -> tuple[str, str]:
    """Decimal degrees, preserving each token's original precision."""
    header = "Format: Decimal Degrees — WGS84"
    lines = [
        f"{lat:.{lat_dec}f}, {lon:.{lon_dec}f}"
        for _, lat, lon, lat_dec, lon_dec in points
    ]
    return header, "\n".join(lines) + "\n"


def format_dms(points: list[tuple[int, float, float, int, int]]) -> tuple[str, str]:
    """DMS (e.g. 53-21-48.00N, 129-47-18.00W), 2 decimals on seconds."""
    header = "Format: DMS — WGS84"
    lines = [
        f"{to_dms(lat, is_lat=True)}, {to_dms(lon, is_lat=False)}"
        for _, lat, lon, _, _ in points
    ]
    return header, "\n".join(lines) + "\n"


def format_utm(points: list[tuple[int, float, float, int, int]]) -> tuple[str, str]:
    """UTM easting/northing, 2 decimals. All vertices must share one zone
    AND one hemisphere (northings reset across the equator)."""
    _, lat0, lon0, _, _ = points[0]
    e0, n0, zone, _band = utm.from_latlon(lat0, lon0)
    hemi = "N" if lat0 >= 0 else "S"

    rows = [(e0, n0)]
    for _, lat, lon, _, _ in points[1:]:
        e, n, z, _b = utm.from_latlon(lat, lon)
        h = "N" if lat >= 0 else "S"
        if z != zone or h != hemi:
            raise ValueError(
                f"polygon spans multiple UTM zones ({zone}{hemi} and {z}{h}); "
                "this tool only handles single-zone polygons"
            )
        rows.append((e, n))

    header = f"Format: UTM Zone {zone}{hemi} — WGS84"
    body = "\n".join(f"{e:.2f}, {n:.2f}" for e, n in rows) + "\n"
    return header, body


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

_FORMATTERS = {
    "decimal": format_decimal,
    "dms": format_dms,
    "utm": format_utm,
}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert a CHS polygon description file to a coordinate list.",
    )
    parser.add_argument("input_file", help="path to the CHS polygon file")
    parser.add_argument(
        "--format",
        choices=list(_FORMATTERS),
        default="decimal",
        help="output format (default: decimal)",
    )
    args = parser.parse_args()

    try:
        points = parse_file(args.input_file)
        points = close_ring(points)
        header, body = _FORMATTERS[args.format](points)
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    # Header (and a trailing blank line) on stderr; data on stdout.
    print(header, file=sys.stderr)
    print("", file=sys.stderr)
    sys.stdout.write(body)

    # Auto-copy when running interactively. Clipboard is a nice-to-have.
    if sys.stdout.isatty():
        try:
            import pyperclip
        except ImportError:
            print(
                "note: clipboard auto-copy is off because the 'pyperclip' "
                "package is not installed.\n"
                "      run `pip install pyperclip` in cmd.exe to enable it.",
                file=sys.stderr,
            )
        else:
            try:
                pyperclip.copy(body)
            except Exception as e:
                print(f"warning: clipboard copy failed: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
