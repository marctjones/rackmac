#lang racket/base
;; Live evaluation and extension loading. Extensions and live code run in one namespace that
;; shares the editor's own module instances (attached, not re-instantiated), so a command
;; defined in init.rkt lands in the running editor's registry.
;;
;; Extension files: <config>/init.rkt, then every <config>/ext/*.rkt in name order. Each
;; is loaded as its own "extension" so everything it registers can be unloaded again, and a
;; reload replaces rather than duplicates. While an extension loads, `require` is restricted
;; to the public API (rackmac/api and rackmac/lang/*): private core modules are refused.
(require racket/class racket/port racket/list racket/string racket/path
         "editor.rkt" "platform.rkt" "owner.rkt")
(provide eval-string load-init! load-extension! unload-all-extensions!
         loaded-extensions eval-namespace)

(define-namespace-anchor anchor)

(define here
  (let-values ([(base name dir?)
                (split-path (resolved-module-path-name
                             (variable-reference->resolved-module-path (#%variable-reference))))])
    base))

(define api-module `(file ,(path->string (build-path here "api.rkt"))))

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

;; Evaluate every form in `str`; return the printed output plus non-void results.
(define (eval-string str)
  (define out (open-output-string))
  (define vals
    (parameterize ([current-namespace (eval-namespace)]
                   [current-output-port out]
                   [current-error-port out])
      (define in (open-input-string str))
      (let loop ([acc '()])
        (define form (read in))
        (if (eof-object? form)
            (reverse acc)
            (loop (append (reverse (call-with-values (lambda () (eval form)) list)) acc))))))
  (string-join
   (filter (lambda (s) (not (string=? s "")))
           (cons (get-output-string out)
                 (for/list ([v (in-list vals)] #:unless (void? v)) (format "~v" v))))
   "\n"))

;; ---- restricting what extensions may require -------------------------------

(define rackmac-dir (path->string (path->directory-path here)))

(define (inside-rackmac? p)
  (and (path? p) (string-prefix? (path->string p) rackmac-dir)))

;; Public = the API facade and the module language; everything else in the core is private.
(define (private-core-module? p)
  (and (inside-rackmac? p)
       (file-exists? p)                 ; the resolver also probes names that do not exist

       (let ([rel (substring (path->string p) (string-length rackmac-dir))])
         (not (or (equal? rel "api.rkt") (string-prefix? rel "lang/"))))))

(define (module-name->path r)
  (define n (and (resolved-module-path? r) (resolved-module-path-name r)))
  (if (pair? n) (car n) n))       ; (list path 'submodule)

;; Wraps the module name resolver: a requirement that reaches a private core module from
;; OUTSIDE the core (i.e. from an extension) is an error. Requirements that core modules
;; make of each other, including those introduced by macros from the public API, are fine.
(define (restrict-to-public-api orig)
  (lambda args
    (define r (apply orig args))
    (when (>= (length args) 3)
      (define target (module-name->path r))
      (define from (module-name->path (cadr args)))
      (when (and (private-core-module? target) (not (inside-rackmac? from)))
        (error 'require "extensions may only use rackmac/api, not the private core module ~a"
               (substring (path->string target) (string-length rackmac-dir)))))
    r))

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
     (message "No init file yet. Run \"Open Init File\" to create ~a" (path->string (init-file-path)))]
    [else
     (define results (for/list ([f (in-list files)]) (load-extension! f)))
     (when (andmap values results)          ; on failure the failure message stays visible
       (message "Loaded ~a extension file~a" (length files) (if (= 1 (length files)) "" "s")))]))
