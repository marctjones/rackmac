# Rackmac's Markdown library: design

_Proposal for the owner and maintainer, 2026-09-25. It details the parser the notes product needs (REPLAN §2
`md-parser`, `md-restyle-region`; UI-DESIGN §2.2 and §5.3) and supersedes the "~400-line scanner" estimate in
REPLAN §9.1. Owner decisions recorded here: our own full CommonMark implementation in Racket; no FFI, no C or
Rust library; the `commonmark` package (ISC) only as a test oracle; GFM task lists, strikethrough, tables and
autolinks plus our extensions ([[wiki links]], #tags, TODO/WAITING/DONE, dates, YAML front matter); pandoc stays
the .docx converter; PDF becomes Racket-native from our tree._

## 0. Build vs. wrap (decision recorded)

The owner asked whether to wrap cmark, cmark-gfm, pulldown-cmark, comrak, markdown-rs or tree-sitter-markdown
over Racket's FFI instead of writing a parser. **Decision (owner, final): write our own in Racket.** Reasons: it is
the simplest thing to maintain long term; no shared library to build for arm64 and x86_64, ship inside the `.app`
and marshal across the FFI (a C crash takes the app down; Rust panics across `extern "C"` abort); and no wrapped
parser gives us everything we need anyway. Three facts verified from the primary sources this session: cmark-gfm
is pinned at 0.29.0.gfm.13 (July 2023), i.e. the 0.29 spec, while CommonMark is at 0.31.2; cmark's inline source
positions needed a correctness fix as recently as 0.31.2 ("Fix inline source positions (#551)"), and cmark-gfm
computes emphasis positions differently from cmark; markdown-rs has token-level events (`AttentionSequence`,
`CodeFencedFenceSequence`, ...) but its `event` module is private, so only the mdast node positions are public.
tree-sitter-markdown's README says it should not be used "where correctness is important". What we borrow freely:
cmark's block algorithm (the spec's appendix), the delimiter-stack inline algorithm, micromark's token vocabulary
for markup tokens, and pulldown-cmark's idea of a half-open offset range on every event.

**Measured this session (Racket CS 9.3, Apple Silicon, headless), which decides how much incrementality v0.3 needs:**

| Input | `commonmark` package, full parse (no positions) | Prototype block-line classification + inline delimiter scan with position tokens |
|---|---|---|
| generated notes, 150 KB, 2,763 lines | 27.1 ms | 1.3 ms |
| `docs/*.md` concatenated, 231 KB | 40.5 ms | — |
| CommonMark `spec.txt`, 204 KB, 9,748 lines | 22.6 ms | 1.9 ms |
| notes, 301 KB, 5,526 lines (REPLAN's 5,000-line case) | 43.2 ms | 3.2 ms |

Timing the package's inline phase alone over the blank-line-separated chunks of the 150 KB document gave 26.6 ms,
so nearly the whole cost is inline parsing (the split is approximate: the chunking fed fences and tables to the
inline parser too). A parser that also records positions and tokens will cost more, 1.5–2× is the honest estimate,
so a full re-parse of a 150 KB note lands around 40–55 ms: not "well under 30 ms". Conclusion: **v0.3 re-parses the
block structure in full on every debounced keystroke (a few ms even at 300 KB) and memoizes the inline parse per
leaf block**, which makes a keystroke cost one block's inline parse. Block-level incremental parsing (restart
points, splicing) is designed in §3.3 but built only if measurements demand it.

## 1. Data model

### 1.1 Positions

Every position is a **0-based code-point offset into the document string**, half-open ranges `[start, end)`.
`text%` counts positions in characters and Racket characters are code points: verified this session,
`(send t last-position)` is 6 for `"a😀b\n\tx"`, equal to `string-length`. `fileio.rkt` normalizes line endings to
`\n` on load and restores them on save, and `buffer%` inserts that normalized string, so a parser offset **is** a
`text%` position with no mapping. (The library still accepts `\r\n` and `\r` as line endings for other callers and
for spec examples; offsets then index the string as given.) Line and column are derived, never stored: `document`
holds a `line-index` (vector of line-start offsets); `offset->line+col` is a binary search, columns count code
points and a tab as one character. Tab stops matter only inside the block parser. Byte offsets (SQLite, pandoc)
are a consumer's problem: `string-utf-8-length` on the prefix.

### 1.2 Nodes and tokens

All structs are immutable and `#:transparent` (structural equality drives the tests). Two kinds of range appear:
the **node span** (what a consumer styles as a unit) and **markup tokens**, the characters that are syntax rather
than content, so the editor can de-emphasize (v0.3) or hide (v0.4 experiment) exactly them.

