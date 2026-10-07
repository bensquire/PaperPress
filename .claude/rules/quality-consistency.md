---
title: Match the Code Around You
impact: HIGH
impactDescription: One idiom for one job, so a reader learns it once
tags: [quality, consistency, idioms, reuse]
paths: ["Sources/**/*.swift", "Tests/**/*.swift"]
---

## Match the Code Around You

**Impact: HIGH**

New code reads like the file it lands in: the same naming, comment density,
error style (`PressError` for the engine, `PaperPressTools.ToolFailure` for an
assistant's answer), and idioms. Before writing a helper, look for the one that
exists — `Pipeline.histogram`, `Pipeline.otsuThreshold`,
`GrayImage.resampled(scale:)`, `levelled()`, `jpegData(quality:dpi:)`,
`ImageEncode.png`, `PDFRender.gray(page:dpi:)`, `OutputPlan.isSameFile`,
`PDFInspector.isPaperPressOutput`, `byteLabel(_:)` for a size as Finder writes
it, `PassReason.label` for a verdict — and call it. In tests, `Fixtures` has the
page builders (`textPage`, `blockPage`, `photoPage`, `renderedTextPage`), the
PDF builders (`scannedPDF`, `g4PDF`, `bornDigitalPDF`, `drawnPDF`) and the
readers (`rendered`, `pageText`, `contentStream`); `FixtureTestCase` gives each
test its temp directory, `AppModelTestCase` its model and `waitFor`, and
`assertThrowsAsync` checks awaited errors. A second spelling of the same thing
is a bug waiting for one of them to drift.

**Incorrect (a fresh spelling of an existing helper):**

```swift
let out = try Data(contentsOf: url)
let page = CGPDFDocument(CGDataProvider(data: out as CFData)!)!.page(at: 1)!
// … forty lines of CGContext setup to rasterise it
```

**Correct:**

```swift
let page = try Fixtures.rendered(url, dpi: 150)
```
