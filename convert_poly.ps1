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
    - A format header ("Format: Decimal Degrees - WGS84", or "Format:
      Degrees Minutes Seconds - WGS84" for DMS) goes to STDERR.
    - The coordinate data goes to STDOUT.
  This way `convert_poly.ps1 file.txt | Set-Clipboard` puts only the data
  on the clipboard, while running interactively shows both header and data
  on the terminal. When STDOUT is a terminal, the data is also auto-copied
  to the clipboard via Set-Clipboard.

  Data lines are emitted via Write-Output (not Console.Out.Write), so the
  output flows through the PowerShell pipeline and `... | Set-Clipboard`
  works as expected. Side effect: STDOUT line endings are CRLF on Windows
  (Environment.NewLine), not LF.

  To change how the output looks (column separator, precision, etc.), edit
  Format-Decimal (decimal) or Format-DMS / Convert-DegreesToDMS (DMS) below.

  Use -Format to choose the output coordinate format: Decimal (default,
  signed decimal degrees) or DMS (signed dash-separated degrees-minutes-
  seconds, (-)dd-mm-ss.ssss).

.PARAMETER InputFile
  Path to the CHS polygon file.

.PARAMETER Format
  Output coordinate format. 'Decimal' (default) emits signed decimal
  degrees, e.g. 53.363333,-129.788333. 'DMS' emits signed dash-separated
  degrees-minutes-seconds, e.g. 53-21-47.9988,-129-47-17.9988. Both are
  WGS84. Case-insensitive.

.EXAMPLE
  .\convert_poly.ps1 polygon.txt

.EXAMPLE
  .\convert_poly.ps1 polygon.txt | Set-Clipboard

.EXAMPLE
  .\convert_poly.ps1 polygon.txt -Format DMS
#>
[CmdletBinding()]
param(
    # Optional. When omitted in an interactive session, a Windows file
    # picker is shown so non-technical users can double-click the .bat
    # shim and pick a file. When omitted in a non-interactive session
    # (CI, pipes, scripts) the script errors out with exit code 1.
    [Parameter(Position = 0)]
    [string]$InputFile,

    # Output coordinate format. 'Decimal' (default) emits signed decimal
    # degrees; 'DMS' emits signed dash-separated degrees-minutes-seconds
    # ((-)dd-mm-ss.ssss). ValidateSet is case-insensitive.
    [Parameter(Position = 1)]
    [ValidateSet('Decimal', 'DMS')]
    [string]$Format = 'Decimal'
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
    # Parse a coordinate token in one of three auto-detected forms:
    #   decimal degrees          '53.363333N'
    #   degrees-decimal-minutes  '53-22.711152N'   (DDM)
    #   degrees-minutes-seconds  '53-22-42.69N'    (DMS)
    # Detection is by the count of '-'-separated components in the numeric
    # part; a decimal point is allowed only in the last component. Returns
    # @{ Value = <signed decimal>; Decimals = <decimal places for output> }.
    # Decimal input preserves its own precision; DDM/DMS use a fixed 6 dp.
    param([string]$Token)

    if ($Token -notmatch '^([0-9.\-]+)([NSEW])$') {
        throw "could not parse coordinate '$Token'"
    }
    $num  = $Matches[1]
    $hemi = $Matches[2]

    $parts = $num -split '-'
    switch ($parts.Count) {
        1 {
            # Decimal degrees: degrees may be fractional.
            if ($parts[0] -notmatch '^\d+(\.\d+)?$') {
                throw "could not parse coordinate '$Token'"
            }
            $value = [double]::Parse($parts[0], $Invariant)
            if ($parts[0].Contains('.')) {
                $decimals = ($parts[0].Split('.', 2)[1]).Length
            } else {
                $decimals = 0
            }
        }
        2 {
            # DDM: integer degrees, fractional minutes.
            if ($parts[0] -notmatch '^\d+$' -or $parts[1] -notmatch '^\d+(\.\d+)?$') {
                throw "could not parse coordinate '$Token'"
            }
            $deg = [double]::Parse($parts[0], $Invariant)
            $min = [double]::Parse($parts[1], $Invariant)
            if ($min -ge 60) { throw "minutes out of range in '$Token'" }
            $value    = $deg + $min / 60.0
            $decimals = 6
        }
        3 {
            # DMS: integer degrees, integer minutes, fractional seconds.
            if ($parts[0] -notmatch '^\d+$' -or
                $parts[1] -notmatch '^\d+$' -or
                $parts[2] -notmatch '^\d+(\.\d+)?$') {
                throw "could not parse coordinate '$Token'"
            }
            $deg = [double]::Parse($parts[0], $Invariant)
            $min = [double]::Parse($parts[1], $Invariant)
            $sec = [double]::Parse($parts[2], $Invariant)
            if ($min -ge 60) { throw "minutes out of range in '$Token'" }
            if ($sec -ge 60) { throw "seconds out of range in '$Token'" }
            $value    = $deg + $min / 60.0 + $sec / 3600.0
            $decimals = 6
        }
        default {
            throw "could not parse coordinate '$Token'"
        }
    }

    if ($hemi -eq 'S' -or $hemi -eq 'W') { $value = -$value }
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
        $lines.Add("$latStr,$lonStr")
    }
    return @{ Header = $header; Lines = $lines }
}


function Convert-DegreesToDMS {
    # Convert a signed decimal degree to '(-)dd-mm-ss.ssss'. The leading
    # minus marks S/W (matching the decimal output's sign convention);
    # minutes and seconds are zero-padded to two integer digits, and
    # seconds are fixed at four decimal places regardless of input precision.
    param([double]$Value)

    $neg = $Value -lt 0
    $v   = [math]::Abs($Value)

    $deg = [int][math]::Floor($v)
    $remMin = ($v - $deg) * 60
    $min = [int][math]::Floor($remMin)
    $sec = ($remMin - $min) * 60
    $sec = [math]::Round($sec, 4, [System.MidpointRounding]::AwayFromZero)
    # Rounding can push seconds to 60.0000; carry up. A third (degree-level)
    # carry isn't needed: Read-PolygonFile rejects inputs outside
    # [-90,90]/[-180,180], so degrees can't round-carry past those bounds.
    if ($sec -ge 60) { $sec -= 60; $min += 1 }
    if ($min -ge 60) { $min -= 60; $deg += 1 }

    $sign   = if ($neg) { '-' } else { '' }
    $minStr = $min.ToString('00', $Invariant)
    $secStr = $sec.ToString('00.0000', $Invariant)
    return "$sign$deg-$minStr-$secStr"
}


function Format-DMS {
    param($Points)

    $header = "Format: Degrees Minutes Seconds - WGS84"

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Points) {
        $latStr = Convert-DegreesToDMS $p.Lat
        $lonStr = Convert-DegreesToDMS $p.Lon
        $lines.Add("$latStr,$lonStr")
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
    # @(...) forces array context. Without it, a single-vertex file makes
    # PowerShell unwrap the one-element result to a bare hashtable, whose
    # .Count is its key count (5) and whose [0] is a key miss ($null) - so
    # Close-Ring then dereferences $null and throws under StrictMode.
    $points = @(Read-PolygonFile -Path $InputFile)
    $points = @(Close-Ring -Points $points)
    $result = switch ($Format) {
        'DMS'   { Format-DMS     -Points $points }
        default { Format-Decimal -Points $points }
    }
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
# clipboard ends up set twice in that case.
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