```racket
(struct token (role start end))          ; role: see the list below
(struct block (start end tokens))        ; abstract; children carry their own spans
(struct document block (text children refmap line-index extensions))
(struct paragraph block (segments inlines))            ; leaf
(struct heading block (level setext? keyword segments inlines))   ; keyword: #f or "TODO" etc. (extension)
(struct thematic-break block ())
(struct code-block block (fenced? fence-char info lines))  ; lines: list of (start end virtual-indent), §1.3
(struct html-block block (kind))                       ; kind 1..7
(struct block-quote block (children))
(struct list-block block (ordered? start-number delimiter tight? children))
(struct list-item block (marker-end content-indent task children))  ; task: #f 'open 'done 'cancelled (ext.)
(struct link-ref-def block (label dest title))         ; kept in the tree so it can be styled and edited
(struct table block (alignments head rows))            ; extension; cells are (start end segments inlines)
(struct front-matter block (fields))                   ; extension; fields: alist or #f if not parseable

(struct inline (start end tokens))       ; abstract
(struct text inline (value))             ; value: decoded (entities, escapes); differs from the source slice
(struct soft-break inline ()) (struct hard-break inline ())
(struct emph inline (children)) (struct strong inline (children)) (struct strike inline (children))
(struct code-span inline (value))
(struct link inline (kind dest title children label))  ; kind: 'inline 'full 'collapsed 'shortcut 'autolink 'literal
(struct image inline (kind dest title children label))
(struct raw-html inline ())
(struct wiki-link inline (target heading alias))       ; extension
(struct tag inline (name))                             ; extension
(struct date-ref inline (date keyword))                ; extension: ISO date, keyword "due" or #f
(struct state-keyword inline (keyword))                ; extension: TODO/WAITING/DONE in a heading
```

Token roles (a closed set, exported as a list so tests can check coverage): `heading-marker` (`#`s and the
closing sequence), `setext-underline`, `quote-marker`, `bullet`, `ordered-marker`, `task-marker`, `fence`,
`fence-info`, `code-indent`, `emph-delim`, `strong-delim`, `strike-delim`, `code-delim`, `link-open` (`[` or `![`),
`link-close` (`]`), `link-dest-open` (`(`), `link-dest` (the destination, with its `<>` if any), `link-title` (the
quoted title when present), `link-dest-close` (`)`), `link-label` (`[ref]` of a full reference), `refdef-label`, `refdef-dest`, `refdef-title`, `autolink-bracket`,
`escape` (the backslash), `entity` (the whole `&amp;`), `hard-break-marker`, `table-pipe`, `table-delim-row`,
`wiki-open`, `wiki-pipe`, `wiki-close`, `tag-hash`, `front-matter-fence`, `html`. Invariants, tested: a node's
tokens lie inside its span; children lie inside the parent and are ordered and disjoint; tokens of one block's
subtree are disjoint; the decoded `value` of a `text` is never used for positions.

### 1.3 Line maps: from block content to source

The hardest positions problem is that inline content is assembled from several lines with container prefixes
(`> `, list indentation) removed and tabs partly consumed. Every leaf block therefore carries `segments`, a list of
`(segment content-start content-length source-start source-length)`: the block's content string is the
concatenation of the segments (joined by `\n`), and an inline content offset maps to source by locating its
segment. Inline tokens never span a segment boundary (a prefix is never inline content; a soft break is the `\n`
between segments). A tab partly consumed by a container prefix yields virtual spaces that occupy content positions
but no source characters: a segment with `content-length` k and `source-length` 0 whose `source-start` is the offset
after the tab, so any token touching them clamps to the tab. Code blocks meet the same case more often (`>\tcode`
inside a quote), so each entry of `code-block-lines` is `(start end virtual-indent)` and the HTML and PDF renderers
emit `virtual-indent` spaces before the source slice. This is precisely where cmark's inline positions went wrong;
making the map part of the data model is what keeps ours right.

Inline nodes are **stored in the memo cache with content-relative offsets** (§3.1) and exposed to consumers with
absolute offsets: `block-inlines` relocates the cached tree through the block's segments on first request and caches
the result on the block instance (a promise; the only mutable slot in the model, invisible to callers).

### 1.4 Reference definitions and extension state

`refmap` maps normalized labels (Unicode case fold, whitespace collapsed, per spec) to `(dest title node)`; the first
definition wins. Because definitions may appear after their use, inline parsing only starts when the block phase
is complete, and the memo key includes a fingerprint of the refmap (§3.1). `extensions` is an `extension-set`
struct of booleans (`tables tasks strike autolink-literal wiki tags dates keywords front-matter`), with
`no-extensions` used by the spec runner and `all-extensions` by the editor.

## 2. Parsing

### 2.1 Phase 1: blocks, line by line

