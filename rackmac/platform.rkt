#lang racket/base
;; Platform detection and per-platform paths. `current-platform` is a parameter so
;; tests can exercise Windows key resolution from a Mac.
(provide current-platform mac? windows? config-dir init-file-path)

(define current-platform
  (make-parameter (case (system-type 'os)
                    [(macosx) 'mac]
                    [(windows) 'windows]
                    [else 'linux])))

(define (mac?) (eq? (current-platform) 'mac))
(define (windows?) (eq? (current-platform) 'windows))

(define (config-dir)
  (cond [(getenv "RACKMAC_HOME") => string->path]
        [(windows?) (build-path (or (getenv "APPDATA") (find-system-path 'home-dir)) "rackmac")]
        [else (build-path (find-system-path 'home-dir) ".config" "rackmac")]))

(define (init-file-path) (build-path (config-dir) "init.rkt"))
