#lang racket/base
;; Builds dist/Rackmac.app (#286): a double-clickable macOS app that runs without Racket.
;;
;;   racket tools/build-mac-app.rkt [--work DIR] [--smoke]
;;   racket tools/build-mac-app.rkt --smoke-only        (test the dist/Rackmac.app already built)
;;
;; 1. Installs the two packages (rackmac-markdown, rackmac) as copies into a fresh, private
;;    add-on directory (PLTADDONDIR=<work>/addon), never into your own Racket.
;; 2. `raco exe --gui` on a one-line launcher that runs rackmac/app's main submodule, with
;;    ++lib rackmac/api, rackmac/lang/rackmac, rackmac/lang/reader and racket/base/lang/reader
;;    (and racket/date, which the Customize with Code template requires) embedded so a person's init.rkt (`#lang rackmac`, or `#lang racket/base` with
;;    `(require rackmac/api)`) compiles against the app's own modules. Only embedded libraries
;;    exist inside the app: an extension may require what the app itself uses (racket/list,
;;    racket/string, racket/gui/base, ...), not arbitrary collections; then `raco distribute`, which copies in the Racket runtime, the native libraries
;;    and every define-runtime-path file.
;; 3. Sets Info.plist (name, cl.skpt.rackmac, version from rackmac/version.rkt, .md/.markdown/
;;    .txt document types so Finder's Open With lists Rackmac) and the icon (tools/app-icon.rkt,
;;    made into an .icns with iconutil). The bundle is not signed (#20).
;;
;; --smoke then runs the built app headless (RACKMAC_SMOKE=1, see rackmac/smoke.rkt) with an
;; empty environment -- PATH=/usr/bin:/bin, so neither Racket nor pandoc is on it -- a fresh
;; RACKMAC_HOME holding a `#lang rackmac` init.rkt, and a note to open; it fails the build
;; unless every check passes. The window is never shown.
;;
;; The work directory (default dist/build) holds the add-on directory, launcher and iconset;
;; dist/ is not committed.
(require racket/cmdline racket/file racket/port racket/system racket/string racket/list
         racket/runtime-path json setup/dirs
         "app-icon.rkt" "../rackmac/version.rkt")
(provide plist-settings)

(define-runtime-path root "..")
(define dist (simplify-path (build-path root "dist")))
(define app (build-path dist "Rackmac.app"))

(define work (make-parameter (build-path dist "build")))
(define smoke? (make-parameter #f))
(define build? (make-parameter #t))

(define (say fmt . args) (apply printf fmt args) (newline) (flush-output))

(define (run! #:env [env #f] prog . args)
  (define argv (map (lambda (a) (if (path? a) (path->string a) a)) args))
  (say "$ ~a ~a" prog (string-join argv " "))
  (unless (parameterize ([current-environment-variables (or env (current-environment-variables))])
            (apply system* prog argv))
    (error 'build-mac-app "failed: ~a ~a" prog (string-join argv " "))))

(define (bin name)
  (or (for/or ([d (list (find-console-bin-dir) (find-user-console-bin-dir))])
        (define p (build-path d name))
        (and (file-exists? p) p))
      (find-executable-path name)
      (error 'build-mac-app "cannot find ~a" name)))

(define (with-addon addon)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"PLTADDONDIR" (path->bytes addon))
  env)

;; ---- Info.plist ---------------------------------------------------------------------------

(define (document-type name uti exts)
  (hasheq 'CFBundleTypeName name
          'CFBundleTypeRole "Editor"
          'LSHandlerRank "Alternate"          ; offered in Open With; never takes over the default
          'LSItemContentTypes (list uti)
          'CFBundleTypeExtensions exts))

(define plist-settings
  (hasheq 'CFBundleName "Rackmac"
          'CFBundleDisplayName "Rackmac"
          'CFBundleIdentifier "cl.skpt.rackmac"
          'CFBundleShortVersionString app-version
          'CFBundleVersion app-version
          'CFBundleIconFile "Rackmac"
          'CFBundleSignature "????"
          'CFBundleDevelopmentRegion "en"
          'LSApplicationCategoryType "public.app-category.productivity"
          'CFBundleDocumentTypes
          (list (document-type "Markdown document" "net.daringfireball.markdown" '("md" "markdown"))
                (document-type "Plain text document" "public.plain-text" '("txt")))
          ;; Declares the Markdown type for Macs where no other app has.
          'UTImportedTypeDeclarations
          (list (hasheq 'UTTypeIdentifier "net.daringfireball.markdown"
                        'UTTypeDescription "Markdown document"
                        'UTTypeConformsTo '("public.plain-text")
                        'UTTypeTagSpecification (hasheq 'public.filename-extension '("md" "markdown"))))))

(define (update-plist! plist)
  (define plutil (or (find-executable-path "plutil") "/usr/bin/plutil"))
  (define current
    (string->jsexpr (with-output-to-string
                      (lambda () (system* plutil "-convert" "json" "-o" "-" (path->string plist))))))
  (define json-file (build-path (work) "Info.json"))
  (with-output-to-file json-file #:exists 'truncate
    (lambda () (write-json (for/fold ([h current]) ([(k v) (in-hash plist-settings)]) (hash-set h k v)))))
  (run! plutil "-convert" "xml1" "-o" plist json-file)
  (run! plutil "-lint" plist))

;; ---- build --------------------------------------------------------------------------------

(define (build!)
  (define w (simplify-path (path->complete-path (work))))
  (define addon (build-path w "addon"))
  (define raco (bin "raco"))
  (when (directory-exists? addon) (delete-directory/files addon))
  (make-directory* w)

  (say "== Installing rackmac-markdown and rackmac into ~a" addon)
  (parameterize ([current-directory root])
    (run! #:env (with-addon addon) raco "pkg" "install" "--scope" "user" "--auto" "--copy" "--batch"
          "./rackmac-markdown" "./rackmac"))

  (say "== raco exe")
  (define launcher (build-path w "Rackmac.rkt"))
  (with-output-to-file launcher #:exists 'truncate
    (lambda ()
      (display "#lang racket/base\n;; Generated by tools/build-mac-app.rkt: the app bundle's entry point.\n")
      (display "(require (submod rackmac/app main))\n")))
  (define exe-app (build-path w "Rackmac.app"))
  (when (directory-exists? exe-app) (delete-directory/files exe-app))
  (run! #:env (with-addon addon) raco "exe" "--gui" "-o" (build-path w "Rackmac")
        "++lib" "rackmac/api" "++lib" "rackmac/lang/rackmac" "++lib" "rackmac/lang/reader"
        "++lib" "racket/base/lang/reader"      ; so an init file may also be `#lang racket/base`
        "++lib" "racket/date"                  ; the Customize with Code template requires it
        launcher)

  (say "== raco distribute")
  (define staged (build-path w "dist"))
  (when (directory-exists? staged) (delete-directory/files staged))
  (run! #:env (with-addon addon) raco "distribute" staged exe-app)
  (when (directory-exists? app) (delete-directory/files app))
  (make-directory* dist)
  ;; ditto, not a rename: the work directory may be on another volume, and the frameworks
  ;; inside hold symbolic links that must stay links.
  (run! (or (find-executable-path "ditto") "/usr/bin/ditto") (build-path staged "Rackmac.app") app)

  (say "== Icon and Info.plist")
  (define iconset (build-path w "Rackmac.iconset"))
  (when (directory-exists? iconset) (delete-directory/files iconset))
  (write-iconset! iconset)
  (define resources (build-path app "Contents" "Resources"))
  (run! (or (find-executable-path "iconutil") "/usr/bin/iconutil")
        "-c" "icns" "-o" (build-path resources "Rackmac.icns") iconset)
  (define starter (build-path resources "Starter.icns"))
  (when (file-exists? starter) (delete-file starter))
  (update-plist! (build-path app "Contents" "Info.plist"))
  (call-with-output-file (build-path app "Contents" "PkgInfo") #:exists 'truncate
    (lambda (o) (display "APPL????" o)))

  (say "== Built ~a (~a)" app (bundle-size)))

(define (bundle-size)
  (define bytes (for/sum ([p (in-directory app)] #:when (and (file-exists? p) (not (link-exists? p))))
                  (file-size p)))
  (format "~a MB" (/ (round (/ bytes 100000.)) 10)))

;; ---- smoke test ---------------------------------------------------------------------------

(define (smoke!)
  (define exe (build-path app "Contents" "MacOS" "Rackmac"))
  (unless (file-exists? exe) (error 'build-mac-app "no app to test: ~a" exe))
  (define home (make-temporary-directory "rackmac-smoke~a"))
  ;; Shaped like the Customize with Code template (rackmac/commands.rkt), racket/date and all.
  (display-to-file (string-append "#lang rackmac\n(require racket/date)\n"
                                  "(extension-info #:name \"Smoke\" #:requires-api 1)\n"
                                  "(define-command (smoke-date) (insert-text (date->string (current-date) #t)))\n")
                   (build-path home "init.rkt"))
  ;; The other way to write one: plain Racket requiring the API, plus a library the app embeds.
  (make-directory* (build-path home "ext"))
  (display-to-file (string-append "#lang racket/base\n(require rackmac/api racket/string)\n"
                                  "(add-hook! 'echo (lambda (s) (string-trim s)))\n")
                   (build-path home "ext" "smoke-ext.rkt"))
  (define note (build-path home "Smoke note.md"))
  (display-to-file "# Smoke\n\nOpened by the smoke test.\n" note)
  ;; An empty environment, as launchd gives a double-clicked app: no Racket, no Homebrew.
  (define env (make-environment-variables
               #"HOME" (path->bytes (find-system-path 'home-dir))
               #"PATH" #"/usr/bin:/bin"
               #"RACKMAC_HOME" (path->bytes home)
               #"RACKMAC_SMOKE" #"1"
               #"RACKMAC_NO_FRONT" #"1"))
  (say "== Smoke test: ~a (RACKMAC_HOME=~a, PATH=/usr/bin:/bin)" exe home)
  (define out (open-output-string))
  (define ok?
    (parameterize ([current-environment-variables env]
                   [current-output-port out]
                   [current-error-port out])
      (system* exe (path->string note))))
  (define text (get-output-string out))
  (display text)
  (delete-directory/files home #:must-exist? #f)
  (unless (and ok? (regexp-match? #rx"(?m:^ok$)" text))
    (error 'build-mac-app "smoke test failed"))
  (say "== Smoke test passed"))

(module+ main
  (command-line
   #:once-each
   [("--work") dir "Work directory (default dist/build)" (work (string->path dir))]
   [("--smoke") "Run the headless smoke test after building" (smoke? #t)]
   [("--smoke-only") "Only run the smoke test, on the app already in dist/" (smoke? #t) (build? #f)]
   #:args ()
   (when (build?) (build!))
   (when (smoke?) (smoke!))))
