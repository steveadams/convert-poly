<#
Pester 5 acceptance tests for convert_poly.ps1.

Tests target observable CLI behaviour (input file -> exit code, stdout,
stderr) and avoid asserting on internal function shapes so the script
can be refactored freely.

Run with:
    Invoke-Pester ./convert_poly.Tests.ps1 -Output Detailed

Pester 5+ is required. To install on a fresh machine:
    Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -SkipPublisherCheck
#>

BeforeAll {
    $script:Here       = $PSScriptRoot
    $script:ScriptPath = Join-Path $script:Here 'convert_poly.ps1'
    $script:SamplePath = Join-Path $script:Here 'sample_input.txt'
    $script:ExpectedDecimal = Get-Content `
        -LiteralPath (Join-Path $script:Here 'sample_output_decimal.txt') `
        -Raw -Encoding UTF8
    $script:ExpectedDms = Get-Content `
        -LiteralPath (Join-Path $script:Here 'sample_output_dms.txt') `
        -Raw -Encoding UTF8
    $script:DdmSamplePath = Join-Path $script:Here 'sample_input_ddm.txt'
    $script:ExpectedDdmDecimal = Get-Content `
        -LiteralPath (Join-Path $script:Here 'sample_output_ddm_decimal.txt') `
        -Raw -Encoding UTF8

    # Use whichever PowerShell host is running these tests, so the same
    # tests cover both Windows PowerShell 5.1 and PowerShell 7+.
    $script:PwshExe = (Get-Process -Id $PID).Path

    # Reusable canonical polygon body, identical to CANONICAL_BODY in the
    # Python test file. Built with -join "`n" rather than a here-string so
    # the literal line endings are LF on every platform.
    $script:CanonicalBody = (@(
        "`tLatitude`tLongitude"
        "1`t53.363333N`t129.788333W"
        "2`t53.385278N`t129.788333W"
        "3`t53.385278N`t129.755000W"
        "4`t53.363333N`t129.755000W"
    ) -join "`n") + "`n"

    function script:Invoke-CliScript {
        # Run convert_poly.ps1 as a child process and capture stdout,
        # stderr, and the exit code. Uses Start-Process so it works on
        # Windows PowerShell 5.1 (whose .NET Framework lacks
        # ProcessStartInfo.ArgumentList) as well as PowerShell 7+.
        # Omit -InputPath entirely to test the missing-argument case.
        #
        # Stdin is redirected from an empty file so the script's
        # IsInputRedirected check sees a non-interactive session - this
        # keeps the missing-arg test from popping a Windows file picker
        # when a developer runs the suite locally on Windows.
        param(
            [string]$InputPath,
            [string]$Format
        )
        $stdinFile  = [System.IO.Path]::GetTempFileName()
        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()
        try {
            $argList = @('-NoProfile', '-NonInteractive', '-File', $script:ScriptPath)
            if ($PSBoundParameters.ContainsKey('InputPath')) {
                $argList += $InputPath
            }
            if ($PSBoundParameters.ContainsKey('Format')) {
                $argList += @('-Format', $Format)
            }
            $proc = Start-Process `
                -FilePath               $script:PwshExe `
                -ArgumentList           $argList `
                -RedirectStandardInput  $stdinFile `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError  $stderrFile `
                -NoNewWindow -PassThru -Wait
            $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
            $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
            return [pscustomobject]@{
                ExitCode = $proc.ExitCode
                StdOut   = if ($null -eq $stdout) { '' } else { $stdout }
                StdErr   = if ($null -eq $stderr) { '' } else { $stderr }
            }
        } finally {
            Remove-Item -LiteralPath $stdinFile  -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        }
    }

    function script:Write-PolyInput {
        # Write text to a file with a known UTF-8 encoding (BOM optional).
        param(
            [Parameter(Mandatory = $true)] [string]$Path,
            [Parameter(Mandatory = $true)] [string]$Body,
            [switch]$Bom
        )
        $enc = [System.Text.UTF8Encoding]::new([bool]$Bom)
        [System.IO.File]::WriteAllText($Path, $Body, $enc)
    }

    function script:Get-NormalizedLines {
        # Strip trailing newline, normalise CRLF -> LF, return string[].
        param([string]$Text)
        if ($null -eq $Text) { return @() }
        return ($Text -replace "`r`n", "`n").TrimEnd("`n") -split "`n"
    }

    function script:Get-NormalizedText {
        param([string]$Text)
        if ($null -eq $Text) { return '' }
        return ($Text -replace "`r`n", "`n")
    }

    function script:New-TempPath {
        param([string]$Suffix = '.txt')
        return [System.IO.Path]::Combine(
            [System.IO.Path]::GetTempPath(),
            "convert_poly_test_$([guid]::NewGuid().ToString('N'))$Suffix"
        )
    }
}


Describe 'Canonical fixture round-trip' {
    It 'decimal output matches the sample fixture (line endings normalised)' {
        $r = Invoke-CliScript -InputPath $script:SamplePath
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        (Get-NormalizedText $r.StdOut) |
            Should -Be (Get-NormalizedText $script:ExpectedDecimal)
    }
}


Describe 'Stream split (header on stderr, data on stdout)' {
    It 'header lands on stderr and never on stdout' {
        $r = Invoke-CliScript -InputPath $script:SamplePath
        $r.StdErr | Should -Match '^Format: '
        $r.StdErr | Should -Match 'WGS84'
        $r.StdOut | Should -Not -Match 'Format:'
    }
}


Describe 'Polygon closure' {
    It 'open polygon comes out closed' {
        $r = Invoke-CliScript -InputPath $script:SamplePath
        $lines = Get-NormalizedLines $r.StdOut
        $lines.Count | Should -Be 5
        $lines[0]    | Should -Be $lines[$lines.Count - 1]
    }

    It 'already-closed polygon is not double-closed' {
        $body = $script:CanonicalBody + "5`t53.363333N`t129.788333W`n"
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body $body
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            $lines = Get-NormalizedLines $r.StdOut
            $lines.Count | Should -Be 5
            $lines[0]    | Should -Be $lines[$lines.Count - 1]
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'Datum guardrails' {
    It 'rejects datum marker <Marker>' -ForEach @(
        @{ Marker = 'NAD83'  }
        @{ Marker = 'NAD 83' }
        @{ Marker = 'nad83'  }
        @{ Marker = 'Nad 83' }
        @{ Marker = 'CSRS'   }
        @{ Marker = 'csrs'   }
    ) {
        $body = "Datum: $Marker`n" + $script:CanonicalBody
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body $body
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 1
            $r.StdErr   | Should -Match 'WGS84'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'Coordinate validation' {
    It 'rejects E/W suffix on the latitude column (likely transposed file)' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t53.0E`t125.0W`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 1
            $r.StdErr   | Should -Match 'N or S'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects N/S suffix on the longitude column' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t53.0N`t125.0N`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 1
            $r.StdErr   | Should -Match 'E or W'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects out-of-range lat=<LatToken> lon=<LonToken>' -ForEach @(
        @{ LatToken = '91.0N';      LonToken = '125.0W' }
        @{ LatToken = '53.0N';      LonToken = '181.0W' }
        @{ LatToken = '99.999999N'; LonToken = '0.0E'   }
    ) {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t$LatToken`t$LonToken`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 1
            $r.StdErr   | Should -Match 'out of range'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects malformed coordinate <Bad>' -ForEach @(
        @{ Bad = '53..0N'    }
        @{ Bad = '53.0'      }
        @{ Bad = 'abcN'      }
        @{ Bad = '12.34.56N' }
    ) {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t$Bad`t125.0W`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'Decimal precision preservation' {
    It 'preserves each vertex''s input precision independently' {
        $body = (@(
            "`tLat`tLon"
            "1`t53.36N`t125.788333W"
            "2`t53.0N`t125.0W"
            "3`t52.0N`t124.0W"
            "4`t52.0N`t124.5W"
        ) -join "`n") + "`n"
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body $body
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            $lines = Get-NormalizedLines $r.StdOut
            $lines[0] | Should -Be '53.36,-125.788333'
            $lines[1] | Should -Be '53.0,-125.0'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'Input quirks' {
    It 'handles UTF-8 BOM (real CHS files saved on Windows often have one)' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body $script:CanonicalBody -Bom
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            (Get-NormalizedText $r.StdOut) |
                Should -Be (Get-NormalizedText $script:ExpectedDecimal)
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'ignores blank lines in input' {
        $body = (@(
            ''
            "`tLat`tLon"
            ''
            "1`t53.363333N`t129.788333W"
            ''
            "2`t53.385278N`t129.788333W"
            "3`t53.385278N`t129.755000W"
            "4`t53.363333N`t129.755000W"
            ''
        ) -join "`n") + "`n"
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body $body
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            (Get-NormalizedText $r.StdOut) |
                Should -Be (Get-NormalizedText $script:ExpectedDecimal)
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects rows with too few columns' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t53.363333N`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 1
            $r.StdErr   | Should -Match 'row 1'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'errors when the file has no data rows' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`nfoo bar baz`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 1
            $r.StdErr.ToLower() | Should -Match 'no data'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'CLI surface' {
    It 'exits 1 when the input file does not exist' {
        $tmp = New-TempPath
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $r = Invoke-CliScript -InputPath $tmp
        $r.ExitCode | Should -Be 1
    }

    It 'exits non-zero when the input argument is missing' {
        # Mandatory parameter + -NonInteractive -> binding error.
        $r = Invoke-CliScript
        $r.ExitCode | Should -Not -Be 0
    }
}


Describe 'Help discoverability' {
    It 'Get-Help returns a non-empty synopsis mentioning polygon' {
        $help = Get-Help -Name $script:ScriptPath
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Match 'polygon'
    }

    It 'documents the -Format parameter and mentions DMS' {
        $help = Get-Help -Name $script:ScriptPath -Parameter Format -ErrorAction Stop
        # .Description.Text is an array of strings on PS 5.1 and a single
        # string on PS 7; -join handles both shapes.
        ($help.Description.Text -join ' ') | Should -Match 'DMS'
    }
}


Describe 'DMS output format' {
    It 'DMS output matches the sample fixture (line endings normalised)' {
        $r = Invoke-CliScript -InputPath $script:SamplePath -Format 'DMS'
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        (Get-NormalizedText $r.StdOut) |
            Should -Be (Get-NormalizedText $script:ExpectedDms)
    }

    It 'header names the DMS format on stderr and never on stdout' {
        $r = Invoke-CliScript -InputPath $script:SamplePath -Format 'DMS'
        $r.StdErr | Should -Match '^Format: '
        $r.StdErr | Should -Match 'Degrees Minutes Seconds'
        $r.StdErr | Should -Match 'WGS84'
        $r.StdOut | Should -Not -Match 'Format:'
    }

    It 'zero-pads minutes/seconds and keeps four decimal places' {
        $r = Invoke-CliScript -InputPath $script:SamplePath -Format 'DMS'
        $lines = Get-NormalizedLines $r.StdOut
        $lines[1] | Should -Be '53-23-07.0008,-129-47-17.9988'
    }

    It 'marks W/S with a single leading minus, positive values unsigned' {
        $r = Invoke-CliScript -InputPath $script:SamplePath -Format 'DMS'
        $lines = Get-NormalizedLines $r.StdOut
        $lines[0] | Should -Be '53-21-47.9988,-129-47-17.9988'
    }
}


Describe 'Format selection' {
    It 'defaults to decimal when -Format is omitted' {
        $r = Invoke-CliScript -InputPath $script:SamplePath
        (Get-NormalizedText $r.StdOut) |
            Should -Be (Get-NormalizedText $script:ExpectedDecimal)
    }

    It 'explicit -Format Decimal matches the decimal fixture' {
        $r = Invoke-CliScript -InputPath $script:SamplePath -Format 'Decimal'
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        (Get-NormalizedText $r.StdOut) |
            Should -Be (Get-NormalizedText $script:ExpectedDecimal)
    }

    It 'rejects an unknown -Format value with a non-zero exit' {
        $r = Invoke-CliScript -InputPath $script:SamplePath -Format 'Banana'
        $r.ExitCode | Should -Not -Be 0
    }
}


Describe 'DMS rounding carry' {
    It 'carries seconds that round to 60 up into minutes and degrees' {
        # 10.9999999999 deg: the seconds remainder rounds to 60.0000, which the
        # carry guard rolls into minutes then degrees, yielding 11-00-00.0000.
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t10.9999999999N`t100.0W`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp -Format 'DMS'
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            # @() is REQUIRED here: this input produces a single output line,
            # which would otherwise be unwrapped to a scalar string, making
            # $lines[0] index the first character instead of the first line.
            $lines = @(Get-NormalizedLines $r.StdOut)
            $lines[0] | Should -Be '11-00-00.0000,-100-00-00.0000'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'DDM input (degrees + decimal minutes)' {
    It 'converts a DDM vertex to decimal at fixed 6 dp' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t10-30.0N`t100-15.0W`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            # @() REQUIRED: single output line would otherwise unwrap to a
            # scalar string, making [0] index the first character.
            $lines = @(Get-NormalizedLines $r.StdOut)
            $lines[0] | Should -Be '10.500000,-100.250000'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'renders DDM input to DMS output when -Format DMS is set' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t10-30.0N`t100-15.0W`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp -Format 'DMS'
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            $lines = @(Get-NormalizedLines $r.StdOut)
            $lines[0] | Should -Be '10-30-00.0000,-100-15-00.0000'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects DDM minutes >= 60' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t53-72.5N`t125.0W`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 1
            $r.StdErr   | Should -Match 'out of range'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'DMS input (degrees-minutes-seconds)' {
    It 'converts a DMS vertex to decimal at fixed 6 dp' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t10-30-00.0N`t100-15-00.0W`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            $lines = @(Get-NormalizedLines $r.StdOut)
            $lines[0] | Should -Be '10.500000,-100.250000'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects DMS seconds >= 60' {
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body "`tLat`tLon`n1`t53-22-72.5N`t125.0W`n"
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 1
            $r.StdErr   | Should -Match 'out of range'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'Mixed coordinate formats in one file' {
    It 'parses a decimal row and a DDM row in the same file' {
        $body = (@(
            "`tLat`tLon"
            "1`t53.5N`t129.5W"
            "2`t53-45.0N`t129-15.0W"
        ) -join "`n") + "`n"
        $tmp = New-TempPath
        Write-PolyInput -Path $tmp -Body $body
        try {
            $r = Invoke-CliScript -InputPath $tmp
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            $lines = @(Get-NormalizedLines $r.StdOut)
            $lines[0] | Should -Be '53.5,-129.5'           # decimal: precision preserved
            $lines[1] | Should -Be '53.750000,-129.250000' # DDM: fixed 6 dp
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'Issue #5 - DDM polygon regression' {
    It 'parses the issue-5 DDM polygon to the expected decimal output' {
        $r = Invoke-CliScript -InputPath $script:DdmSamplePath
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        (Get-NormalizedText $r.StdOut) |
            Should -Be (Get-NormalizedText $script:ExpectedDdmDecimal)
    }

    It 'does not mistake the Angle/bearing column for a coordinate' {
        $r = Invoke-CliScript -InputPath $script:DdmSamplePath
        $lines = @(Get-NormalizedLines $r.StdOut)
        $lines.Count | Should -Be 6   # 5 vertices + auto-closed ring
    }
}
