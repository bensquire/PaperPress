---
name: apple-docs
description: Look up Apple's developer documentation, WWDC transcripts and sample code offline with `scrapple`, before using a system API, choosing a system feature, or claiming what macOS does. Use whenever a change touches SwiftUI, AppKit, Core Graphics' PDF API, Vision, ImageIO, Accelerate (vImage), Network, Quick Look, UniformTypeIdentifiers or a Human Interface Guideline.
---

# Apple's documentation, locally

`scrapple` (Homebrew, `/opt/homebrew/bin/scrapple`) holds Apple's developer
documentation, WWDC transcripts, sample projects and their source files in a local
SQLite index at `~/.local/share/scrapple/`. About 300,000 resources are indexed.
Nothing leaves the machine. It is the reference for the
`native-check-apples-documentation` rule.

## When to ask it

- Before calling an API whose signature, availability or behaviour you are not
  certain of. Look rather than guess at a modifier's name or what it does. The
  deployment target is macOS 26, so check a symbol's availability too.
- Before building anything the system might already provide (a panel, a
  preview, a menu placement, a Finder integration). Search first; the answer is
  usually a framework the app already links.
- Before stating a convention as fact: a shortcut, a menu order, a font style,
  a window behaviour. The Human Interface Guidelines themselves are *not* in
  the index (it covers `/documentation`, not `/design`); the conventions are in
  the WWDC design talks — search `--type talk` for "Designing iPad Apps for
  Mac" (menu bar, shortcuts), "Adopt the new look of macOS" (sidebar, toolbar),
  "Writing Great Accessibility Labels" — and in the framework docs' own
  discussion sections.
- When a symbol's doc says one thing and the app does another: read the doc,
  then decide.

## Commands

```sh
scrapple search "<query>" --type doc  --limit 5 --human    # API reference and articles
scrapple search "<query>" --type talk --limit 5 --human    # WWDC transcripts, with timestamps
scrapple search "<query>" --type sample --limit 3 --human  # sample projects
scrapple search "<query>" --type code_file --limit 3 --human   # a file inside a sample
scrapple -h show <id>         # the full page as Markdown, with links to related pages
scrapple -h show /documentation/vision/vnrecognizetextrequest
scrapple open <id>            # the page in the browser, for the user
scrapple status               # how much is indexed, and what failed
```

- Without `--human` (`-h`, before the subcommand for `show`) the output is JSON:
  a search gives `id`, `title`, `type`, `url`, `snippet`, `score`; `show` gives
  `manifest`, `breadcrumbs` and `content[].body`. Use JSON when a script reads
  it, `-h` when you do.
- A symbol name is the best query (`CGPDFDocument`, `RecognizeDocumentsRequest`,
  `vImageScale_Planar8`, `CGImageDestinationAddImage`, `NWListener`). A
  question in words works too; the search is keyword and semantic together.
  `--keyword-only` is faster and exact for a known name; `--semantic-only` for a
  concept you cannot name.
- The first semantic search in a while takes about fifteen seconds; the rest are
  quick. Keep it out of hooks.
- `show` prints the whole page, with its See Also links as `doc://` paths that
  `show` accepts in turn. Pipe it through `head -80` first, or `grep -n` for the
  section you want, then read the range.
- `id`s are stable, so a doc found once can be shown again by id.
- Overloaded symbols carry a suffix in their path, so search, or `show` the
  parent type and read its Topics, rather than guessing a path.
- `scrapple sync` refreshes the index. It takes hours from empty; the user runs
  it, not you.

## What to do with the answer

- Use the documented API, at the documented signature. If the doc says a
  modifier or placement exists, use that rather than a hand-built copy.
- When a decision rests on what a doc says, say so where the decision lives, in
  a short comment with the page's path, e.g.
  `// /documentation/network/nwendpoint/unix(path:)`.
  A URL in a comment is fine; a paragraph is not.
- When a doc contradicts how the app works on purpose (the hand-rolled PDF
  writer and its G4 path, the hand-written MCP server), raise it with the user
  rather than "fixing" it. The doc is the platform's word; the design decision
  is the user's.
- If the index has nothing on the subject, say so and fall back to reasoning
  from the frameworks, stating that it is unverified.
