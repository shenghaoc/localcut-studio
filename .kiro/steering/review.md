---
inclusion: manual
---

# Code Review Policy

Applies to **all review agents** (Claude, Gemini, Kiro, Codex). Loaded on demand —
reference it with `#review` when reviewing a PR.

> **Single source of truth:** the priority-classified checklist (P0/P1) and the
> review method live in [AGENTS.md → Review guidelines](../../AGENTS.md#review-guidelines)
> so every agent reads one list and nothing drifts. Codex reads `AGENTS.md`
> directly; Kiro/Claude get it via `CLAUDE.md` → `@AGENTS.md`. **Do not restate the
> checklist here — extend it in `AGENTS.md`.** This file adds only the process and
> output format that `AGENTS.md` doesn't carry.

Severity ↔ priority mapping: **critical → P0**, **high → P1** (GitHub surfaces only P0/P1).

## Review Process

Run the Method in [AGENTS.md → Review guidelines](../../AGENTS.md#review-guidelines), then:

1. Confirm the PR matches the spec it claims (`.kiro/specs/<name>/tasks.md`); note tasks done vs. outstanding.
2. Build with `BuildProject` (or `xcodebuild`) and run the suite before judging behaviour.
3. Verify preview and export still share one render path.
4. Scan for resource leaks (unbalanced security scope, un-removed observers, uncancelled `Task`s) before approving.

## Output Format

- **Overview** — approach and soundness.
- **Automated Review Status** — resolved vs. open bot findings.
- **Issues Found** — priority (P0/P1), `file:line`, impact, fix.
- **Positives** — what the PR does well.
- **Summary** — two to three sentences.

## Platform-Specific Review Tooling

- **Claude**: `@claude review` PR comment (see `.github/workflows/claude.yml`).
- **Kiro**: review hooks configured in `.kiro/`.
- **Gemini / Codex**: `/gemini review`, `@codex review`.
