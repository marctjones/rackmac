# Handoff

_Kept current by long-running sessions after every tag (docs/DEVELOPMENT.md). A fresh session reads this first._

## State (2026-09-27)

- Last tag `v0.3.0-alpha.7`. v0.3 is down to 6 open issues: #330 (font-bundling decision, genuinely unresolved),
  #331/#332 (built per recommendation, awaiting owner sign-off to close), #400 (CI diagnostic, non-blocking), #283
  (live macOS check — owner-driven, blocks the final `v0.3.0` tag), #226 (epic tracking issue).
  Owner direction (2026-09-26): implement milestones in priority order, skipping E13; commit, test, tag
  `v0.3.0-alpha.K` per closed milestone and push; parallelize where files don't collide; interactive GUI testing allowed
  (see DEVELOPMENT.md exception). **This E13-skip direction is still standing** — do not start E13 (Emacs preset)
  without a fresh owner go-ahead, even though it appears next in milestone-number order.
- 2026-09-27: an Opus review cross-checked the tracker against `REPLAN.md`/`PRODUCT.md`/`UI-DESIGN.md`/
  `MARKDOWN-DESIGN.md`/`ASSISTANT-DESIGN.md` and filed #401–#412 (mostly MDLIB "Later" work, now milestone
  `MDLIB.M3 Renderers and docs`) for plan-documented gaps that had no issue. It also found three duplicate pairs
  still both open — **#261/#313, #141/#298, #82/#314** (the last pair may be genuinely different scopes; check
  before closing) — and confirmed `ASSISTANT-DESIGN.md §8`'s v0.7–v0.9 renumbering hasn't propagated to REPLAN,
  `roadmap.rktd`, or any `release:` label. Decision **#396** (E21 placement/model/trust mode, still open) should
  settle which numbering wins.
- 2026-09-27: every open issue not already carrying a `model:*` label (190 of them) was assigned one in bulk by
  milestone-level heuristic (parser/FFI/rendering/a11y/layout/index work → `model:opus-5.5`; crisp, contained
  acceptance criteria → `model:sonnet-5`; pure docs/glossary → `model:haiku-4.5`; needs a live machine or real API
  key → `model:lead`) — see the label on each issue rather than a hand-maintained table from here on. E21 already
  had per-issue labels from when it was filed; those were left as-is.
- `caffeinate -dims` runs in the background so the display stays awake for GUI tests.
- Other sessions on this Mac (skiaracket, excise) ask for quiet periods: pause compiles and test runs until they say
  "quiet period ended". **Check for one in effect before running `raco` or spawning lane agents** — this Mac runs
  multiple concurrent Claude sessions and an in-progress, uncommitted `tests/open-clean-test.rkt` was found in this
  checkout on 2026-09-27; it's not tracked in git history, so it belongs to another session's live work. Leave it.

## Parallel lanes and the collision rule

Two agents never write the same file. `rackmac/commands.rkt` is the collision point, so **new features put their
commands in their own module** (`rackmac/<feature>.rkt` using `define-command`, required from `app.rkt`), never in
`commands.rkt`. Each agent works in its own worktree on its own branch. The lead session reviews, reruns the suite on
`main`, merges and pushes. Agents never push or tag.

| Lane | Scope | Worktree / branch |
|---|---|---|
| P, parser | `rackmac-markdown/` only (MDLIB v0.3 part) | `../rackmac-mdlib` / `mdlib` |
| R, app | `rackmac/`, `tests/`: one agent at a time | `../rackmac-app` / `app` |
| Lead | merges, CI, reviews, tags, bookkeeping, interactive tests | main checkout |

## Model per milestone (v0.3)

