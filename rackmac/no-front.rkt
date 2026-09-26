#lang racket/base
;; Keep Rackmac from taking keyboard focus when its windows appear. racket/gui's macOS
;; backend skips bringing the app to the front when the process global
;; "Racket-GUI-no-front" is set, so this must run BEFORE racket/gui loads: require this
;; module first. The app turns it on with RACKMAC_NO_FRONT=1 (background launches);
;; tests/no-front.rkt turns it on unconditionally.
(require ffi/unsafe/global)
(provide enable-no-front! no-front-requested?)

(define (enable-no-front!) (register-process-global #"Racket-GUI-no-front" #"yes"))
(define (no-front-requested?) (and (getenv "RACKMAC_NO_FRONT") #t))

;; `void`: a module's top-level results are printed, and register-process-global returns one --
;; a stray "#f" on stdout that broke the crash test's worker protocol on CI, which sets
;; RACKMAC_NO_FRONT=1.
(when (no-front-requested?) (void (enable-no-front!)))
