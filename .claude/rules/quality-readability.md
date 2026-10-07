---
title: Code Reads Like the Prose Around It
impact: HIGH
impactDescription: The next reader is a person, usually months later, often the author
tags: [quality, readability, naming]
paths: ["Sources/**/*.swift", "Tests/**/*.swift"]
---

## Code Reads Like the Prose Around It

**Impact: HIGH**

Names say what a thing is in the words the domain uses — `isPaperPressOutput`,
`checkDestination`, `minSavingFraction`, `removeScanBorders`, `firstCollision` —
so a call site reads as a sentence. Short names are right where the convention
uses them (`g` for a gray image, `bw` for a binary one, `dpi`, `i`) and wrong
anywhere else. A function does what its name says and nothing more; one that
needs "and" in its name is two. Nesting is shallow; the early `guard` says what
a function refuses. A trick that needs a comment to decode earns its place only
when it is necessary, and then the comment says why, with the measurement.

**Incorrect:**

```swift
func chk(_ a: URL, _ b: URL, _ f: Bool) throws -> Bool {
    if f { if FileManager.default.fileExists(atPath: a.path) { /* … forty lines … */ } }
    return false
}
```

**Correct:**

```swift
/// The output may replace only what PaperPress wrote before, or a file
/// byte-identical to the source.
static func checkDestination(_ dst: URL, source: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: dst.path) else { return false }
    …
}
```
