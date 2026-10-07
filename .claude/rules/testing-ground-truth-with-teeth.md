---
title: Ground Truth Is the Written PDF, and the Bar Has Teeth
impact: HIGH
impactDescription: A result that says "converted" can be a file Quartz renders blank, or one whose text cannot be found
tags: [testing, ground-truth, pdf, calibration, fixtures]
paths: ["Tests/**/*.swift"]
---

## Ground Truth Is the Written PDF, and the Bar Has Teeth

**Impact: HIGH**

A fixture is a page with known content — `blockPage` with one solid block at a
known place, `renderedTextPage` with real type at a known size and ink — so the
output can be judged by reading it back: render the written page
(`Fixtures.rendered`) and compare pixels, read its text (`Fixtures.pageText`),
inspect its content stream for the filter it claims (`CCITTFaxDecode`,
`DCTDecode`). The `FileResult` is checked too, but it is not the proof.

Where it can, a test also states what the alternative would have measured, so
the bar cannot be cleared by accident: `test_sauvola_bandedMatchesBruteForceReference`
checks the fast path against a brute-force mean and variance, and
`test_damage_calibrationAnchors_holdWithinTolerance` pins the damage metric
between bands taken from real crisp and real degraded pages, so a drift fails
even when no page crosses the threshold. A tolerance carries the reason for its
size. When a bug is fixed, a test pins it, with the measurement that showed it.

**Incorrect (a bar with no teeth — passes on a file that holds nothing):**

```swift
XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
XCTAssertTrue(result.converted)
```

**Correct (the written file itself, and the alternative ruled out):**

```swift
let written = try Data(contentsOf: out)
XCTAssertNotNil(written.range(of: Data("DCTDecode".utf8)), "photo page should stay JPEG")
XCTAssertNil(written.range(of: Data("CCITTFaxDecode".utf8)))
```
