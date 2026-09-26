#lang racket/base
;; Menu snapshot (#289, menu-tools): the full menu bar's titles and item labels, in order, for
;; a prose document and a code document, with every feature module loaded (app.rkt, as
;; tests/shortcuts-test.rkt does), so every menu item that exists is in it. A drift test -- when
;; an issue changes what either document type shows, this fails and the golden snapshots below
;; are the thing to update, deliberately, alongside it. They differ by the Format menu, which
;; only prose documents show (md-format.rkt's #:when; frame.rkt hides an empty top menu).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/string
         "../rackmac/commands.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt"
         "../rackmac/command.rkt"
         "../rackmac/app.rkt")   ; every feature module, so their menu items are in the snapshot

(define f (make-main-frame))                ; hidden: show is never called

;; Menu items carry their shortcut baked into the label (command-menu-label, frame.rkt): four
;; spaces then the key on macOS, a tab then the key on Windows. Stripped so the snapshot reads
;; as plain menu structure regardless of platform.
(define (strip-shortcut s)
  (regexp-replace #px"(\t.*|  .*)$" s ""))

;; A submenu (Editor Theme, Open Recent, Extensions) is a nested menu%; everything else is a
;; leaf item or a separator. Recurses so any depth of submenu is captured.
(define (snapshot-menu m)
  (send m on-demand)
  (for/list ([item (in-list (send m get-items))])
    (cond
      [(is-a? item separator-menu-item%) "---"]
      [(is-a? item menu%) (cons (send item get-label) (snapshot-menu item))]
      [else (strip-shortcut (send item get-label))])))

(define (snapshot-menu-bar)
  (for/list ([m (in-list (send (send (main-frame) get-menu-bar) get-items))])
    (cons (send m get-label) (snapshot-menu m))))

;; A prose (Markdown) document: every menu, the Format menu included.
(define golden-prose
  '(("File" "New Note" "Open…" "Quick Open…" ("Open Recent" "Files you open appear here.")
     "Add Folder…" "Import Word Document…" "Remove Folder…" "---"
     "Save" "Save As…" "Close Tab" "Reopen Closed Tab" "Reload from Disk" "Print…" "Save All"
     "Export to Word…" "Export as PDF…" "---"
     "Next Tab" "Previous Tab" "---" "Settings…" "---" "Quit")
    ("Edit" "Undo" "Redo" "---" "Cut" "Copy" "Paste" "Select All" "Select Line" "---"
     "Find…" "Find and Replace…" "Find Next" "Find Previous" "Go to Line…" "---"
     "Toggle Comment" "Duplicate Line" "Delete Line" "Move Line Up" "Move Line Down"
     "Indent Lines" "Outdent Lines" "---"
     "Insert Date" "Insert Date and Time" "---"
     ("Spelling" "Check Spelling While Typing" "Check Document Now"))
    ("Format" "Bold" "Italic" "Inline Code" "Strikethrough" "---" "Insert Link…" "---"
     "Heading 1" "Heading 2" "Heading 3" "Body Text" "---"
     "Bulleted List" "Numbered List" "Checklist" "Quote" "---" "Mark Done")
    ("View" "Zoom In" "Zoom Out" "Actual Size" "---" "Toggle Word Wrap" "Toggle Dark/Light Theme"
     "Toggle Full Screen" ("Editor Theme" "Use System Setting" "Light" "Dark") "Show Toolbar" "Show Library"
     "Show Markdown Source" "---" "Show Activity Log" "---" "Command Palette…" "Set Language…")
    ("Tools" "Run Selection" "Run Document" "---" "Scratch Pad" "New Code File…" "---"
     ("Extensions" "Customize with Code" "Reload Extensions" "List Extensions"))
    ("Help" "What Does This Key Do?" "Keyboard Shortcuts" "Explain a Command…" "Start Screen"
     "Shortcuts as Text" "---" "About Rackmac")))

;; A code document: the same menus without Format.
(define golden-code
  '(("File" "New Note" "Open…" "Quick Open…" ("Open Recent" "Files you open appear here.")
     "Add Folder…" "Import Word Document…" "Remove Folder…" "---"
     "Save" "Save As…" "Close Tab" "Reopen Closed Tab" "Reload from Disk" "Print…" "Save All"
     "Export to Word…" "Export as PDF…" "---"
     "Next Tab" "Previous Tab" "---" "Settings…" "---" "Quit")
    ("Edit" "Undo" "Redo" "---" "Cut" "Copy" "Paste" "Select All" "Select Line" "---"
     "Find…" "Find and Replace…" "Find Next" "Find Previous" "Go to Line…" "---"
     "Toggle Comment" "Duplicate Line" "Delete Line" "Move Line Up" "Move Line Down"
     "Indent Lines" "Outdent Lines" "---"
     "Insert Date" "Insert Date and Time" "---"
     ("Spelling" "Check Spelling While Typing" "Check Document Now"))
    ("View" "Zoom In" "Zoom Out" "Actual Size" "---" "Toggle Word Wrap" "Toggle Dark/Light Theme"
     "Toggle Full Screen" ("Editor Theme" "Use System Setting" "Light" "Dark") "Show Toolbar" "Show Library"
     "Show Markdown Source" "---" "Show Activity Log" "---" "Command Palette…" "Set Language…")
    ("Tools" "Run Selection" "Run Document" "---" "Scratch Pad" "New Code File…" "---"
     ("Extensions" "Customize with Code" "Reload Extensions" "List Extensions"))
    ("Help" "What Does This Key Do?" "Keyboard Shortcuts" "Explain a Command…" "Start Screen"
     "Shortcuts as Text" "---" "About Rackmac")))

(test-case "the menu bar matches the golden snapshot for a prose document"
  (define b (new-buffer! "prose.md" #:mode 'markdown-mode))
  (set-current-buffer! b)
  (check-equal? (snapshot-menu-bar) golden-prose))

(test-case "the menu bar matches the golden snapshot for a code document: no Format menu"
  (define b (new-buffer! "code.rkt" #:mode 'racket-mode))
  (set-current-buffer! b)
  (check-equal? (snapshot-menu-bar) golden-code))

(test-case "the two snapshots differ by the Format menu only"
  (check-equal? (filter (lambda (m) (not (equal? (car m) "Format"))) golden-prose) golden-code))

(test-case "⌘, is Settings…, not Customize with Code, and the latter has no default key (#289)"
  (check-equal? (default-key-strings 'open-settings 'mac) '("Mod-,"))
  (check-equal? (default-key-strings 'customize-with-code 'mac) '()))

(test-case "Customize with Code, Reload Extensions and List Extensions are off the top menus"
  (check-false (command-menu (find-command 'customize-with-code)))
  (check-false (command-menu (find-command 'reload-init)))
  (check-false (command-menu (find-command 'list-extensions)))
  (check-not-false (find-command 'customize-with-code) "still runnable by name")
  (check-equal? (command-category (find-command 'customize-with-code)) "Extensions"))
