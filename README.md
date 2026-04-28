# convert-poly

## What this does

Reads a CHS polygon description file (the kind with columns for index,
latitude, longitude, distance, and angle) and prints the polygon's
vertices as a list of WGS84 decimal-degree coordinates. The output is
auto-copied to your clipboard so you can paste it straight into Excel,
an email, or wherever you need it.

The script assumes WGS84. If your file mentions NAD83 or CSRS it will
refuse to run rather than give you wrong numbers.

The repo contains two files you actually use:

- **`convert_poly.bat`** — what you click. Opens a file picker, or
  accepts a file dragged onto it.
- **`convert_poly.ps1`** — the actual conversion script. The `.bat`
  calls this; you don't need to touch it directly.

PowerShell is built into every modern Windows machine, so there is
nothing to install.

## First-time setup (about 5 minutes)

1. Open <https://github.com/steveadams/convert-poly> in a browser.
2. Click the green **Code** button → **Download ZIP**.
3. Find the ZIP in your **Downloads** folder. Right-click it →
   **Properties** → tick **Unblock** → **OK**. (This clears the
   "downloaded from internet" tag on every extracted file in one go.
   Skip this and you may see a SmartScreen warning later — you can
   still proceed past it, but unblocking up front avoids the friction.)
4. Right-click the ZIP again → **Extract All...** → choose somewhere
   easy to find (Desktop or Documents). You'll get a folder named
   `convert-poly-main` (or similar).
5. Open that folder. Keep `convert_poly.bat` and `convert_poly.ps1`
   together — the `.bat` looks for the `.ps1` in the same folder.

## Your first conversion

6. Find the CHS polygon `.txt` file you want to convert.
7. **Drag it onto** `convert_poly.bat`. (Or double-click the `.bat`
   first and pick the file from the dialog.)
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
10. Switch to Excel / email / wherever the coordinates need to go,
    and paste with **Ctrl+V**.

The polygon is always emitted **closed** (first vertex repeated at the
end) so the output is ready to drop into a GIS tool that expects a
closed ring.

## Troubleshooting

**"Windows protected your PC" (SmartScreen)** — click *More info* →
*Run anyway*. Happens once per file on a new machine. Unblocking the
ZIP before extracting (step 3 above) usually prevents this.

**Red error mentioning execution policy** — open PowerShell once
(Start menu → "Windows PowerShell") and run:

```
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then try the `.bat` again. This shouldn't be needed because the `.bat`
already passes `-ExecutionPolicy Bypass`, but corporate Group Policy
can override that.

**`error: input file mentions NAD83 or CSRS`** — the file is in a
datum the script refuses to handle. Convert it to WGS84 in your GIS
tool first and try again.

**`error: no input file specified`** — you ran the `.ps1` directly
from a non-interactive context (a pipe, a script, or CI). Use the
`.bat`, drag a file onto it, or pass an explicit path:
`.\convert_poly.ps1 path\to\polygon.txt`.

## Advanced: command-line use

If you're comfortable with PowerShell, you can run the script directly
and pipe its output. The format header goes to **stderr** and the
coordinate data goes to **stdout**, so piping captures only the data:

```
.\convert_poly.ps1 polygon.txt | Set-Clipboard
.\convert_poly.ps1 polygon.txt > out.txt
```

## Editing the output

To tweak the output format (separator, precision, etc.), edit the
`Format-Decimal` function near the bottom of `convert_poly.ps1`.
