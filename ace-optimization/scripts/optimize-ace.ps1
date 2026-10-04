#Requires -Version 5.1
<#
  optimize-ace.ps1 -- scan and clean stale Tencent AntiCheatExpert (ACE) leftovers.

  READ-ONLY BY DEFAULT. Nothing is changed unless you pass -Apply.

  The problem this solves: every ACE update registers a new kernel-driver service
  named ACE-CORE<build> and deletes the previous build's .sys file, but it never
  deletes the previous service registry key. Over several updates the registry
  accumulates dead ACE-CORE* entries that the Service Control Manager still tries
  to load at every boot. That is the "multiple ACE versions" users see.

  Safety rules baked in:
    * Refuses to change anything while ACE or a game using it is running.
    * Never touches a service that is running, or whose driver file exists.
    * Never touches a build NEWER than the installed one (ACE mid-update).
    * Exports every registry key it removes to a .reg backup first.
    * Does not delete files inside a game's own ACE folder unless asked.

  Usage:
    powershell -ExecutionPolicy Bypass -File optimize-ace.ps1              # report
    powershell -ExecutionPolicy Bypass -File optimize-ace.ps1 -Deep        # + find game-bundled ACE
    powershell -ExecutionPolicy Bypass -File optimize-ace.ps1 -Apply       # clean
    powershell -ExecutionPolicy Bypass -File optimize-ace.ps1 -SelfTest    # verify logic
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Deep,
    [switch]$PurgeDriverFiles,
    [switch]$DisableTrayAutostart,
    [switch]$SelfTest,
    [string]$BackupDir = "$env:USERPROFILE\ace-optimization-backup",
    [int]$KeepBootLogs = 2,
    # Where the self-contained HTML report lands. Empty means "pick a sensible
    # spot": the Desktop for a real run (easy to double-click), or the backup
    # folder under -Sandbox so fixture tests do not litter the Desktop.
    [string]$ReportPath,
    # --- testing hooks ---------------------------------------------------
    # These exist so the script can be exercised against a fixture that mimics
    # another machine's leftovers (stale keys, stacked drivers) without touching
    # the real registry. Normal use never passes them.
    [string]$SvcRoot,
    [string]$RunKey,
    [string]$InstallDir,
    [switch]$Sandbox
)