The spec's algorithm (appendix "A parsing strategy"), as cmark implements it. For each line: (1) walk the open
containers from the document down and try to **match** each (block quote: optional 0–3 spaces then `>` and one
optional space; list item: the item's content indent, or a blank line; fenced code and HTML blocks: always match
until their end condition); (2) unless the tip is a paragraph accepting a **lazy continuation** or we are inside a
fence/HTML/indented code block, look for **new block starts** in order: indented code (indent ≥ 4 and not
interrupting a paragraph), fence, ATX heading, block quote, thematic break (checked before list items, which it
outranks), list item (bullet, or ordered with a 1–9 digit number; only `1.`/`1)` may interrupt a paragraph), HTML
block start conditions 1–7 (7 cannot interrupt a paragraph), setext underline (when the tip is a paragraph);
(3) add the remainder to the tip, opening a paragraph if needed. Blank lines close paragraphs and mark list
looseness. **Tabs** are tracked as columns with partial consumption (the `column`/`remaining-spaces` pair cmark
uses), so `>\tfoo` and `-\t\tfoo` produce the spec's virtual spaces. **Finalization**: a paragraph first has link
reference definitions stripped from its start (label, destination, optional title, possibly across lines; a
paragraph consisting only of definitions disappears, its `link-ref-def` nodes stay in the tree), then setext
headings and table detection (§2.3) apply; fenced code records its info string and content lines; lists are marked
tight or loose after all items are closed.

Line handling is a hand-written character scanner over the document string (no per-line substrings, no regexps in
the hot path; a single anchored `regexp-match-positions*` over the 150 KB fixture already costs 9 ms, six times the
whole prototype scan). The block phase produces the tree, segments and refmap in ~1–5 ms for 150–300 KB, which is
what makes §3.1 possible.

### 2.2 Phase 2: inlines per leaf block

