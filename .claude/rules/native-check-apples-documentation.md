---
title: Check Apple's Documentation Before Using Its API
impact: HIGH
impactDescription: A guessed signature compiles by luck; a copied feature is one the OS already had
tags: [native, documentation, scrapple, apple, hig, wwdc]
paths: ["Sources/**/*.swift"]
---

## Check Apple's Documentation Before Using Its API

**Impact: HIGH**

Before using a system API you are not certain of, before building anything the
system might already provide, and before stating a platform convention as fact,
look it up. `scrapple` holds Apple's framework documentation, WWDC transcripts
and sample code offline — not the Human Interface Guidelines, whose conventions
are in the design talks; the `apple-docs` skill says how to ask it. A symbol
name is the best query. A decision that rests on what a page says carries the
page's path in a one-line comment, as the code already does
(`/documentation/coregraphics/cgpdfbox/cropbox`,
`/documentation/network/nwendpoint/unix(path:)`), so the next reader can check
it too. A doc that contradicts a deliberate design choice — the hand-rolled PDF
writer, say — is raised with the user, not followed or ignored in silence. This
matters most around Core Graphics' PDF reading, Vision's document reader,
vImage, ImageIO's encoders and SwiftUI's newer modifiers.

**Incorrect (guessed: a Vision type's options, from memory):**

```swift
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate   // the line reader; is that the one that boxes words?
```

**Correct (looked up, and named):**

```sh
scrapple search "RecognizeDocumentsRequest" --type doc --limit 3 --human --keyword-only
```

```swift
// /documentation/vision/documentobservation/container/text-swift.struct/words
var request = RecognizeDocumentsRequest()
request.textRecognitionOptions.maximumCandidateCount = 1
```

Reference: `scrapple` (github.com/searlsco/scrapple); Apple Developer Documentation.
