---
name: ace-optimization
description: Cleans up stale Tencent AntiCheatExpert (ACE) leftovers on Windows — the accumulated old ACE-CORE kernel-driver service entries that every ACE update leaves behind and that Windows keeps trying to load at boot. Use this whenever the user says "优化ace", "ACE优化", "清理ace", "ace旧版本", "游戏掉帧", "掉帧卡死", "ACE占资源", "AntiCheatExpert", "反作弊优化", "优化反作弊", "游戏卡", or reports stuttering / frame drops / freezes in a Tencent game (三角洲行动, 无畏契约, 穿越火线, CF, DNF, 英雄联盟, 王者荣耀, 和平精英, Delta Force, Valorant, CrossFire, LoL) and ACE is installed. Also trigger when they mention `C:\Program Files\AntiCheatExpert`, `SGuard`, `ACE-CORE`, `ACE-BASE`, `ACE-Tray`, or ask why there are several ACE versions on their machine. Trigger even for a vague "电脑卡" when ACE is present — the fix is usually the same stale-driver cleanup.
---

# ACE Optimization

Clean up Tencent AntiCheatExpert (ACE) leftovers: stale kernel-driver service
entries, orphaned driver files, and the unbounded boot-log pile.

## What is actually wrong

ACE ships a versioned kernel driver per update: `ACE-CORE<build>.sys`, e.g.
`ACE-CORE30405.sys`. On every update ACE does three things:

1. registers a **new** service key `ACE-CORE<build>`
2. installs its `.sys` into `C:\Program Files\AntiCheatExpert\` and/or
   `C:\Windows\System32\drivers\`
3. deletes the **previous** build's `.sys` file

It never deletes the previous build's **service key**. So after a few updates the
registry holds several `ACE-CORE*` entries — `ACE-CORE10405`, `ACE-CORE20405`,
`ACE-CORE30405` — most pointing at a `.sys` file that no longer exists. Windows'
Service Control Manager still enumerates and attempts to load each one at boot.
That is the "多个旧版本同时存在" the user sees.

Say this plainly to the user. Their mental model is right about the cause and
slightly off about the effect: the stale entries are not *running* — they are
registry-only residue whose driver files are already gone. That distinction
matters, because it tells them this is registry hygiene, not a process kill.

Be honest about what this fixes. The residue costs boot-time enumeration, not
in-game frames — nothing is loaded from a dead key. So if the user's complaint is
stutter *during* play, say that the cleanup is worth doing but may not be the fix,
and name the likelier causes (GPU driver, VRAM/RAM pressure, background
antivirus or recording software, thermal throttling, game settings) rather than
implying the cleanup will cure it. Overpromising here costs more trust than the
cleanup buys, and the user will come back with the same symptom.

### Two separate messes

There are two different kinds of ACE leftover, and they need different handling:

- **Stale service keys** (system install, `C:\Program Files\AntiCheatExpert`) —
  registry-only, safe to delete, this is the main fix.
- **Bundled duplicate driver files** (some games ship their own ACE copy; Valorant
  under `...\ShooterGame\Binaries\Win64\AntiCheatExpert\` is the common one) — a
  game folder can hold five stacked `ACE-CORE.sys`, `.sys2`, `.sys3`, `.sysa`,
  `.sysa2` builds totalling ~16 MB. These are **reported, not auto-deleted.** ACE
  manages that folder itself, and removing a file it expects can stop the game
  launching. Only touch them with `-PurgeDriverFiles`, and only if the user
  accepts that tradeoff.

### What must not be touched

`ACE-BASE`, `ACE-BOOT`, `ACE-GAME`, `ACE-ADVT`, `ACE-SSC-DRV64`, and the current
`ACE-CORE<build>` are live anti-cheat components. Removing them, or disabling the
ACE services wholesale, is what trips anti-cheat integrity checks and gets
accounts banned. Never do it, and never suggest it — if the user pushes for it,
say plainly that it risks a ban on their game account.

## Workflow

### 1. Scan

Read-only, instant. This also writes the HTML report and opens it:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/optimize-ace.ps1
```

Add `-Deep` to also walk fixed drives for game-bundled ACE folders. That walk
costs 30–60s, so use it when the user's symptoms persist after the basic scan, or
when they mention a specific game folder. A plain `C:\Program Files` +
`C:\ProgramData` scan will not find a bundled copy.

If the scan reports `ACE busy : True`, a game session is live. Do not clean yet —
tell the user to close the game and the ACE tray first.

### 2. Report before changing

Show the user the findings: how many stale entries, which ones, and where any
duplicate CORE files are. Users asking to "optimize ACE" generally have no idea
the residue is registry keys, so one sentence on the mechanism plus the list of
what will be removed is worth more than a silent fix. The generated HTML report
already lays this out — point the user at it and summarise in the chat.

### 3. Apply

