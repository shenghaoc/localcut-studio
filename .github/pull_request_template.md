## Summary

<!-- Briefly describe what this PR does and why. Link the spec it implements. -->

Spec: `.kiro/specs/<name>/` <!-- e.g. feature-colour-grading -->

## Checklist

### Spec & Documentation

- [ ] Changes match the linked spec's `tasks.md`; completed tasks are checked off
- [ ] User-facing changes are documented in `docs/`
- [ ] New keyboard shortcuts are documented in the shortcuts reference

### Quality Gates

- [ ] `xcodebuild` (Debug, macOS) builds cleanly
- [ ] Tests pass; test count has not decreased for non-trivial logic
- [ ] Preview and export still share one render path (no effect in only one path)
- [ ] No resource leaks (security scope balanced, time observers removed, `Task`s cancelled)
- [ ] Heavy work (decode/export/large IO) is not left blocking the main actor

### Accessibility

- [ ] Icon-only controls have an accessibility label (not just `.help`)
- [ ] Interactive elements are keyboard-accessible; focus is visible; no traps
- [ ] Text uses system text styles (Dynamic Type); layout reflows at large sizes

### Self-Review

- [ ] I reviewed my own diff for logic errors, races, and dead code
- [ ] Error paths surface a user-visible message (no silent failures)
- [ ] Comments accurately describe the code they accompany