Run over the block's content string with a `subject` (string, position, delimiter stack, bracket stack). Code spans
first (a backtick run matches an equal-length run; otherwise literal), then `<` for autolinks (URI and email) and raw
HTML (open/close tags, comments, processing instructions, declarations, CDATA), `\` escapes (ASCII punctuation
only; a backslash before `\n` is a hard break), `&` entities (2,231 named entities vendored from WHATWG
`entities.json` into `entities.rktd`, decimal and hex numeric references, U+0000 → U+FFFD), `*` and `_` delimiter
runs with the left/right-flanking rules (Unicode punctuation and whitespace classes from the spec), `[` and `![`
pushed on the bracket stack, `]` triggering link matching (inline `(dest "title")` with balanced parentheses and
angle-bracket destinations; full, collapsed and shortcut references through the refmap; links may not contain
links, images may contain anything), two-space and backslash hard breaks, soft breaks. `process-emphasis` closes
delimiters with the "rule of 3" and the `openers_bottom` table so it stays linear. Every node records its span and
tokens as it is made: the emphasis node spans from the first used opener character to the last used closer
character, with `emph-delim`/`strong-delim` tokens for the consumed run parts; leftover run characters become
`text`. Decoded values (`text-value`, `code-span-value`, `link-dest` after unescaping and entity decoding,
percent-encoding left to the HTML renderer) are computed once here.

### 2.3 Where the extensions hook in

Each hook is guarded by its flag; with `no-extensions` the code paths are not reached, so the spec suite runs on
the pure parser. GFM and our extensions hook at these exact points:

- **Front matter**: before line 1 only; `---` then lines until `---` or `...`; unterminated → not front matter,
  the lines re-enter the normal block parser. Fields are parsed by a tiny reader (top-level `key: value`, flow
  lists `[a, b]`, block lists `- a`); anything else leaves `fields` `#f` and the block is still a block.
- **Tables** (GFM): when a line would be appended as the second or later line of a paragraph and it is a delimiter
  row whose cell count equals the previous line's, the previous line becomes the header and a `table` starts; earlier
  paragraph lines stay a paragraph. The table ends at a blank line or any other block start; cells are inline
  content with their own segments; excess cells are dropped, missing ones empty; `\|` escapes a pipe inside cells.
- **Task markers** (GFM): at list-item finalization, if the first child is a paragraph whose content starts with
  `[ ]`, `[x]`, `[X]` (or `[-]`, ours, for cancelled) followed by whitespace, the item's `task` is set, a
  `task-marker` token is recorded and the paragraph's first segment starts after the marker.
- **Strikethrough** (GFM): `~` and `~~` runs are a third delimiter type in the attention algorithm (GFM allows
  one or two tildes, matched by equal length).
- **Autolink literals** (GFM): a post-pass over `text` nodes for `www.`, `http://`, `https://` and email
  candidates with GFM's trailing-punctuation and `<`/`)` rules; never inside links, code or raw HTML because those
  are not `text` nodes.
- **Wiki links**: at `[` followed by `[`, an atomic scan for `[[target(#heading)?(|alias)?]]` on one line with no
  `]` inside; success emits `wiki-link` and skips the bracket stack, failure falls back to a plain `[`. So a note
  with the extension off still parses `[[x]]` as the spec does (a shortcut reference inside brackets).
- **Tags and dates**: a post-pass over `text` nodes: `#` preceded by start of text, whitespace or punctuation and
  followed by a letter, then `[\w/-]+`, becomes `tag` (never at a line start, which the block phase already made a
  heading or text); `\d{4}-\d{2}-\d{2}` becomes `date-ref`, with `keyword` set when preceded by `due ` (the keyword
  list is a parameter). Code spans and link destinations are excluded by construction.
- **Heading keywords**: after a heading's inlines are parsed, a first `text` node starting with a configured
  keyword followed by a space is split into `state-keyword` + `text`.

## 3. Incremental re-parsing

### 3.1 v0.3 design: full block pass, memoized inline pass

A `parser` object (one per open document) holds the extension set, a snapshot of the keyword lists taken at
`make-parser` (a global parameter changing under a cache would make it unsound), and an **inline memo**: a hash from
`(leaf-block-kind, content-string, refmap-fingerprint, extension-set + keyword snapshot)` to a content-relative
inline tree. The block kind is part of the key because identical content parses differently in a heading (`TODO
foo` yields a `state-keyword`), a paragraph or a table cell. `parser-reparse!` receives
the new text and the edit (`start end replacement`, from `after-insert`/`after-delete`), runs the block phase in
full (fresh tree, fresh segments, fresh refmap), then for each leaf block looks up its content string: a hit
returns the cached inline tree (relocated lazily, §1.3); a miss parses the block and stores it. Entries not
touched by a parse are dropped afterwards, so memory is bounded by the document. The refmap fingerprint is an
`equal-hash-code` over the sorted normalized labels with destinations and titles: editing a definition invalidates
every inline cache once (tens of ms on a large note, acceptable and rare), while ordinary typing misses only in
the edited block. A definition added **later in the document** than its use is handled by the same mechanism:
the fingerprint changes, the earlier block re-parses and its `[foo]` becomes a link.

The result of a reparse is the new `document` plus a `change-report`: the leaf blocks whose inline tree was
freshly parsed (cache miss), the blocks whose kind, level, depth, list marker or task state differ from the block
covering the same content in the previous document (paragraph-layout changes), and a `structure-changed?` flag when
the block sequence itself changed (a block split, joined, or converted). `md-restyle-region` restyles exactly the
reported ranges; `text%` styles are attached to characters, so unchanged blocks that merely moved keep theirs
(whether paragraph margins move with their paragraphs is a `text%` question for `md-render` to verify, not a parser
concern). Positions are never shifted: every parse computes them fresh from the block pass.

**Budget for one keystroke in a 300 KB, 5,500-line note** (REPLAN `md-restyle-region`: under 10 ms): block pass
≤ 5 ms; inline parse of the edited block < 1 ms; relocation of that block's inlines negligible; the rest for
`change-style` calls. Full parse of the 150 KB fixture ≤ 40 ms (v0.3 acceptance, ≤ 60 ms at 300 KB). The
block/inline split above is estimated; measuring it on the real parser is part of `mdlib-bench`.

### 3.2 Fallbacks

Full re-parse is the only path; there is nothing to fall back to and nothing to splice. Above `large-file-threshold`
(500k characters, the existing guard) the document opens in Source view, whose coloring the same parser provides
from the block pass only (headings, fences, markers), skipping the inline phase entirely.

### 3.3 Later optimization: incremental block pass (reserved, not scheduled)

If `mdlib-bench` shows the block pass exceeding ~10 ms on the 300 KB fixture, the design admits a classic
incremental block phase without changing consumers: keep, per top-level block, its span and the container state at
its start; on an edit, restart at the last **safe restart point** before the edit, a top-level block start that is
not inside a fenced code block, HTML block, indented code, list or block quote (their lazy continuation and
looseness rules make interior points unsafe); re-parse forward until the parser reaches a top-level block start at
or after the edit whose line text and container state equal the old parse (offsets shifted by the edit's size
delta), then reuse the old blocks with shifted offsets. Anything touching a link reference definition forces a full
pass. The consumer-visible API (`document` + `change-report`) is identical, and the `reparse == parse` property test
already exists to guard it.

## 4. Consumers

### 4.1 Editor: style runs, markup tokens, layouts

`(style-runs doc #:start s #:end e)` → sorted, non-overlapping `(run start end roles node)` records covering the
styled spans in the range, where `roles` is the list of roles from outermost to innermost (`'(heading-2 strong)` for
bold inside a heading), so `md-render` composes deltas without walking the tree. Roles: `heading-1..6`, `emph`,
`strong`, `strike`, `code`, `code-block`, `quote`, `link`, `link-dest`, `image`, `wiki-link`, `tag`, `date`,
`keyword` (with the node for its value), `task-done`, `task-cancelled`, `markup`, `html`, `front-matter`. Dates carry
no "overdue" role: the parser does not know today; the editor decides from `date-ref-date`.
`(markup-tokens doc #:start s #:end e)` → the tokens in the range, what the v0.4 hiding experiment turns into
zero-width snips; disjointness lets each become one snip. `(block-layouts doc)` → per block `(start end kind depth
list-level ordered? number)` for `set-paragraph-margins`. `(block-at doc pos)` finds the innermost block at a
position (caret paragraph, Enter in lists, outline).

### 4.2 HTML renderer

`document->html` emits the spec's exact formatting (cmark's: block tags each on their own line, `<br />`,
percent-encoded destinations, entity-escaped text), so the spec runner compares strings **exactly**, as the
`commonmark` package's own tests do; a whitespace-collapsing normalizer is kept as a diagnostic only. Raw HTML is
dropped unless `#:unsafe? #t` (cmark's default posture); **the spec runner renders with `#:unsafe? #t`**, as cmark's
own spec tests run `cmark --unsafe`, because the HTML blocks and Raw HTML sections (64 examples) expect the HTML in
the output. GFM's `tagfilter` is not implemented (comrak deprecated it in 0.55 as "poorly designed"). Extensions render as GFM does (`<del>`, `<input type="checkbox" disabled="">`,
`<table>`), wiki links as `<a href>` through a caller-supplied resolver, tags and dates as `<span class>`. In v0.4
this renderer feeds Copy as Rich Text instead of `pandoc -t html`.

