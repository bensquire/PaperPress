---
title: Fast, but Not Over Accuracy
impact: MEDIUM
impactDescription: A test that is quick because it cannot see the defect is not a test; a slow suite is one nobody runs
tags: [testing, performance, accuracy, fixtures, ocr]
paths: ["Tests/**/*.swift"]
---

## Fast, but Not Over Accuracy

**Impact: MEDIUM**

A test is first for what it proves, then as cheap as that allows — never the
other way round. The suite is 149 tests in about 12 s, built in release
(`make test`; the pixel loops make a debug run take minutes). Speed is bought
by not paying for what the test does not need: OCR is off (`noOCR`,
`makeModel()`) in every test that converts a page, because Vision is the
slowest thing a page does. Vision runs only in `OCRTests`, on one rendered
page, and the text layer is tested by writing known words
(`PDFWriter.Page(…, ocrWords:)`) and reading them back. A rule about one unit
is pinned on that unit (`Gray4.encode` on one page, `Inbox.sweep` on one file),
not on a whole folder conversion.

Speed is never bought by making the test see less. A test of how a real A4
scan converts uses a full-size page (2480 × 3508 at 300 dpi), because the
estimate, the dpi cap and the G4 size all depend on it; the damage-calibration
test renders real type, because only real type shows strokes merging. A
fixture shrunk until the defect would not show, or a tolerance loosened so a
small fixture clears it, is a faster test that no longer tests. The slowest
tests run about a second each (inspecting a page's ink, reading one with
Vision); a new one much slower than that says why in its Arrange note.

**Incorrect (fast because it cannot see):**

```swift
let page = Fixtures.textPage(width: 60, height: 80)    // too small to tell G4 from JPEG by size
XCTAssertLessThan(result.outputBytes, result.inputBytes * 2)   // loosened until it passes
```

**Correct (cheap where it costs nothing to be; exact where it counts):**

```swift
let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)   // a real A4 at 300 dpi
let result = try await Converter.convert(report: report, to: out, settings: noOCR)  // no Vision: not under test
XCTAssertLessThan(result.outputBytes, result.inputBytes / 2)
```
