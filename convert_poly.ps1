<#
.SYNOPSIS
  Convert a CHS polygon description file to a WGS84 decimal-degree
  coordinate list.

.DESCRIPTION
  Reads a CHS polygon file (whitespace-separated columns: index,
  latitude, longitude, ...) and prints the closed polygon ring as one
  "lat, lon" line per vertex.

  Datum: WGS84 only. If the input mentions NAD83 or CSRS, the script
  aborts rather than silently produce wrong coordinates.

  Output streams:
    - The format header ("Format: Decimal Degrees - WGS84") goes to STDERR.
    - The coordinate data goes to STDOUT.
  This way `convert_poly.ps1 file.txt | Set-Clipboard` puts only the data
  on the clipboard, while running interactively shows both header and data
  on the terminal. When STDOUT is a terminal, the data is also auto-copied
  to the clipboard via Set-Clipboard.

  Line endings: data lines are emitted via Write-Output, so STDOUT uses
  the platform line separator (CRLF on Windows). The Python sibling
  script always emits LF. This is deliberate - going through the
  PowerShell pipeline is what makes `... | Set-Clipboard` work, and
  Windows-native consumers (Excel, email) prefer CRLF anyway.

  To change how the output looks (column separator, precision, etc.), edit
  Format-Decimal below.

.PARAMETER InputFile
  Path to the CHS polygon file.

.EXAMPLE
  .\convert_poly.ps1 polygon.txt

.EXAMPLE
  .\convert_poly.ps1 polygon.txt | Set-Clipboard
#>
[CmdletBinding()]
param(
    # Optional. When omitted in an interactive session, a Windows file
    # picker is shown so non-technical users can double-click the .bat
    # shim and pick a file. When omitted in a non-interactive session
    # (CI, pipes, scripts) the script errors out with exit code 1.
    [Parameter(Position = 0)]
    [string]$InputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture


function Write-StdErr {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

function Convert-LatLonToken {
    # Parse a coordinate token like '53.363333N' or '129.788333W'.
    # Returns @{ Value = <signed decimal>; Decimals = <input precision> }.
    param([string]$Token)

    if ($Token -notmatch '^(\d+(?:\.\d+)?)([NSEW])$') {
        throw "could not parse coordinate '$Token'"
    }
    $number = $Matches[1]
    $hemi   = $Matches[2]

    $value = [double]::Parse($number, $Invariant)
    if ($hemi -eq 'S' -or $hemi -eq 'W') {
        $value = -$value
    }

    $decimals = 0
    if ($number.Contains('.')) {
        $decimals = ($number.Split('.', 2)[1]).Length
    }

    return @{ Value = $value; Decimals = $decimals }
}


function Read-PolygonFile {
    # Read a CHS polygon file and return an array of vertex hashtables:
    # @{ Idx, Lat, Lon, LatDec, LonDec }.
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "file not found: $Path"
    }

    # -Encoding UTF8 reads UTF-8 (with or without BOM) on PS 5.1+.
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $text) { $text = '' }

    # Defensive BOM strip in case the encoding heuristics let one through.
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }

    if ($text -match '(?i)NAD\s?83|CSRS') {
        throw "input file mentions NAD83 or CSRS; this tool only handles WGS84"
    }

    $points = New-Object System.Collections.Generic.List[hashtable]

    foreach ($line in ($text -split "`r?`n")) {
        $tokens = @($line -split '\s+' | Where-Object { $_.Length -gt 0 })
        if ($tokens.Count -eq 0) { continue }

        $idx = 0
        if (-not [int]::TryParse($tokens[0], [ref]$idx)) {
            # Header row or other non-data line.
            continue
        }
        if ($tokens.Count -lt 3) {
            throw "row $($idx): expected at least 3 columns, got $($tokens.Count)"
        }

        $latToken = $tokens[1]
        $lonToken = $tokens[2]

        # Hemisphere-suffix sanity: catches transposed-column files early.
        if (-not ($latToken.EndsWith('N') -or $latToken.EndsWith('S'))) {
            throw "row $($idx): latitude '$latToken' must end in N or S"
        }
        if (-not ($lonToken.EndsWith('E') -or $lonToken.EndsWith('W'))) {
            throw "row $($idx): longitude '$lonToken' must end in E or W"
        }

        $lat = Convert-LatLonToken $latToken
        $lon = Convert-LatLonToken $lonToken

        if ($lat.Value -lt -90.0 -or $lat.Value -gt 90.0) {
            throw "row $($idx): latitude $($lat.Value) out of range [-90, 90]"
        }
        if ($lon.Value -lt -180.0 -or $lon.Value -gt 180.0) {
            throw "row $($idx): longitude $($lon.Value) out of range [-180, 180]"
        }

        $points.Add(@{
            Idx    = $idx
            Lat    = $lat.Value
            Lon    = $lon.Value
            LatDec = $lat.Decimals
            LonDec = $lon.Decimals
        })
    }

    if ($points.Count -eq 0) {
        throw "no data rows found in input"
    }
    return $points
}


