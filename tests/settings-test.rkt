#lang racket/base
;; define-setting/setting-ref/setting-set! (#270): resolution order, contracts reported
;; instead of raised, per-Language overrides, and extension unload. Persistence to
;; settings.rktd (#271) is tested at the bottom: restart survival and a corrupt file.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/runtime-path
         "../rackmac/settings.rkt" "../rackmac/owner.rkt" "../rackmac/hook.rkt" "../rackmac/platform.rkt"
         "../rackmac/eval.rkt")

;; So `#lang rackmac` resolves as a collection, the way init-test.rkt sets it up.
(define-runtime-path root "..")
(current-library-collection-paths (cons root (current-library-collection-paths)))

(define dir (make-temporary-file "rackmac-settings~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))

(test-case "a setting reads its default until set"
  (define-setting st-basic #:contract string? #:default "hi" #:doc "d")
  (check-equal? (setting-ref 'st-basic) "hi")
  (setting-set! 'st-basic "bye")
  (check-equal? (setting-ref 'st-basic) "bye"))

(test-case "setting-set! fires the change hook"
  (define-setting st-hook #:contract boolean? #:default #f #:doc "d")
  (define changed '())
  (add-hook! 'setting-changed (lambda (n) (set! changed (cons n changed))))
  (setting-set! 'st-hook #t)
  (check-equal? changed '(st-hook)))

(test-case "an unknown name is reported, not raised"
  (define seen #f)
  (parameterize ([error-reporter (lambda (who e) (set! seen (list who e)))])
    (check-false (setting-ref 'st-does-not-exist))
    (setting-set! 'st-does-not-exist 1))
  (check-equal? (car seen) 'setting-set!)
  (check-regexp-match #rx"unknown setting" (cadr seen)))

(test-case "a contract violation is reported and the value is left unchanged"
  (define-setting st-contract #:contract exact-nonnegative-integer? #:default 0 #:doc "d")
  (setting-set! 'st-contract 5)
  (define seen #f)
  (parameterize ([error-reporter (lambda (who e) (set! seen e))])
    (setting-set! 'st-contract "not a number"))
  (check-regexp-match #rx"does not satisfy its contract" seen)
  (check-equal? (setting-ref 'st-contract) 5 "unchanged"))

(test-case "a global-only setting refuses a per-document or per-Language value"
  (define-setting st-global-only #:contract string? #:default "g" #:doc "d" #:scope 'global)
  (define seen #f)
  (parameterize ([error-reporter (lambda (who e) (set! seen e))])
    (setting-set! 'st-global-only "nope" #:language 'racket-mode))
  (check-regexp-match #rx"cannot be set per-document or per-Language" seen)
  (check-equal? (setting-ref 'st-global-only) "g"))

(test-case "document -> Language -> global resolution"
  (define-setting st-scoped #:contract string? #:default "global" #:doc "d" #:scope 'document)
  (define doc-a (gensym 'doc-a))
  (define doc-b (gensym 'doc-b))
  (check-equal? (setting-ref 'st-scoped #:document doc-a) "global")
  (setting-set! 'st-scoped "for-racket" #:language 'racket-mode)
  (check-equal? (setting-ref 'st-scoped #:document doc-a #:language 'racket-mode) "for-racket")
  (check-equal? (setting-ref 'st-scoped #:document doc-a #:language 'markdown-mode) "global"
                "a different Language still sees the global value")
  (setting-set! 'st-scoped "for-doc-a" #:document doc-a)
  (check-equal? (setting-ref 'st-scoped #:document doc-a #:language 'racket-mode) "for-doc-a"
                "the document override wins over the Language override")
  (check-equal? (setting-ref 'st-scoped #:document doc-b #:language 'racket-mode) "for-racket"
                "doc-b has no override of its own, so it falls through to the Language value")
  (check-equal? (setting-ref 'st-scoped #:document doc-b) "global"))

(test-case "a document override of #f is not confused with no override"
  (define-setting st-false #:contract boolean? #:default #t #:doc "d" #:scope 'document)
  (define doc (gensym 'doc-false))
  (setting-set! 'st-false #f #:document doc)
  (check-false (setting-ref 'st-false #:document doc)))

(test-case "an extension's setting unloads with it"
  (define ext (make-extension "settings-ext"))
  (parameterize ([current-extension ext])
    (define-setting st-ext #:contract string? #:default "x" #:doc "d"))
  (check-equal? (setting-ref 'st-ext) "x")
  (unload-extension! ext)
  (define seen #f)
  (parameterize ([error-reporter (lambda (who e) (set! seen e))])
    (check-false (setting-ref 'st-ext)))
  (check-regexp-match #rx"unknown setting" seen))

;; ---- persistence (#271: settings-store) -----------------------------------------------

(test-case "a global value survives a simulated restart (reload from settings.rktd)"
  (define ext (make-extension "persist-ext"))
  (parameterize ([current-extension ext])
    (define-setting st-persist #:contract string? #:default "a" #:doc "d"))
  (setting-set! 'st-persist "b")
  (unload-extension! ext)                      ; the extension (and its in-memory setting) is gone
  (define ext2 (make-extension "persist-ext"))  ; a fresh load, as Reload Extensions would do
  (parameterize ([current-extension ext2])
    (define-setting st-persist #:contract string? #:default "a" #:doc "d"))
  (check-equal? (setting-ref 'st-persist) "b" "the value came back from settings.rktd")
  (unload-extension! ext2))

(test-case "a corrupt settings.rktd is quarantined and reported, never fatal"
  (define path (settings-file-path))
  (make-directory* (let-values ([(base n d?) (split-path path)]) base))
  (display-to-file "(this is not )) a valid preferences file(" path #:exists 'truncate)
  (define reports '())
  (parameterize ([error-reporter (lambda (who e) (set! reports (cons (list who e) reports)))])
    (define-setting st-after-corrupt #:contract string? #:default "fallback" #:doc "d"))
  (check-equal? (setting-ref 'st-after-corrupt) "fallback" "never raised; the default is used")
  (check-true (pair? reports) "the corruption was reported")
  (check-true (ormap (lambda (r) (regexp-match? #rx"valid preferences file|could not be read" (cadr r))) reports))
  (define dir* (let-values ([(base n d?) (split-path path)]) base))
  (check-true (ormap (lambda (p) (regexp-match? #rx"settings[.]rktd[.]corrupt-" (path->string p)))
                     (directory-list dir*))
             "the corrupt file was renamed aside"))

;; ---- usable from #lang rackmac (carried over from #90) ---------------------------------

(test-case "define-setting/setting-ref/setting-set! work from a real #lang rackmac init file"
  (display-to-file (string-append "#lang rackmac\n"
                                  "(define-setting st-lang #:contract string? #:default \"abc\" #:doc \"d\")\n")
                   (build-path dir "init.rkt") #:exists 'truncate)
  (load-init!)
  (check-equal? (setting-ref 'st-lang) "abc")
  (setting-set! 'st-lang "xyz")
  (load-init!)                        ; Reload Extensions: re-registers st-lang from scratch
  (check-equal? (setting-ref 'st-lang) "xyz" "the persisted value survives the reload"))
