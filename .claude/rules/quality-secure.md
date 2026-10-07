---
title: Offline, One Private Socket, Nothing Overwritten
impact: HIGH
impactDescription: An archive tool that writes over an original, talks to the network, or lets anyone on the Mac queue writes has broken trust
tags: [quality, security, privacy, network, files, socket]
paths: ["Sources/**/*.swift", "bundle.sh", "scripts/**", "Package.swift"]
---

## Offline, One Private Socket, Nothing Overwritten

**Impact: HIGH**

- **Offline.** No network requests and no telemetry; the README promises
  "entirely offline", and OCR is Vision on the Mac. The `Network` framework is
  used only for the local socket below. A feature that needs a remote host is a
  product decision for the user, raised before it is built.
- **One socket, private, and off until asked for.** The app listens for the
  assistant helper only while Settings › Assistants is on, at
  `~/Library/Application Support/PaperPress/paperpress.sock`, in a folder made
  `0700` with the socket `0600`: whoever can connect can ask for files to be
  written. `analyse` and `preview` run in the helper and only read.
- **Originals are never written.** `OutputPlan` refuses an output folder that
  would put a file on top of a source; `Converter.checkDestination` replaces
  only an earlier PaperPress output (it carries the Producer marker) or a file
  byte-identical to the source, and leaves anything else alone. A rebuilt PDF
  is reopened by Quartz and its pages counted before it replaces anything, and
  it is written atomically.
- **Deletion is narrow.** Only `Inbox` deletes, only files really inside the
  inbox folder — not through a link — and only after they are written out or
  have waited a day.
- **No child processes.** The one `execv` is the helper replacing itself with
  the newer helper inside the running app, once, guarded by
  `PAPERPRESS_MCP_REPLACED`.
- **Signed and hardened.** `bundle.sh` signs both executables with the hardened
  runtime, the helper first; `release.yml` notarises the app and the DMG. The
  app is not sandboxed, so the checks above are what stand between a mistake
  and the user's files.

**Incorrect:**

```swift
try data.write(to: dst)   // whatever was at dst is gone, even an original
```

**Correct:**

```swift
try checkDestination(dst, source: src)        // only our own output, or identical bytes
try data.write(to: outURL, options: .atomic)
```
