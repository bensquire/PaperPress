---
title: A Change Is Checked, Not Believed
impact: CRITICAL
impactDescription: A unit test proves a page fixture; only a real scan shows what a user's archive becomes
tags: [workflow, verification, tests, lint, pdf]
paths: ["Sources/**", "Tests/**", "Package.swift", "bundle.sh", "scripts/**"]
---

## A Change Is Checked, Not Believed

**Impact: CRITICAL**

Before saying a change is done:

1. **`make lint`** — `swift format lint --strict` over `Sources`, `Tests` and
   `Package.swift`, as CI and the pre-commit hook run it. Under a second.
2. **`make test`**, the whole suite. It builds in release because the pixel
   loops are slow unoptimised (the Makefile's figures: 30 s from clean in
   release, 2.5 min in debug); warm, 149 tests run in about 12 s.
3. **The real thing**, for anything touching analysis, conversion or the text
   layer: convert real scans — the relaunched app, or
   `PAPERPRESS_FOLDER=/path swift run PaperPress` — and open the output. Check
   the verdict, how each page was encoded (G4, 4-bit or JPEG), the size against
   the source, and that the text is there (`pdftotext -raw out.pdf - | head`).
   Look at small print at 1:1 in Preview: a page that lost strokes is a
   regression whatever the byte count says.
4. **The bundle**, when `bundle.sh`, `scripts/Info.plist.template` or a target
   changes: `CODESIGN_IDENTITY=- ./bundle.sh`, as CI's smoke step does, and
   check both executables are in `PaperPress.app/Contents/MacOS`.

Report what was run and what it showed. A check that was skipped is named as
skipped, not left out.

**Incorrect (one class, no lint, no real file):**

```
Ran ConverterTests; passes. Done.
```

**Correct:**

```
lint clean; 148 tests in 10.8 s; converted ~/Scans/letters in the app: the
3-page letter is 152 KB, every page G4, pdftotext reads 1,014 words, and the
small print in its footer is still whole at 1:1.
```