| Milestone | Issues → model | Why |
|---|---|---|
| MDLIB (v0.3 part) | #318 inlines, #321 parser, #322 runs, #323 edits → **Opus**; #319 html, #320 ext, #324 bench → **Sonnet** | Delimiter-stack and incremental-reparse correctness propagate everywhere; the others are spec-driven and checked by the spec tests |
| E14.M1 Writing | #266 restyle-region, #268 md-render, #269 view toggle, #351 spell check (FFI) → **Opus**; #333, #334, #335, #336, #337, #338, #339, #352, #267 finish → **Sonnet** | Styling engine, performance and FFI need design judgment; the rest have crisp acceptance criteria |
| E15.M1 Library | #270, #271, #272, #274, #275, #276, #277, #290 → **Sonnet**; #273 lib-sidebar → **Opus** | The sidebar is the largest new surface and carries the #331 design |
| E3.M1 Autosave | #74–#78 → **Sonnet** | Well specified; the crash test (#78) proves it |
| E4.M1, E1.M3, E1.M4, E2.M0, E2.M2 | #291, #264, #289, #254, #288 → **Sonnet** | Contained changes with tests |
| E18.M1 Word/PDF | #278, #280, #281 → **Sonnet**; #279 PDF export, #282 clipboard spike → **Opus** | Pagination and platform probing need judgment |
| E0.M3 Distribution | #284 CI → **lead**; #285 pkg-hygiene, #286 app bundle → **Opus**; #283 live check → **lead** (interactive) | Packaging decisions touch how init files load the API |
| Before every tag | adversarial review of delivered vs. acceptance → **Fable** | One strong sample reviewing the v0.3 plan |
| Bookkeeping | issue closing, milestone counts, README/ROADMAP regeneration → **lead**, or **Haiku** for bulk | Mechanical |

Reassign if an agent's first report is weak.

## Priority order (v0.3) — done except the tail

1. ~~CI #284~~ ~~Lane P (MDLIB)~~ ~~Lane R (settings, recents, autosave, Library, Settings dialog, menus)~~
   ~~E14.M1~~ ~~E18.M1~~ all closed.
2. Remaining: owner decision on #330 (fonts) → #283 live check (owner-driven) → tag `v0.3.0`.

## Priority order (post-v0.3) — proposed, not yet started

Nearest-to-done milestones first (least new work to reach a closed milestone), staying inside whichever scope the
owner confirms next (see the open scope question in chat as of 2026-09-27 — how far past v0.3 to go, and whether
E13/E12.M2-icebox are in or out):

1. E6.M1 Find bar (1 open), E2.M4 status bar (1 open), E3.M3 Files (1 open), E9.M2 Sidebar (1 open), E15.M2
   Templates (1 open) — small remainders on otherwise-closed milestones.
2. E17.M1 Tasks/states/dates/tags (#294–#297) and E17.M2 Outline — v0.4, unblocked, no open decisions.
3. E7 (Clipboard History, Record Actions, Selection actions), E8 (Activity panel, Extension failures), E16 (Linking
   and backlinks) — v0.4/v0.5, unblocked.
4. E9.M1 Split panes, E11 (Extension platform) — larger, foundational; E11 is a good candidate to prototype the
   core/extension boundary discussed 2026-09-27 (agenda-style views, etc. as extensions once the API exists).
5. E13 (Emacs preset) and E12.M2 (Legal workspace, icebox) — **only with a fresh owner go-ahead**; both currently
   override standing owner directives (E13 was explicitly told to be skipped; E12 is "Parked by request").
6. E21 (Assistant) — blocked entirely on decision #396.

## In flight

- Tags so far: v0.3.0-alpha.1 through alpha.9. Wave 1 (#87, #109, #353) is fully merged, tested (682 passing),
  tagged, and pushed as of alpha.9. The `app`, `app2`, and `mdlib` worktrees are all clean (checked 2026-09-27).
  **No pull requests, ever** (owner instruction, 2026-09-27) — see docs/DEVELOPMENT.md's new Workflow section.
  Close #261 and #141 as duplicates when convenient (blocked here by a Bash permission-classifier denial on
  `gh issue close`, not a GitHub-side problem); #87 itself should also be closed (implementation predates this
  effort, this wave only added test coverage) referencing e97dfb9/d6f1fd3/55c2da3 plus tests/encoding-test.rkt.
- **Before starting new lane work: check whether the shared-Mac quiet period is still in effect.** Other sessions on
  this Mac (skiaracket, excise) have asked for quiet periods before, and an untracked, uncommitted
  `tests/open-clean-test.rkt` was found in the main checkout on 2026-09-27 — not ours, don't touch it, don't clean it
  up, it's evidence someone else is mid-edit.
- Owner declined computer-use control of Rackmac; live checks are read-only window captures unless the owner drives.
- #400: the CI "runs without Racket installed" step is non-blocking until diagnosed.
- Model assignment for all remaining issues now lives on each issue's `model:*` label (bulk-assigned 2026-09-27),
  not in a hand-maintained table — check the label before picking an agent for an issue.
