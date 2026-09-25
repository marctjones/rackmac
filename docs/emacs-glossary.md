# Emacs glossary

Material for the Emacs preset (v0.8, epic E13, GitHub #263) — **not part of the default
product.** Rackmac's default experience uses office vocabulary throughout (Document/Tab,
Cursor/Selection, Cut/Paste, Language, and so on); an ordinary Windows or macOS user never
sees an Emacs term. When the Emacs preset is enabled, it uses this table to reintroduce
Emacs names as command aliases and labels.

| Emacs | Rackmac |
|---|---|
| buffer | Document, Tab |
| window / frame | Pane / Window |
| point, mark, region | Cursor, Selection |
| kill / yank | Cut / Paste |
| kill ring | Clipboard History |
| M-x | Command Palette |
| minibuffer, echo area | Command bar, Status message |
| mode line | Status bar |
| major mode | Language |
| minor mode | Option |
| keymap, key binding | Shortcut |
| hook | Trigger |
| init file | Customize with Code |
| evaluate | Run |
| *scratch* | Scratch Pad |
| *Messages* | Activity log |
| describe-key | What Does This Key Do? |
| describe-function | Explain a Command |
| package | Extension |

See also `rackmac/presets/emacs-names.rktd`, the data file preserving the Emacs-style
command aliases (`yank`, `find-file`, `kill-region`, ...) that used to ship in the default
product's `#:aliases` lists before docs/REPLAN.md §8 moved them behind this preset.
