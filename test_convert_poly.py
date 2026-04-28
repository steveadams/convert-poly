"""
Acceptance tests for convert_poly.

Tests target observable CLI behaviour: input → exit code, stdout, stderr.
They deliberately avoid asserting on internal function shapes so the
implementation can change freely.

Dev-only deps (NOT required by the shipped script):
    pip install pytest pyproj

Run:
    pytest test_convert_poly.py -v
"""

import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).parent
SCRIPT = HERE / "convert_poly.py"
SAMPLE = HERE / "sample_input.txt"


def run_cli(*args, input_path=SAMPLE):
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(input_path), *args],
        capture_output=True,
        text=True,
    )


def write_input(tmp_path, body, name="poly.txt", encoding="utf-8"):
    path = tmp_path / name
    path.write_text(body, encoding=encoding)
    return path


# Reusable polygon body — small valid Canadian polygon, four open vertices.
CANONICAL_BODY = (
    "\tLatitude\tLongitude\n"
    "1\t53.363333N\t129.788333W\n"
    "2\t53.385278N\t129.788333W\n"
    "3\t53.385278N\t129.755000W\n"
    "4\t53.363333N\t129.755000W\n"
)


# ---------------------------------------------------------------------------
# Canonical fixture round-trip — covers default format, all three formats,
# and that the closed-ring contract is satisfied byte-for-byte.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("fmt", ["decimal", "dms", "utm"])
def test_format_matches_fixture(fmt):
    result = run_cli("--format", fmt)
    assert result.returncode == 0, result.stderr
    expected = (HERE / f"sample_output_{fmt}.txt").read_text()
    assert result.stdout == expected


def test_default_format_is_decimal():
    result = run_cli()
    assert result.returncode == 0
    expected = (HERE / "sample_output_decimal.txt").read_text()
    assert result.stdout == expected


# ---------------------------------------------------------------------------
# Stream split — header on stderr, data on stdout (this is what makes
# `convert_poly file | clip` work without flags).
# ---------------------------------------------------------------------------

def test_header_goes_to_stderr_data_to_stdout():
    result = run_cli()
    assert result.stderr.startswith("Format: ")
    assert "WGS84" in result.stderr
    assert "Format:" not in result.stdout


def test_utm_header_names_zone_and_hemisphere():
    result = run_cli("--format", "utm")
    assert result.returncode == 0
    # Canonical polygon is in BC, zone 9N
    assert "Zone 9N" in result.stderr


# ---------------------------------------------------------------------------
# Polygon closure — script always emits a closed ring, but never duplicates
# a vertex when the input is already closed.
# ---------------------------------------------------------------------------

def test_open_polygon_is_closed_in_output():
    # Canonical input is open (4 vertices); output must be 5 lines.
    result = run_cli()
    lines = result.stdout.strip().splitlines()
    assert len(lines) == 5
    assert lines[0] == lines[-1]


def test_closed_polygon_is_not_double_closed(tmp_path):
    body = CANONICAL_BODY + "5\t53.363333N\t129.788333W\n"
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    lines = result.stdout.strip().splitlines()
    assert len(lines) == 5  # not 6
    assert lines[0] == lines[-1]


# ---------------------------------------------------------------------------
# Datum guardrails — fail loudly on anything that isn't WGS84.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("marker", [
    "NAD83",
    "NAD 83",
    "nad83",
    "Nad 83",
    "CSRS",
    "csrs",
])
def test_non_wgs84_datum_rejected(tmp_path, marker):
    body = f"Datum: {marker}\n" + CANONICAL_BODY
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "WGS84" in result.stderr


# ---------------------------------------------------------------------------
# Coordinate validation — wrong hemisphere suffix, out-of-range values,
# malformed tokens.
# ---------------------------------------------------------------------------

