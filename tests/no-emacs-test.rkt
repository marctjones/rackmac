#lang racket/base
;; Guard: the default product is completely free of Emacs vocabulary (docs/DEVELOPMENT.md
;; "A native app, not Emacs."; docs/REPLAN.md §8 "default-no-emacs"). Emacs names and terms
;; return only with the opt-in v0.8 preset (epic E13); this file makes sure nothing in the
;; default registry leaks them, and that the preserved alias data stays unloaded by default.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/list racket/string racket/file racket/runtime-path racket/port
         "../rackmac/command.rkt" "../rackmac/commands.rkt" "../rackmac/mode.rkt")

(define-runtime-path rackmac-dir "../rackmac")
(define-runtime-path presets-file "../rackmac/presets/emacs-names.rktd")

;; Word-boundary patterns so "bookmark", "Markdown" and "remark" pass, but the real Emacs
;; names and vocabulary fail. Matched case-insensitively.
(define emacs-patterns
  (list #px"(?i:\\bemacs\\b)"
        #px"(?i:\\bbuffers?\\b)"
        #px"(?i:\\byank\\b)"
        #px"(?i:\\bkill-)"
        #px"(?i:\\bm-x\\b)"
        #px"(?i:\\bc-x\\b)"
        #px"(?i:\\bminibuffer\\b)"
        #px"(?i:\\bmode line\\b)"
        #px"(?i:\\bmajor mode\\b)"
        #px"(?i:\\bminor mode\\b)"
        #px"(?i:\\bisearch\\b)"
        #px"[*]scratch[*]"
        #px"(?i:[*]messages[*])"
        #px"(?i:\\binit\\.el\\b)"
        #px"(?i:\\bdescribe-)"
        #px"(?i:\\bapropos\\b)"))

(define (emacs-term-in s)
  (and (string? s) (not (string=? s ""))
       (for/first ([p (in-list emacs-patterns)] #:when (regexp-match? p s)) p)))

(define (check-clean! label s)
  (define hit (emacs-term-in s))
  (check-false hit (format "~a contains Emacs vocabulary (~a): ~s" label hit s)))

(test-case "no registered command's title, help, doc, category, menu or aliases names Emacs"
  (for ([c (all-commands)])
    (define n (command-name c))
    (check-clean! (format "~a title" n) (command-title c))
    (check-clean! (format "~a help" n) (command-help c))
    (check-clean! (format "~a doc" n) (command-doc c))
    (check-clean! (format "~a category" n) (command-category c))
    (check-clean! (format "~a menu" n) (command-menu c))
    (for ([a (command-aliases c)])
      (check-clean! (format "~a alias" n) a))))

(test-case "no mode's label or doc names Emacs"
  (for ([m (append (all-modes 'major) (all-modes 'minor))])
    (check-clean! (format "~a label" (mode-name m)) (mode-label m))
    (check-clean! (format "~a doc" (mode-name m)) (mode-doc m))))

(test-case "word-boundary patterns let ordinary words through, but still catch real Emacs terms"
  (check-false (emacs-term-in "Bookmark this page"))
  (check-false (emacs-term-in "Markdown"))
  (check-false (emacs-term-in "remark"))
  (check-false (emacs-term-in "a killer feature"))
  (check-not-false (emacs-term-in "the buffer contents"))
  (check-not-false (emacs-term-in "kill-region")))

(test-case "the Emacs preset's alias data exists, reads, and stays out of the default build"
  (check-true (file-exists? presets-file) "rackmac/presets/emacs-names.rktd exists")
  (define data (call-with-input-file presets-file read))
  (check-true (list? data) "the preset file reads as a Racket datum (a list)")
  (check-true (andmap (lambda (e) (and (pair? e) (symbol? (car e)) (andmap string? (cdr e)))) data)
              "every entry is (command-symbol \"emacs-name\" ...)")
  (check-true (andmap (lambda (e) (and (find-command (car e)) #t)) data)
              "every entry's command symbol resolves to a real built-in command")
  ;; No module under rackmac/ may require or read the preset file; it belongs to the v0.8
  ;; preset only. A plain text search for its name is a reliable proxy for "requires/reads".
  (define offenders
    (for/list ([p (in-directory rackmac-dir)]
               #:when (and (file-exists? p) (regexp-match? #rx"[.]rkt$" (path->string p))))
      (define text (call-with-input-file p port->string))
      (and (regexp-match? #rx"emacs-names" text) (path->string p))))
  (check-equal? (filter values offenders) '()
                "no module under rackmac/ mentions emacs-names.rktd (it is preset-only, not loaded by default)"))

;; #264: command IDs show up in palette search and Explain a Command, so they use office words
;; too. (Renamed once, pre-release: close-buffer → close-tab, eval-selection → run-selection, …)
(test-case "no built-in command ID uses Emacs words"
  (define id-patterns (list #px"\\bbuffers?\\b" #px"major-mode" #px"minor-mode" #px"^eval-" #px"\\byank\\b"
                            #px"\\bkill-" #px"\\binit-file\\b"))
  (for ([c (all-commands)])
    (define id (symbol->string (command-name c)))
    (for ([p id-patterns])
      (check-false (regexp-match? p id) (format "command ID ~a matches ~a" id (object-name p))))))
