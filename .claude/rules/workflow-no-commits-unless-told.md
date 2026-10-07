---
title: Never Commit or Push Unless Told To
impact: CRITICAL
impactDescription: A committed feature the user did not want costs a revert and trust
tags: [workflow, git, commits, handover]
---

## Never Commit or Push Unless Told To

**Impact: CRITICAL**

Do not commit, and do not push, unless the user has said to in this
conversation. "Make it work", "fix it" and "finish it" are not that instruction.
"Commit", "commit and push", or a reply that says the work stays, are. When
told to commit on `main`, branch first and say so.

The user tries a feature before deciding whether it stays. A working feature is
not the same as a wanted one, and only they can tell the difference.

This is about product decisions, not about editing: do not ask permission to
change files. `ISSUES.md` at the repo root is untracked — the user's own notes
from a code review — and stays out of a commit unless they ask for it.

**Incorrect (committing because the work is done):**

```
Tests pass and the converted letter is searchable, so I've committed and pushed.
```

**Correct (handing over and waiting):**

```
Tests pass. I've rebuilt and relaunched the app — convert the letter and search
it in Preview. Nothing is committed; say if it stays.
```
