---
title: Dependencies and Settings Are Handed In as Values
impact: HIGH
impactDescription: Code that reaches for a global cannot be tested, varied or reused without it
tags: [quality, dependency-injection, values, testability]
paths: ["Sources/**/*.swift", "Tests/**/*.swift"]
---

## Dependencies and Settings Are Handed In as Values

**Impact: HIGH**

A type takes its collaborators and its settings as values, and whoever calls
it hands them in. `Converter.convert(report:to:settings:)` takes a
`Converter.Settings`; `PaperPressTools` takes its link to the app, its launcher
and its working directory at init; `Automation` takes its `UserDefaults` and
socket path; `Inbox.sweep(_:now:)` takes the clock. The environment and the
disk's preferences are read only at the edges: `PaperPressApp` reads
`PAPERPRESS_FOLDER`, `SettingsStore.load(_:)` turns stored defaults into a
`Settings` value once, and `paperpress-mcp/main.swift` builds the real link and
launcher. Tests hand in a temp directory, a suite-named `UserDefaults`, a
`FakeLink` and a `FakeLauncher`.

When a knob is added, it is added once — on the type that uses it, usually
`Converter.Settings` — and reached through the value that carries it, not
mirrored as a second flag on every caller.

**Incorrect (a setting read from the defaults inside the converter; the clock read inside the sweep):**

```swift
let ocr = UserDefaults.standard.bool(forKey: "ocrEnabled")   // inside Converter
if Date().timeIntervalSince(added) > Inbox.keptFor { … }      // no way to test "a day later"
```

**Correct:**

```swift
let result = try await Converter.convert(report: report, to: out, settings: settings)
Inbox.sweep(inbox, now: Date().addingTimeInterval(2 * Inbox.keptFor))
```
