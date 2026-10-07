---
title: A Comment Is Short, and Says Why
impact: HIGH
impactDescription: A comment costs every reader time and every token money; it earns that or it goes
tags: [quality, comments, documentation, measurements, brevity]
paths: ["Sources/**/*.swift", "Tests/**/*.swift"]
---

## A Comment Is Short, and Says Why

**Impact: HIGH**

A comment adds what the code cannot say — why this, what was measured, what was
rejected — in as few plain words as will still read. It does not restate a
method or property name. A claim carries its measurement: the page or fixture,
before, after. A constant carries the measurement that set it, as
`photoDpiCap`, `ocrDpi` and `estimatedBytesPerPixel` do. Where a decision rests
on Apple's documentation, the page's path goes in the comment
(`/documentation/coregraphics/cgpdfbox/cropbox`). No flourish, no anecdote told
twice, no comment about code that has gone.

**Incorrect (restates the name; no provenance; flowery):**

```swift
/// The photo DPI cap.
public var photoDpiCap = 200

/// After a great deal of careful experimentation we found that a lower
/// resolution works really well for most photographs …
```

**Correct (the why and the number, then stop):**

```swift
/// Photographic pages are stored at their native resolution up to
/// this. Measured on a real photograph scanned at 300 dpi: 200 dpi
/// JPEG q0.6 is 2.4 dB truer on screen than 150 dpi (40.8 vs 38.4
/// PSNR) for 58% more bytes — a better trade than raising the JPEG
/// quality, which bought 0.6 dB for 43% more.
public var photoDpiCap = 200
```
