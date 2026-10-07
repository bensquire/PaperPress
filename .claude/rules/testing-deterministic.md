---
title: Every Run Gives the Same Answer
impact: HIGH
impactDescription: A flaky test is a test nobody trusts
tags: [testing, determinism, fixtures, clock]
paths: ["Tests/**/*.swift"]
---

## Every Run Gives the Same Answer

**Impact: HIGH**

Fixtures are drawn in code, never fetched or committed: `Fixtures` builds every
page and PDF, and anything random in them comes from `SeededRandom`, so the
same bytes come out on every run. No network. No wall-clock dependence: a type
that ages things takes the clock (`Inbox.sweep(_:now:)`), and a test that waits
on the app's model polls its state with `waitFor`, which fails with what it was
waiting for on timeout, rather than sleeping for luck. No dependence on another
test having run first or on the order tests run in: each test gets its own temp
directory from `FixtureTestCase`; a test that turns Assistants on hands
`AppModel` a suite-named `UserDefaults` and a socket path of its own, so it
never touches the user's settings or a running PaperPress; and a test that sets
an `@AppStorage` value removes it in `tearDown`. A test of the assistant tools
stands a `FakeLink` and a `FakeLauncher` in for the app, so it never opens
PaperPress.

A bound that rests on rendering — CoreText type, Vision's reading — is set wide
enough to hold across OS versions, and says so, as the damage-calibration bands
do.

**Incorrect:**

```swift
try await Task.sleep(for: .seconds(1))                           // hope the queue got there
Inbox.sweep(inbox)                                               // and wait a real day?
```

**Correct:**

```swift
try await waitFor("job over") { model.job(id)?.state.isTerminal == true }
Inbox.sweep(inbox, now: Date().addingTimeInterval(2 * Inbox.keptFor))
```