def test_transposed_columns_rejected(tmp_path):
    """Latitude column with E/W suffix (likely a transposed file)."""
    body = (
        "\tLat\tLon\n"
        "1\t53.0E\t125.0W\n"  # latitude with E suffix — wrong axis
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "N or S" in result.stderr


def test_longitude_with_ns_suffix_rejected(tmp_path):
    body = (
        "\tLat\tLon\n"
        "1\t53.0N\t125.0N\n"  # longitude with N suffix
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "E or W" in result.stderr


@pytest.mark.parametrize("lat_token, lon_token", [
    ("91.0N", "125.0W"),    # lat > 90
    ("53.0N", "181.0W"),    # lon > 180
    ("99.999999N", "0.0E"),  # lat just over 90 with high precision
])
def test_out_of_range_coord_rejected(tmp_path, lat_token, lon_token):
    body = f"\tLat\tLon\n1\t{lat_token}\t{lon_token}\n"
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "out of range" in result.stderr


@pytest.mark.parametrize("bad", ["53..0N", "53.0", "abcN", "12.34.56N"])
def test_malformed_coord_rejected(tmp_path, bad):
    body = f"\tLat\tLon\n1\t{bad}\t125.0W\n"
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1


# ---------------------------------------------------------------------------
# UTM correctness — single-zone enforcement, southern hemisphere, equator
# crossing, independent cross-check via pyproj.
# ---------------------------------------------------------------------------

def test_multi_zone_polygon_rejected_for_utm(tmp_path):
    # lon -127 → zone 9; lon -121 → zone 10.
    body = (
        "\tLat\tLon\n"
        "1\t53.0N\t127.0W\n"
        "2\t54.0N\t127.0W\n"
        "3\t54.0N\t121.0W\n"
        "4\t53.0N\t121.0W\n"
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p), "--format", "utm"],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "zone" in result.stderr.lower()


def test_multi_zone_polygon_ok_for_decimal(tmp_path):
    """Multi-zone is only an error for UTM, not for decimal/DMS."""
    body = (
        "\tLat\tLon\n"
        "1\t53.0N\t127.0W\n"
        "2\t54.0N\t127.0W\n"
        "3\t54.0N\t121.0W\n"
        "4\t53.0N\t121.0W\n"
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 0


def test_equator_crossing_rejected_for_utm(tmp_path):
    """Northings reset across the equator; mixing them would be silently wrong."""
    body = (
        "\tLat\tLon\n"
        "1\t1.0N\t30.0E\n"
        "2\t1.0N\t31.0E\n"
        "3\t1.0S\t31.0E\n"
        "4\t1.0S\t30.0E\n"
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p), "--format", "utm"],
        capture_output=True, text=True,
    )
    assert result.returncode == 1


def test_southern_hemisphere_utm_header(tmp_path):
    body = (
        "\tLat\tLon\n"
        "1\t40.0S\t175.0E\n"
        "2\t41.0S\t175.0E\n"
        "3\t41.0S\t176.0E\n"
        "4\t40.0S\t176.0E\n"
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p), "--format", "utm"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    assert "Zone 60S" in result.stderr


def test_utm_independent_check():
    """Cross-check UTM output against pyproj. Skipped if pyproj missing."""
    pyproj = pytest.importorskip("pyproj")
    transformer = pyproj.Transformer.from_crs(
        "EPSG:4326", "EPSG:32609", always_xy=True
    )
    expected_e, expected_n = transformer.transform(-129.788333, 53.363333)
    first_line = (HERE / "sample_output_utm.txt").read_text().splitlines()[0]
    e_str, n_str = [s.strip() for s in first_line.split(",")]
    assert float(e_str) == pytest.approx(expected_e, abs=0.01)
    assert float(n_str) == pytest.approx(expected_n, abs=0.01)


# ---------------------------------------------------------------------------
# Decimal precision preservation.
# ---------------------------------------------------------------------------

