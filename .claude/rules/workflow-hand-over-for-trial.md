---
title: Hand Work Over for the User to Try
impact: CRITICAL
impactDescription: The user judges a feature in the app, not in a report
tags: [workflow, handover, bundle, app, mcp]
---

## Hand Work Over for the User to Try

**Impact: CRITICAL**

When a change the user can see in the app is done and checked, put it in front
of them there. A change to the tests, the rules or the docs is handed over as
what it is: the suite's result, the file to read.

1. `make bundle`, so `PaperPress.app` carries the change. It signs with the
   Developer ID in the keychain; `CODESIGN_IDENTITY=- ./bundle.sh` signs ad hoc,
   as CI's smoke build does, where that identity is not available.
2. Relaunch it: `pkill -x PaperPress; open PaperPress.app`. Quit first: `open`
   brings forward a PaperPress that is already running — another copy, such as
   one in `/Applications`, has the same bundle identifier — instead of starting
   this one. The window starts empty; the conversion settings, the two
   Assistants switches and whether the queue column shows persist in
   `UserDefaults` (`com.bensquire.paperpress`), so say which the trial assumes.
3. For a change to the assistant tools, say that the client keeps the helper it
   started running: restart it (`/mcp` in Claude Code) to pick up the new one.
4. Say what to look at and what the figures were.
5. Stop.

**Incorrect (declaring done from the command line):**

```
The suite passes and the converter test reads 1,014 words. Done.
```

**Correct (the app relaunched, the eye pointed):**

```
Rebuilt and relaunched. Convert the 3-page letter and search it in Preview:
words now select one at a time, and `pdftotext -raw` reads 1,014 words where it
read 85 run-together chunks.
```
