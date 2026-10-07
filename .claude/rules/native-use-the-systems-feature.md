---
title: Use the System's Feature, Not a Copy of It
impact: HIGH
impactDescription: The OS version already handles accessibility, Dark Mode, localisation and next year's macOS
tags: [native, macos, appkit, swiftui, quick-look, finder, vision]
paths: ["Sources/PressApp/**/*.swift", "Sources/PaperPress/**/*.swift", "Sources/PressKit/**/*.swift", "scripts/Info.plist.template"]
---

## Use the System's Feature, Not a Copy of It

**Impact: HIGH**

PaperPress should feel like a Mac app Apple could have shipped: it behaves the
way the user's other apps behave, by using what macOS provides rather than
building a version of its own. Before writing a control, a panel, a preview or
an alert, ask whether the OS has one. It usually does.

- **Choosing files** is `NSOpenPanel`, plus drag and drop onto the window;
  folders are walked, not asked about.
- **Arriving from Finder** is the system's: Open With (the document types in
  `Info.plist.template`, ranked so Preview stays the default), drops on the
  Dock icon, and the "Analyse with PaperPress" Services entry.
- **Looking at a file** is Quick Look (`quickLookPreview`, toggled with Space);
  showing where output went is `NSWorkspace.activateFileViewerSelecting`.
- **Reading text** is Vision, on the Mac. **Rasterising and image encoding**
  are Core Graphics, ImageIO and Accelerate.
- **Icons** are SF Symbols, chosen for their meaning. No bitmaps for things a
  symbol says.
- **Confirming a destructive step** is the system's alert or
  `confirmationDialog`, as quitting with batches unfinished is
  (`applicationShouldTerminate`), not a sheet of our own.
- **Text, colour and spacing** are `Font` styles, semantic colours and standard
  control sizes. Nothing hard-coded that the system defines.

Native is not generic: the review table, the queue and the conversion pipeline
are the app's own work — built from the system's parts. The hand-rolled PDF
writer is a deliberate design decision, not a gap to fill with PDFKit; raise
it with the user before changing that.

**Incorrect (a preview of our own):**

```swift
struct PagePreview: View { … Image(nsImage: render(page)) … }   // a sheet with arrows
```

**Correct (the system's):**

```swift
.quickLookPreview($previewItem, in: urls)
```
