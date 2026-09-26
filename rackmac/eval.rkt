#lang racket/base
;; Live evaluation and extension loading. Extensions and live code run in one namespace that
;; shares the editor's own module instances (attached, not re-instantiated), so a command
;; defined in init.rkt lands in the running editor's registry.
;;
;; Extension files: <config>/init.rkt, then every <config>/ext/*.rkt in name order. Each
;; is loaded as its own "extension" so everything it registers can be unloaded again, and a
;; reload replaces rather than duplicates. While an extension loads, `require` is restricted
;; to the public API (rackmac/api and rackmac/lang/*): private core modules are refused.
(require racket/class racket/port racket/list racket/string racket/path racket/runtime-path
         "editor.rkt" "platform.rkt" "owner.rkt")
(provide eval-string load-init! load-extension! unload-all-extensions!
         loaded-extensions eval-namespace)

(define-namespace-anchor anchor)

;; This file's directory on disk, or #f when there is none: inside Rackmac.app (#286, `raco
;; exe`) the modules are embedded, their names are not files, and no sources ship.
(define here
  (let ([name (resolved-module-path-name
               (variable-reference->resolved-module-path (#%variable-reference)))])
    (and (path? name)
         (let-values ([(base n dir?) (split-path name)])
           (and (path? base) (directory-exists? base) base)))))

;; rackmac/api as this module's own sibling, however the app was started (checkout, installed
;; package, or the app bundle, where a built file path would name nothing). Not 'rackmac/api
;; by collection: a checkout run must never pick up an installed copy (two registries).
(define-runtime-module-path-index api-mpi "api.rkt")
(define api-module
  (let ([n (resolved-module-path-name (module-path-index-resolve api-mpi))])
    (if (path? n) n (list 'quote n))))        ; a file, or an embedded module's symbol name

;; ---- the app bundle's embedded libraries ----------------------------------------------------
;; In Rackmac.app every library (racket/base, rackmac/api, rackmac/lang/reader, ...) is embedded
;; in the executable, and raco exe's module name resolver knows them only in the app's own
;; module registry. Extensions load in a fresh registry (so a reload re-runs them), where that
;; resolver finds nothing and there are no collection directories to fall back on. This
;; resolver wrapper answers a library path (or a lookup made by an embedded module) from the
;; app's registry and attaches the app's own instance, so `#lang rackmac` and
;; `(require rackmac/api)` reach the running editor exactly as in a checkout. Installed only
;; when the modules are embedded; outside the bundle nothing changes.
(define embedded? (not (path? (resolved-module-path-name
                               (variable-reference->resolved-module-path (#%variable-reference))))))

(define app-namespace (namespace-anchor->empty-namespace anchor))   ; shares the app's registry

(define (library-path? mp)
  (or (symbol? mp)
      (and (pair? mp) (eq? (car mp) 'lib))
      (and (pair? mp) (eq? (car mp) 'submod) (pair? (cdr mp)) (library-path? (cadr mp)))))

(define (embedded-name? r)
  (and (resolved-module-path? r)
       (let ([n (resolved-module-path-name r)]) (symbol? (if (pair? n) (car n) n)))))

(define (share-embedded-libraries orig)
  (case-lambda
    [(r ns) (orig r ns)]
    [(mp rel stx load?)
     (define app-registry (namespace-module-registry app-namespace))
     (define from-app
       (and (not (eq? (namespace-module-registry (current-namespace)) app-registry))
            (or (library-path? mp) (embedded-name? rel))
            (with-handlers ([exn:fail? (lambda (e) #f)])
              (define r (parameterize ([current-namespace app-namespace]) (orig mp rel stx #f)))
              (and (embedded-name? r) r))))
     (cond
       [from-app
        ;; A submodule the app lacks (the `reader` probe `#lang` makes) is left undeclared.
        (when (and load?
                   (parameterize ([current-namespace app-namespace]) (module-declared? from-app #f))
                   (not (module-declared? from-app #f)))
          ;; Attaching needs an instance; instantiate it in the app first (as a shared
          ;; registry would), so its dependencies, rackmac/api above all, stay the app's own.
          (parameterize ([current-namespace app-namespace]) (dynamic-require from-app #f))
          (namespace-attach-module app-namespace from-app (current-namespace)))
        from-app]
       [else (orig mp rel stx load?)])]))

(when embedded?
  (current-module-name-resolver (share-embedded-libraries (current-module-name-resolver))))

(define (make-editor-namespace)
  (define src (namespace-anchor->empty-namespace anchor))
  (define ns (make-empty-namespace))
  ;; #f (instantiate), not (void) (visit only): attaching an uninstantiated module leaves
  ;; the extension with a second, empty copy of the registries.
  (for ([m (list 'racket/base 'racket/class 'racket/gui/base 'racket/list 'racket/string api-module)])
    (parameterize ([current-namespace src]) (dynamic-require m #f))
    (namespace-attach-module src m ns))
  (parameterize ([current-namespace ns])
    (namespace-require 'racket/base)
    (namespace-require api-module))
  ns)

(define ns #f)
(define (eval-namespace)
  (unless ns (set! ns (make-editor-namespace)))
  ns)

;; Evaluate `str` in the editor namespace; return the printed output plus non-void results.
;; Text that starts with #lang (a whole module, e.g. the init file) is declared as a module
;; under a fresh name and instantiated; anything else is evaluated form by form.
(define run-counter 0)
(define (lang-text? str) (regexp-match? #px"^(?:\\s|;[^\n]*\n)*#lang " str))

(define (eval-string str)
  (define out (open-output-string))
  (define vals
    (parameterize ([current-namespace (eval-namespace)]
                   [current-output-port out]
                   [current-error-port out])
      (define in (open-input-string str))
      (cond
        [(lang-text? str)
         (set! run-counter (add1 run-counter))
         (define name (make-resolved-module-path (string->symbol (format "rackmac-run-~a" run-counter))))
         (define form (parameterize ([read-accept-reader #t] [read-accept-lang #t]) (read-syntax 'run in)))
         (parameterize ([current-module-declare-name name]) (eval form))
         (dynamic-require name #f)
         '()]
        [else
         (let loop ([acc '()])
           (define form (read in))
           (if (eof-object? form)
               (reverse acc)
               (loop (append (reverse (call-with-values (lambda () (eval form)) list)) acc))))])))
  (string-join
   (filter (lambda (s) (not (string=? s "")))
           (cons (get-output-string out)
                 (for/list ([v (in-list vals)] #:unless (void? v)) (format "~v" v))))
   "\n"))

;; ---- restricting what extensions may require -------------------------------
;; This is hygiene, not a sandbox: it stops an extension from *requiring* private core
;; modules (so the API stays the contract), but extension code runs with the editor's full
;; privileges, and `eval-string` (Run Selection) is not restricted at all.
;;
;; Files are compared by identity (device + inode), not by path text, so a different
;; spelling, letter case or symlink of the same file is still recognised.

;;
;; In the app bundle (`here` is #f) no core files exist on disk to compare against, and an
;; extension can only reach the modules raco exe embedded, so the lists below are empty and
;; the check passes everything through.

(define (core-files)
  (if here
      (for/list ([p (in-directory here)] #:when (regexp-match? #rx"[.]rkt$" (path->string p))) p)
      '()))

(define (identity p) (with-handlers ([exn:fail? (lambda (e) #f)]) (file-or-directory-identity p)))

(define-values (core-ids public-ids)
  (let ([public (if here
                    (list* (build-path here "api.rkt")
                           (for/list ([p (in-directory (build-path here "lang"))]) p))
                    '())])
    (values (for/hash ([p (core-files)]) (values (identity p) #t))
            (for/hash ([p public]) (values (identity p) #t)))))

(define (core-module? p) (and (path? p) (hash-ref core-ids (identity p) #f)))
(define (private-core-module? p) (and (core-module? p) (not (hash-ref public-ids (identity p) #f))))

(define (module-name->path r)
  (define n (and (resolved-module-path? r) (resolved-module-path-name r)))
  (if (pair? n) (car n) n))       ; (list path 'submodule)

;; The core file's own name (e.g. "editor.rkt"), however the requirement spelled it.
(define core-names (for/hash ([p (core-files)]) (values (identity p) (path->string (find-relative-path here p)))))
(define (core-relative p) (hash-ref core-names (identity p) (lambda () (path->string p))))

;; Wraps the module name resolver: a requirement that reaches a private core module from
;; OUTSIDE the core (i.e. from an extension) is an error, raised before the module is
;; loaded. Requirements core modules make of each other, including those introduced by
;; macros from the public API, are fine.
(define (restrict-to-public-api orig)
  (case-lambda
    [(r ns) (orig r ns)]                                     ; notification form: pass through
    [(mp rel stx load?)
     (define resolved (orig mp rel stx #f))                  ; resolve only; do not load yet
     (define target (module-name->path resolved))
     (define from (module-name->path rel))
     (when (and (private-core-module? target) (not (core-module? from)))
       (error 'require "extensions may only use rackmac/api, not the private core module ~a"
              (core-relative target)))
     (if load? (orig mp rel stx #t) resolved)]))

;; ---- extensions ----------------------------------------------------------

(define loaded '())                     ; oldest first
(define (loaded-extensions) loaded)

(define (unload-all-extensions!)
  (for ([e (in-list (reverse loaded))]) (unload-extension! e))
  (set! loaded '()))

;; Load one extension file. On failure everything it had registered is unloaded again and
;; the error is reported (never raised). Returns the extension, or #f.
(define (load-extension! path)
  (define name (path->string (file-name-from-path path)))
  (define ext (make-extension name path))
  (with-handlers ([exn:fail? (lambda (e)
                               (unload-extension! ext)
                               (message "~a failed: ~a" name (exn-message e))
                               #f)])
    (parameterize ([current-namespace (eval-namespace)]
                   [current-extension ext]
                   [current-module-name-resolver (restrict-to-public-api (current-module-name-resolver))])
      (dynamic-require path #f))
    (set! loaded (append loaded (list ext)))
    ext))

(define (extension-files)
  (define init (init-file-path))
  (define dir (build-path (config-dir) "ext"))
  (append (if (file-exists? init) (list init) '())
          (if (directory-exists? dir)
              (sort (filter (lambda (p) (regexp-match? #rx"[.]rkt$" (path->string p)))
                            (directory-list dir #:build? #t))
                    path<?)
              '())))

;; Unloads whatever was loaded before, then loads init.rkt and ext/*.rkt in a fresh namespace.
(define (load-init!)
  (unload-all-extensions!)
  (set! ns #f)
  (define files (extension-files))
  (cond
    [(null? files)
     ;; Nothing to report at startup; the Activity log says where customizations would go.
     (log-message "No customization files yet. \"Customize with Code\" creates ~a." (path->string (init-file-path)))]
    [else
     (define results (for/list ([f (in-list files)]) (load-extension! f)))
     (when (andmap values results)          ; on failure the failure message stays visible
       (message "Loaded ~a extension file~a" (length files) (if (= 1 (length files)) "" "s")))]))
