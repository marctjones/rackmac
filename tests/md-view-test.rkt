#lang racket/base
;; Formatted / Markdown Source (#269, docs/UI-DESIGN.md §2.2.1): one command reached from the View
;; menu, ⌥⌘U, the status segment and a toolbar button, all in sync; Source is the mono, uncentered,
;; regex-colored look; switching keeps the text, selection, scroll, modified flag and undo; the
;; default view is a setting; each note's view is remembered in recents.rktd; long notes open in
;; Source; a 5,000-line note switches in under a second. Driven through the real hidden window.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list racket/file racket/string
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/buffer.rkt" "../rackmac/hook.rkt" "../rackmac/theme.rkt"
         "../rackmac/settings.rkt" "../rackmac/platform.rkt" "../rackmac/toolbar.rkt"
         "../rackmac/status-defaults.rkt" "../rackmac/ui/status-bar.rkt" "../rackmac/ui/layout.rkt"
         "../rackmac/md-view.rkt" "../rackmac/md-view-commands.rkt"
         "../rackmac/library/recents.rkt")

(define home (make-temporary-file "rackmac-mdview~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string home)))   ; settings and recents go here, not to the real ones

(define f (make-main-frame))
(send f reflow-container)                             ; geometry only; the frame is never shown
(define sb (main-status-bar))

(define (style-at b pos) (send (send b find-snip pos 'after) get-style))
(define (face-at b pos) (send (send (style-at b pos) get-font) get-face))
(define (size-at b pos) (send (send (style-at b pos) get-font) get-point-size))

(define sample "# Minutes\n\nSome **bold** words and `code`.\n\n- first item\n- second item\n")
(define (note [text sample] #:name [name "view.md"])
  (define b (new-buffer! name #:mode 'markdown-mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  (send b set-position 0)
  (set-current-buffer! b)
  b)

(define (seg-text name)
  (define s (findf (lambda (s) (eq? (seg-view-name s) name)) (send sb current-model)))
  (and s (seg-view-text s)))
(define (menu-checked?)
  (send (menu-for-title "View") on-demand)
  (send (menu-item-for 'toggle-markdown-view) is-checked?))
(define (in-source? b) (eq? (markdown-view b) 'source))

;; ---- entry points ---------------------------------------------------------------------------

(test-case "the command switches the view; menu, segment and a toolbar button follow"
  (define b (note))
  (add-toolbar-item! 'toggle-markdown-view #:group 'format-probe #:end? #t)
  (define tb (main-toolbar))
  (send tb rebuild!)
  (check-false (in-source? b) "notes open Formatted")
  (check-true (is-a? (menu-item-for 'toggle-markdown-view) checkable-menu-item%))
  (check-false (menu-checked?))
  (check-equal? (seg-text 'markdown-view) "Formatted")
  (check-false (send tb button-shows-checked? 'toggle-markdown-view))
  (run-command 'toggle-markdown-view)
  (send tb refresh-enabled!)
  (check-true (in-source? b))
  (check-true (menu-checked?))
  (check-equal? (seg-text 'markdown-view) "Markdown")
  (check-true (send tb button-shows-checked? 'toggle-markdown-view) "the button offers Show Formatted")
  (run-command 'toggle-markdown-view)
  (send tb refresh-enabled!)
  (check-false (in-source? b))
  (check-false (menu-checked?))
  (check-equal? (seg-text 'markdown-view) "Formatted")
  (check-false (send tb button-shows-checked? 'toggle-markdown-view))
  (remove-toolbar-item! 'toggle-markdown-view))

(test-case "clicking the status segment runs the same command"
  (define b (note))
  (define ran #f)
  (define (spy n) (set! ran n))
  (add-hook! 'before-command spy)
  (define w (send sb get-width)) (define h (send sb get-height))
  (define m (send sb current-model))
  (define dc (send sb get-dc))
  (send dc set-font (font-for-width w))
  (define r (list-ref (layout-segments m w dc h) (index-of (map seg-view-name m) 'markdown-view)))
  (check-not-false r "the segment is on screen")
  (define x (inexact->exact (round (+ (first r) (/ (third r) 2)))))
  (define y (inexact->exact (round (+ (second r) (/ (fourth r) 2)))))
  (send sb on-event (new mouse-event% [event-type 'left-down] [x x] [y y]))
  (remove-hook! 'before-command spy)
  (check-eq? ran 'toggle-markdown-view)
  (check-true (in-source? b))
  (check-equal? (seg-text 'markdown-view) "Markdown"))

(test-case "the segment sits right after the Language and only shows for Markdown"
  (note)
  (define names (map seg-view-name (send sb current-model)))
  (check-equal? (cadr (member 'language names)) 'markdown-view)
  (set-current-buffer! (new-buffer! "code" #:mode 'racket-mode))
  (check-false (seg-text 'markdown-view))
  (check-false (command-enabled? (find-command 'toggle-markdown-view)) "#:when Markdown")
  (check-false (command-checked? (find-command 'toggle-markdown-view))))

(test-case "⌥⌘U (Chrome's View Source) toggles on macOS; nothing on Windows"
  (check-equal? (default-key-strings 'toggle-markdown-view 'mac) '("Mod-Alt-u"))
  (check-equal? (default-key-strings 'toggle-markdown-view 'windows) '()
                "Ctrl+Alt+letter is AltGr and Ctrl+U is Underline")
  (when (mac?)
    (define b (note))
    (define key (new key-event% [key-code #\u] [meta-down #t] [alt-down #t]))
    (send key set-other-altgr-key-code #\u)
    (send b on-char key)
    (check-true (in-source? b))
    (check-equal? (send b get-text) sample "the key typed nothing")))

;; ---- what each view looks like --------------------------------------------------------------

(test-case "Source is mono, one size, colored headings, not centered; Formatted is the page"
  (define b (note))
  (define heading 3) (define body 13)
  (check-equal? (send b default-style-name) "Prose")
  (check-true (> (size-at b heading) (size-at b body)) "Formatted: sized headings")
  (define wide-inset (send (main-canvas) horizontal-inset))
  (run-command 'toggle-markdown-view)
  (check-equal? (send b default-style-name) "Standard")
  (check-equal? (face-at b heading) mono-face)
  (check-equal? (face-at b body) mono-face)
  (check-equal? (size-at b heading) (size-at b body) "Source: every character the same size")
  (check-equal? (size-at b (+ 2 (caar (regexp-match-positions #rx"`code`" sample)))) (size-at b body)
                "inline code too")
  (check-equal? (send (send (style-at b heading) get-font) get-weight) 'bold "headings colored and bold")
  (check-false (send (style-at b 0) get-underlined))
  (check-true (send b auto-wrap) "still wraps at the measure")
  (check-equal? (send (main-canvas) horizontal-inset) editor-inset-x "not centered")
  (check-equal? (send (main-canvas) vertical-inset) editor-inset-y)
  (run-command 'toggle-markdown-view)
  (check-equal? (face-at b heading) prose-face)
  (check-equal? (send (main-canvas) horizontal-inset) wide-inset "centered again"))

(test-case "switching changes no text and is not an edit: modified flag and undo untouched"
  (define b (note))
  (send b insert "More." (send b last-position))
  (check-true (send b is-modified?))
  (define text (send b get-text))
  (run-command 'toggle-markdown-view)
  (check-equal? (send b get-text) text)
  (check-true (send b is-modified?) "still modified")
  (send b undo)
  (check-equal? (send b get-text) sample "undo undoes the typing, not the switch")
  (send b set-modified #f)
  (run-command 'toggle-markdown-view)
  (check-false (send b is-modified?) "switching a clean note leaves it clean"))

(test-case "the selection is kept across a switch"
  (define b (note))
  (send b set-position 12 18)
  (run-command 'toggle-markdown-view)
  (check-equal? (list (send b get-start-position) (send b get-end-position)) '(12 18))
  (run-command 'toggle-markdown-view)
  (check-equal? (list (send b get-start-position) (send b get-end-position)) '(12 18)))

(test-case "the scroll position is kept: the line at the top stays at the top"
  (define text (string-append* (for/list ([i 400]) (format "Line ~a with **some** words.\n\n" i))))
  (define b (note text))
  (send f reflow-container)
  (define target (send b paragraph-start-position 300))
  (send b set-position target)
  (send b scroll-to-position target #f (send b last-position) 'start)
  (define (top) (let ([s (box 0)] [e (box 0)]) (send b get-visible-position-range s e #f)
                  (send b position-paragraph (unbox s))))
  (define before (top))
  (check-true (> before 100) "scrolled well down")
  (run-command 'toggle-markdown-view)
  (check-true (<= (abs (- (top) before)) 1) (format "Source: top ~a, was ~a" (top) before))
  (run-command 'toggle-markdown-view)
  (check-true (<= (abs (- (top) before)) 1) (format "Formatted: top ~a, was ~a" (top) before)))

(test-case "typing in either view edits the same Markdown; Source recolors like before"
  (define a (note))
  (define b (note))
  (run-command 'toggle-markdown-view)
  (for ([d (list a b)])
    (send d set-position 2)
    (send d insert "Board ")
    (send d insert "## " (send d last-position)))
  (check-equal? (send a get-text) (send b get-text) "the view is a styling layer only")
  (send b rehighlight!)
  (check-equal? (face-at b 3) mono-face)
  (check-equal? (send (send (style-at b 3) get-font) get-weight) 'bold "the heading line is recolored"))

(test-case "changing the Language away and back keeps the view but not its look"
  (define b (note))
  (run-command 'toggle-markdown-view)
  (send b set-mode! 'text-mode)
  (check-equal? (send b default-style-name) "Prose" "plain text is prose again")
  (check-equal? (face-at b 20) prose-face)
  (check-true (> (send (main-canvas) horizontal-inset) editor-inset-x) "and centered again")
  (send b set-mode! 'markdown-mode)
  (check-true (in-source? b) "Markdown again: back in Source")
  (check-equal? (face-at b 20) mono-face))

(test-case "a wrapped paragraph before the last line does not break either view (text% margins)"
  (define b (note (string-append "# Title\n\n" (make-string 400 #\w) "\n")))
  (send b set-max-width 300)                           ; what a shown window does: the line wraps
  (run-command 'toggle-markdown-view)
  (check-true (in-source? b))
  (run-command 'toggle-markdown-view)
  (check-false (in-source? b))
  (send b set-max-width 'none))

;; ---- defaults, memory, long notes -----------------------------------------------------------

(test-case "the markdown-default-view setting decides how new notes open"
  (check-equal? (setting-default (find-setting 'markdown-default-view)) 'formatted)
  (setting-set! 'markdown-default-view 'formatted)          ; whatever the real settings file says
  (check-equal? (map car (setting-choices (find-setting 'markdown-default-view))) '(formatted source))
  (setting-set! 'markdown-default-view 'source)
  (define b (note))
  (check-true (in-source? b))
  (check-equal? (face-at b 20) mono-face)
  (setting-set! 'markdown-default-view 'formatted)
  (check-false (in-source? (note))))

(test-case "each note's view is remembered with its recents entry and restored on open"
  (enable-recent-tracking!)
  (enable-markdown-view-memory!)
  (define p (build-path home "kept-in-source.md"))
  (display-to-file sample p #:exists 'replace)
  (define b (open-file! p))
  (set-current-buffer! b)
  (check-false (in-source? b))
  (run-command 'toggle-markdown-view)
  (check-eq? (recent-entry-view (find-recent p)) 'source)
  (kill-buffer! b)
  (reload-recents!)                                    ; read back from disk
  (define again (open-file! p))
  (check-true (in-source? again) "opens in Source next time")
  (check-equal? (face-at again 20) mono-face)
  (check-false (send again is-modified?))
  ;; another note still follows the setting
  (define q (build-path home "other.md"))
  (display-to-file sample q #:exists 'replace)
  (check-false (in-source? (open-file! q)))
  ;; an untitled note keeps its view once saved
  (define u (note))
  (run-command 'toggle-markdown-view)
  (define up (build-path home "was-untitled.md"))
  (send u save-to! up)
  (check-eq? (recent-entry-view (find-recent up)) 'source)
  (enable-markdown-view-memory! #f))

(test-case "a long note opens in Source with a message; the toggle still formats it"
  (define p (build-path home "long.md"))
  (display-to-file (string-append "# Long\n\n" (make-string 3000 #\x) "\n") p #:exists 'replace)
  (define said '())
  (define (spy s) (set! said (cons s said)))
  (add-hook! 'echo spy)
  (define b (parameterize ([large-file-threshold 1000]) (open-file! p)))
  (remove-hook! 'echo spy)
  (check-true (in-source? b))
  (check-true (for/or ([s said]) (regexp-match? #rx"long note, so it opens as Markdown source" s)))
  (set-current-buffer! b)
  (parameterize ([large-file-threshold 1000])
    (run-command 'toggle-markdown-view)
    (check-false (in-source? b))
    (check-true (> (size-at b 3) (size-at b 12)) "formatted on request")))

;; ---- speed ----------------------------------------------------------------------------------

(test-case "a 5,000-line note switches in under a second, both ways"
  (define para (string-append "Some **bold** and *italic* words in a longer sentence, a [link](https://example.com) "
                              "and `code` here, with more words to make the line long like real notes are.\n"))
  (define text
    (string-append*
     (for/list ([i 1000])
       (string-append (format "## Section ~a\n\n" i) para
                      "- item one with a few words\n- item two with a few words\n"))))
  (check-true (>= (length (regexp-match* #rx"\n" text)) 5000))
  (define b (note text))
  (define (timed thunk) (define t0 (current-inexact-milliseconds)) (thunk) (- (current-inexact-milliseconds) t0))
  (define to-source (timed (lambda () (run-command 'toggle-markdown-view))))
  (define to-formatted (timed (lambda () (run-command 'toggle-markdown-view))))
  (printf "md-view: 5,000-line note (~a KB): to Source ~a ms, to Formatted ~a ms\n"
          (quotient (string-length text) 1024) (round to-source) (round to-formatted))
  (check-true (< to-source 1000) (format "to Source took ~a ms" to-source))
  (check-true (< to-formatted 1000) (format "to Formatted took ~a ms" to-formatted)))
