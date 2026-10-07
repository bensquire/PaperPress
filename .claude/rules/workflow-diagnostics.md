---
title: Diagnostics Are Gated to Keep, Separate to Throw Away
impact: MEDIUM
impactDescription: A debug block woven into the converter has to be edited out of the converter; a print in the helper breaks the protocol
tags: [workflow, diagnostics, environment, mcp, stderr]
paths: ["Sources/**"]
---

## Diagnostics Are Gated to Keep, Separate to Throw Away

**Impact: MEDIUM**

A switch worth keeping is an environment variable named `PAPERPRESS_*`, read
once, at the composition root, and handed in as a value:
`PAPERPRESS_FOLDER` is read in `PaperPressApp` and passed to
`AppModel(initialFolder:)`, so the model itself stays environment-free.
Diagnostics for one investigation go in a separate file, marked temporary, and
are deleted before handover — never woven into `Converter` or the pipeline,
where stripping them means editing the code that converts.

In the helper, standard output is the MCP channel: one JSON message a line and
nothing else. A diagnostic there goes to standard error through
`StdioTransport.log`; a stray `print` corrupts the stream the client is reading.

**Incorrect (a dump inline in the page loop; a print in the helper):**

```swift
if ProcessInfo.processInfo.environment["DEBUG_PAGES"] != nil {
    print(page.encoding, data.count)   // inside Converter.convert, between pages
}
```

**Correct (its own file, one call, one deletion; stderr in the helper):**

```swift
// Sources/PressKit/Debug.swift — TEMPORARY, not for commit
func dumpPage(_ index: Int, _ content: PDFWriter.Content) { … }

// paperpress-mcp
StdioTransport.log("paperpress-mcp: the running PaperPress speaks protocol \(version)")
```