### 4.3 PDF renderer hook (design only)

The tree, decoded values and `block-layouts` are the input; markup tokens are never consulted. A `layout.rkt` turns
blocks into **boxes**: a block box per block with margins from depth and kind (quote indent, list hanging indent,
heading space-before/after, code block padding), inline content shaped into **line boxes** by measuring runs with
`get-text-extent` on the target `dc<%>` (fonts from `tokens.rkt` roles: prose, mono, heading sizes), breaking at
spaces and soft breaks, honoring hard breaks; tables as a grid of measured cells with column widths from the
widest cell, capped at the measure; images scaled to the measure. Pagination is a greedy fill of the page content
box with two rules: a heading never ends a page alone, and a code block splits only between lines. Output goes to
`pdf-dc%` with page numbers; the same layout tree could feed print preview. v0.3's `export-pdf-native` still uses
`print-to-dc` on the styled `text%`; this renderer replaces it when its output looks better (v0.5+).

### 4.4 Edits and the serializer

Formatting commands are **text edits computed from tokens**, not re-serialization, which is what makes their diffs
minimal and undo natural: `toggle-emphasis-edits doc start end kind` returns `(edit start end text)` records that
insert `**` around the selection or the word at the caret, or delete the two `strong-delim` tokens of the enclosing
`strong`; `set-heading-level-edits` replaces or inserts the `heading-marker` token; `toggle-task-edits` rewrites the
three characters of `task-marker` (or inserts `[ ] ` after the bullet); `set-list-edits` adds or removes a `bullet`
/ `ordered-marker` (renumbering the continued item for `md-lists-enter`); `wrap-link-edits` wraps a selection or
URL. `document->markdown` is a normalizing pretty-printer (ATX headings, `-` bullets, `1.` numbering, fenced code,
one blank line between blocks, reference definitions at the end) used by the round-trip property test and, later,
for generated documents (the Today view, imports). It is not used to save the user's file: the file is the truth.

## 5. Testing strategy

- **Spec runner** (`tests/spec-test.rkt`): iterates the vendored `spec-0.31.2.json` (652 examples), parses with
  `no-extensions`, renders, compares exactly; prints per-section counts. A `known-failures.rktd` (example numbers)
  keeps CI green while conformance grows in v0.3; the v0.4 gate is that file being empty.
- **Vendoring with attribution**: `rackmac-markdown/tests/spec/` holds `spec-0.31.2.json`, `gfm-0.29-extensions.json`
  (the 24 examples of the GFM extension sections: tables 8, task lists 2, strikethrough 2, autolinks 11, tagfilter 1,
  extracted by `tools/extract-gfm-examples.rkt` from `spec.txt`; the tagfilter example is skipped) and a `LICENSE.md`
  reproducing the CC-BY-SA 4.0 notice: "Copyright (C) 2014-16 John MacFarlane, commonmark-spec test/spec.txt,
  version 0.31.2, unmodified except extraction to JSON" and, for GFM, "GitHub Flavored Markdown Spec 0.29, GitHub,
  CC-BY-SA 4.0" (its front matter states the license). The test data is not under the repository's own license
  (none is declared at the root today; choosing one is part of `mdlib-docs`); `info.rkt` and README say so.
- **Position and coverage properties** (`positions-test.rkt`): for every fixture and every spec example: children
  inside parents, ordered, disjoint; tokens inside nodes and disjoint per block; every non-blank character of the
  source belongs to exactly one leaf block or block token; `block-inlines` relocation never leaves a block's span.
- **Incremental property** (`incremental-test.rkt`): random edits (insert/delete/replace at random positions,
  including inside fences, list markers and reference definitions) applied to the fixtures; after each edit,
  `parser-reparse!` must equal `parse-document` on the new text (`equal?` on the transparent structs, absolute
  positions included), and the change report must cover every block whose inline tree differs.
