# Developing Rackmac

Rules for anyone (person or agent) changing this repository.

## Product rules

- **Modern shortcuts only.** Defaults follow macOS, Windows, Microsoft Office and Chrome conventions.
  No Emacs-style key sequences in the defaults; `tests/shortcuts-test.rkt` enforces this. Emacs keys belong
  only to the optional v0.7 preset.
- **Office vocabulary in the UI.** "Document/Tab", "Language", "Activity log", never "buffer", "major mode",
  `*starred*` names. Emacs names go in `#:aliases` so the palette still finds them. Never rename a command's
  symbol; `tests/vocab-test.rkt` pins them (add new names there).
- **Native controls, modern layout.** Follow `docs/UI-DESIGN.md`. Colors come from `rackmac/ui/tokens.rkt`
  (roles, light and dark); spacing from `rackmac/ui/layout.rkt`; icons from `rackmac/ui/icons.rkt`.
- **macOS first.** Releases target macOS. Keep Windows code paths compiling and their tests passing, but
  Windows-only work is deferred (label `platform:windows`).
- **Pre-release.** Versions are v0.x. Do not create, plan or mention a v1.0.

## Code rules

- Match the surrounding style: short modules, a header comment saying what the module is for, comments
  only where they explain *why*.
- Commands: `define-command` with `#:title`, `#:aliases` (include the Emacs name if there is one), `#:help`
  (one plain sentence ending in a period), `#:icon` if it appears in a menu, `#:menu`/`#:menu-order`, and keys
  per platform (`#:keys`, `#:keys/mac`, `#:keys/windows`). `#:when` for "does it apply right now".
- Anything a user or an extension can register (commands, keys, hooks, modes, toolbar items, context items,
  status segments, settings) must call `register-undo!` (`rackmac/owner.rkt`) so it unloads with its extension.
- Dialogs that ask the user something are parameters (see `confirm-save-changes`, `confirm-discard-changes`
  in `rackmac/commands.rkt`) so tests can answer them.
- Painted widgets keep drawing in a pure function of their inputs so they can be tested on a `bitmap-dc%`.
- No new dependencies beyond the standard Racket distribution without asking.

## Tests

- Run everything: `raco make rackmac/*.rkt rackmac/ui/*.rkt rackmac/lang/*.rkt tests/*.rkt main.rkt && raco test tests`
- Every change adds or updates tests. Prefer behavior tests through the real registry and the real (hidden)
  window (`tests/window-test.rkt`, `tests/toolbar-test.rkt` show how: `make-main-frame` without `show`,
  drive controls with `command`, synthetic `key-event%`/`mouse-event%`, assert through hooks and state).
- Generated docs have drift tests: the README shortcut table (`rackmac/cheatsheet.rkt`), the glossary
  (`rackmac/glossary.rkt`), `ROADMAP.md` (`racket tools/roadmap.rkt`). Regenerate them when they change.
- Never launch the GUI (`racket main.rkt`), send keystrokes, or take screenshots from an automated agent.
  Visual checks are done by the maintainer session, announced to the owner first.

## Commits, issues, releases

- Small commits, each with passing tests. Message: a short summary line naming the GitHub issues
  (`(#59, #60)`), a blank line, bullets saying what changed and why, the test count change, then the trailer
  `Co-Authored-By: <model> <noreply@anthropic.com>`.
- Push to `origin main`. Close each finished issue with `gh issue close N --repo marctjones/rackmac
  --reason completed --comment "Done in <sha>. Tests: <file>."`; comment instead if only partly done.
- GitHub issues are the source of truth for status. `ROADMAP.md` is the initial plan.
- Releases are annotated tags `v0.N.0` on `main`, made by the maintainer after a review.
