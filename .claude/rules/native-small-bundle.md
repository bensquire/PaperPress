---
title: Small, With No Dependencies
impact: MEDIUM
impactDescription: The app is about 1.5 MB with its assistant helper; growth is a signal
tags: [native, macos, bundle, dependencies, size]
paths: ["Package.swift", "bundle.sh", "scripts/**", "icon/**"]
---

## Small, With No Dependencies

**Impact: MEDIUM**

`PaperPress.app` is about 1.5 MB on disk (`du -sh`): the app's executable
778 KB, the `paperpress-mcp` helper 641 KB and the icon 95 KB (6 October 2026,
the stripped `-Osize` release build). `Package.swift` has no dependencies: the PDF
writer, the G4 path, the MCP server and the socket are this package's own code
over Core Graphics, ImageIO, Vision, Accelerate, Network and zlib, all already
on every Mac. `bundle.sh` builds with `-Osize` and strips both executables.

That is a consequence of using the system's features and a check on it: a
feature that arrives with a package, a framework or a third executable is a sign
the wrong path was taken. Check `du -sh PaperPress.app` after `make bundle`;
growth needs a reason.

**Incorrect:**

```swift
// Package.swift
dependencies: [.package(url: "https://github.com/…/SomePDFKit", from: "2.0.0")]   // for what CGPDF reads
```

**Correct:**

```swift
import CoreGraphics   // CGPDFDocument, already on every Mac
```
