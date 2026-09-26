#lang info
;; The app package (#285): this directory alone is the single `rackmac` collection, so
;; `(require rackmac/api)` and `#lang rackmac` resolve once it is installed, and the checkout's
;; tests/, tools/ and docs/ are never installed as collections. Install it next to its sibling
;; package, from the checkout root (both copy, or both --link; see docs/DEVELOPMENT.md):
;;     raco pkg install ./rackmac-markdown ./rackmac
;; Running from the checkout (`racket main.rkt`, `raco test tests`) needs neither installed.
(define collection "rackmac")
;; draw-lib (racket/draw) and net-lib (net/sendurl) are used directly, so declared (both come with Racket).
(define deps '("base" "gui-lib" "draw-lib" "net-lib" "syntax-color-lib" "rackmac-markdown"))
(define pkg-desc "Rackmac, a notes and documents editor scripted in Racket")
(define pkg-authors '("marctjones"))
