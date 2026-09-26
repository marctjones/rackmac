# Handoff

_Kept current by long-running sessions after every tag (docs/DEVELOPMENT.md). A fresh session reads this first._

## State (2026-09-26)

- Last tag `v0.3.0-alpha.2` (E2.M0). Pending tags: E4.M1 (merged, waits for green CI) and E3.M1 (waits for the data-safety fixes below).
- Owner direction (2026-09-26): implement milestones in priority order, skipping E13; commit, test, tag
  `v0.3.0-alpha.K` per closed milestone and push; parallelize where files don't collide; interactive GUI testing allowed
  (see DEVELOPMENT.md exception). Working assumption for open decision #331: option (a), the bench sidebar, until the
  owner says otherwise. #330 and #332 are also open; work not blocked by them proceeds.
- `caffeinate -dims` runs in the background so the display stays awake for GUI tests.
- Other sessions on this Mac (skiaracket) ask for quiet periods: pause compiles and test runs until they say "quiet
  period ended".

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

## Priority order (v0.3)

1. CI #284 (guards everything after).
2. Lane P: #318 → #321 → #322 → #320 → #319 → #323 → #324, closing MDLIB.
3. Lane R: settings (#270, #271) → recents (#274, #275) → autosave E3.M1 (#74–#78) → Library (#272, #276, #277,
   #290, #273) → Settings dialog #291 and menus #289 → small milestones (#254, #264, #288).
4. After MDLIB: E14.M1 (restyle, render, formatting commands, toolbar, spell check).
5. E18.M1 exports; E0.M3 bundle; #283 live check; tag `v0.3.0`.

## In flight

- `../rackmac-app` / `app` (Opus): fixing Fable's E3.M1 data-safety review (3 must-fix: Don't Save then Cancel on quit,
  encoding/EOL on restore, stale-file overwrite; 5 should-fix; crash-test CI flake). Main's CI is red on that flake until it lands.
- `../rackmac-app2` / `app2` (Opus): #266 md-restyle-region, #268 md-render (E14.M1).
- `../rackmac-mdlib` / `mdlib` (Opus): #323 mdlib-edits, #320 mdlib-ext.
- Done and merged since alpha.2: #278, #280, #281 (E18.M1 left: #279 PDF after md-render, #282 clipboard spike);
  #291, #289 (E4.M1 complete); #321, #322; E3.M1 #74–#78 (tag after fixes).
- app.rkt requires: one feature module per line to avoid merge conflicts.