- **Round trip** (`serialize-test.rkt`): `parse(serialize(parse(x)))` structurally equals `parse(x)` modulo
  positions; `edits` applied to the text produce the intended structure and touch only the reported ranges.
- **Oracle** (`oracle-test.rkt`, `build-deps` only): a grammar-based generator (headings, lists nested to depth 4,
  quotes, fences, emphasis soup, links and references, entities, tabs) produces documents; our HTML with
  `no-extensions` must equal the package's output written through its spec-format HTML writer; differences are
  saved as regression fixtures. Skips cleanly when the package is absent.
- **Pathological inputs**: cmark's `pathological_tests.py` cases (nested brackets, unclosed emphasis runs, deep
  block quotes) at 10⁴–10⁵ repetitions must finish in linear-looking time (< 1 s).
- **Benchmarks** (`bench.rkt`): the three fixtures from §0, printing block-pass, inline-pass and total; a test
  asserts the §3.1 budgets with a 3× margin so CI does not flake.
- **Editor integration** stays in `tests/` as REPLAN plans: parse → style → `get-text` byte-identical, goldens.

## 6. Module layout, public API, phased plan

### 6.1 Layout

"Usable by other Racket programs" rules out making the library one more collection inside the `rackmac` package:
in a `'multi` package only the root `info.rkt` declares dependencies, and installing the library would drag in
`gui-lib`. So `rackmac-markdown/` is a **sibling package** with its own `info.rkt` (`(define collection
"rackmac-markdown")`, `deps '("base")`, `build-deps '("rackunit-lib" "commonmark-lib")`), the layout
racket-commonmark itself uses, and the app's `info.rkt` lists `"rackmac-markdown"` in `deps`. Locally and in CI that
is two installs (`raco pkg install ./rackmac-markdown ./`); `raco distribute` bundles collections regardless of
packages. This touches #246 `pkg-hygiene`, so `mdlib-pkg` carries that change rather than pretending #246 is untouched:

```
rackmac-markdown/
  info.rkt            collection "rackmac-markdown"; deps: base; build-deps: rackunit-lib, commonmark-lib (oracle)
  main.rkt            public API with contracts (below); re-exports ast.rkt structs
  ast.rkt             structs of §1.2, token roles, extension-set
  chars.rkt           spec character classes (Unicode punctuation, whitespace), tab columns
  entities.rkt        named entities from entities.rktd (vendored WHATWG table)
  lines.rkt           line index, segments, offset<->line/col
  blocks.rkt          phase 1                      inlines.rkt   phase 2 (delimiter and bracket stacks)
  refs.rkt            label normalization, refmap  extensions/   front-matter, tables, tasks, strike,
  parser.rkt          parser object, memo, reparse, change report   autolink-literal, wiki, tags-dates, keywords
  runs.rkt            style runs, markup tokens, block layouts
  html.rkt            renderer                     edits.rkt     token-based edit operations
  serialize.rkt       pretty-printer               layout.rkt    (later) boxes for the PDF renderer
  tests/              spec-test, gfm-test, positions-test, incremental-test, serialize-test, oracle-test,
                      pathological-test, bench; spec/ (vendored data + LICENSE.md); fixtures/
```

`rackmac/markdown/render.rkt`, `edit.rkt` and `snips.rkt` (UI-DESIGN §5.2) stay in the app and consume this
collection; `highlight-markdown!`'s regexes retire in favor of `style-runs` in Source view too.

### 6.2 Public API (`main.rkt`)

Contracts sit on the functions at the collection boundary; structs are exported with plain `struct-out`
(contracted accessors on twenty thousand nodes per keystroke would eat the budget).

