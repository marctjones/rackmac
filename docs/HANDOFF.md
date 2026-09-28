# Handoff

_Kept current by long-running sessions after every tag (docs/DEVELOPMENT.md). A fresh session reads this first._

## State (2026-09-27, end of session)

- Last tag `v0.3.0-alpha.12`. **All standing decisions from this session are now resolved** — see "Decisions
  resolved 2026-09-27" below. The only thing left before the final `v0.3.0` tag is **#283**, the owner-driven
  live macOS interactive check (typing, Cmd+B, palette, zoom) — cannot be automated, needs the owner at the
  keyboard.
- Owner direction (2026-09-26, reaffirmed 2026-09-27 for scope through E21/E13/E12 inclusive): implement
  milestones in priority order; commit, test, tag `v0.3.0-alpha.K` per merged chunk of work and push;
  parallelize in worktrees where files don't collide. **Never open a pull request** — direct `git merge` by
  the lead session into `main`, always (docs/DEVELOPMENT.md's Workflow section). E13 (Emacs preset) and
  E12.M2 (Legal workspace, icebox) are explicitly in scope now, overriding the earlier skip/park directives —
  don't treat work on either as a mistake if a future session picks it up, but also don't assume it's been
  *started* just because it's *authorized*; nothing in E13/E12 has been touched yet.
- 2026-09-27: an Opus review cross-checked the tracker against the design docs and filed #401–#412 (mostly
  MDLIB "Later" work, now milestone `MDLIB.M3`) for plan-documented gaps with no issue. Found three duplicate
  pairs; **#261/#313 and #141/#298 confirmed duplicates and closed** (#261, #141 closed 2026-09-27); **#82 vs
  #314 still needs a human read** — may be genuinely different scopes (external-file-change compare vs.
  general document compare), not just a title match.
- 2026-09-27: every open issue lacking a `model:*` label (190 of them) was bulk-assigned one by milestone-level
  heuristic — see the label on each issue, not a hand-maintained table, when picking a model for an agent.
- Other sessions on this Mac (skiaracket, excise, and others per `ListAgents`) may ask for quiet periods —
  check before running `raco` or spawning lane agents if resuming after a gap. An in-progress, uncommitted
  `tests/open-clean-test.rkt` (untracked, no git history) belongs to another session — leave it alone,
  whenever it appears or disappears.

## Decisions resolved 2026-09-27

- **#330 fonts**: bundle. IBM Plex (Serif/Mono/Sans) plus two more OFL faces — **Atkinson Hyperlegible**
  (accessibility, low-vision legibility, pairs with epic E10) and **JetBrains Mono** (popular code-font
  alternative). Acceptance criteria need updating to cover the two additions' TTFs and license notices.
- **#331 sidebar** and **#332 formatting icons**: owner confirmed fine as built. Both closed.
- **#396 Assistant decisions** (10 sub-items): accepted as recommended, with two resolved by same-day
  research rather than taken blind:
  - **Local models (item 9), un-deferred**: real Racket packages exist for Ollama (`ollama`, `ollama-lib`),
    and Ollama's MLX backend (landed ~March 2026) gives strong Apple Silicon performance as a *shared*
    server multiple apps can route to — exactly what was asked for. Filed as **#418**, new milestone
    **E21.M6 Local and alternative models** (#72).
  - **Subscription-as-transport, ruled out**: the owner asked whether a Claude Pro/Max subscription could
    power the Assistant instead of API billing (to save cost while keeping prompt-caching benefits).
    Researched, not assumed: Anthropic has enforced server-side since 2026-01-09 that subscription OAuth is
    for Claude Code/claude.ai only, not third-party reuse (even Anthropic's own Agent SDK headless path
    moved off the subscription quota onto separate billing on 2026-06-15). Filed as a decision record,
    **#417**, so this doesn't get silently re-proposed later without the context. The actual goal (cheap
    repeated-context calls) is unaffected: prompt caching is a normal Messages-API feature, available with
    ordinary API-key billing, which #359/#361 already assume — item 2 (default model `claude-opus-5` via
    API key) resolves as originally recommended.
  - Small follow-up **not yet done**: `ASSISTANT-DESIGN.md §8`'s recommended release renumbering
    (Workspace→v0.7, Open→v0.8, Emacs preset→v0.9) still hasn't been applied to existing issue labels now
    that v0.6-for-E21 is confirmed. Low priority, flagged in the #396 comment thread.
