---
title: Every Test Arranges, Acts and Asserts
impact: HIGH
impactDescription: A test with a step missing tests something other than it claims
tags: [testing, aaa, structure, xctest]
paths: ["Tests/**/*.swift"]
---

## Every Test Arranges, Acts and Asserts

**Impact: HIGH**

Every test has three steps, in this order, each present and identifiable, and
the file marks them `// Arrange`, `// Act`, `// Assert` — every test in the
suite does today:

1. **Arrange** — build the input: a page from `Fixtures`, a PDF written into the
   test's own `dir`, a `PDFInspector.Report`, a model from `makeModel()`. A
   short note after the marker says what is special about it
   (`// Arrange — 600dpi source, capped to 150`).
2. **Act** — the one call under test. One act per test where the design
   allows; a test that acts twice is two tests, or a test of the pair, marked
   `// Act / Assert` as `test_sweep_deletesOnlyWhatHasWaitedADay` does.
3. **Assert** — `XCTAssert…` against what the act produced; `XCTUnwrap` for
   the thing the rest cannot run without.

The steps need not be on separate lines — a short test can be one line — but a
reader should be able to point at the input, the call, and the check.

**Incorrect (the act hidden inside the assert; no act at all):**

```swift
XCTAssertEqual(try await Converter.convert(report: try PDFInspector.inspect(src), to: out, settings: noOCR).outcome, .converted([.g4]))

func test_pageIsText() { XCTAssertEqual(PageClassifier.classify(page), .text) }   // page built where?
```

**Correct:**

```swift
// Arrange
let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
let src = Fixtures.write(Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "scan.pdf")
let report = try PDFInspector.inspect(src)

// Act
let result = try await Converter.convert(report: report, to: out, settings: noOCR)

// Assert
XCTAssertEqual(result.outcome, .converted([.g4]))
```
