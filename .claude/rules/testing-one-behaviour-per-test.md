---
title: One Behaviour Per Test, Named as a Sentence
impact: HIGH
impactDescription: A test of several things fails for one and hides the rest
tags: [testing, naming, scope, xctest]
paths: ["Tests/**/*.swift"]
---

## One Behaviour Per Test, Named as a Sentence

**Impact: HIGH**

A test pins one behaviour, and its name says which, as
`test_subject_behaviour` that reads in the report:
`test_convert_passThroughVerdict_copiesFileByteIdentical`,
`test_sauvola_keepsFaintPrintAlongsideBoldPrint`,
`test_convert_whenPaperPressCantBeOpened_saysSo`. A name with "and" in it that
lists unrelated checks is usually two tests (a name with "and" that describes
one observable outcome is fine). When the same behaviour is asked of several
inputs, loop over a table inside one test with the input in every message,
rather than copy the test.

Test the behaviour, not the implementation: what the written PDF holds, how
each page was encoded, what the queue reports, what an assistant is told — not
which private function ran. `@testable` is for reaching a real internal seam
like `Binarize.window(dpi:)` or `Inbox.keptFor`, not for asserting on
scaffolding.

**Incorrect:**

```swift
func test_convertWorks() async throws {
    // checks verdict, encoding, size, OCR text and modification date in one go
}
```

**Correct:**

```swift
func test_convert_scannedTextPDF_producesSmallerG4PDF() async throws { … }
func test_convert_photoPage_staysJPEG() async throws { … }
func test_convert_preservesSourceModificationDate() async throws { … }
```
