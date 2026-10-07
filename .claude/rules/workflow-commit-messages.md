---
title: Commit Messages Are Prose With the Measurements
impact: HIGH
impactDescription: The history is where the reasoning is kept
tags: [workflow, git, commits, history]
---

## Commit Messages Are Prose With the Measurements

**Impact: HIGH**

When told to commit, the message says what changed and why, in prose, with the
measurements that justified it — the file or fixture, the figure before, the
figure after — and what was tried and taken out, if anything was. One commit
per change of meaning: work that was already in the tree and is not part of the
change goes in its own commit, described honestly. End with the attribution
lines the session prescribes.

**Incorrect:**

```
Fix icon size and cleanup
```

**Correct:**

```
Losslessly halve the icon: oxipng + direct icns repack

iconutil re-encodes PNGs when packing an icns, so optimising the
iconset alone achieves nothing. scripts/repack-icns.py rebuilds the
container directly (the icnsoptim approach): oxipng'd PNG chunks,
Apple's own ic04/ic05 ARGB chunks kept verbatim, info plist dropped.
Pixel-identical at every size, verified by CoreGraphics decode.
icns 192399 -> 96255 bytes; DMG 345 KB -> 246 KB.
```