```racket
(contract-out
 [parse-document   (->* (string?) (#:extensions extension-set?) document?)]
 [make-parser      (->* () (#:extensions extension-set?) parser?)]
 [parser-parse!    (-> parser? string? document?)]
 [parser-reparse!  (-> parser? string? edit? (values document? change-report?))]
 [document-blocks  (-> document? (listof block?))]
 [block-inlines    (-> leaf-block? (listof inline?))]            ; absolute offsets
 [block-at         (-> document? exact-nonnegative-integer? (or/c block? #f))]
 [style-runs       (->* (document?) (#:start exact-nonnegative-integer? #:end exact-nonnegative-integer?) (listof run?))]
 [markup-tokens    (->* (document?) (#:start exact-nonnegative-integer? #:end exact-nonnegative-integer?) (listof token?))]
 [block-layouts    (-> document? (listof layout?))]
 [offset->line+col (-> document? exact-nonnegative-integer? (values exact-nonnegative-integer? exact-nonnegative-integer?))]
 [line+col->offset (-> document? exact-nonnegative-integer? exact-nonnegative-integer? exact-nonnegative-integer?)]
 [document->html   (->* (document?) (#:unsafe? boolean? #:resolve-wiki (-> string? (or/c string? #f) string?)) string?)]
 [document->markdown (-> document? string?)]
 [toggle-emphasis-edits (-> document? exact-nonnegative-integer? exact-nonnegative-integer? (or/c 'emph 'strong 'strike) (listof edit?))]
 [set-heading-level-edits (-> document? exact-nonnegative-integer? (integer-in 0 6) (listof edit?))]
 [toggle-task-edits (-> document? exact-nonnegative-integer? (listof edit?))]
 [set-list-edits   (-> document? exact-nonnegative-integer? (or/c #f 'bullet 'ordered 'task) (listof edit?))]
 [wrap-link-edits  (-> document? exact-nonnegative-integer? exact-nonnegative-integer? string? (listof edit?))]
 [front-matter-fields (-> document? (or/c #f (listof (cons/c string? any/c))))]
 [document-links (-> document? (listof (or/c link? wiki-link?)))]  ; for lib-index, with headings/tags/tasks/dates alike
 [document-headings (-> document? (listof heading?))] [document-tags (-> document? (listof tag?))]
 [document-tasks (-> document? (listof list-item?))] [document-dates (-> document? (listof date-ref?))]
 [all-extensions extension-set?] [no-extensions extension-set?]
 [heading-keywords (parameter/c (listof string?))] [date-keywords (parameter/c (listof string?))])
(struct-out edit) (struct-out run) (struct-out change-report) ... every struct of §1.2
```

### 6.3 Phased plan

Sizes as in REPLAN (`S` under half a day, `M` one to two days, `L` three to five). REPLAN's `md-parser` (M) and
#220 are **replaced** by the `mdlib-*` keys below; `md-render`, `md-restyle-region`, `md-format-commands`,
`md-lists-enter`, `md-links-click`, `task-*`, `tags`, `outline-*` now depend on them as noted. Total for v0.3:
about three weeks of the seven in REPLAN §2, two more than the scanner estimate; the owner is asked to accept that
cost for a parser the whole product stands on, or to move `mdlib-edits` and `mdlib-bench` below the cut line. The
performance acceptance replaces `md-parser`'s "5,000-line note under 50 ms": the 5,500-line, 300 KB fixture in
§0 is the larger document, and its budget is 60 ms for a full parse, 10 ms for a keystroke.

**v0.3 First notes**: correct, positioned, memoized; may fail rare spec examples as long as it degrades to plain text.

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `mdlib-pkg` | `rackmac-markdown/` as a sibling package (§6.1): `info.rkt`, `main.rkt`, `ast.rkt` structs and token roles, vendored `spec-0.31.2.json`, `entities.rktd`, `tests/spec/LICENSE.md` with CC-BY-SA attribution; the app's `info.rkt` depends on it | S | `raco pkg install ./rackmac-markdown ./` works in a clean Racket and the library alone installs without `gui-lib`; `raco test rackmac-markdown` runs; CI does both installs; README names the licenses | #246 (done together) |
| `mdlib-blocks` | Phase 1 (§2.1): all container and leaf blocks, tabs, fences, HTML blocks 1–7, indented code, setext, thematic break precedence, list rules, lazy continuation, reference definitions, segments and line index; includes the block-level half of the HTML renderer and the spec runner so the sections below can be scored (inline content rendered as escaped text until `mdlib-inlines`) | L | spec sections Tabs, Thematic breaks, ATX/Setext headings, Indented/Fenced code, HTML blocks, Link reference definitions, Paragraphs, Blank lines, Block quotes, List items, Lists ≥ 95% on their block structure; positions-test green | `mdlib-pkg` |
| `mdlib-inlines` | Phase 2 (§2.2): code spans, emphasis, links, images, autolinks, raw HTML, escapes, entities, breaks, with spans and tokens | L | spec sections Backslash escapes, Entities, Code spans, Emphasis, Links, Images, Autolinks, Raw HTML, Hard/Soft line breaks, Textual content ≥ 95%; pathological-test under 1 s | `mdlib-pkg` |
| `mdlib-html` | HTML renderer completed for inlines (spec format, `#:unsafe?`, percent-encoding, entity escaping), spec runner finished with `known-failures.rktd` | M | overall ≥ 600 of 652 at the v0.3 tag, failures listed with reasons | `mdlib-blocks`, `mdlib-inlines` |
| `mdlib-ext` | Extensions of §2.3: front matter, tables, task markers (incl. `[-]`), strikethrough, autolink literals, wiki links, tags, dates, heading keywords; `extension-set` | M | GFM extension examples 23/23 (tagfilter skipped); `no-extensions` leaves spec results unchanged; a test corpus of our syntax | `mdlib-inlines` |
| `mdlib-parser` | `parser` object, inline memo keyed by content and refmap fingerprint, `parser-reparse!`, `change-report` | M | incremental-test: 10,000 random edits over the fixtures, `reparse == parse`; a keystroke in the 300 KB fixture under 10 ms including report | `mdlib-blocks`, `mdlib-inlines` |
| `mdlib-runs` | `style-runs`, `markup-tokens`, `block-layouts`, `block-at` | S | runs non-overlapping and role-stacked; tokens disjoint; every fixture char covered | `mdlib-parser` |
| `mdlib-edits` | Token-based edit operations of §4.4 for `md-format-commands`, `md-lists-enter`, task toggle | M | each operation's diff touches only the tokens it names; toggling twice is the identity; tests across nested markup | `mdlib-runs` |
| `mdlib-bench` | Fixtures (150 KB notes, 300 KB / 5,500 lines, `spec.txt`), block/inline split, budgets with 3× margin | S | 150 KB full parse ≤ 40 ms, block pass ≤ 5 ms at 300 KB, numbers recorded in this document | `mdlib-parser` |

