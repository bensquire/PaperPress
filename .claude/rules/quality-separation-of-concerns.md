---
title: Each Part Does One Job, and Knows Only Its Neighbours
impact: HIGH
impactDescription: The engine is tested headlessly and shared by the window, the queue and the assistant helper because nothing in it knows about either
tags: [quality, architecture, separation-of-concerns, layers]
paths: ["Sources/**/*.swift", "Package.swift"]
---

## Each Part Does One Job, and Knows Only Its Neighbours

**Impact: HIGH**

The layers are the targets in `Package.swift`, and the dependencies run one way:

- **`PressKit`** is the engine — inspection, classification, binarisation,
  encoding, the PDF writer, OCR, output planning. It imports no AppKit or
  SwiftUI.
- **`PressJobs`** is the job vocabulary the app and the helper share (a request,
  its status, the socket messages) and the socket itself.
- **`PressMCP`** is the MCP server and PaperPress's tools. No AppKit: the app and
  its launcher are protocols (`PaperPressLink`, `PaperPressLauncher`) a test
  stands in for.
- **`paperpress-mcp`** is the helper's edge: `WorkspaceLauncher` finds and opens
  the app through AppKit.
- **`PressApp`** holds the model and the views; **`PaperPress`** is the `@main`
  scene and nothing more.

Within the engine, `PDFInspector` decides a verdict, `Converter` decides what
each page becomes, `PDFWriter` writes bytes, and values (`Report`, `Settings`,
`FileResult`) flow between them. A change that needs `PressKit` to import a UI
framework, a view to decide a verdict, or `PressMCP` to reach for `NSWorkspace`
is at the wrong layer.

**Incorrect (a view deciding something the engine owns):**

```swift
// DraftView
let worthIt = row.bytes / row.pages > 45_000   // the "already small" rule, copied
```

**Correct (the engine states the rule; the view shows it):**

```swift
// PressKit
public static func inspect(_ url: URL) throws -> Report   // carries .verdict
// view, through FileRow, which labels row.report?.verdict
Text(row.verdictLabel)
```
