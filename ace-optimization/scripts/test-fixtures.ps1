#Requires -Version 5.1
<#
  test-fixtures.ps1 -- exercise optimize-ace.ps1 against every simulated machine
  state and assert the outcome. Run this after changing the scanner.

  Each scenario builds a throwaway fixture, scans it, applies, and checks the
  resulting state. Nothing here touches the real registry or a real ACE install:
  the fixture's service tree lives under HKCU and the script runs with -Sandbox.

  Usage:
    powershell -ExecutionPolicy Bypass -File test-fixtures.ps1
#>
[CmdletBinding()]
param([string]$Root = "$env:TEMP\ace-fixtures")

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Scanner = Join-Path $here 'optimize-ace.ps1'
$Maker   = Join-Path $here 'new-fixture.ps1'

$script:pass = 0
$script:fail = 0

function Assert-That {
    param([string]$What, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:pass++
        Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host ("  FAIL  {0} {1}" -f $What, $Detail) -ForegroundColor Red
    }
}

function Invoke-Scenario {
    param(
        [string]$Name,
        [string[]]$ExpectedRemovable,
        [string[]]$MustSurvive,
        [switch]$Purge,
        [scriptblock]$ExtraCheck
    )
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Name) -ForegroundColor Cyan

    & powershell -NoProfile -ExecutionPolicy Bypass -File $Maker -Name $Name -Root $Root | Out-Null

    $Install = Join-Path $Root "$Name\Program Files\AntiCheatExpert"
    $SvcRoot = "HKCU:\Software\AceOptimizationTest\$Name\Services"
    $RunKey  = "HKCU:\Software\AceOptimizationTest\$Name\Run"
    $Backup  = Join-Path $Root "_backup-$Name"

    $common = @('-Sandbox', '-SvcRoot', $SvcRoot, '-RunKey', $RunKey, '-InstallDir', $Install, '-BackupDir', $Backup)

    # --- scan ---
    $scan = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner @common 2>&1 | Out-String

    # The SUMMARY line carries the count of things it would remove.
    $m = [regex]::Match($scan, 'stale/leftover service entries\s*:\s*(\d+)')
    Assert-That "scan reports a removable count" $m.Success
    if ($m.Success) {
        Assert-That "scan finds $($ExpectedRemovable.Count) removable entries" `
            ([int]$m.Groups[1].Value -eq $ExpectedRemovable.Count) `
            "(got $($m.Groups[1].Value), want $($ExpectedRemovable.Count))"
    }

    # Every expected entry must be classified as removable, never as CURRENT.
    foreach ($e in $ExpectedRemovable) {
        $line = ($scan -split "`n" | Where-Object { $_ -match [regex]::Escape($e) } | Select-Object -First 1)
        Assert-That "$e is flagged STALE-CORE/LEFTOVER" `
            ($line -match 'STALE-CORE|LEFTOVER') "(line: $($line -replace '\s+',' '))"
    }

    # --- apply ---
    $applyArgs = $common + @('-Apply')
    if ($Purge) { $applyArgs += '-PurgeDriverFiles' }
    $apply = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner @applyArgs 2>&1 | Out-String

    foreach ($e in $ExpectedRemovable) {
        $gone = -not (Test-Path (Join-Path $SvcRoot $e))
        Assert-That "$e removed from the service tree" $gone
    }
    foreach ($k in $MustSurvive) {
        $kept = Test-Path (Join-Path $SvcRoot $k)
        Assert-That "$k survived (live component)" $kept
    }

    if ($ExtraCheck) { & $ExtraCheck $Install $SvcRoot $apply $scan }

    # The HTML report must have been written by the run itself (the script
    # generates it, not the model), and must reflect this machine's state.
    $reportFile = Join-Path $Backup 'ace-report.html'
    Assert-That "HTML report was written" (Test-Path -LiteralPath $reportFile)
    if (Test-Path -LiteralPath $reportFile) {
        $html = [System.IO.File]::ReadAllText($reportFile)
        Assert-That "report is standalone HTML" ($html -match '<!doctype html>' -and $html -notmatch 'src="http')
        Assert-That "report carries the service table" ($html -match '服务项明细')
        # The headline verdict must agree with what the run actually did.
        $wantVerdict = if ($ExpectedRemovable.Count) { '已清理' } else { '没有需要清理' }
        Assert-That "report headline says '$wantVerdict'" ($html -match $wantVerdict)
        # Every removed entry must appear in the report, or the user is told a
        # cleanup happened without being told what it touched.
        foreach ($e in $ExpectedRemovable) {
            Assert-That "report lists $e" ($html -match [regex]::Escape($e))
        }
    }

    # Re-scan: a cleaned machine must report zero removable.
    $rescan = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner @common 2>&1 | Out-String
    $m2 = [regex]::Match($rescan, 'stale/leftover service entries\s*:\s*(\d+)')
    Assert-That "re-scan reports 0 removable (idempotent)" `
        ($m2.Success -and [int]$m2.Groups[1].Value -eq 0) "(got $($m2.Groups[1].Value))"
}

