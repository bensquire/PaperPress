---
title: PaperPress Rules Index
impact: LOW
impactDescription: About the rules themselves; loads only when a rule is being written
tags: [meta, rules]
paths: [".claude/rules/*.md"]
---

# PaperPress Rules

Modular, machine-readable rules for working on PaperPress. Each file is one
rule, named `{section}-{rule-name}.md`, with YAML frontmatter Claude Code reads:
a rule with `paths` loads only when a matching file is in play; one without
applies always. `_sections.md` defines the sections and their order;
`_template.md` is the shape of a new rule.

## Rules Index

### Workflow

- [workflow-challenge-the-rules](workflow-challenge-the-rules.md) - A rule in the way is raised with the user, not obeyed or broken in silence
- [workflow-no-commits-unless-told](workflow-no-commits-unless-told.md) - Never commit or push unless told to
- [workflow-hand-over-for-trial](workflow-hand-over-for-trial.md) - Bundle, relaunch, say what to look at, stop
- [workflow-checking-work](workflow-checking-work.md) - Lint, the whole suite in release, then real scans opened and read
- [workflow-commit-messages](workflow-commit-messages.md) - Prose, with the measurements
- [workflow-diagnostics](workflow-diagnostics.md) - `PAPERPRESS_*` read at the edge to keep, a separate file to throw away; stderr in the helper

### Quality

- [quality-separation-of-concerns](quality-separation-of-concerns.md) - PressKit knows no window; PressMCP knows no AppKit; dependencies run one way
- [quality-dependency-injection](quality-dependency-injection.md) - Settings, link, launcher and clock handed in as values
- [quality-readability](quality-readability.md) - Code reads like the prose around it
- [quality-consistency](quality-consistency.md) - Match the code around you; reuse the helper that exists
- [quality-extensible](quality-extensible.md) - Add a case and its behaviour, not an `if`
- [quality-performant](quality-performant.md) - OCR capped, pixel passes banded, the queue bounded, and measured
- [quality-secure](quality-secure.md) - Offline; one private socket, off until asked for; originals never written
- [quality-comments-carry-measurements](quality-comments-carry-measurements.md) - Short, says why, carries the number or the doc path
- [quality-formatting-is-the-tools](quality-formatting-is-the-tools.md) - Apple's swift-format decides, strict
- [quality-images-minified](quality-images-minified.md) - Lossless first, then lossy to the edge; the icon repacked, not re-encoded

### Testing

- [testing-arrange-act-assert](testing-arrange-act-assert.md) - Each step present, in order, marked
- [testing-one-behaviour-per-test](testing-one-behaviour-per-test.md) - One behaviour, named as a sentence
- [testing-ground-truth-with-teeth](testing-ground-truth-with-teeth.md) - Judge the written PDF; say what the alternative measures
- [testing-deterministic](testing-deterministic.md) - Fixtures drawn in code, seeded; own temp dirs; no clock, no network
- [testing-fast](testing-fast.md) - Fast by paying only for what the test needs, never by seeing less
- [testing-failure-reads-as-a-sentence](testing-failure-reads-as-a-sentence.md) - A message where the expression alone doesn't tell the story

### Native

- [native-use-the-systems-feature](native-use-the-systems-feature.md) - Open panel, Finder, Quick Look, Vision, SF Symbols
- [native-keyboard-and-menus](native-keyboard-and-menus.md) - The shortcuts every Mac user knows
- [native-small-bundle](native-small-bundle.md) - About 1.5 MB with the helper, no dependencies
- [native-check-apples-documentation](native-check-apples-documentation.md) - Look it up in `scrapple` before using, copying or asserting

### Communication

- [communication-plain-language](communication-plain-language.md) - ISO 24495-1: relevant, findable, understandable, usable