$ErrorActionPreference = 'Stop'
if (-not $SvcRoot)    { $SvcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services' }
if (-not $RunKey)     { $RunKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
if (-not $InstallDir) { $InstallDir = "$env:ProgramFiles\AntiCheatExpert" }

# In -Sandbox the registry lives under HKCU (writable without elevation) and the
# machine-state gates (elevation, live process/driver checks) are skipped, so the
# apply path can be tested end to end against a throwaway fixture.
function Assert-SandboxHive {
    <# Both registry roots must be checked. Guarding only -SvcRoot leaves -RunKey
       free to point at the real HKLM Run key, and -DisableTrayAutostart would then
       delete a real entry from a "sandbox" run. #>
    param([string]$ParamName, [string]$Value)
    $normalized = $Value -replace '^Registry::', '' -replace '^HKEY_CURRENT_USER', 'HKCU:'
    if ($normalized -notlike 'HKCU:*') {
        throw ("-Sandbox requires -{0} under HKCU: (got '{1}'). Refusing to run a sandbox apply against the real registry." `
               -f $ParamName, $Value)
    }
}
if ($Sandbox) {
    Assert-SandboxHive -ParamName 'SvcRoot' -Value $SvcRoot
    Assert-SandboxHive -ParamName 'RunKey'  -Value $RunKey
}

# User-mode ACE processes. ACE-BOOT is deliberately absent: it is Start=1
# (SYSTEM_START) and loads on every boot, game or not, so treating it as "busy"
# would block cleanup forever. What indicates a live session is these processes
# plus the demand-start game drivers.
$AceProcess  = 'ACE-Tray', 'SGuard64', 'SGuardSvc64', 'ACE-Service64', 'ACE-Helper'
$GameDrivers = 'ACE-GAME', 'ACE-BASE', 'ACE-ADVT', 'ACE-CORE*', 'ace-game-*'
$GameProcess = 'DeltaForceClient', 'deltaforce', 'VALORANT', 'VALORANT-Win64-Shipping',
               'CrossFire', 'cfs', 'DNF', 'LeagueClient', 'GameLoop', 'aow_exe'

# ---------------------------------------------------------------- helpers

function Get-CoreBuildNumber {
    <# Extract <build> from "ACE-CORE<build>". Returns $null when the name is not
       a numbered CORE entry OR when the number does not fit in a long.

       A plain [int] cast here is a landmine: a stray file or key named
       ACE-CORE88888888888 throws "value too large for Int32" and aborts the
       whole scan. Names come from other people's machines, so this must never
       throw -- an unparseable build is simply not a build we can compare. #>
    param([string]$Name)
    if ($Name -notmatch '^ACE-CORE(\d+)$') { return $null }
    $n = 0L
    if (-not [long]::TryParse($Matches[1], [ref]$n)) { return $null }
    return $n
}

function Get-AceClass {
    <# Pure decision function -- the part that must be right, so it is isolated
       and covered by -SelfTest rather than inlined in the scan loop. #>
    param(
        [string]$Name,
        [bool]$FileExists,
        [bool]$Running,
        [Nullable[long]]$CurrentCoreBuild
    )
    if ($Running) { return 'ACTIVE' }
    $build = Get-CoreBuildNumber $Name
    if ($null -ne $build) {
        if ($null -eq $CurrentCoreBuild) { return 'CORE-UNVERIFIED' }
        if ($build -lt $CurrentCoreBuild) { return 'STALE-CORE' }
        if ($build -eq $CurrentCoreBuild) { return 'CURRENT' }
        return 'AHEAD-OF-INSTALL'   # ACE is mid-update; hands off
    }
    if (-not $FileExists) { return 'LEFTOVER' }
    return 'CURRENT'
}

function Resolve-DriverPath {
    param([string]$ImagePath)
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }
    $p = $ImagePath
    # Any run of leading slashes before ?? is the \??\ prefix, however it was
    # written. Being strict here is a liability: an unmatched prefix leaves a
    # literal "\\??\\" path, and Test-Path then throws on it instead of just
    # reporting the file missing.
    $p = $p -replace '^[\\/]+\?\?[\\/]+', ''
    $p = $p -replace '^[\\/]*SystemRoot[\\/]', "$env:SystemRoot\"
    $p = $p -replace '^System32[\\/]', "$env:SystemRoot\System32\"
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Test-PathSafe {
    <# Test-Path throws on malformed paths (bad drive letters, illegal chars).
       A scanner must treat "cannot evaluate" as "not there" and keep going --
       one weird ImagePath on someone else's machine should not abort the scan. #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return (Test-Path -LiteralPath $Path -ErrorAction Stop) } catch { return $false }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AceLocations {
    <# Standard install locations are instant. -Deep walks fixed drives, which is
       the only way to find an ACE copy bundled inside a game folder (Valorant and
       some Tencent titles ship their own). That walk costs ~30s, hence opt-in. #>
    param([switch]$Deep)
    $found = New-Object System.Collections.Generic.List[string]

    if ($Sandbox) {
        # Fixture only -- never fall through to the host's real ACE installs.
        # Search from the fixture root, not from the install dir: a game-bundled
        # copy sits beside the install, not under it.
        $fixtureRoot = Split-Path (Split-Path $InstallDir -Parent) -Parent
        if (Test-PathSafe $fixtureRoot) {
            Get-ChildItem $fixtureRoot -Recurse -Directory -Filter 'AntiCheatExpert' `
                -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $found.Add($_.FullName) }
        }
        if (Test-PathSafe $InstallDir) { $found.Add($InstallDir) }
        return ($found | Sort-Object -Unique)
    }

    $standard = @(
        $InstallDir,
        "${env:ProgramFiles(x86)}\AntiCheatExpert",
        "$env:ProgramData\AntiCheatExpert"
    )
    foreach ($p in $standard) { if ($p -and (Test-PathSafe $p)) { $found.Add($p) } }

    if ($Deep) {
        $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.DeviceID + '\' }
        foreach ($d in $drives) {
            Write-Host ("  scanning {0} ..." -f $d)
            # Depth 8 is what the Valorant bundle needs
            # (program\Tencent Games\VALORANT\live\ShooterGame\Binaries\Win64\...).
            # Going deeper multiplies the walk cost for no real gain, so this is
            # deliberately shallow.
            Get-ChildItem $d -Recurse -Directory -Depth 8 -Filter 'AntiCheatExpert' `
                -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    # A deep walk can also hit stub directories inside launcher
                    # packages (e.g. ...\node_modules\@tencent\tencent-games-api\
                    # ...\AntiCheatExpert) that hold no ACE binaries at all.
                    # Requiring an actual ACE file keeps those out of the report.
                    # (Where-Object, not -Include: -Include is silently ignored
                    # unless the path carries a wildcard.)
                    $hasAce = Get-ChildItem $_.FullName -Recurse -Depth 2 -File -Force `
                              -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -like 'ACE-*' } |
                              Select-Object -First 1
                    if ($hasAce) { $found.Add($_.FullName) }
                }
        }
    }
    return ($found | Sort-Object -Unique)
}

function Get-CoreBuilds {
    <# ACE ships ACE-CORE<build>.sys for system installs. Game-bundled copies use
       ACE-CORE.sys with no build number, so they contribute nothing here -- which
       is correct, they are not what the service keys point at. #>
    param([string]$Path)
    $out = @()
    if (-not (Test-PathSafe $Path)) { return $out }
    Get-ChildItem $Path -Filter 'ACE-CORE*.sys' -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $b = Get-CoreBuildNumber $_.BaseName
            if ($null -ne $b) { $out += $b }
        }
    return $out
}

