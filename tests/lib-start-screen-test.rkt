#lang racket/base
;; The start screen (#277 start-view): shown with no document open, native controls only
;; (message%, button%, list-box%), leaves once a document opens, a command reopens it, and it
;; is keyboard reachable (Enter on a highlighted Recent row opens it, like a double-click).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/list racket/path
         "../rackmac/library/folders.rkt" "../rackmac/library/new-note.rkt"
         "../rackmac/library/start-screen.rkt" "../rackmac/library/recents.rkt"
         "../rackmac/settings.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt"
         "../rackmac/command.rkt" "../rackmac/platform.rkt")

(define dir (make-temporary-file "rackmac-startview~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))
(setting-set! 'library-folders '())
(setting-set! 'skip-start-screen #f)
(define lib (build-path dir "Notes"))
(make-directory* lib)
(add-library-folder-path! lib)
(enable-recent-tracking!)

(define f (make-main-frame))     ; hidden: show is never called

(define (panel) (main-start-panel))
(define (children-of w) (send w get-children))
(define (all-descendants w)
  (cons w (append-map all-descendants (with-handlers ([exn:fail? (lambda (e) '())]) (children-of w)))))
(define (find-by-class cls) (filter (lambda (w) (is-a? w cls)) (all-descendants (panel))))

(test-case "with no document open, the start screen (not the tabs/canvas) is shown"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (check-true (start-screen-shown?))
  (check-true (no-document-open?))
  (check-not-false (memq (panel) (send (main-frame) get-children)))
  (check-false (memq (main-tabs) (send (main-frame) get-children))))

(test-case "it is native controls: at least one button% and one list-box%"
  (check-true (>= (length (find-by-class button%)) 3) "New Note, Add Folder, Open, Get Started")
  (check-true (>= (length (find-by-class list-box%)) 1) "the Recent list"))

(test-case "opening a document dismisses the start screen"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (check-true (start-screen-shown?))
  (run-command 'new-note)
  (check-false (start-screen-shown?))
  (check-not-false (memq (main-tabs) (send (main-frame) get-children))))

(test-case "closing the last document brings it back"
  (kill-buffer! (current-buffer))
  (check-true (start-screen-shown?)))

(test-case "the Start Screen command reopens it even with a document open"
  (run-command 'new-note)
  (check-false (start-screen-shown?))
  (run-command 'show-start-screen)
  (check-true (start-screen-shown?))
  ;; and it leaves again once a document is actually opened, as usual
  (run-command 'new-note)
  (check-false (start-screen-shown?)))

;; ---- Recent: real files, keyboard reachable -----------------------------------------------

(test-case "Recent lists real files and Enter on a row opens it, same as a double-click"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (clear-recent-files!)
  (define p (build-path lib "recent-me.md"))
  (display-to-file "# Hi" p #:exists 'truncate)
  (record-recent-open! (path->string p))
  (define lb (car (find-by-class list-box%)))
  (send (panel) refresh-recent!)
  (check-true (>= (send lb get-number) 1))
  (send lb set-selection 0)
  (send (panel) on-subwindow-char lb (new key-event% [key-code #\return]))
  (check-equal? (send (current-buffer) get-name) "recent-me.md"))

(test-case "a moved or deleted recent file is not offered"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (clear-recent-files!)
  (define gone (build-path lib "gone.md"))
  (display-to-file "x" gone)
  (record-recent-open! (path->string gone))
  (delete-file gone)
  (send (panel) refresh-recent!)
  (define lb (car (find-by-class list-box%)))
  (check-regexp-match #rx"appear here" (send lb get-string 0)))

;; ---- Get Started ---------------------------------------------------------------------------

(test-case "Get Started opens a bundled note with checkboxes, creating it once"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (run-command 'open-getting-started)
  (define b (current-buffer))
  (check-regexp-match #rx"Getting started" (send b get-name))
  (check-regexp-match #rx"- \\[ \\]" (send b get-text))
  (define p (send b get-path))
  (check-true (file-exists? p))
  ;; opening it again reuses the same file rather than overwriting it
  (send b insert "edited")
  (send b save-to! p)
  (kill-buffer! b)
  (run-command 'open-getting-started)
  (check-regexp-match #rx"edited" (send (current-buffer) get-text)))

;; ---- setting: skip the screen -------------------------------------------------------------

(test-case "skip-start-screen opens the most recent existing note instead"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (clear-recent-files!)
  (define p (build-path lib "skip-me.md"))
  (display-to-file "hi" p #:exists 'truncate)
  (record-recent-open! (path->string p))
  (setting-set! 'skip-start-screen #t)
  (maybe-skip-start-screen!)
  (check-equal? (send (current-buffer) get-name) "skip-me.md")
  (setting-set! 'skip-start-screen #f))

(test-case "skip-start-screen with nothing to open still leaves the screen showing"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (clear-recent-files!)
  (setting-set! 'skip-start-screen #t)
  (maybe-skip-start-screen!)
  (check-true (no-document-open?))
  (setting-set! 'skip-start-screen #f))
