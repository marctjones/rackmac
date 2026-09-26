#lang racket/base
;; Menu snapshot (#289, menu-tools): the full menu bar's titles and item labels, in order, for
;; a prose document and a code document. A drift test -- when a future issue (run-code-only's
;; #:when scoping, md-format-commands' Format menu) changes what either document type shows,
;; this fails and the golden snapshot below is the thing to update, deliberately, alongside it.
;; Today the two are identical: nothing yet varies the menu bar by document type.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/string
         "../rackmac/commands.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt"
         "../rackmac/command.rkt" "../rackmac/ui/settings-dialog.rkt" "../rackmac/tools-menu.rkt"
         "../rackmac/library/open-recent.rkt"
         "../rackmac/library/folders.rkt" "../rackmac/library/new-note.rkt")

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

(define golden
  '(("File" "New Note" "Open…" "Quick Open…" ("Open Recent" "Files you open appear here.")
     "Add Folder…" "Remove Folder…" "---"
     "Save" "Save As…" "Close Tab" "Reopen Closed Tab" "Reload from Disk" "Print…" "Save All" "---"
     "Next Tab" "Previous Tab" "---" "Settings…" "---" "Quit")
    ("Edit" "Undo" "Redo" "---" "Cut" "Copy" "Paste" "Select All" "Select Line" "---"
     "Find…" "Find and Replace…" "Find Next" "Find Previous" "Go to Line…" "---"
     "Toggle Comment" "Duplicate Line" "Delete Line" "Move Line Up" "Move Line Down"
     "Indent Lines" "Outdent Lines")
    ("View" "Zoom In" "Zoom Out" "Actual Size" "---" "Toggle Word Wrap" "Toggle Dark/Light Theme"
     "Toggle Full Screen" ("Editor Theme" "Use System Setting" "Light" "Dark") "Show Toolbar" "---"
     "Show Activity Log" "---" "Command Palette…" "Set Language…")
    ("Tools" "Run Selection" "Run Document" "---" "Scratch Pad" "New Code File…" "---"
     ("Extensions" "Customize with Code" "Reload Extensions" "List Extensions"))
    ("Help" "What Does This Key Do?" "Keyboard Shortcuts" "Explain a Command…" "Shortcuts as Text" "---"
     "About Rackmac")))

(test-case "the menu bar matches the golden snapshot for a prose document"
  (define b (new-buffer! "prose.md" #:mode 'markdown-mode))
  (set-current-buffer! b)
  (check-equal? (snapshot-menu-bar) golden))

(test-case "the menu bar matches the golden snapshot for a code document (identical for now)"
  (define b (new-buffer! "code.rkt" #:mode 'racket-mode))
  (set-current-buffer! b)
  (check-equal? (snapshot-menu-bar) golden))

(test-case "⌘, is Settings…, not Customize with Code, and the latter has no default key (#289)"
  (check-equal? (default-key-strings 'open-settings 'mac) '("Mod-,"))
  (check-equal? (default-key-strings 'customize-with-code 'mac) '()))

(test-case "Customize with Code, Reload Extensions and List Extensions are off the top menus"
  (check-false (command-menu (find-command 'customize-with-code)))
  (check-false (command-menu (find-command 'reload-init)))
  (check-false (command-menu (find-command 'list-extensions)))
  (check-not-false (find-command 'customize-with-code) "still runnable by name")
  (check-equal? (command-category (find-command 'customize-with-code)) "Extensions"))