function ConvertTo-HtmlSafe {
    <# Escape untrusted text for HTML. Service names and paths come from other
       people's machines, so a stray '<' or '&' in a name must not corrupt the
       report. HTML-escaping is the correct fix at this trust boundary. #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' `
          -replace '"', '&quot;' -replace "'", '&#39;'
}

function Write-AceReport {
    <# Render a self-contained HTML report and open it. The SCRIPT writes the
       HTML, not the model: that keeps the report identical whether the skill is
       driven by Claude Code, Doubao, or anything else, and it costs no tokens.
       No external CSS/JS/fonts -- everything is inline so the file works by
       double-click on a machine with no network. #>
    param(
        [object]$Report,
        [string]$Path,
        [switch]$Sandbox,
        [string]$BackupDir
    )

    if (-not $Path) {
        if ($Sandbox) {
            $Path = Join-Path $BackupDir 'ace-report.html'
        } else {
            # Desktop first so the user can double-click it right after the run.
            $desktop = [Environment]::GetFolderPath('Desktop')
            if (-not (Test-PathSafe $desktop)) { $desktop = $env:USERPROFILE }
            $Path = Join-Path $desktop ("ace-report-{0}.html" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        }
    }

    $esc = { param($t) ConvertTo-HtmlSafe $t }

    $rows     = @($Report.Rows)
    $removable = @($Report.Removable)
    $dups     = @($Report.DupGroups)
    # .ToArray(), not @(): in PS 5.1 @() on a List[object] throws "parameter type
    # mismatch". Actions is the one collection built as a generic List.
    $actions  = $Report.Actions.ToArray()
    $refusal  = $Report.Refusal

    $removed  = @($actions | Where-Object { $_.Status -eq 'removed' -or $_.Status -eq 'moved' })
    $failed   = @($actions | Where-Object { $_.Status -eq 'failed' })

    # --- headline: what state is this machine in, in one sentence ---
    if ($refusal) {
        $verdict = '没有做任何修改'
        $verdictSub = "原因：$refusal。请关闭游戏和 ACE 托盘后重试，或以管理员身份运行。"
        $verdictClass = 'warn'
    } elseif (-not $Report.Applied) {
        $verdict = if ($removable.Count) { "发现 $($removable.Count) 个可清理项" } else { '没有发现需要清理的东西' }
        $verdictSub = '这是只读扫描，没有改动任何东西。确认后再执行清理。'
        $verdictClass = if ($removable.Count) { 'info' } else { 'ok' }
    } else {
        $verdict = if ($removed.Count) { "已清理 $($removed.Count) 项" } else { '没有需要清理的项目' }
        $verdictSub = if ($failed.Count) { "其中 $($failed.Count) 项失败，见下方明细。" } else { '每个被删除的注册表项都已备份，可回滚。' }
        $verdictClass = if ($failed.Count) { 'warn' } elseif ($removed.Count) { 'ok' } else { 'ok' }
    }

    # --- honesty banner: does this fix stutter? ---
    $honesty = @'
<p class="note"><strong>说明：</strong>ACE 的旧版本残留是<strong>注册表里的死键</strong>——
对应的驱动文件早就被 ACE 更新时删掉了，它们并没有在后台运行。清理它们能减少开机时
系统对无效驱动的枚举，但<strong>通常不会直接解决游戏内掉帧</strong>。如果掉帧发生在游戏中，
更可能的原因是显卡驱动、显存/内存占用、后台杀毒或录屏、温度墙、以及游戏画质设置。</p>
'@

    # --- service table ---
    $svcRows = ''
    if ($rows.Count) {
        foreach ($r in $rows) {
            $cls = $r.Class
            $badge = switch ($cls) {
                'STALE-CORE'       { '<span class="b b-stale">STALE-CORE</span>' }
                'LEFTOVER'         { '<span class="b b-left">LEFTOVER</span>' }
                'CURRENT'          { '<span class="b b-ok">CURRENT</span>' }
                'ACTIVE'           { '<span class="b b-ok">ACTIVE</span>' }
                'AHEAD-OF-INSTALL' { '<span class="b b-ahead">AHEAD-OF-INSTALL</span>' }
                default            { '<span class="b b-unk">CORE-UNVERIFIED</span>' }
            }
            # NOT $path: PowerShell variables are case-insensitive, so a local
            # named $path silently overwrites the $Path parameter holding the
            # report location, and the report lands on a driver file path.
            $imgPath = & $esc $r.Path
            if (-not $imgPath) { $imgPath = '<span class="dim">（无 ImagePath）</span>' }
            $svcRows += "<tr><td><code>$(& $esc $r.Name)</code></td><td>$badge</td><td>$imgPath</td></tr>`n"
        }
    } else {
        $svcRows = '<tr><td colspan="3" class="dim">没有找到 ACE 服务项。</td></tr>'
    }

    # --- duplicate bundled files ---
    $dupBlock = ''
    if ($dups.Count) {
        $dupRows = ''
        foreach ($d in $dups) {
            $dupRows += ("<tr><td>{0}</td><td>{1}</td><td>{2:N1} MB</td><td>{3}</td></tr>`n" -f `
                (& $esc $d.Location), $d.Count, ($d.Bytes / 1MB), (& $esc $d.Newest))
        }
        $dupBlock = @"
<h2>游戏自带的重复驱动文件</h2>
<p class="note">这些文件夹里堆着多个版本的 <code>ACE-CORE*.sys</code>。默认<strong>只报告、不删除</strong>——
ACE 自己管理这些文件，删掉它预期的文件可能导致游戏无法启动。确认要回收这部分空间时，
再用 <code>-PurgeDriverFiles</code>（文件会被<strong>移动</strong>到备份目录，不是删除）。</p>
<table><thead><tr><th>位置</th><th>文件数</th><th>占用</th><th>最新</th></tr></thead><tbody>
$dupRows</tbody></table>
"@
    }

    # --- actions ---
    $actionBlock = ''
    if ($actions.Count) {
        $actRows = ''
        foreach ($a in $actions) {
            $st = switch ($a.Status) {
                'removed' { '<span class="b b-ok">已清理</span>' }
                'moved'   { '<span class="b b-ok">已移走</span>' }
                'failed'  { '<span class="b b-stale">失败</span>' }
                default   { '<span class="b b-left">跳过</span>' }
            }
            $actRows += "<tr><td>$st</td><td><code>$(& $esc $a.Name)</code></td><td>$(& $esc $a.Detail)</td></tr>`n"
        }
        $actionBlock = @"
<h2>实际执行的动作</h2>
<table><thead><tr><th>结果</th><th>项目</th><th>说明</th></tr></thead><tbody>
$actRows</tbody></table>
"@
    }

    # --- stat tiles ---
    $tiles = @"
<div class="tiles">
  <div class="tile"><div class="n">$($removable.Count)</div><div class="l">可清理的服务项</div></div>
  <div class="tile"><div class="n">$($dups.Count)</div><div class="l">重复驱动文件夹</div></div>
  <div class="tile"><div class="n">$([math]::Round($Report.OldLogBytes / 1MB, 1))</div><div class="l">可回收日志 (MB)</div></div>
  <div class="tile"><div class="n">$(if ($null -eq $Report.CurrentBuild) { '—' } else { $Report.CurrentBuild })</div><div class="l">当前 ACE 版本号</div></div>
</div>
"@

    $locList = (@($Report.Locations) | ForEach-Object { "<li><code>$(& $esc $_)</code></li>" }) -join "`n"
    if (-not $locList) { $locList = '<li class="dim">没有找到 ACE 安装目录。</li>' }

    $busyLine = if ($Report.AceBusy) {
        "<p class='warnbox'>检测到 ACE 或游戏正在运行：<code>$(& $esc (($Report.BusyDetail) -join ', '))</code>。清理已被拒绝。</p>"
    } else { '' }

    $backupLine = if ($Report.Applied -and -not $refusal) {
        "<p>备份目录：<code>$(& $esc $Report.BackupDir)</code>。删除的注册表项已导出为 <code>.reg</code>，双击即可回滚。</p>"
    } else { '' }

    $html = @"
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ACE 优化报告</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 32px 16px; font: 15px/1.6 -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
         background: #f5f6f8; color: #1c1e21; }
  .wrap { max-width: 880px; margin: 0 auto; }
  header { margin-bottom: 24px; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .meta { color: #6b7280; font-size: 13px; }
  .verdict { border-radius: 10px; padding: 16px 18px; margin: 16px 0; border: 1px solid; }
  .verdict .big { font-size: 19px; font-weight: 600; }
  .verdict.ok   { background: #ecfdf3; border-color: #a6f4c5; color: #065f46; }
  .verdict.info { background: #eff6ff; border-color: #bcd6fb; color: #1e40af; }
  .verdict.warn { background: #fffbeb; border-color: #fde68a; color: #92400e; }
  h2 { font-size: 16px; margin: 28px 0 10px; }
  table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden;
          box-shadow: 0 1px 2px rgba(0,0,0,.06); }
  th, td { text-align: left; padding: 9px 12px; border-bottom: 1px solid #eef0f3; vertical-align: top; }
  th { background: #fafbfc; font-size: 12px; color: #6b7280; text-transform: uppercase; letter-spacing: .03em; }
  tr:last-child td { border-bottom: 0; }
  code { font: 12.5px/1.5 "Cascadia Mono", Consolas, monospace; background: #f0f2f5; padding: 1px 5px; border-radius: 4px; word-break: break-all; }
  .b { display: inline-block; font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 20px; white-space: nowrap; }
  .b-ok    { background: #dcfce7; color: #166534; }
  .b-stale { background: #fee2e2; color: #991b1b; }
  .b-left  { background: #fef3c7; color: #92400e; }
  .b-ahead { background: #e0e7ff; color: #3730a3; }
  .b-unk   { background: #e5e7eb; color: #374151; }
  .tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin: 16px 0; }
  .tile { background: #fff; border-radius: 10px; padding: 14px; box-shadow: 0 1px 2px rgba(0,0,0,.06); }
  .tile .n { font-size: 26px; font-weight: 700; }
  .tile .l { font-size: 12px; color: #6b7280; margin-top: 2px; }
  .note { background: #fff; border-left: 3px solid #93c5fd; padding: 12px 14px; border-radius: 0 8px 8px 0;
          color: #374151; font-size: 14px; }
  .warnbox { background: #fffbeb; border-left: 3px solid #f59e0b; padding: 12px 14px; border-radius: 0 8px 8px 0; }
  .dim { color: #9ca3af; }
  ul { padding-left: 20px; }
  footer { margin-top: 32px; color: #9ca3af; font-size: 12px; }
  @media (max-width: 640px) { .tiles { grid-template-columns: repeat(2, 1fr); } }
  @media (prefers-color-scheme: dark) {
    body { background: #16181c; color: #e5e7eb; }
    table, .tile, .note { background: #1f2227; }
    th { background: #23262c; }
    th, td { border-color: #2c3037; }
    code { background: #2a2e35; }
    .verdict.ok { background: #0f2a1d; border-color: #1c5b3a; color: #6ee7b7; }
    .verdict.info { background: #10203a; border-color: #1e3a8a; color: #93c5fd; }
    .verdict.warn { background: #2c2410; border-color: #78601a; color: #fcd34d; }
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>ACE 优化报告</h1>
    <div class="meta">$(& $esc $Report.Computer) · $(& $esc $Report.Stamp) · $(if ($Report.Applied) { '已执行清理' } else { '只读扫描' }) · $(if ($Report.Elevated) { '管理员' } else { '普通权限' })</div>
  </header>

  <div class="verdict $verdictClass">
    <div class="big">$verdict</div>
    <div>$verdictSub</div>
  </div>

  $tiles
  $busyLine
  $honesty

  <h2>服务项明细</h2>
  <table><thead><tr><th>名称</th><th>判定</th><th>驱动文件</th></tr></thead><tbody>
  $svcRows</tbody></table>

  $dupBlock
  $actionBlock

  <h2>扫描到的 ACE 目录</h2>
  <ul>$locList</ul>

  $backupLine

  <footer>
    由 ace-optimization skill 生成。只清理注册表中的无效残留项，不触碰正在使用的
    ACE 组件（ACE-BASE / ACE-BOOT / ACE-GAME / 当前版本），以免触发反作弊校验。
  </footer>
</div>
</body>
</html>
"@

    try {
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-PathSafe $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # UTF8 without BOM: the meta charset is utf-8, and a BOM would show as a
        # stray glyph before <!doctype> in some viewers.
        [System.IO.File]::WriteAllText($Path, $html, (New-Object System.Text.UTF8Encoding $false))
        Write-Host ""
        Write-Host ("HTML report: {0}" -f $Path)
    } catch {
        Write-Host ("  (could not write HTML report: {0})" -f $_.Exception.Message)
        return
    }

    # Open it separately: the file is already on disk, so a machine with no
    # browser (or a headless harness) must not be told the report failed.
    if (-not $Sandbox) {
        try { Start-Process $Path } catch { }
    }
}

# ---------------------------------------------------------------- self test

if ($SelfTest) {
    $cases = @(
        @{ n='ACE-CORE10405'; f=$false; r=$false; b=30405; want='STALE-CORE'      },
        @{ n='ACE-CORE20405'; f=$false; r=$false; b=30405; want='STALE-CORE'      },
        @{ n='ACE-CORE30405'; f=$false; r=$false; b=30405; want='CURRENT'         },
        @{ n='ACE-CORE30405'; f=$true;  r=$false; b=30405; want='CURRENT'         },
        @{ n='ACE-CORE99999'; f=$false; r=$false; b=30405; want='AHEAD-OF-INSTALL'},
        @{ n='ACE-CORE10405'; f=$false; r=$true;  b=30405; want='ACTIVE'          },
        @{ n='ace-game-0';    f=$false; r=$false; b=30405; want='LEFTOVER'        },
        @{ n='ACE-BASE';      f=$true;  r=$false; b=30405; want='CURRENT'         },
        @{ n='ACE-CORE30405'; f=$false; r=$false; b=$null; want='CORE-UNVERIFIED' },
        # Names from other people's machines must never throw. A build number too
        # big for a long is not a build we can compare, so it falls through to the
        # file-existence check instead of crashing the scan.
        @{ n='ACE-CORE88888888888'; f=$false; r=$false; b=30405; want='AHEAD-OF-INSTALL' },
        @{ n='ACE-CORE99999999999999999999999'; f=$false; r=$false; b=30405; want='LEFTOVER' },
        @{ n='ACE-CORE99999999999999999999999'; f=$true;  r=$false; b=30405; want='CURRENT'  },
        @{ n='ACE-COREabc';   f=$false; r=$false; b=30405; want='LEFTOVER'        },
        @{ n='ACE-CORE';      f=$false; r=$false; b=30405; want='LEFTOVER'        },
        @{ n='ACE-CORE0';     f=$false; r=$false; b=30405; want='STALE-CORE'      }
    )
    $fail = 0
    foreach ($c in $cases) {
        $got = Get-AceClass -Name $c.n -FileExists $c.f -Running $c.r -CurrentCoreBuild $c.b
        if ($got -ne $c.want) {
            Write-Host ("FAIL  {0,-30} build={1,-6} -> got {2}, want {3}" -f $c.n, $c.b, $got, $c.want)
            $fail++
        }
    }

    # Get-CoreBuildNumber must return $null (never throw) on unparseable names.
    $parseCases = @(
        @{ n='ACE-CORE30405';                   want=30405 },
        @{ n='ACE-CORE0';                       want=0     },
        @{ n='ACE-CORE88888888888';             want=88888888888 },
        @{ n='ACE-CORE99999999999999999999999'; want=$null },   # exceeds Int64
        @{ n='ACE-COREabc';                     want=$null },
        @{ n='ACE-CORE';                        want=$null },
        @{ n='ACE-BASE';                        want=$null }
    )
    foreach ($c in $parseCases) {
        try { $got = Get-CoreBuildNumber $c.n } catch { $got = "THREW: $($_.Exception.Message)" }
        if ($got -ne $c.want) {
            Write-Host ("FAIL  parse {0,-20} -> got {1}, want {2}" -f $c.n, $got, $c.want)
            $fail++
        }
    }

    Write-Host ("SelfTest: {0}/{1} passed" -f (($cases.Count + $parseCases.Count) - $fail), ($cases.Count + $parseCases.Count))
    exit ([int]($fail -gt 0))
}

# ---------------------------------------------------------------- environment

$aceRunning = @(Get-Process -Name $AceProcess -ErrorAction SilentlyContinue)
$gameRunning = @(Get-Process -Name $GameProcess -ErrorAction SilentlyContinue)
$loadedDrv  = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
                Where-Object { $n = $_.Name; $GameDrivers | Where-Object { $n -like $_ } } |
                Where-Object { $_.State -eq 'Running' })
$aceBusy = ($aceRunning.Count -gt 0) -or ($loadedDrv.Count -gt 0) -or ($gameRunning.Count -gt 0)
if ($Sandbox) {
    # A sandbox fixture models an idle machine -- the point is to test the
    # cleanup logic, not the host's live state.
    $aceRunning = @(); $gameRunning = @(); $loadedDrv = @(); $aceBusy = $false
}

Write-Host "ACE optimization scan"
Write-Host ("  elevated   : {0}" -f (Test-Admin))
Write-Host ("  ACE busy   : {0}" -f $aceBusy)
if ($aceRunning)  { Write-Host ("  ACE procs  : {0}" -f (($aceRunning  | ForEach-Object Name) -join ', ')) }
if ($gameRunning) { Write-Host ("  games      : {0}" -f (($gameRunning | ForEach-Object Name) -join ', ')) }
if ($loadedDrv)   { Write-Host ("  game drv   : {0}" -f (($loadedDrv   | ForEach-Object Name) -join ', ')) }
Write-Host ""

# ---------------------------------------------------------------- locations

Write-Host "ACE locations:"
$locations = Get-AceLocations -Deep:$Deep
if (-not $locations) { Write-Host "  none found" }
foreach ($loc in $locations) { Write-Host ("  {0}" -f $loc) }
Write-Host ""

# Global highest build across every location that uses numbered CORE filenames.
$allBuilds = @($locations | ForEach-Object { Get-CoreBuilds $_ })
$currentBuild = if ($allBuilds.Count) { ($allBuilds | Measure-Object -Maximum).Maximum } else { $null }

# Fallback: no numbered CORE .sys on disk (uninstalled, or a game-bundled-only
# install). Trust the highest build among the service entries rather than nothing.
if ($null -eq $currentBuild) {
    $svcBuilds = @(Get-ChildItem $SvcRoot -ErrorAction SilentlyContinue |
                   ForEach-Object { Get-CoreBuildNumber $_.PSChildName } |
                   Where-Object { $null -ne $_ })
    if ($svcBuilds.Count) { $currentBuild = ($svcBuilds | Measure-Object -Maximum).Maximum }
}
Write-Host ("installed ACE-CORE build: {0}" -f $(if ($null -eq $currentBuild) { '<none found>' } else { $currentBuild }))
Write-Host ""

# ---------------------------------------------------------------- services

$rows = foreach ($key in (Get-ChildItem $SvcRoot -ErrorAction SilentlyContinue |
                          Where-Object { $_.PSChildName -like 'ACE*' -or $_.PSChildName -like 'ace-*' })) {
    $name = $key.PSChildName
    $prop = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
    $path = Resolve-DriverPath $prop.ImagePath
    $exists = Test-PathSafe $path
    $running = if ($Sandbox) { $false }
               else { ((Get-Service -Name $name -ErrorAction SilentlyContinue).Status -eq 'Running') }
    [PSCustomObject]@{
        Name  = $name
        Class = Get-AceClass -Name $name -FileExists $exists -Running $running -CurrentCoreBuild $currentBuild
        Start = $prop.Start
        File  = if ($exists) { 'yes' } else { 'MISSING' }
        Path  = $path
    }
}

Write-Host "Service entries:"
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$removable = @($rows | Where-Object { $_.Class -in 'STALE-CORE', 'LEFTOVER' })

# ---------------------------------------------------------------- bundled files

# A game-bundled ACE folder keeps every CORE build it ever staged (ACE-CORE.sys,
# .sys2, .sys3, ...). These are reported, never auto-deleted: ACE manages that
# folder itself and removing a file it expects can stop the game launching.
$dupGroups = @()
foreach ($loc in $locations) {
    $cores = @(Get-ChildItem $loc -Filter 'ACE-CORE*.sys*' -File -Force -ErrorAction SilentlyContinue)
    if ($cores.Count -gt 1) {
        $dupGroups += [PSCustomObject]@{
            Location = $loc
            Count    = $cores.Count
            Bytes    = ($cores | Measure-Object Length -Sum).Sum
            Newest   = ($cores | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name
        }
    }
}
if ($dupGroups) {
    Write-Host "Duplicate ACE-CORE files (game-bundled):"
    $dupGroups | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

# ---------------------------------------------------------------- logs

$bootLogs = @()
$logDir = if (Test-PathSafe $InstallDir) { $InstallDir } else { $null }
if ($logDir) {
    $bootLogs = @(Get-ChildItem $logDir -Filter 'ace-boot-*.log' -Force -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
}
$oldLogs  = @($bootLogs | Select-Object -Skip $KeepBootLogs)
$logBytes = ($oldLogs | Measure-Object Length -Sum).Sum
if ($null -eq $logBytes) { $logBytes = 0 }

Write-Host ("boot logs    : {0} present, {1} older than the newest {2} ({3:N1} MB)" -f `
    $bootLogs.Count, $oldLogs.Count, $KeepBootLogs, ($logBytes / 1MB))
$trayValue = (Get-ItemProperty $RunKey -Name 'ACE-Tray' -ErrorAction SilentlyContinue).'ACE-Tray'
Write-Host ("tray auto-run: {0}" -f $(if ($trayValue) { $trayValue } else { '<not set>' }))
Write-Host ""

# ---------------------------------------------------------------- report

$report = [ordered]@{
    Stamp         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Computer      = $env:COMPUTERNAME
    Applied       = [bool]$Apply
    Elevated      = (Test-Admin)
    AceBusy       = $aceBusy
    BusyDetail    = @($aceRunning + $gameRunning | ForEach-Object Name)
    CurrentBuild  = $currentBuild
    Locations     = @($locations)
    Rows          = @($rows)
    Removable     = @($removable)
    DupGroups     = @($dupGroups)
    BootLogCount  = $bootLogs.Count
    OldLogCount   = $oldLogs.Count
    OldLogBytes   = $logBytes
    TrayValue     = $trayValue
    BackupDir     = $BackupDir
    Actions       = New-Object System.Collections.Generic.List[object]
    Refusal       = $null
}

Write-Host "SUMMARY:"
Write-Host ("  stale/leftover service entries : {0}" -f $removable.Count)
Write-Host ("  reclaimable boot-log bytes     : {0}" -f $logBytes)
if ($removable) {
    Write-Host "  -> registry-only: their driver files are already gone, but the"
    Write-Host "     Service Control Manager still tries to load each one at boot."
}
if ($dupGroups) {
    Write-Host ("  -> {0} location(s) hold duplicate CORE builds. Left alone by default:" -f $dupGroups.Count)
    Write-Host "     ACE manages those files; remove them with -PurgeDriverFiles if you accept the risk."
}
if (-not $Deep) {
    Write-Host "  -> run with -Deep to also search game folders for bundled ACE copies."
}

# ---------------------------------------------------------------- apply

if (-not $Apply) {
    Write-Host ""
    Write-Host "Report only. Re-run with -Apply to make these changes."
    Write-AceReport -Report $report -Path $ReportPath -Sandbox:$Sandbox -BackupDir $BackupDir
    exit 0
}

if ($aceBusy) {
    $report.Refusal = 'ACE or a game is running'
    Write-Host ""
    Write-Host "REFUSING TO APPLY: ACE or a game is running. Close the game and the ACE tray, then retry."
    Write-Host "Cleaning while ACE is live can trip anti-cheat integrity checks."
    Write-AceReport -Report $report -Path $ReportPath -Sandbox:$Sandbox -BackupDir $BackupDir
    exit 2
}

if (-not $Sandbox -and -not (Test-Admin)) {
    $report.Refusal = 'not elevated'
    Write-Host ""
    Write-Host "REFUSING TO APPLY: not elevated. Re-run from an Administrator terminal."
    Write-AceReport -Report $report -Path $ReportPath -Sandbox:$Sandbox -BackupDir $BackupDir
    exit 3
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

foreach ($r in $removable) {
    if ($Sandbox) {
        # The fixture is HKCU-only, so a plain Remove-Item on the key stands in for
        # `sc delete`. Record the would-be action in the backup dir as the artifact.
        $regFile = Join-Path $BackupDir "$($r.Name).$stamp.reg"
        Set-Content -Path $regFile -Value "sandbox: would export HKLM\SYSTEM\CurrentControlSet\Services\$($r.Name)" -Encoding UTF8
        try {
            Remove-Item -Path (Join-Path $SvcRoot $r.Name) -Recurse -Force
            Write-Host ("  removed  {0,-16} [{1}]  (sandbox)" -f $r.Name, $r.Class)
            $report.Actions.Add([ordered]@{ Kind='service'; Name=$r.Name; Status='removed'; Detail=$r.Class })
        } catch {
            Write-Host ("  FAILED   {0} ({1})" -f $r.Name, $_.Exception.Message)
            $report.Actions.Add([ordered]@{ Kind='service'; Name=$r.Name; Status='failed'; Detail=$_.Exception.Message })
        }
        continue
    }
    $regPath = "HKLM\SYSTEM\CurrentControlSet\Services\$($r.Name)"
    $regFile = Join-Path $BackupDir "$($r.Name).$stamp.reg"
    & reg.exe export $regPath $regFile /y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  SKIP     {0} (backup failed, exit {1})" -f $r.Name, $LASTEXITCODE)
        $report.Actions.Add([ordered]@{ Kind='service'; Name=$r.Name; Status='skipped'; Detail="backup failed (exit $LASTEXITCODE)" })
        continue
    }
    & sc.exe delete $r.Name | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  removed  {0,-16} [{1}]  backup: {2}" -f $r.Name, $r.Class, (Split-Path $regFile -Leaf))
        $report.Actions.Add([ordered]@{ Kind='service'; Name=$r.Name; Status='removed'; Detail="$($r.Class); backup $(Split-Path $regFile -Leaf)" })
    } else {
        Write-Host ("  FAILED   {0} (sc delete exit {1})" -f $r.Name, $LASTEXITCODE)
        $report.Actions.Add([ordered]@{ Kind='service'; Name=$r.Name; Status='failed'; Detail="sc delete exit $LASTEXITCODE" })
    }
}

# Old boot logs. Each session writes a fresh ~2 MB file and they never rotate.
foreach ($log in $oldLogs) {
    try {
        Remove-Item $log.FullName -Force
        Write-Host ("  removed  {0}" -f $log.Name)
        $report.Actions.Add([ordered]@{ Kind='log'; Name=$log.Name; Status='removed'; Detail=("{0:N0} KB" -f ($log.Length/1KB)) })
    } catch {
        Write-Host ("  SKIP     {0} ({1})" -f $log.Name, $_.Exception.Message)
        $report.Actions.Add([ordered]@{ Kind='log'; Name=$log.Name; Status='skipped'; Detail=$_.Exception.Message })
    }
}

if ($PurgeDriverFiles -and $dupGroups) {
    # Opt-in. Superseded builds are MOVED to the backup folder, not deleted, so a
    # game that objects can be repaired by moving them back.
    foreach ($g in $dupGroups) {
        $cores = @(Get-ChildItem $g.Location -Filter 'ACE-CORE*.sys*' -File -Force -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)
        foreach ($f in ($cores | Select-Object -Skip 1)) {
            $dest = Join-Path $BackupDir ("{0}-{1}" -f $g.Location.Replace(':\', '_').Replace('\', '_'), $f.Name)
            try {
                Move-Item $f.FullName $dest -Force
                Write-Host ("  moved    {0}  (from {1})" -f $f.Name, $g.Location)
                $report.Actions.Add([ordered]@{ Kind='driver-file'; Name=$f.Name; Status='moved'; Detail=$g.Location })
            } catch {
                Write-Host ("  SKIP     {0} ({1})" -f $f.Name, $_.Exception.Message)
                $report.Actions.Add([ordered]@{ Kind='driver-file'; Name=$f.Name; Status='skipped'; Detail=$_.Exception.Message })
            }
        }
    }
}

if ($DisableTrayAutostart -and $trayValue) {
    # ACE-Tray is what keeps ACE resident between games. Disabling it means ACE
    # only spins up at game launch -- lower idle footprint, slower first launch.
    if ($Sandbox) {
        Set-Content -Path (Join-Path $BackupDir "Run.$stamp.reg") `
            -Value "sandbox: would export HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Encoding UTF8
    } else {
        & reg.exe export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
            (Join-Path $BackupDir "Run.$stamp.reg") /y | Out-Null
    }
    Remove-ItemProperty -Path $RunKey -Name 'ACE-Tray' -Force -ErrorAction SilentlyContinue
    Write-Host "  removed  ACE-Tray auto-run entry (backed up)"
    $report.Actions.Add([ordered]@{ Kind='autostart'; Name='ACE-Tray'; Status='removed'; Detail='auto-run entry' })
}

Write-Host ""
Write-Host ("Backups: {0}" -f $BackupDir)
Write-Host "A reboot clears the removed driver entries from the loaded-driver list."
Write-AceReport -Report $report -Path $ReportPath -Sandbox:$Sandbox -BackupDir $BackupDir