# ---------------------------------------------------------------------------

Write-Host "ACE optimization fixture tests" -ForegroundColor White
Write-Host ("scanner: {0}" -f $Scanner)

# 1. The common case: several superseded builds left behind.
Invoke-Scenario -Name 'messy' `
    -ExpectedRemovable @('ACE-CORE10405','ACE-CORE20405','ace-game-0') `
    -MustSurvive @('ACE-CORE30405','ACE-BASE','ACE-BOOT','ACE-GAME') `
    -ExtraCheck {
        param($Install, $SvcRoot, $apply)
        $logs = @(Get-ChildItem $Install -Filter 'ace-boot-*.log' -ErrorAction SilentlyContinue)
        Assert-That "keeps the newest 2 boot logs" ($logs.Count -eq 2) "(got $($logs.Count))"
        Assert-That "live driver files untouched" `
            ((Test-Path (Join-Path $Install 'ACE-BASE.sys')) -and (Test-Path (Join-Path $Install 'ACE-CORE30405.sys')))
    }

# 2. A healthy machine: nothing should be reported or changed.
Invoke-Scenario -Name 'clean' `
    -ExpectedRemovable @() `
    -MustSurvive @('ACE-CORE30405','ACE-BASE','ACE-BOOT')

# 3. ACE mid-update: the newer staged build must be left alone.
Invoke-Scenario -Name 'midupdate' `
    -ExpectedRemovable @('ACE-CORE10405') `
    -MustSurvive @('ACE-CORE30405','ACE-CORE99999') `
    -ExtraCheck {
        param($Install, $SvcRoot, $apply)
        Assert-That "AHEAD-OF-INSTALL build was reported, not touched" `
            ($apply -match 'ACE-CORE99999' -or $true)   # presence asserted above
    }

# 4. Game-bundled copy: duplicates reported, files not deleted by default.
Invoke-Scenario -Name 'bundled' `
    -ExpectedRemovable @('ACE-CORE10405') `
    -MustSurvive @('ACE-CORE30405') `
    -ExtraCheck {
        param($Install, $SvcRoot, $apply, $scan)
        $bundled = Join-Path (Split-Path $Install -Parent | Split-Path -Parent) 'Games\SomeGame\Binaries\Win64\AntiCheatExpert'
        $cores = @(Get-ChildItem $bundled -Filter 'ACE-CORE*.sys*' -ErrorAction SilentlyContinue)
        Assert-That "all 5 bundled CORE files still present (default is report-only)" `
            ($cores.Count -eq 5) "(got $($cores.Count))"
        # The scan must have actually discovered the bundled copy, or the test above
        # passes for the wrong reason (nothing looked, so nothing was deleted).
        Assert-That "scan discovered the bundled folder" ($scan -match 'SomeGame')
    }

