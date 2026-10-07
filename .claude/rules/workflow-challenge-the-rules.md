---
title: Challenge a Rule When It Is in the Way
impact: CRITICAL
impactDescription: The rules serve the best system; a rule that blocks a better one is a defect to raise, not a wall to work around
tags: [workflow, rules, architecture, standards, judgement]
---

## Challenge a Rule When It Is in the Way

**Impact: CRITICAL**

These rules exist to make the best system, not to be obeyed for their own
sake. When following one would make the code, the architecture, a standard
or the product worse — or when a better way exists that a rule forbids —
raise it with the user, plainly: which rule, what it costs here, what the
alternative is, and what it would take. Then wait. Sometimes the answer is to
rearchitect, change a standard, or rewrite the rule.

Silent compliance and silent breaking both hide the decision, so do neither.
A rule the user has just confirmed stands.

**Incorrect (working under it in silence):**

```
Tests should be fast, so I've left OCR off in the new text-layer test and
checked the layer's byte count instead of the words.
```

**Correct (the case made, the decision left with the user):**

```
"Fast, but not over accuracy" and the per-word boxes pull apart: proving a
word lands over its ink needs Vision on a rendered page, about 0.9 s a test.
Doing that in all 32 converter tests would add about half a minute to a suite
that runs in 11 s. I'd keep OCR off in the converter tests and add two OCR
tests that render and read. Want that, or a different split?
```
