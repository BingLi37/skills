#Requires -Version 5.1
<#
  new-fixture.ps1 -- build a throwaway "dirty ACE" fixture for testing
  optimize-ace.ps1 without touching the real machine.

  Everything lives under one root directory. The registry half is written to
  HKCU:\Software\AceOptimizationTest\<FixtureName>\Services, which is writable
  without elevation and trivially removable. The file half is a directory tree
  that mimics a real ACE install plus a game-bundled copy.

  Scenarios:
    messy        -- the common case: 3 stale CORE keys whose files are gone,
                    plus a leftover non-CORE key
    clean        -- healthy machine: one current build, nothing to remove
    midupdate    -- a build NEWER than the installed one is present (ACE updating);
                    the tool must refuse to touch it
    bundled      -- system install + a game folder holding 5 stacked CORE builds
    uninstalled  -- ACE removed but keys left behind (no CORE .sys on disk at all)
    adversarial  -- names and ImagePath values that must not crash the scanner:
                    huge build numbers, empty/UNC/nonexistent-drive paths, no
                    ImagePath at all. These are what other people's machines throw
                    at it, and a scanner that dies on one skips every later entry.

  Usage:
    powershell -ExecutionPolicy Bypass -File new-fixture.ps1 -Name messy
    powershell -ExecutionPolicy Bypass -File new-fixture.ps1 -Name messy -Clean
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('messy','clean','midupdate','bundled','uninstalled','adversarial')]
    [string]$Name,
    [string]$Root = "$env:TEMP\ace-fixtures",
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$FixtureRoot = Join-Path $Root $Name
$Install     = Join-Path $FixtureRoot 'Program Files\AntiCheatExpert'
$Bundled     = Join-Path $FixtureRoot 'Games\SomeGame\Binaries\Win64\AntiCheatExpert'
$SvcRoot     = "HKCU:\Software\AceOptimizationTest\$Name\Services"
$RunKey      = "HKCU:\Software\AceOptimizationTest\$Name\Run"

if ($Clean) {
    Remove-Item $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "HKCU:\Software\AceOptimizationTest\$Name" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "cleaned fixture '$Name'"
    exit 0
}

# Start from a clean slate so re-runs are deterministic.
Remove-Item $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "HKCU:\Software\AceOptimizationTest\$Name" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Install | Out-Null
New-Item -ItemType Directory -Force -Path $SvcRoot  | Out-Null
New-Item -ItemType Directory -Force -Path $RunKey   | Out-Null

