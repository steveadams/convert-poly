# convert-poly

```
            input (CHS polygon format)                          decimal output
  ─────────────────────────────────────────────────────────     ──────────────────────────
    Latitude    Longitude    Z (m)  Distance (m)  Angle
  1 53.363333N  129.788333W         2442.28       0-00-00.00N    →  53.363333, -129.788333
  2 53.385278N  129.788333W         2217.93       89-59-11.84N   →  53.385278, -129.788333
  3 53.385278N  129.755000W         2442.28       180-00-00.00N  →  53.385278, -129.755000
  4 53.363333N  129.755000W                                      →  53.363333, -129.755000
                                                                 ↳  53.363333, -129.788333   (auto-close)
```

## What this does

Reads a polygon description file (the kind with columns for index, latitude, longitude, distance, and angle) and prints the polygon's vertices as a list of WGS84 decimal-degree coordinates. The output is auto-copied to your clipboard so you can paste it straight into Excel, CHSDIR, or wherever you need it.

The script assumes WGS84.

The repo contains two files you actually use:

- **`convert_poly.bat`** — what you click. Opens a file picker, or accepts a file dragged onto it.
- **`convert_poly.ps1`** — the actual conversion script. The `.bat` calls this; you don't need to touch it directly.

PowerShell is built into every modern Windows machine, so there's nothing to install.

## First-time setup

1. Click the green **Code** button → **Download ZIP**, or visit this: [https://github.com/steveadams/convert-poly/archive/refs/heads/main.zip](https://github.com/steveadams/convert-poly/archive/refs/heads/main.zip)
2. Find the ZIP in your Downloads folder. Right-click it → **Properties** → tick **Unblock** → **OK**. (This clears the "downloaded from internet" tag on every extracted file in one go. Skip this and you may see a SmartScreen warning later. You can still proceed past it, but unblocking up front avoids the friction.)
3. Right-click the ZIP again → **Extract All...** → choose somewhere easy to find when you need to make conversions. You'll get a folder named `convert-poly-main` (or similar).
4. Open that folder. Keep `convert_poly.bat` and `convert_poly.ps1` together. The `.bat` looks for the `.ps1` in the same folder.

## Your first conversion

6. Find the CHS polygon `.txt` file you want to convert.
7. **Drag it onto** `convert_poly.bat`. (Or double-click the `.bat` first and pick the file from the dialog.)
8. A console window opens and shows something like:

```
Format: Decimal Degrees - WGS84

53.363333, -129.788333
53.385278, -129.788333
53.385278, -129.755000
53.363333, -129.755000
53.363333, -129.788333

Coordinates copied to clipboard.
Press any key to continue . . .
```

9. Press any key to close the window.
10. Switch to Excel / email / wherever the coordinates need to go, and paste the data.

The polygon is always emitted **closed** (first vertex repeated at the end) so the output is ready to drop into a GIS tool that expects a closed ring. If the data already included a closing vertex, it won't be altered or doubled by the script.

## Troubleshooting

**"Windows protected your PC" (SmartScreen)** — click *More info* → *Run anyway*. Happens once per file on a new machine. Unblocking the ZIP before extracting (step 3 above) usually prevents this.

**Red error mentioning execution policy** — open PowerShell once (Start menu → "Windows PowerShell") and run:

```ps1
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then try the `.bat` again. This shouldn't be needed because the `.bat` already passes `-ExecutionPolicy Bypass`, but corporate Group Policy can override that.

**`error: input file mentions NAD83 or CSRS`** — the file is in a datum the script refuses to handle. Convert it to WGS84 in your GIS tool first and try again.

**`error: no input file specified`** — you ran the `.ps1` directly from a non-interactive context (a pipe, a script, or CI). Use the `.bat`, drag a file onto it, or pass an explicit path: `.\convert_poly.ps1 path\to\polygon.txt`.

## Advanced: command-line use

If you're comfortable with PowerShell, you can run the script directly and pipe its output. The format header goes to **stderr** and the coordinate data goes to **stdout**, so piping captures only the data:

```ps1
.\convert_poly.ps1 polygon.txt | Set-Clipboard
.\convert_poly.ps1 polygon.txt > out.txt
```

## Editing the output

To tweak the output format (separator, precision, etc.), edit the `Format-Decimal` function near the bottom of `convert_poly.ps1`.
