"""
Acceptance tests for convert_poly.

Tests target observable CLI behaviour: input → exit code, stdout, stderr.
They deliberately avoid asserting on internal function shapes so the
implementation can change freely.

Dev-only deps (NOT required by the shipped script):
    pip install pytest

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
# Canonical fixture round-trip.
# ---------------------------------------------------------------------------

def test_decimal_matches_fixture():
    result = run_cli()
    assert result.returncode == 0, result.stderr
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


# ---------------------------------------------------------------------------
# Polygon closure — script always emits a closed ring, but never duplicates
# a vertex when the input is already closed.
# ---------------------------------------------------------------------------

def test_open_polygon_is_closed_in_output():
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
    assert len(lines) == 5
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
    body = "\tLat\tLon\n1\t53.0E\t125.0W\n"
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "N or S" in result.stderr


def test_longitude_with_ns_suffix_rejected(tmp_path):
    body = "\tLat\tLon\n1\t53.0N\t125.0N\n"
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "E or W" in result.stderr


@pytest.mark.parametrize("lat_token, lon_token", [
    ("91.0N", "125.0W"),
    ("53.0N", "181.0W"),
    ("99.999999N", "0.0E"),
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
# Decimal precision preservation — different vertices may carry different
# precision; output should round-trip each one.
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
    body = "\tLat\tLon\n1\t53.363333N\n"
    p = write_input(tmp_path, body)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(p)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "row 1" in result.stderr


def test_no_data_rows_error(tmp_path):
    body = "\tLat\tLon\nfoo bar baz\n"
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


def test_help_flag():
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--help"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    assert "polygon" in result.stdout.lower()


# ---------------------------------------------------------------------------
# Missing pyperclip is non-fatal — the script still emits coordinates.
# We simulate "package not installed" by injecting a stub on PYTHONPATH
# that raises ImportError on import.
# ---------------------------------------------------------------------------

def test_missing_pyperclip_does_not_block_output(tmp_path):
    stub_dir = tmp_path / "stubs"
    stub_dir.mkdir()
    (stub_dir / "pyperclip.py").write_text(
        "raise ImportError('simulated: pyperclip not installed')\n"
    )
    env = {**os.environ, "PYTHONPATH": str(stub_dir)}
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(SAMPLE)],
        capture_output=True, text=True, env=env,
    )
    assert result.returncode == 0
    assert result.stdout == (HERE / "sample_output_decimal.txt").read_text()
    assert "Traceback" not in result.stderr
