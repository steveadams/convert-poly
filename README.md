# convert-poly

## What this does

`convert_poly.py` reads a CHS polygon description file (the kind with
columns for index, latitude, longitude, distance, and angle) and prints
the polygon's vertices as a list of coordinates. You pick the output
shape with a `--format` flag: decimal degrees (the default), DMS, or
UTM. Output is automatically copied to your clipboard so you can paste
it straight into another program.

The script assumes WGS84. If your file mentions NAD83 or CSRS the script
will refuse to run rather than give you wrong numbers.

## Install Python

1. Go to <https://www.python.org/downloads/> and download Python 3.10 or
   newer for Windows.
2. Run the installer.
3. **Important:** on the first screen of the installer, tick the
   checkbox labelled **"Add python.exe to PATH"** before clicking
   Install. Without this checkbox you won't be able to run `python` from
   the command prompt.

To confirm it worked, open `cmd.exe` and run:

```
python --version
```

You should see something like `Python 3.12.4`.

## Install dependencies

In `cmd.exe`, run:

```
pip install utm pyperclip
```

That's it — those two libraries are all the script needs.

## Run

The basic shape is:

```
python convert_poly.py path\to\polygon.txt
```

This prints the format header on screen, prints the data on screen, and
quietly copies the data to your clipboard. From there you can paste it
into Excel, an email, or wherever you need it.

To pick a different format, use one of the shortcut flags:

```
python convert_poly.py polygon.txt --dms
python convert_poly.py polygon.txt --utm
```

There are exactly three formats: `decimal` (the default), `dms`, and
`utm`. Each invocation produces one format. The longer form
`--format dms` / `--format utm` works too if you prefer it.

Example:

```
> python convert_poly.py sample_input.txt --utm
Format: UTM Zone 9N — WGS84

447540.35, 5912979.17
447567.31, 5915420.46
449784.28, 5915396.49
449758.46, 5912955.20
447540.35, 5912979.17
```

The polygon is always emitted **closed** (first vertex repeated at the
end) so the output is ready to drop into a GIS tool that expects a
closed ring.

## Advanced: piping

If you're comfortable with the command line, you can pipe the output to
another program. The format header is printed to **stderr** and the
data to **stdout**, so piping captures only the data — no header noise.

```
:: cmd.exe — copy data to the clipboard without the header
python convert_poly.py polygon.txt | clip

:: PowerShell — same, using its native clipboard cmdlet
python convert_poly.py polygon.txt | Set-Clipboard

:: Save data to a file
python convert_poly.py polygon.txt > out.txt
```

## Editing the output

The three output formats are produced by three small functions near the
bottom of `convert_poly.py`:

- `format_decimal()` — decimal degrees, comma-separated, preserving the
  precision of the input.
- `format_dms()` — degrees-minutes-seconds, dash-separated, two decimal
  places on seconds.
- `format_utm()` — UTM easting and northing, two decimal places. The
  zone is computed from the first vertex; if the polygon spans more
  than one UTM zone the script aborts.

If you need to tweak how a format looks, edit just that one function —
the other two are independent.

## Troubleshooting

**`'python' is not recognized as an internal or external command`** —
Python isn't on your PATH. Re-run the Python installer and make sure
the "Add python.exe to PATH" checkbox is ticked.

**`pip install` fails behind a corporate proxy** — set the proxy
environment variables before running pip:
`set HTTP_PROXY=http://your.proxy:port` and the same for `HTTPS_PROXY`.
Your IT team will know the right values.

**`error: input file mentions NAD83 or CSRS`** — the file is in a
datum this script doesn't handle. Convert the file to WGS84 first
(your GIS tool can do this) and try again.

**`error: polygon spans multiple UTM zones`** — your polygon crosses a
6° longitude boundary. UTM zones change every 6° of longitude, so a
single polygon can't be expressed in one zone. Use `--format decimal`
or `--format dms` instead.
