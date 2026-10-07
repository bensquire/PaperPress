---
title: Add a Case and Its Behaviour, Not an `if`
impact: HIGH
impactDescription: A special case on shared infrastructure is a band-aid the next change tears off
tags: [quality, extensibility, altitude, design]
paths: ["Sources/**/*.swift"]
---

## Add a Case and Its Behaviour, Not an `if`

**Impact: HIGH**

The places PaperPress grows are enumerations with one mechanism behind them: a
`PDFInspector.PassReason` is a case with its label (`PressJobs`) and its help
text (`AppModel`), each an exhaustive `switch`; a
`Converter.PageEncoding` is derived from the `PDFWriter.Content` a page was
written with — "derived, not tracked in parallel, so a new branch can't forget
to record it"; a `DemotedTextFormat` is a case the converter switches on and
the MCP `preview` tool lists. Adding a verdict or an encoding means adding a
case and its behaviour, and letting the compiler's exhaustive `switch` find
every place that has to say something about it — not an `if` in the converter
for the new one.

When a change wants a special case on shared code, the fix is usually one level
deeper: make the shared mechanism carry what the case needs (the damage
backstop on the one G4 decision, rather than a second check for small print).

**Incorrect (the converter learns about one case on the side):**

```swift
var usedJPEG = false
if isPhoto { usedJPEG = true }   // a second record of what the page became
```

**Correct (the case carries it, through the one mechanism):**

```swift
private static func encoding(of content: PDFWriter.Content) -> PageEncoding {
    switch content {
    case .g4: .g4
    case .gray4Flate: .gray4
    case .jpegGray: .jpeg
    case .original: .original
    }
}
```
