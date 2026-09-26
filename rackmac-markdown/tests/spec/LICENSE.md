# Vendored test data license

`spec-0.31.2.json` is derived from the CommonMark specification's example suite
(`test/spec.txt` in the `commonmark/commonmark-spec` repository, tag `0.31.2`,
fetched from <https://spec.commonmark.org/0.31.2/spec.json>), extracted to JSON
by the upstream project's own tooling. The Markdown/HTML example pairs are
unmodified except for that extraction to JSON.

> Copyright (C) 2014-16 John MacFarlane

Licensed under the Creative Commons Attribution-ShareAlike 4.0 International
license (CC-BY-SA 4.0): <https://creativecommons.org/licenses/by-sa/4.0/>.

This test data is used here solely to check `rackmac-markdown`'s conformance
to the CommonMark specification (`tests/spec-test.rkt`, `tests/positions-test.rkt`).
It is not covered by this package's own license (see the root `info.rkt`); it
is redistributed here, attributed, under the terms above.

## GitHub Flavored Markdown extension examples

`gfm-0.29-extensions.json` holds the 24 extension examples (tables 8, task list
items 2, strikethrough 2, autolinks 11, disallowed raw HTML 1) of the GitHub
Flavored Markdown Spec, version 0.29 (2019-04-06), `test/spec.txt` in the
`github/cmark-gfm` repository at tag `0.29.0.gfm.13`
(<https://raw.githubusercontent.com/github/cmark-gfm/0.29.0.gfm.13/test/spec.txt>),
extracted to JSON by `extract-gfm-examples.rkt` in this directory. The
Markdown/HTML example pairs are unmodified except for that extraction (with `→`
read as a tab, as upstream's own test runner does).

> GitHub Flavored Markdown Spec, version 0.29, GitHub; based on the CommonMark
> Spec, Copyright (C) 2014-16 John MacFarlane

Licensed under the Creative Commons Attribution-ShareAlike 4.0 International
license (CC-BY-SA 4.0), as the spec's front matter states:
<https://creativecommons.org/licenses/by-sa/4.0/>.

This test data is used only to check `rackmac-markdown`'s GFM extensions
(`tests/gfm-test.rkt`, `tests/positions-test.rkt`). It is not covered by this
package's own license; it is redistributed here, attributed, under the terms
above.
