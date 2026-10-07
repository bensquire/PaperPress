---
title: Formatting Is Decided by the Tool
impact: MEDIUM
impactDescription: No formatting diffs, no style arguments in review, no drift between machines
tags: [quality, formatting, swift-format, lint]
paths: ["Sources/**/*.swift", "Tests/**/*.swift", "Package.swift", ".swift-format"]
---

## Formatting Is Decided by the Tool

**Impact: MEDIUM**

Apple's `swift format`, the one that ships with the toolchain, and
`.swift-format` are the style: four-space indents, 110-column lines, ordered
imports, no semicolons or block comments, shorthand type names. `make lint`
runs it with `--strict` over `Sources`, `Tests` and `Package.swift`, so a
warning fails; CI's first step and the pre-commit hook run the same target.
`make format` rewrites in place. There is no SwiftLint here.

`NeverForceUnwrap`, `NeverUseForceTry` and `NeverUseImplicitlyUnwrappedOptionals`
are on, so a nil or a thrown error goes down the path the code already has for
failure — a `guard` that returns or throws, a `try` that propagates — rather than
crashing a batch. Where a value truly cannot be nil, say why in a comment and put
`// swift-format-ignore: NeverForceUnwrap` on the line above it.

Run `make lint` before handing over, and fix what it reports rather than
formatting around it by hand. Run `make format` over the files you changed, not
the whole tree in a change that is about something else: a reformat of
untouched files buries the change in the diff.

**Incorrect:**

```swift
import XCTest
import CoreGraphics;   // unordered, and a semicolon the config forbids
/* disabled for now */
```

**Correct:**

```swift
import CoreGraphics
import XCTest
```