def test_mixed_precision_preserved(tmp_path):
    body = (
        "\tLat\tLon\n"
        "1\t53.36N\t125.788333W\n"
        "2\t53.0N\t125.0W\n"
        "3\t52.0N\t124.0W\n"
        "4\t52.0N\t124.5W\n"
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    lines = result.stdout.splitlines()
    assert lines[0] == "53.36, -125.788333"
    assert lines[1] == "53.0, -125.0"


# ---------------------------------------------------------------------------
# DMS correctness — output structure and the seconds=60 carry case.
# ---------------------------------------------------------------------------

def test_dms_never_emits_60_seconds(tmp_path):
    """A latitude that nearly hits 54° must round up cleanly, not wrap to ...-60.00."""
    body = (
        "\tLat\tLon\n"
        "1\t53.9999999N\t125.0W\n"  # 7 nines triggers seconds → 60.00 → carry
        "2\t53.0N\t125.0W\n"
        "3\t53.0N\t124.0W\n"
        "4\t53.5N\t124.0W\n"
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p), "--format", "dms"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    assert "-60.00" not in result.stdout
    # And the carried-up vertex should have rolled to 54-00-00.00.
    assert "54-00-00.00N" in result.stdout.splitlines()[0]


def test_dms_lines_well_formed():
    """Every DMS line is two coords like 'DD-MM-SS.SSH, DDD-MM-SS.SSH'."""
    import re
    result = run_cli("--format", "dms")
    pattern = re.compile(
        r"^\d{2}-\d{2}-\d{2}\.\d{2}[NS], \d{3}-\d{2}-\d{2}\.\d{2}[EW]$"
    )
    for line in result.stdout.splitlines():
        assert pattern.match(line), f"malformed DMS line: {line!r}"


def test_dms_round_trip_within_arcsecond(tmp_path):
    """DMS values, parsed back to decimal degrees, should match the
    decimal-degrees output to within ~0.01 arcsecond."""
    p = write_input(tmp_path, CANONICAL_BODY)
    dms = subprocess.run(
        [sys.executable, str(SCRIPT), str(p), "--format", "dms"],
        capture_output=True, text=True,
    )
    dec = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert dms.returncode == 0 and dec.returncode == 0

    def from_dms(token):
        sign = -1 if token[-1] in "SW" else 1
        d, m, s = token[:-1].split("-")
        return sign * (float(d) + float(m) / 60 + float(s) / 3600)

    tol = 1.0 / 360_000  # ~0.01 arcsecond in decimal degrees
    for dms_line, dec_line in zip(dms.stdout.splitlines(), dec.stdout.splitlines()):
        dms_lat, dms_lon = [from_dms(t.strip()) for t in dms_line.split(",")]
        dec_lat, dec_lon = [float(t.strip()) for t in dec_line.split(",")]
        assert abs(dms_lat - dec_lat) < tol
        assert abs(dms_lon - dec_lon) < tol


# ---------------------------------------------------------------------------
# Input quirks — UTF-8 BOM, blank lines, missing-required-columns.
# ---------------------------------------------------------------------------

def test_utf8_bom_handled(tmp_path):
    """Real-world CHS files saved on Windows often have a UTF-8 BOM."""
    body = "﻿" + CANONICAL_BODY
    p = tmp_path / "bom.txt"
    p.write_text(body, encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    assert result.stdout == (HERE / "sample_output_decimal.txt").read_text()


def test_blank_lines_in_input_ignored(tmp_path):
    body = (
        "\n"
        "\tLat\tLon\n"
        "\n"
        "1\t53.363333N\t129.788333W\n"
        "\n"
        "2\t53.385278N\t129.788333W\n"
        "3\t53.385278N\t129.755000W\n"
        "4\t53.363333N\t129.755000W\n"
        "\n"
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    assert result.stdout == (HERE / "sample_output_decimal.txt").read_text()


def test_row_with_missing_columns_rejected(tmp_path):
    body = (
        "\tLat\tLon\n"
        "1\t53.363333N\n"  # only one coord column
    )
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "row 1" in result.stderr


def test_no_data_rows_error(tmp_path):
    body = "\tLat\tLon\nfoo bar baz\n"  # both lines non-data
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "no data" in result.stderr.lower()


# ---------------------------------------------------------------------------
# CLI surface — exit codes for usage and missing files, --help works.
# ---------------------------------------------------------------------------

def test_missing_file_exits_1(tmp_path):
    missing = tmp_path / "nope.txt"
    result = run_cli(input_path=missing)
    assert result.returncode == 1


def test_missing_required_arg_exits_2():
    """argparse convention: usage errors exit 2."""
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        capture_output=True, text=True,
    )
    assert result.returncode == 2


def test_unknown_format_exits_2():
    result = run_cli("--format", "kml")
    assert result.returncode == 2


def test_help_flag():
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--help"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    assert "polygon" in result.stdout.lower()
    assert "--format" in result.stdout
    # Shortcut flags advertised in --help
    for shortcut in ("--decimal", "--dms", "--utm"):
        assert shortcut in result.stdout


# ---------------------------------------------------------------------------
# Shortcut flags — `--decimal`, `--dms`, `--utm` are equivalent to
# `--format <name>` and must not be combinable.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("fmt", ["decimal", "dms", "utm"])
def test_shortcut_flag_matches_format_flag(fmt):
    """`--utm` produces the same output as `--format utm`, etc."""
    short = run_cli(f"--{fmt}")
    long = run_cli("--format", fmt)
    assert short.returncode == 0
    assert short.stdout == long.stdout
    assert short.stdout == (HERE / f"sample_output_{fmt}.txt").read_text()


@pytest.mark.parametrize("flags", [
    ("--dms", "--utm"),
    ("--decimal", "--dms"),
    ("--format", "utm", "--dms"),
])
def test_conflicting_format_flags_rejected(flags):
    """Mutually exclusive group: combining format flags is a usage error."""
    result = run_cli(*flags)
    assert result.returncode == 2
    assert "not allowed with" in result.stderr


# ---------------------------------------------------------------------------
# Missing-dependency hints — first-time CHS user forgot to run pip install.
# We simulate "package not installed" by injecting a stub package on
# PYTHONPATH that raises ImportError on import.
# ---------------------------------------------------------------------------

def _run_with_stub(tmp_path, stub_name, *args, input_path=SAMPLE):
    stub_dir = tmp_path / "stubs"
    stub_dir.mkdir()
    (stub_dir / f"{stub_name}.py").write_text(
        f"raise ImportError('simulated: {stub_name} not installed')\n"
    )
    env = {**os.environ, "PYTHONPATH": str(stub_dir)}
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(input_path), *args],
        capture_output=True, text=True, env=env,
    )


def test_missing_utm_gives_friendly_install_hint(tmp_path):
    result = _run_with_stub(tmp_path, "utm")
    assert result.returncode == 1
    assert "pip install utm pyperclip" in result.stderr
    # No raw Python traceback should reach the user.
    assert "Traceback" not in result.stderr


def test_missing_pyperclip_does_not_block_output(tmp_path):
    """Clipboard is optional — the script should still emit data successfully."""
    result = _run_with_stub(tmp_path, "pyperclip")
    assert result.returncode == 0
    # Coordinate output is unaffected.
    assert result.stdout == (HERE / "sample_output_decimal.txt").read_text()
    # When stdout is a pipe (as in this test), the clipboard branch is
    # skipped entirely, so no pyperclip-specific hint is expected.
    assert "Traceback" not in result.stderr