- **New milestone `E14.M3 Tables`** (#71): filed from a 2026-09-27 discussion on why office workers misuse
  Excel for non-numeric list-keeping. #343 (table alignment) moved into it; added **#414** (row/column
  insert-delete, cell navigation), **#415** (sort table by column), and **#416** (paste from Excel → GFM
  table, filed under E18.M2 since it shares #307's clipboard-detection path). Explicitly out of scope:
  formulas/computation — GFM tables have no formula concept and adding one would break the
  reads-the-same-everywhere portability guarantee the whole product depends on.
- **Tutorial critique**: the shipped Get Started tutorial (#103, closed) is a deliberate, already-live homage
  to the Emacs tutorial's learn-by-doing structure, but its content predates most of what shipped this
  session (Find-all, Clipboard History, Record Actions, Outline nav, selection tools, task-state cycling)
  and needs restructuring into staged tiers once #102/#104 are picked up — not filed as new issues yet,
  captured here for whoever resumes E5.M2.

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

Model assignment is now per-issue via the `model:*` label (see "Decisions resolved" and the bulk-labeling note
above) — the old hand-maintained v0.3 table this section used to hold is fully superseded; don't recreate one.

## Priority order (v0.3) — one item left

Everything else closed. Remaining: **#283 live check** (owner-driven, interactive, can't be automated) →
tag final `v0.3.0`.

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

## Update 2026-09-28 (after the 09-27 stop): wave 4 landed, publishing epic filed

- **Wave 4 merged, 894 tests passing, tagged `v0.3.0-alpha.13`**: #416 (paste a copied spreadsheet range as a GFM
  pipe table) and #343/#414/#415 (pipe-table alignment, row/column editing, cell navigation, sort by column).
  #416 turned out to need the rich-paste base layer (`pasteboard.rkt`, `paste-dispatch.rkt`, a small `do-paste`
  override in `buffer.rkt`) because **#307 (paste-from-word) is still open**; my brief wrongly called it shipped
  (only the #282 spike is closed). #307 should register an HTML-via-pandoc converter *below* priority 100.
  Both branches were checked by reading the diff before merging; the only merge conflict was two adjacent
  one-line requires in `app.rkt`.
- **The "flaky" `md-view-test` is a load artefact, now measured**: about 215 ms to Source and 250 ms to Formatted
  on a quiet machine (budget 1000 ms), and roughly 1000-1600 ms when the shared Mac's load average is 12-45.
  Neither the table `#:when` checks nor anything else merged today affects it.
- **New epic E22 Publishing (#429)**, design in `docs/PUBLISHING-DESIGN.md`: Scribble, Slideshow and Pollen as
  editable Rackmac Languages with a live preview, PDF and slides first, visible styles, Pollen layer for power
  users. Milestones E22.M1 (#419-#424 Scribble + preview), E22.M2 (#425-#427 Slideshow), E22.M3 (#428 Pollen,
  optional, detect-never-bundle). Two spikes gate the embedded previews: #422 (WKWebView) and #425 (capturing
  Slideshow picts). Documents in these languages are programs, so preview is explicit and sandboxed. Depends on
  E19 language groundwork still open (#310, #315). Pollen is not installed here; Scribble/Slideshow/pict are.
- Local models: a verified MLX bridge exists in `/Users/marc/Documents/GitHub/racket-steering`
  (`scripts/mlx_generate.py`, `scripts/eval-local.rkt`); see the comment on #418 (batch-shaped, not interactive).
- Reminder: close the GitHub issue as the last step of landing something (see the 09-27 note below).

## Update 2026-09-28 (later): E22 Scribble slice landed, tags alpha.14 and alpha.15

- **alpha.14**: #419 Scribble as a Language (`rackmac/lang-scribble.rkt`; `mode.rkt` gained `#:first-line`, so a
  `#lang` line beats the extension), #424 Publishing settings (`rackmac/publish-settings.rkt`), #422 spike.
- **alpha.15**: #420 Preview builds a `.scrbl` to HTML in a sandboxed subprocess (`scribble-build.rkt`,
  `scribble-worker.rkt`, `scribble-preview.rkt`). 957 tests passing.
- **The web view is a GO** (`docs/spikes/webview-embed.md`): a `WKWebView` embeds beside the editor with conditions
  recorded on #423 (hand-built ObjC blocks, `#:async-apply`, results via a script message handler, build the
  preview outside `$TMPDIR`). Not yet verified live: a real mouse click into the page and back, and racket/gui
  focus events. Add both to the #283 live check.
