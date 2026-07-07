# Bugfix: CI Flaky-Test Detection

## Problem

The CI flaky-test wrapper retries failed Xcode tests in isolation and previously
allowed the job to pass when those isolated retries succeeded. That can hide a
deterministic suite-order or shared-state failure: the full Xcode suite can fail
reliably, while each failed test still passes when run alone.

## Impact

- CI can go green even though the same full-suite command remains red.
- Order-dependent failures and shared mutable test state are mislabelled as
  allowed flakiness.
- Reviewers lose the signal that the failing behavior still exists in the
  production CI command.

## Requirements

1. Isolated retries may be used to identify likely flaky tests, but they must not
   be sufficient to pass CI by themselves.
2. After all isolated retries pass, CI must re-run the full Xcode suite before
   returning success.
3. If the full-suite confirmation fails, CI must fail and report the condition
   as order-dependent or shared-state failure.
4. Test-runner, bootstrap, and build failures must not be passed to
   `-only-testing:` as if they were individual test cases.
5. The flaky report and documentation must expose whether full-suite
   confirmation was required and whether it passed.
6. The wrapper must remain compatible with the system Bash shipped on macOS 26.
