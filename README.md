# skills

Agent skills.

## Install

```bash
npx skills add BingLi37/skills@grokbot-icon
npx skills add BingLi37/skills@ace-optimization
```

Or copy the skill folder into your agent's skills directory (for Claude Code: `~/.claude/skills/`).

## Contents

| Skill | What it does |
|---|---|
| [`grokbot-icon`](grokbot-icon/SKILL.md) | Turns an uploaded reference image into a minimal 2D bot-face icon — 1:1, solid charcoal background, two black capsule eyes. Keeps only the reference's hair color, hair silhouette, and signature accessory. |
| [`ace-optimization`](ace-optimization/SKILL.md) | Cleans up stale Tencent AntiCheatExpert (ACE) leftovers on Windows — the accumulated `ACE-CORE` driver service entries every ACE update leaves behind, plus duplicate game-bundled drivers and unbounded boot logs. Writes a self-contained HTML report to the Desktop that opens by double-click. |