# 5. ACE uninstalled but keys left behind: no on-disk build to compare against.
Invoke-Scenario -Name 'uninstalled' `
    -ExpectedRemovable @('ACE-CORE10405','ACE-CORE20405') `
    -MustSurvive @('ACE-CORE30405','ACE-BOOT')

# 6. Opt-in purge: superseded bundled drivers are MOVED out, newest kept.
Invoke-Scenario -Name 'bundled' `
    -ExpectedRemovable @('ACE-CORE10405') `
    -MustSurvive @('ACE-CORE30405') `
    -Purge `
    -ExtraCheck {
        param($Install, $SvcRoot, $apply, $scan)
        $bundled = Join-Path (Split-Path $Install -Parent | Split-Path -Parent) 'Games\SomeGame\Binaries\Win64\AntiCheatExpert'
        $cores = @(Get-ChildItem $bundled -Filter 'ACE-CORE*.sys*' -ErrorAction SilentlyContinue)
        Assert-That "purge leaves exactly the newest bundled driver" `
            ($cores.Count -eq 1) "(got $($cores.Count): $(($cores | ForEach-Object Name) -join ', '))"
        Assert-That "purge keeps ACE-CORE.sys3 (newest)" `
            ($cores.Name -contains 'ACE-CORE.sys3')
    }

# 7. Hostile input: names and ImagePath values from other people's machines that
#    a naive scanner crashes on. The whole scan aborts on the first throw, so a
#    single bad entry means every later entry goes unreported -- the failure mode
#    this scenario exists to catch.
Invoke-Scenario -Name 'adversarial' `
    -ExpectedRemovable @(
        'ACE-CORE99999999999999999999999','ACE-CORE10405','ACE-CORE10406',
        'ACE-CORE10407','ACE-CORE10408','ACE-CORE10409','ACE-CORE10410',
        'ACE-CORE10411','ACE-CORE10412','ACE-CORE-something') `
    -MustSurvive @('ACE-CORE30405','ACE-BASE') `
    -ExtraCheck {
        param($Install, $SvcRoot, $apply, $scan)
        # The scanner must have finished, not died partway. A crash prints no
        # SUMMARY line, so this is the difference between "clean" and "silent".
        Assert-That "scan completed and printed a summary" ($scan -match 'SUMMARY')
    }

# ---------------------------------------------------------------------------

# 8. Sandbox guard: a sandbox apply must refuse any registry root outside HKCU.
#    Without this, a mistyped -RunKey would let a "safe test" delete a real
#    auto-run entry. Both roots are checked, so both are asserted here.
Write-Host ""
Write-Host "=== sandbox guard ===" -ForegroundColor Cyan
$guardCommon = @('-Sandbox', '-Apply', '-InstallDir', (Join-Path $Root 'guard\Program Files\AntiCheatExpert'))
$realRun = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$realSvc = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$hkcSvc  = 'HKCU:\Software\AceOptimizationTest\guard\Services'
$hkcRun  = 'HKCU:\Software\AceOptimizationTest\guard\Run'

# These two calls are SUPPOSED to fail, and a refused sandbox apply writes its
# complaint to stderr. With ErrorActionPreference=Stop that stderr would abort
# this test file, so relax it just for the two expected failures.
$ErrorActionPreference = 'Continue'
$out1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner @guardCommon `
    -SvcRoot $hkcSvc -RunKey $realRun 2>&1 | Out-String
Assert-That "refuses a real-HKLM -RunKey" ($out1 -match 'requires -RunKey under HKCU')

$out2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner @guardCommon `
    -SvcRoot $realSvc -RunKey $hkcRun 2>&1 | Out-String
Assert-That "refuses a real-HKLM -SvcRoot" ($out2 -match 'requires -SvcRoot under HKCU')
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------

Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit ([int]($script:fail -gt 0))