Needs Administrator and a closed game. The script refuses on its own if either is
missing, so you can run it without pre-checking:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/optimize-ace.ps1 -Apply
```

Each removed key is exported to a `.reg` backup under `~/ace-optimization-backup/`
before deletion, so the change is reversible. Tell the user where the backup went.

### 4. Confirm

Re-run the scan and show the summary. A clean machine reports zero stale entries.
Tell the user to reboot — removed entries stay in the loaded-driver list until then.
Finish by telling the user where the HTML report is and what its headline says.

## The HTML report

Every run writes a self-contained HTML report and (on a real run) opens it. The
**script** produces it, not you — so the report is identical whether this skill is
driven by Claude Code, Doubao, or any other harness, and you spend no tokens
rendering it. Your job is to tell the user where it is and what it says.

- Real run: `<Desktop>\ace-report-<timestamp>.html`, opened automatically.
- Override the location with `-ReportPath <file.html>`.
- The file is standalone: inline CSS, no external fonts or scripts, so it works by
  double-click with no network. Light and dark mode both handled.

It leads with the verdict ("已清理 3 项" / "发现 3 个可清理项" / "没有发现需要清理的
东西"), then the service table, duplicate-file folders, the actions actually taken,
and the backup path. It also carries the honesty note from above, so a user who
reads only the report still learns the cleanup may not fix in-game stutter.

A report is written on every exit path — scan, apply, and refusal — so the user
always gets something to open. If a run refuses (ACE busy, not elevated), the
report says so in the headline rather than reporting a phantom cleanup.

## Verifying the tool itself

This skill is meant to be handed to other people and run on machines you cannot
see. Before trusting it on a real machine — and any time `scripts/optimize-ace.ps1`
changes — run its self-tests. Both are safe: they never touch the real registry or
a real ACE install.

```bash
# Pure logic check (classification), ~1s
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/optimize-ace.ps1 -SelfTest

# Simulated machines: builds throwaway fixtures under %TEMP% and asserts
# scan + cleanup behaviour on each. ~30s
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-fixtures.ps1
```

`test-fixtures.ps1` covers six machine states, because "works on the one machine
I looked at" is not the same as "works on the user's machine":

| Scenario | Models |
|---|---|
| `messy` | The common case — several superseded builds, plus a non-CORE leftover |
| `clean` | A healthy machine; the tool must report nothing and change nothing |
| `midupdate` | A build newer than the installed one — must be left alone |
| `bundled` | System install plus a game folder with 5 stacked CORE drivers |
| `uninstalled` | ACE removed, keys left behind; no on-disk build to compare against |
| `adversarial` | Hostile input: build numbers too big for a 64-bit integer, empty/UNC/nonexistent-drive/relative `ImagePath`, a missing `ImagePath`, a wrong-typed one |

The `adversarial` scenario matters more than it looks. The scanner reads names
and paths it did not create, from machines you cannot see, so any single throw
aborts the whole scan — the user sees a clean-looking report while every later
entry goes unexamined. A silent truncation is worse than a loud failure, which is
why the fixture asserts the scan printed a `SUMMARY` line and not merely that it
exited.

If you change the classification logic, add a scenario for whatever you changed
rather than only editing the existing ones.

The `-Sandbox`, `-SvcRoot`, `-RunKey` and `-InstallDir` parameters exist for this
testing. They are not for normal use — a sandbox apply writes only to a fixture
under `HKCU`, never to the real service tree.

## Optional flags

Reach for these only when the user asks for more than the default cleanup, and
state the tradeoff before using them.

| Flag | Effect | When it is worth it |
|---|---|---|
| `-Deep` | Also search game folders for bundled ACE copies | Symptoms persist after the basic clean, or the user names a game path |
| `-PurgeDriverFiles` | Moves superseded bundled `ACE-CORE*` files into the backup folder | Only if the user wants the ~16 MB back and accepts that ACE may object. Moved, not deleted, so it can be undone |
| `-DisableTrayAutostart` | Removes the `ACE-Tray` auto-run entry | When the user wants ACE not resident between games. Tradeoff: ACE does its setup at game launch instead, so first launch is slower |
| `-KeepBootLogs <n>` | How many `ace-boot-*.log` files survive (default 2) | Each game session writes a fresh ~2 MB log and they never rotate on their own |

## Reading the output

| Class | Meaning | Action |
|---|---|---|
| `STALE-CORE` | Old `ACE-CORE<build>`, build < installed, file gone | Remove |
| `LEFTOVER` | Non-CORE ACE entry whose file is gone | Remove |
| `CURRENT` | Current build, or file present | Leave |
| `ACTIVE` | Currently running | Leave |
| `AHEAD-OF-INSTALL` | Build newer than installed — ACE is mid-update | Leave, and do not clean until it settles |
| `CORE-UNVERIFIED` | No numbered `ACE-CORE*.sys` on disk to compare against | Investigate before acting |

`CORE-UNVERIFIED` means ACE is uninstalled or mid-install, or the machine only has
a game-bundled copy (which uses unnumbered `ACE-CORE.sys`). Do not guess which
entry is current — ask the user whether ACE is installed, or run `-Deep`.

## Guardrails

- Scan first and let the user see it. Never jump straight to `-Apply`.
- Never clean while a game is running. The script blocks this; do not work around it.
- The script is idempotent. If it finds nothing, say so rather than manufacturing a fix.
- Do not delete the ACE install directory, and do not "uninstall and reinstall ACE"
  as a first move. The residue survives reinstall — that is the whole point.
- If `-Apply` fails with an access error despite elevation, ACE's self-protection is
  holding the key. Report it; do not escalate to taking ownership of the key or
  suspending ACE's protection.
- Never modify files inside a game's own ACE folder without explicit user consent.
