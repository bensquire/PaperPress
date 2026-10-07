---
title: Fast Where It Counts, and Measured
impact: HIGH
impactDescription: OCR dominates a page's wall clock, and a full-page table at 300 dpi is a hundred megabytes; everything else is written for the reader
tags: [quality, performance, memory, concurrency, ocr]
paths: ["Sources/PressKit/**/*.swift", "Sources/PressApp/AppModel+Queue.swift", "Sources/PressApp/AppModel.swift"]
---

## Fast Where It Counts, and Measured

**Impact: HIGH**

The cost is in a few places, and each carries its measurement where it is
decided:

- **OCR**, which dominates a page's wall clock, reads a 150 dpi grayscale
  (`Converter.ocrDpi`): as accurate as the 300 dpi 1-bit page, at about 2.4×
  less time.
- **Pixel passes at 300 dpi.** Sauvola's integrals are built per band of
  `sauvolaBandRows` rows — about 7 MB transient against about 140 MB for two
  full-page tables on an A4 — and despeckling avoids a page-sized label map
  (35 MB).
- **The queue's fan-out.** With OCR on, two files convert at once: Vision reads
  two together (two copies of a 3-page letter took 2.5 s against 2.2 s for
  one) and each more holds another 75–90 MB of pages for little. With OCR off,
  up to four.
- **Analysis**, which parses rather than renders: a few milliseconds a file,
  fanned out across the cores in `PDFInspector.inspectAll`.

Which code is hot is decided by measuring — `time` on a real folder, the
suite's own figures, a page's size before and after — and a comment on a fast
path says what it cost before and after. Prose code stays prose; a hot path
does not allocate a page-sized buffer per call.

**Incorrect (unbounded fan-out; a full-page table where a band would do):**

```swift
for item in work { group.addTask { await Self.convert(item, settings: settings) } }  // 200 files at once
var integral = [UInt64](repeating: 0, count: (g.width + 1) * (g.height + 1))         // per page, twice
```

**Correct (bounded, banded, and the measurement kept):**

```swift
// With OCR on, two: Vision reads two at once (two copies of a 3-page letter
// took 2.5 s, against 2.2 s for one), and each more holds another 75–90 MB.
let width = settings.ocr ? 2 : min(4, max(1, cores - 2))
```
