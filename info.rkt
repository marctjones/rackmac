#lang info
(define collection 'multi)
;; rackmac-markdown (design docs/MARKDOWN-DESIGN.md §6.1) is a sibling package, not a nested
;; collection here: install it separately (locally, `raco pkg install --link ./rackmac-markdown`)
;; before installing this one, since a --link install of `.` and of a subdirectory of `.` cannot
;; coexist (raco pkg refuses overlapping linked directories). `racket main.rkt` from a checkout
;; still works without installing either package, via the collection-path patch in main.rkt.
(define deps '("base" "gui-lib" "syntax-color-lib" "rackmac-markdown"))
(define build-deps '("rackunit-lib"))
