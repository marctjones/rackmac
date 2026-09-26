#lang info
;; The checkout root is not a package (#285). It holds two sibling packages:
;;   rackmac-markdown/  the CommonMark library (collection `rackmac-markdown`, design
;;                      docs/MARKDOWN-DESIGN.md §6.1)
;;   rackmac/           the app (collection `rackmac`; its deps include rackmac-markdown)
;; Install them with `raco pkg install ./rackmac-markdown ./rackmac` (both copy, or both
;; --link). Do not install `.` itself: every subdirectory of a multi-collection root becomes a
;; collection, so tests/ and tools/ would be installed and the nested rackmac-markdown/ would
;; conflict with its own package. `racket main.rkt` and `raco test tests` need no install.
