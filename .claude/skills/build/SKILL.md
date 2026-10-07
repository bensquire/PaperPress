---
name: build
description: Build, test, lint and bundle PaperPress — the SwiftPM package that holds the app and its paperpress-mcp assistant helper — and what the release path does. Use when building or running the app or the helper, running the suite or one test, linting or formatting, bundling PaperPress.app for a trial, or asked how a release is cut.
---

# Building PaperPress

PaperPress is a SwiftPM package with no Xcode project and no dependencies.
`Package.swift` (tools 6.2, macOS 26) has two executables — `PaperPress`, the
app, and `paperpress-mcp`, the helper an assistant launches — over the
libraries `PressKit`, `PressJobs`, `PressMCP` and `PressApp`, and one XCTest
target, `PaperPressTests`. `bundle.sh` turns the two executables into
`PaperPress.app`.

## Prerequisites

- macOS 26 and Xcode 26 (Swift 6.2 or later); CI pins Xcode 26.6 on
  `macos-26`, so a local Xcode 26.6 lints exactly as CI does.
- `swift format` ships with the toolchain; nothing to install for lint.
- For a Developer ID bundle: the "Developer ID Application" identity in the
  login keychain. Without it, sign ad hoc (below).
- For icon work only: `oxipng` (Homebrew) and `python3` for
  `scripts/repack-icns.py`.

## Commands

| What | Command | Notes |
|---|---|---|
| Debug build | `swift build` | `.build/debug/PaperPress` and `.build/debug/paperpress-mcp`; ~5 s incremental |
| Run unbundled | `swift run PaperPress` | `PAPERPRESS_FOLDER=/path swift run PaperPress` analyses that folder at launch (a plain argument doesn't work: AppKit takes it as a document to open) |
| Test suite | `make test` | `swift test -c release`: 149 tests, ~12 s warm. Release because the pixel loops are slow unoptimised — the Makefile notes 2.5 min for a debug run |
| One test | `swift test -c release --filter ConverterTests/test_convert_photoPage_staysJPEG` | `--filter Gray4Tests` for a class; `swift test list -c release` names them all |
| Lint | `make lint` | `swift format lint --strict` over `Sources`, `Tests`, `Package.swift`; under a second, warnings fail |
| Format | `make format` | rewrites in place; run it over the files you changed |
| Bundle | `make bundle` | `./bundle.sh` → `PaperPress.app` at the repo root (git-ignored), signed with Developer ID |
| Bundle, ad hoc | `CODESIGN_IDENTITY=- ./bundle.sh` | what CI's smoke step runs; `VERSION=1.2.3` sets the marketing version (default 0.1.0) |
| Launch | `pkill -x PaperPress; open PaperPress.app` | quit first: `open` brings forward a PaperPress already running (another copy, such as one in `/Applications`, has the same bundle identifier) |
| Clean | `make clean` | `swift package clean`, and removes `PaperPress.app` and `PaperPress.dmg` |

What `bundle.sh` does, in order: `swift build -c release -Xswiftc -Osize`;
copies both executables into `Contents/MacOS` and strips them; copies
`icon/PaperPress.icns`; writes `Info.plist` from
`scripts/Info.plist.template` with the version and checks it with `plutil`;
signs the helper, then the app, with the hardened runtime and a timestamp; and
verifies the signature. The result is about 1.5 MB.

## Matching CI

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests that
aren't drafts, skipping changes that touch only Markdown, `images/`, `LICENSE`
or `.gitignore`. It runs `make lint`, `make test`, then
`CODESIGN_IDENTITY=- ./bundle.sh` and checks the app's executable exists. Those
three locally are a CI run.

`.githooks/pre-commit` runs `make lint` and `make test`. It is active only once
`git config core.hooksPath .githooks` is set in the clone; `git config
core.hooksPath` shows whether it is.

## Things that bite

- **`make test` and `make bundle` share `.build/release` with different flags**
  (`-Osize` for the bundle), so going from one to the other recompiles: a
  one-test run after a bundle took 19 s instead of under 1 s.
- **A plain `swift test` is a debug build** and takes minutes; use `make test`
  or pass `-c release`.
- **An assistant keeps the helper it started.** After a rebuild, restart the
  MCP server in the client (`/mcp` in Claude Code) to load the new
  `paperpress-mcp`. A helper older than the running app replaces itself with
  the app's own where it can, and otherwise says which side is older.
- **Developer ID signing timestamps with Apple's server**, so `make bundle`
  needs the network and the identity; `CODESIGN_IDENTITY=-` avoids the
  identity.

## Releasing

Run this only when the user asks for a release.

- **The published path is a tag.** Pushing a `v*` tag runs
  `.github/workflows/release.yml`: lint and test, import the Developer ID
  certificate into a throwaway keychain, `bundle.sh` with the tag's version,
  notarise and staple the app, build the DMG with `scripts/make-dmg.sh`, sign,
  notarise and staple it, write notes from `git log` since the previous tag,
  and publish a GitHub Release with `gh release create`. A tag with a suffix
  (`v0.2.0-rc1`) publishes as a prerelease. It needs six repository secrets,
  listed in the workflow's header and the README.
- **Locally, `make release`** runs `release.sh`: `bundle.sh` with Developer ID,
  `scripts/make-dmg.sh` into `PaperPress.dmg`, then notarisation and stapling
  if the `paperdrop` notarytool keychain profile is stored (PaperDrop's — one
  Apple account, one credential); without it, it prints that the DMG is not
  notarised.