function New-DriverFile {
    param([string]$Path, [int]$KB = 64)
    # Content is irrelevant; only existence and size matter to the scanner.
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    $bytes = New-Object byte[] ($KB * 1024)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function New-SvcKey {
    param(
        [string]$ServiceName,
        [string]$ImagePath,
        [int]$Start = 3,
        [string]$DisplayName = 'ACE-CORE'
    )
    $key = Join-Path $SvcRoot $ServiceName
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name 'Type'         -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name 'Start'        -Value $Start -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name 'ErrorControl' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name 'ImagePath'    -Value $ImagePath -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DisplayName'  -Value $DisplayName -PropertyType String -Force | Out-Null
}

# ACE-BOOT is Start=1 (SYSTEM_START). Present in every scenario -- it is the
# always-running component the scanner must never flag.
New-DriverFile (Join-Path $Install 'ACE-BOOT.sys')
New-SvcKey 'ACE-BOOT' "\\??\\$(Join-Path $Install 'ACE-BOOT.sys')" -Start 1 -DisplayName 'ACE-BOOT'

switch ($Name) {
    'messy' {
        # Current build: file present, so it is the reference version.
        New-DriverFile (Join-Path $Install 'ACE-CORE30405.sys')
        New-SvcKey 'ACE-CORE30405' "\\??\\$(Join-Path $Install 'ACE-CORE30405.sys')"
        # Two superseded builds: keys remain, files were deleted by the updater.
        New-SvcKey 'ACE-CORE10405' "\\??\\$(Join-Path $Install 'ACE-CORE10405.sys')"
        New-SvcKey 'ACE-CORE20405' "\\??\\$(Join-Path $Install 'ACE-CORE20405.sys')"
        # A non-CORE leftover pointing at a vanished driver.
        New-SvcKey 'ace-game-0'    "\\??\\$(Join-Path $Install 'ace-game-0.sys')" -DisplayName 'ace-game-0'
        # Live components the scanner must leave alone.
        New-DriverFile (Join-Path $Install 'ACE-BASE.sys')
        New-DriverFile (Join-Path $Install 'ACE-GAME.sys')
        New-SvcKey 'ACE-BASE' "\\??\\$(Join-Path $Install 'ACE-BASE.sys')" -DisplayName 'ACE-BASE'
        New-SvcKey 'ACE-GAME' "\\??\\$(Join-Path $Install 'ACE-GAME.sys')" -DisplayName 'ACE-GAME'
        # Never-rotating boot logs, the other thing cleanup reclaims.
        foreach ($d in 0..3) {
            $f = Join-Path $Install ("ace-boot-2026{0:0000}.log" -f $d)
            [System.IO.File]::WriteAllBytes($f, (New-Object byte[] (512 * 1024)))
            (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-$d)
        }
        New-ItemProperty -Path $RunKey -Name 'ACE-Tray' -Value (Join-Path $Install 'ACE-Tray.exe') -Force | Out-Null
    }

    'clean' {
        New-DriverFile (Join-Path $Install 'ACE-CORE30405.sys')
        New-SvcKey 'ACE-CORE30405' "\\??\\$(Join-Path $Install 'ACE-CORE30405.sys')"
        New-DriverFile (Join-Path $Install 'ACE-BASE.sys')
        New-SvcKey 'ACE-BASE' "\\??\\$(Join-Path $Install 'ACE-BASE.sys')" -DisplayName 'ACE-BASE'
    }

    'midupdate' {
        New-DriverFile (Join-Path $Install 'ACE-CORE30405.sys')
        New-SvcKey 'ACE-CORE30405' "\\??\\$(Join-Path $Install 'ACE-CORE30405.sys')"
        # ACE has staged a newer build. Touching this would break an in-flight update.
        New-SvcKey 'ACE-CORE99999' "\\??\\$(Join-Path $Install 'ACE-CORE99999.sys')"
        # And one genuinely stale entry, which SHOULD still be removed.
        New-SvcKey 'ACE-CORE10405' "\\??\\$(Join-Path $Install 'ACE-CORE10405.sys')"
    }

    'bundled' {
        New-DriverFile (Join-Path $Install 'ACE-CORE30405.sys')
        New-SvcKey 'ACE-CORE30405' "\\??\\$(Join-Path $Install 'ACE-CORE30405.sys')"
        New-SvcKey 'ACE-CORE10405' "\\??\\$(Join-Path $Install 'ACE-CORE10405.sys')"
        # Game-bundled copy with five stacked builds -- the Valorant pattern.
        # Timestamps are set explicitly and spread out so "newest" is unambiguous:
        # ACE-CORE.sys3 is the current one, exactly as in a real install. Writing
        # them all in the same second would leave the ordering to chance.
        $bundledFiles = [ordered]@{
            'ACE-CORE.sys'   = 90
            'ACE-CORE.sysa'  = 80
            'ACE-CORE.sysa2' = 70
            'ACE-CORE.sys2'  = 60
            'ACE-CORE.sys3'  = 0     # newest
        }
        $i = 0
        foreach ($n in $bundledFiles.Keys) {
            $f = Join-Path $Bundled $n
            New-DriverFile $f -KB 256
            (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-$bundledFiles[$n]).AddMinutes($i)
            $i++
        }
        New-DriverFile (Join-Path $Bundled 'SGuard\x64\SGuard64.exe') -KB 32
    }

    'uninstalled' {
        # ACE uninstalled; keys survived. No CORE .sys anywhere on disk, so the
        # scanner has no on-disk build to compare against (CORE-UNVERIFIED path).
        New-SvcKey 'ACE-CORE10405' "\\??\\$(Join-Path $Install 'ACE-CORE10405.sys')"
        New-SvcKey 'ACE-CORE20405' "\\??\\$(Join-Path $Install 'ACE-CORE20405.sys')"
        New-SvcKey 'ACE-CORE30405' "\\??\\$(Join-Path $Install 'ACE-CORE30405.sys')"
    }

    'adversarial' {
        # A normal current build, so the scan has a reference version and the
        # garbage entries are judged against it rather than falling into
        # CORE-UNVERIFIED. ACE-CORE30405.sys is the only file on disk.
        New-DriverFile (Join-Path $Install 'ACE-CORE30405.sys')
        New-SvcKey 'ACE-CORE30405' "\\??\\$(Join-Path $Install 'ACE-CORE30405.sys')"

        # Build number too big for Int64. Must not throw; classified by file
        # existence, and since the file is absent it is removable.
        New-SvcKey 'ACE-CORE99999999999999999999999' "\\??\\$(Join-Path $Install 'ACE-CORE99999999999999999999999.sys')"

        # ImagePath shapes seen in the wild that break naive parsers.
        New-SvcKey 'ACE-CORE10405' '\??\C:\NoSuchDriveXYZ\ACE-CORE10405.sys'   # nonexistent drive
        New-SvcKey 'ACE-CORE10406' '\\server\share\ACE-CORE10406.sys'          # UNC path
        New-SvcKey 'ACE-CORE10407' ''                                          # empty
        New-SvcKey 'ACE-CORE10408' '   '                                       # whitespace only
        New-SvcKey 'ACE-CORE10409' 'Relative\Path\ACE-CORE10409.sys'           # relative
        New-SvcKey 'ACE-CORE10410' '%SystemRoot%\System32\drivers\ACE-CORE10410.sys'  # env var

        # A key with no ImagePath property at all. Built by hand because
        # New-SvcKey always writes one.
        $bare = Join-Path $SvcRoot 'ACE-CORE10411'
        New-Item -Path $bare -Force | Out-Null
        New-ItemProperty -Path $bare -Name 'Type'  -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $bare -Name 'Start' -Value 3 -PropertyType DWord -Force | Out-Null

        # Wrong-typed ImagePath (DWORD where a string belongs). Some installers
        # write the wrong type; reading it back must not throw.
        $badType = Join-Path $SvcRoot 'ACE-CORE10412'
        New-Item -Path $badType -Force | Out-Null
        New-ItemProperty -Path $badType -Name 'Start'     -Value 3       -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $badType -Name 'ImagePath' -Value 1234567 -PropertyType DWord -Force | Out-Null

        # Non-numeric CORE suffix (game-bundled style), no file on disk.
        New-SvcKey 'ACE-CORE-something' '\??\C:\nowhere\ACE-CORE-something.sys'

        # A live component that must survive all of the above.
        New-DriverFile (Join-Path $Install 'ACE-BASE.sys')
        New-SvcKey 'ACE-BASE' "\\??\\$(Join-Path $Install 'ACE-BASE.sys')" -DisplayName 'ACE-BASE'
    }
}

Write-Host "fixture '$Name' created"
Write-Host ("  root    : {0}" -f $FixtureRoot)
Write-Host ("  install : {0}" -f $Install)
Write-Host ("  svcroot : {0}" -f $SvcRoot)
if ($Name -eq 'bundled') { Write-Host ("  bundled : {0}" -f $Bundled) }
Write-Host ""
Write-Host "Run the scanner against it with:"
Write-Host ("  powershell -ExecutionPolicy Bypass -File optimize-ace.ps1 -Sandbox " +
            "-SvcRoot '{0}' -RunKey '{1}' -InstallDir '{2}'" -f $SvcRoot, $RunKey, $Install)
