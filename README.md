# convert-poly

## What this does

This repo provides two equivalent tools that read a CHS polygon
description file (the kind with columns for index, latitude, longitude,
distance, and angle) and print the polygon's vertices as a list of
WGS84 decimal-degree coordinates. Output is automatically copied to
your clipboard so you can paste it straight into another program.

- **`convert_poly.py`** — Python version. Pick this one if your team
  already uses Python or if you're on a non-Windows machine.
- **`convert_poly.ps1`** — PowerShell version. Pick this one if you
  don't want to install Python; PowerShell is built into Windows.

Both scripts produce identical output. The rest of this README covers
the Python version first; the PowerShell instructions are at the
bottom.

The scripts assume WGS84. If your file mentions NAD83 or CSRS they
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

## Install dependency

In `cmd.exe`, run:

```
pip install pyperclip
```

That's the only library the script needs — `pyperclip` is what enables
the auto-clipboard.

## Run

```
python convert_poly.py path\to\polygon.txt
```

This prints a one-line header on screen, prints the coordinates on
screen, and quietly copies the coordinates to your clipboard. From
there you can paste them into Excel, an email, or wherever you need
them.

Example:

```
> python convert_poly.py sample_input.txt
Format: Decimal Degrees - WGS84

53.363333, -129.788333
53.385278, -129.788333
53.385278, -129.755000
53.363333, -129.755000
53.363333, -129.788333
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

The output is produced by the `format_decimal()` function near the
bottom of `convert_poly.py`. Edit that function to tweak how the
output looks (column separator, precision, etc.).

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

## PowerShell version (no Python required)

If you'd rather not install Python, use `convert_poly.ps1`. PowerShell
is already on every modern Windows machine, so there is nothing to
install.

Open PowerShell (Start menu → "Windows PowerShell") and run:

```
.\convert_poly.ps1 path\to\polygon.txt
```

The first time you run a `.ps1` file, Windows may refuse with a
message about "running scripts is disabled on this system". To allow
it for your own user account only, run this once:

```
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then try the script again. The output, clipboard behaviour, and piping
options are the same as the Python version — for example:

```
.\convert_poly.ps1 polygon.txt | Set-Clipboard
.\convert_poly.ps1 polygon.txt > out.txt
```

To tweak the output format, edit the `Format-Decimal` function near
the bottom of `convert_poly.ps1` (the equivalent of `format_decimal()`
in the Python version).
