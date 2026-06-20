# Blocker Classification

How to triage issues found in review, testing, or use. Mirrors the review priorities in [`AGENTS.md → Review guidelines`](AGENTS.md#review-guidelines). GitHub surfaces only **P0** and **P1**.

| Priority | Severity | Meaning | Examples (this project) | Gate |
|---|---|---|---|---|
| **P0** | critical | Blocks merge/release; data loss, crash, or core invariant broken | Wrong composition math; main-actor stall during export/decode; security scope leak; clips silently dropped; writing outside user-selected paths; build broken | Must fix before merge |
| **P1** | high | Serious; ship only with explicit, tracked sign-off | Preview/export diverge; silent failure (error swallowed); missing accessibility label on icon-only control; full-composition rebuild on every slider tick | Fix before release; track if deferred |
| **P2** | medium | Should fix; not release-blocking | Minor UX papercut, non-critical copy, suboptimal but correct algorithm | Backlog |
| **P3** | low | Nice to have | Polish, micro-optimizations without measured impact | Optional |

## Rules

1. **Correctness, concurrency, resource-safety, sandbox, and data-loss issues are P0** by default — see the P0 list in `AGENTS.md`.
2. A bug that makes **preview and export disagree** is at least **P1** (the one-render-path invariant).
3. When unsure between two levels, pick the higher and note the reasoning.
4. P0/P1 get a `tasks.md` entry (or a bugfix spec under `.kiro/specs/bugfix-*`) before the fix lands.

## Bugfix specs

Non-trivial fixes use a spec folder `.kiro/specs/bugfix-<slug>/` with `bugfix.md` (instead of `requirements.md`), `design.md`, and `tasks.md`.