- **Security decisions made while reviewing**: a document is a program, so (1) Run Selection/Run Document refuse in
  Scribble (`runs-in-app` mode local; the body guard exists because key bindings ignore `#:when`, #398), (2) the
  build worker gets a scrubbed environment (a probe showed `getenv` leaked a secret; fixed and tested), (3)
  **#431 blocks #421/#423**: a preview must not be able to make network requests, because a built document can read
  its folder and Library and write that into HTML, and only showing the HTML gives it a way out. #432 lists the
  remaining sandbox hardening.
- **The Settings dialog is taller than the screen** (908 pt on an 833 pt display, before anything new). #424's help
  text under each control made it 1569 pt, so that part was backed out. **#430** adds a scroll area.
- Lead-side reviews that mattered this session: reading the diff caught the Run-in-app hole, the dialog height
  (measured with `get-graphical-min-size`), and the environment leak (probed through the real build function).
  Measure and probe; do not trust a report or a green suite alone.
- Next for E22: #431 (ready), #425 Slideshow spike (ready), #428 Pollen detect (ready), then #421/#423 once #431
  lands. #426, #427 follow the Slideshow spike.

## In flight — nothing (as of 2026-09-27's stop; see the updates above).

- **Bookkeeping gap caught and fixed just before archiving**: all 14 issues shipped this session (#87, #109,
  #353, #303, #298, #299, #294, #302, #118, #121, #125–129) were merged/tested/tagged but never actually
  closed on GitHub — the merge-test-tag-push loop never included the `gh issue close` step. All closed now,
  each commented with its merge commit. **Lesson for next time**: close the issue as the last step of landing
  a wave item, not as an afterthought — check `gh issue list --state open` against what's actually in `main`
  before trusting milestone completion percentages.

- Tags: v0.3.0-alpha.1 through **alpha.12**. Three full waves merged, tested, tagged, pushed this session:
  - Wave 1: #87 (encoding test coverage), #109 (Find-all highlight), #353 (New from Template)
  - Wave 2: #303 (lib-watch), #298 (Outline sidebar), #299 (promote/demote/move section), #294 (heading states)
  - Wave 3: #302 (lib-index, SQLite+FTS5), #118 (Clipboard History), #121 (Record Actions), #125–129 (five
    selection tools)
  841 tests passing at the end of wave 3. **No agents running, no worktrees with unmerged work, `main` ==
  `origin/main`.** This is a genuine stopping point, not a paused one — the session ended here at the
  owner's request to archive/clear it.
- **No pull requests, ever** (owner instruction, 2026-09-27) — see docs/DEVELOPMENT.md's Workflow section.
  Every merge this session was a direct `git merge` by the lead into `main`; no PR has ever existed on this
  repo.
- Filed #413 (E17.M2 outline sidebar vs. promote/demote disagree on headings nested in a block quote/list
  item — both #298 and #299 are individually correct, this is a cross-feature seam for whoever builds the
  real mdlib document-headings API, #328).
- A wall-clock test, `tests/md-view-test.rkt`'s "5,000-line note switches in under a second" check, is
  reliably flaky under this shared Mac's load (confirmed independently by three separate agents plus the
  lead across multiple waves): fails around 1000–1200ms under concurrent load, passes at 650–800ms isolated.
  Not a regression from anything merged this session — rerun that one file alone before concluding a real
  regression exists, the same way it was verified three times over today.
- Owner declined computer-use control of Rackmac; live checks are read-only window captures/screenshots
  unless the owner drives interactively.
- #400: the CI "runs without Racket installed" step is non-blocking until diagnosed.

## Next session, in priority order

1. **#283** live check (owner-driven) → tag final `v0.3.0`.
2. Wave 4 candidate, ready to dispatch, no open questions: **E14.M3 Tables** (#414, #415, #416, plus #343).
3. **E21.M6** (#418 local-model backend) is designable/buildable independent of the rest of E21 starting.
4. Broader E21 work can now proceed past #396 (resolved) whenever the owner wants it — start with #388
   (as-tools-library, depends on #302/#306 which are ready) and #363 (as-policy-read, no dependencies).
5. E7/E8/E16's remaining unblocked issues (the wave-4/5 candidates identified pre-table-detour): #302's
   downstream unlocks — #295/#296/#297 (E17.M1 remainder), #304/#305/#306 (E16.M1 remainder) — plus E8
   (Activity panel, Extension failures), plus #119/#120/#122/#123/#124 (the E7 issues that depended on #118/
   #121, now unblocked).
6. E13 and E12.M2 remain authorized but untouched — pick up whenever, no fresh go-ahead needed (that was
   already given 2026-09-27), just genuinely not started yet.