function Close-Ring {
    # Append a copy of the first vertex if the ring isn't already closed.
    param($Points)

    if ($Points.Count -eq 0) { return $Points }

    $first = $Points[0]
    $last  = $Points[$Points.Count - 1]
    if ([math]::Abs($first.Lat - $last.Lat) -lt 1e-9 -and
        [math]::Abs($first.Lon - $last.Lon) -lt 1e-9) {
        return $Points
    }

    $closed = New-Object System.Collections.Generic.List[hashtable]
    foreach ($p in $Points) { $closed.Add($p) }
    $closed.Add($first)
    return $closed
}


# ---------------------------------------------------------------------------
# Output formatting - edit this function to change how the output looks.
# Returns @{ Header = <line>; Lines = <list of "lat, lon" strings> }.
# main writes header to stderr and emits each line to stdout (Write-Output)
# so the output flows naturally through PowerShell pipelines.
# ---------------------------------------------------------------------------

function Format-Decimal {
    param($Points)

    $header = "Format: Decimal Degrees - WGS84"

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Points) {
        $latStr = $p.Lat.ToString("F$($p.LatDec)", $Invariant)
        $lonStr = $p.Lon.ToString("F$($p.LonDec)", $Invariant)
        $lines.Add("$latStr, $lonStr")
    }
    return @{ Header = $header; Lines = $lines }
}


# ---------------------------------------------------------------------------
# Interactive file picker - shown when no -InputFile is supplied AND the
# script is being run from a real console (not redirected stdin from CI,
# a pipeline, or another script). Windows-only because Windows Forms.
# ---------------------------------------------------------------------------

function Show-InputFilePicker {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    }
    catch {
        throw "no input file specified, and the file picker is unavailable on this platform"
    }
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $ofd.Title  = 'Select a CHS polygon description file'
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $ofd.FileName
    }
    return $null
}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if (-not $InputFile) {
    if ([Console]::IsInputRedirected) {
        Write-StdErr "error: no input file specified"
        exit 1
    }
    try {
        $InputFile = Show-InputFilePicker
    }
    catch {
        Write-StdErr "error: $($_.Exception.Message)"
        exit 1
    }
    if (-not $InputFile) {
        # User cancelled the dialog - exit quietly.
        exit 0
    }
}

try {
    $points = Read-PolygonFile -Path $InputFile
    $points = Close-Ring -Points $points
    $result = Format-Decimal -Points $points
}
catch {
    Write-StdErr "error: $($_.Exception.Message)"
    exit 1
}

# Header (and a trailing blank line) on stderr; data on stdout via the
# normal PowerShell pipeline so `... | Set-Clipboard` works.
Write-StdErr $result.Header
Write-StdErr ''
foreach ($line in $result.Lines) {
    Write-Output $line
}

# Auto-copy when running interactively. Clipboard is a nice-to-have.
# IsOutputRedirected catches `> out.txt` and external pipes like `| clip`.
# A native PowerShell pipe like `| Set-Clipboard` won't trip it, so the
# clipboard ends up set twice in that case - same content, harmless.
if (-not [Console]::IsOutputRedirected) {
    try {
        $body = ($result.Lines -join [Environment]::NewLine) + [Environment]::NewLine
        Set-Clipboard -Value $body
        Write-StdErr ''
        Write-StdErr 'Coordinates copied to clipboard.'
    }
    catch {
        Write-StdErr "warning: clipboard copy failed: $($_.Exception.Message)"
    }
}