**v0.4 Tasks and links**: conformance is the release gate.

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `mdlib-conformance` | 652/652 CommonMark 0.31.2 and the 23 GFM extension examples; `known-failures.rktd` empty and its mechanism removed | M | CI fails on any spec regression | `mdlib-html` |
| `mdlib-oracle` | Differential test against `commonmark-lib` (build-dep) on generated documents; disagreements become fixtures | S | 1,000 generated documents agree; skips without the package | `mdlib-conformance` |
| `mdlib-serialize` | `document->markdown` and the round-trip property | M | round trip on every fixture and spec example modulo positions | `mdlib-edits` |
| `mdlib-index-api` | `document-links/headings/tags/tasks/dates`, `front-matter-fields` for `lib-index`, `tags`, `task-dates`, `today-view` | S | one pass extracts everything the index stores; tests | `mdlib-ext` |
| `mdlib-html-clipboard` | `copy-rich` uses `document->html` instead of `pandoc -t html` | S | Word and Outlook paste headings, lists, tables, task lists | `mdlib-conformance` |
| `mdlib-block-incremental` | §3.3, only if `mdlib-bench` shows the block pass over 10 ms at 300 KB; otherwise closed with the measurement | L | incremental-test unchanged and green | `mdlib-bench` |

**Later** (v0.5–v0.6): `mdlib-layout` (boxes and line breaking, M), `mdlib-pdf` (`pdf-dc%` renderer replacing
`print-to-dc`, L), `mdlib-docs` (Scribble manual and catalog publication as `rackmac-markdown`, S), `mdlib-code-in-fences`
(hand fenced content to the code Languages' lexers for coloring, S, with `lang-racket-lexer`).

## 7. Risks and open questions

1. **Positions through prefixes and tabs.** The segment map (§1.3) is new territory and the place other parsers got
   wrong. Mitigation: the coverage and containment properties run on every spec example from `mdlib-blocks` on.
2. **Inline phase cost in Racket.** 27 ms at 150 KB for a positionless parser means ours may reach 50 ms; the memo
   makes typing independent of it, but the first render of a large note and every reference-definition edit pay it,
   and a keystroke inside one huge paragraph (pasted text without blank lines) re-parses that whole paragraph.
   Mitigation: hand-written scanners, no per-node contracts, a "20 KB single paragraph under 10 ms" line in
   `mdlib-bench`, and the budgets as a gate, not a hope.
3. **Extensions versus conformance.** Wiki links, tags and dates change what `[[x]]`, `#x` and digits mean. The
   flags keep the spec suite honest, but the editor always runs with them on, so their corner cases (a `#` inside a
   URL, a date inside a citation) need their own corpus, owned by `mdlib-ext`.
4. **`text%` paragraph margins after structural edits.** Whether margins follow paragraphs when lines are inserted
   above is unverified; if not, `md-render` must re-apply layouts for every block after the edit, which the
   `change-report` can flag (`structure-changed?`) but which costs time on long notes.
5. **Open: which dates count.** Bare ISO dates anywhere, or only after a keyword (`due`, `scheduled`)? The
   parameter `date-keywords` defaults to `("due")` and bare dates are recognized; the owner may narrow this once the
   Today view exists.

**Why this beats wrapping pandoc's AST or forking `commonmark`.** Pandoc's JSON AST carries no source positions,
costs a process launch (hundreds of milliseconds) per call, and is an optional tool by product principle, so the
editor could never depend on it for rendering. The `commonmark` package is excellent as an oracle, but its structs
hold decoded strings and no positions, its inline reader works on ports with `port-count-lines!` over already
stripped paragraph text, and its block reader uses compiled regexps per line; adding spans, tokens, segments and a
memo would rewrite both phases of its 1,900 lines while inheriting a shape (`heading` holds `content` and `depth`,
no tokens) that the editor cannot use. Our own implementation, following the same spec algorithm, gives one tree
with positions for every node and every marker, memoized inline parsing, switchable extensions, and a renderer
path we own from HTML to PDF, at the cost of about three weeks and a conformance suite that tells us exactly how
far along we are.
