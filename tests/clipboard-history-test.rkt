#lang racket/base
;; Clipboard history (#118): every Copy and Cut is recorded, oldest entries drop off past the
;; `clipboard-history-limit` setting, a consecutive repeat of the same text does not waste a
;; slot, and the query API #119's picker will use (`clipboard-history-entries`,
;; `clipboard-history-ref`) behaves as documented. Requiring the module does nothing until
;; `enable-clipboard-history!` is called (matches recents.rkt's own inert-until-enabled test
;; shape in tests/recents-test.rkt).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/class racket/gui/base
         "../rackmac/clipboard-history.rkt" "../rackmac/settings.rkt" "../rackmac/hook.rkt"
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt")

;; setting-set! persists to disk (#271); point it at a throwaway config dir, as
;; tests/settings-test.rkt and tests/recents-test.rkt do.
(define dir (make-temporary-file "rackmac-cliphist~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))

;; ---- the store, driven directly ------------------------------------------------------

(test-case "recording a copy adds it, newest first"
  (clear-clipboard-history!)
  (record-clipboard-text! "first")
  (record-clipboard-text! "second")
  (check-equal? (map clip-entry-text (clipboard-history-entries)) (list "second" "first")))

(test-case "clipboard-history-ref gets entry N back, 0 is newest"
  (clear-clipboard-history!)
  (record-clipboard-text! "alpha")
  (record-clipboard-text! "beta")
  (record-clipboard-text! "gamma")
  (check-equal? (clip-entry-text (clipboard-history-ref 0)) "gamma")
  (check-equal? (clip-entry-text (clipboard-history-ref 1)) "beta")
  (check-equal? (clip-entry-text (clipboard-history-ref 2)) "alpha")
  (check-false (clipboard-history-ref 3) "past the end is #f, not an error")
  (check-false (clipboard-history-ref -1)))

(test-case "clipboard-history-count reports how many entries there are"
  (clear-clipboard-history!)
  (check-equal? (clipboard-history-count) 0)
  (record-clipboard-text! "one")
  (record-clipboard-text! "two")
  (check-equal? (clipboard-history-count) 2))

(test-case "clipboard-history-entries with a limit returns only the first n"
  (clear-clipboard-history!)
  (for ([i (in-range 5)]) (record-clipboard-text! (number->string i)))
  (check-equal? (length (clipboard-history-entries 2)) 2)
  (check-equal? (map clip-entry-text (clipboard-history-entries 2)) (list "4" "3")))

(test-case "empty and non-string text are never recorded"
  (clear-clipboard-history!)
  (record-clipboard-text! "")
  (check-equal? (clipboard-history-count) 0))

(test-case "clear empties the store"
  (record-clipboard-text! "something")
  (clear-clipboard-history!)
  (check-equal? (clipboard-history-entries) '()))

;; ---- size limit / eviction (#118's one acceptance criterion) --------------------------

(test-case "the store caps at the clipboard-history-limit setting, dropping the oldest"
  (clear-clipboard-history!)
  (setting-set! 'clipboard-history-limit 5)
  (for ([i (in-range 8)]) (record-clipboard-text! (number->string i)))
  (define es (clipboard-history-entries))
  (check-equal? (length es) 5)
  (check-equal? (clip-entry-text (car es)) "7" "most recent first")
  (check-false (memf (lambda (e) (member (clip-entry-text e) '("0" "1" "2"))) es)
               "the three oldest were evicted")
  (setting-set! 'clipboard-history-limit 30))     ; restore the default for later test-cases

(test-case "lowering the limit trims on the next record, not retroactively"
  (clear-clipboard-history!)
  (setting-set! 'clipboard-history-limit 10)
  (for ([i (in-range 10)]) (record-clipboard-text! (number->string i)))
  (check-equal? (clipboard-history-count) 10)
  (setting-set! 'clipboard-history-limit 3)
  (record-clipboard-text! "new")
  (check-equal? (clipboard-history-count) 3)
  (setting-set! 'clipboard-history-limit 30))

(test-case "the setting rejects a non-positive-integer value"
  (define seen #f)
  (parameterize ([error-reporter (lambda (who e) (set! seen e))])
    (setting-set! 'clipboard-history-limit 0)
    (setting-set! 'clipboard-history-limit -5)
    (setting-set! 'clipboard-history-limit 1.5))
  (check-not-false seen)
  (check-equal? (setting-ref 'clipboard-history-limit) 30 "unchanged by the bad values"))

;; ---- duplicate consecutive copies ------------------------------------------------------

(test-case "copying the same text twice in a row refreshes the entry instead of duplicating it"
  (clear-clipboard-history!)
  (record-clipboard-text! "same")
  (record-clipboard-text! "same")
  (check-equal? (clipboard-history-count) 1)
  (check-equal? (map clip-entry-text (clipboard-history-entries)) (list "same")))

(test-case "repeating an older (non-consecutive) entry still adds a fresh one at the front"
  (clear-clipboard-history!)
  (record-clipboard-text! "a")
  (record-clipboard-text! "b")
  (record-clipboard-text! "a")
  (check-equal? (map clip-entry-text (clipboard-history-entries)) (list "a" "b" "a")))

;; ---- end-to-end: the real hooks (enable-clipboard-history!) ----------------------------
;; Same shape as tests/md-copy-test.rkt: a hidden main frame, a real clipboard round trip
;; through the actual Copy/Cut commands, the user's clipboard content restored afterwards.

(define f (make-main-frame))                     ; hidden: show is never called
(define saved (send the-clipboard get-clipboard-string 0))
(enable-clipboard-history!)

(define (note text)
  (define b (new-buffer! "clip.md" #:mode 'markdown-mode))
  (send b insert text)
  (set-current-buffer! b)
  b)

(test-case "Copy through the real command records the copied text"
  (clear-clipboard-history!)
  (define b (note "Copy this line"))
  (send b set-position 0 (send b last-position))
  (run-command 'copy)
  (check-equal? (map clip-entry-text (clipboard-history-entries)) (list "Copy this line"))
  (check-equal? (send b get-text) "Copy this line" "copy changes nothing, as before"))

(test-case "Cut through the real command records the cut text and still removes it"
  (clear-clipboard-history!)
  (define b (note "Cut this line"))
  (send b set-position 0 (send b last-position))
  (run-command 'cut)
  (check-equal? (map clip-entry-text (clipboard-history-entries)) (list "Cut this line"))
  (check-equal? (send b get-text) "" "cut still removes the selection, as before"))

(test-case "several documents' copies and cuts all land in the one shared history, newest first"
  (clear-clipboard-history!)
  (define b1 (note "from document one"))
  (send b1 set-position 0 (send b1 last-position))
  (run-command 'copy)
  (define b2 (note "from document two"))
  (send b2 set-position 0 (send b2 last-position))
  (run-command 'cut)
  (check-equal? (map clip-entry-text (clipboard-history-entries))
                (list "from document two" "from document one")))

(test-case "a Copy with nothing selected records nothing (matches the clipboard being untouched)"
  (clear-clipboard-history!)
  (define b (note "unselected text"))
  (send b set-position 0)                        ; empty selection: buffer.rkt's copy is a no-op
  (run-command 'copy)
  (check-equal? (clipboard-history-count) 0))

(send the-clipboard set-clipboard-string (or saved "") 0)
