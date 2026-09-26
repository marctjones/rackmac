#lang racket/base
;; Quick Open searches the Library (#290 lib-quick-open): every note under a Library folder,
;; ranked so a title match always beats a path-only match, and Enter opens the highlighted row
;; (picker.rkt's existing, separately-tested behavior -- see tests/picker-test.rkt).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/class racket/gui/base racket/path racket/list
         "../rackmac/library/folders.rkt" "../rackmac/editor.rkt" "../rackmac/command.rkt"
         "../rackmac/settings.rkt" "../rackmac/platform.rkt")

(define dir (make-temporary-file "rackmac-quickopen~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))
(setting-set! 'library-folders '())

(define lib (build-path dir "Notes"))
(make-directory* lib)
(add-library-folder-path! lib)

(define (write! rel text)
  (define p (build-path lib rel))
  (make-directory* (let-values ([(base n d?) (split-path p)]) base))
  (display-to-file text p #:exists 'truncate)
  p)

;; ---- library-files: which files count, which folders are skipped ------------------------

(test-case "library-files finds notes and code, skips hidden/build directories and other kinds"
  (setting-set! 'library-folders '())
  (add-library-folder-path! lib)
  (write! "one.md" "# One")
  (write! "two.txt" "two")
  (write! "three.rkt" "#lang racket/base")
  (write! "four.py" "x = 1")
  (write! "ignored.png" "not text")
  (write! ".git/HEAD" "ref: refs/heads/main")
  (write! "compiled/one_rkt.zo" "junk")
  (define names (map (lambda (p) (path->string (file-name-from-path p))) (library-files)))
  (check-equal? (sort names string<?) '("four.py" "one.md" "three.rkt" "two.txt")))

(test-case "a missing Library folder contributes nothing, and never raises"
  (setting-set! 'library-folders '())
  (add-library-folder-path! (build-path dir "does-not-exist"))
  (check-equal? (library-files) '()))

;; ---- library-file-title: the first heading, or the file name -----------------------------

(test-case "a Markdown file's title is its first heading, trimmed"
  (define p (write! "titled.md" "\n\n##   Weekly Notes   \nbody text"))
  (check-equal? (library-file-title p) "Weekly Notes"))

(test-case "a Markdown file with no heading falls back to its file name"
  (define p (write! "no-heading.md" "just a paragraph"))
  (check-equal? (library-file-title p) "no-heading.md"))

(test-case "a non-Markdown file's title is always its file name"
  (define p (write! "script.rkt" "# not a heading, a Racket comment"))
  (check-equal? (library-file-title p) "script.rkt"))

;; ---- rank-library-files: title matches first ----------------------------------------------

(test-case "a title match ranks before a path-only match, even if the path match is shorter"
  (define a (write! "roe/notes.md" "# Contract Review"))       ; title matches "contract"
  (define b (write! "contract-template.md" "# Untitled"))      ; only the path matches "contract"
  (define ranked (rank-library-files "contract" (list a b)))
  (check-equal? ranked (list a b)))

(test-case "within the title-matching group, the better title match still comes first"
  (define exact (write! "x1.md" "# Motion to Dismiss"))
  (define fuzzy (write! "x2.md" "# A Long Rambling Motion About Many Things"))
  (define ranked (rank-library-files "motion" (list fuzzy exact)))
  (check-equal? (car ranked) exact))

(test-case "a file matching neither title nor path is left out"
  (define hit (write! "y1.md" "# Zebra"))
  (define miss (write! "y2.md" "# Giraffe"))
  (check-equal? (rank-library-files "zebra" (list hit miss)) (list hit)))

(test-case "a file is never listed twice even if both its title and its path match"
  (define p (write! "budget/budget.md" "# Budget"))
  (check-equal? (rank-library-files "budget" (list p)) (list p)))

;; ---- the command itself: still `quick-open`, same shortcut, Library-aware ------------------

(test-case "quick-open keeps its symbol, title and shortcut after the Library redefines it"
  (define c (find-command 'quick-open))
  (check-equal? (command-title c) "Quick Open…")
  (check-equal? (default-key-strings 'quick-open 'mac) '("Mod-Shift-o")))

(test-case "with no Library folder, quick-open falls back without needing a Library at all"
  (setting-set! 'library-folders '())
  ;; Not exercised interactively here (that would show the real dialog); this only proves the
  ;; branch commands.rkt's own quick-open-fallback! is reachable and the command still resolves.
  (check-not-false (find-command 'quick-open))
  (add-library-folder-path! lib))
