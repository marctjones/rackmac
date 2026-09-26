# rackmac-markdown

A pure-Racket CommonMark 0.31.2 parser, with GitHub Flavored Markdown extensions (tables, task
lists, strikethrough, autolink literals) and Rackmac's own note-taking extensions (`[[wiki
links]]`, `#tags`, TODO/WAITING/DONE keywords, bare dates, YAML-ish front matter). It is a sibling
Racket package -- `deps '("base")` only, no `gui-lib`, no FFI -- so it can be used by any Racket
program, not just the Rackmac app. See `docs/MARKDOWN-DESIGN.md` in the main repository for the
full design.

## Install and test

```
raco pkg install --link ./rackmac-markdown
raco test rackmac-markdown
```

No installation is required to run the tests from a checkout: `raco test rackmac-markdown` also
works unlinked.

## Licenses

This package's own code is MIT-licensed (see `info.rkt`). Two kinds of data are vendored from
elsewhere for testing and for the entity table the parser itself uses at runtime; neither is
covered by this package's MIT license, and both are used here solely for conformance and are
redistributed under their own terms:

- **CommonMark spec examples** (`tests/spec/spec-0.31.2.json`, extracted from the CommonMark
  specification's `test/spec.txt`, copyright (C) 2014-16 John MacFarlane) and **GitHub Flavored
  Markdown spec examples** (`tests/spec/gfm-0.29-extensions.json`, extracted from
  `github/cmark-gfm`'s `test/spec.txt`) are both licensed under the Creative Commons
  Attribution-ShareAlike 4.0 International license (CC BY-SA 4.0):
  <https://creativecommons.org/licenses/by-sa/4.0/>. Full attribution and provenance are in
  `tests/spec/LICENSE.md`.
- **WHATWG named HTML entities** (`entities.rktd`, vendored from
  <https://html.spec.whatwg.org/entities.json>, the WHATWG living standard) are licensed under the
  Creative Commons Attribution 4.0 International license (CC BY 4.0):
  <https://creativecommons.org/licenses/by/4.0/>. Unlike the two data sets above, this table is a
  runtime dependency of the parser itself (`entities.rkt`), not test-only data.
