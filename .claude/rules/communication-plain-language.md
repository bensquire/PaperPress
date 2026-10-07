---
title: Messages to the User Are Plain Language
impact: MEDIUM
impactDescription: The reader gets what they need, can find it, understand it and use it — ISO 24495-1:2023
tags: [communication, plain-language, iso-24495]
---

## Messages to the User Are Plain Language

**Impact: MEDIUM**

Messages follow ISO 24495-1:2023's four principles: the reader gets what they
need, can find it, can understand it, and can use it.

- **Lead with what matters.** The outcome or the answer first; the reasoning
  after. If something failed, say so in the first line.
- **Make it findable.** Headings and short lists when a message has more than
  one part. One idea per paragraph.
- **Make it understandable.** Short sentences. Everyday words where they will
  do; a term of art only where it is the precise one, defined the first time.
  Active voice: say who did what.
- **Make it usable.** Numbers carry their unit and what they are compared with.
  End with what the reader can do next, or that nothing is needed. Keep every
  caveat in plain sight.
- **Say what was done, not what was intended.** A test that was not run was not
  run. A check skipped is named as skipped. A file written over by accident is
  reported in the first line.

The same principles hold for text PaperPress itself shows — a verdict, an
error, a tool's answer to an assistant.

**Incorrect:**

```
I've made some improvements to the OCR layer which should help with search;
there may be some edge cases but overall it's better.
```

**Correct:**

```
Search works word by word now: pdftotext reads the 3-page letter as 1,014
words (was 85 run-together chunks). Lines Vision doesn't split into words —
Chinese, Japanese, Korean, Thai — go in whole. Nothing is committed.
```

Reference: ISO 24495-1:2023, Plain language — Part 1: Governing principles and guidelines.
