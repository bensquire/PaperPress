---
title: A Failure Reads as a Sentence
impact: MEDIUM
impactDescription: A bare comparison fails as a pair of numbers with no story
tags: [testing, assertions, messages, xctest]
paths: ["Tests/**/*.swift"]
---

## A Failure Reads as a Sentence

**Impact: MEDIUM**

An `XCTAssert…` carries a message that says what was measured and what it was,
unless the expression already says it (`XCTAssertEqual(result.outcome,
.copied(.passThrough))`). In a loop the message names the input. `XCTUnwrap`
for the thing the rest of the test cannot run without, with a message saying
what was missing. A helper that asserts on the caller's behalf takes `file:`
and `line:` so the failure lands on the test, not the helper, as
`assertThrowsAsync` does.

**Incorrect:**

```swift
XCTAssertTrue(Fixtures.pageText(of: url).contains("HELLO"))
XCTAssertEqual(weight, 1, accuracy: 0.12)
```

**Correct:**

```swift
XCTAssertTrue(Fixtures.pageText(of: url).contains("HELLO"), "page text should be searchable")
XCTAssertEqual(weight, 1, accuracy: 0.12, "stroke weight \(weight)× the scan's")
let defaults = try XCTUnwrap(UserDefaults(suiteName: suite), "no defaults suite for \(suite)")
```
