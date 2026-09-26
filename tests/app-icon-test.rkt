#lang racket/base
;; The app bundle's icon and Info.plist settings (#286): the committed SVG masters are what
;; tools/app-icon.rkt draws (regenerate with `racket tools/app-icon.rkt assets`), every
;; iconutil size renders at its pixel size, and the bundle declares what Finder needs.
(require rackunit racket/class racket/draw racket/file racket/list racket/runtime-path
         "../tools/app-icon.rkt" "../tools/build-mac-app.rkt" "../rackmac/version.rkt")

(define-runtime-path assets "../assets/icon")

(test-case "the committed SVG masters match tools/app-icon.rkt"
  (check-equal? (file->string (build-path assets "rackmac-mark.svg")) (icon-svg #f))
  (check-equal? (file->string (build-path assets "rackmac-mark-small.svg")) (icon-svg #t))
  (check-true (file-exists? (build-path assets "rackmac-256.png"))))

(test-case "brand project mark: slate tile, one verdigris detail"
  (for ([small? '(#f #t)])
    (define shapes (icon-shapes small?))
    (check-equal? (first shapes) '(rrect 6 6 116 116 26 "#232B36"))
    (check-equal? (length (filter (lambda (s) (equal? (last s) "#43BEB0")) shapes)) 1)))

(test-case "iconutil's ten entries, 16 to 1024 pixels, each rendered at its size"
  (check-equal? (length iconset-entries) 10)
  (check-equal? (remove-duplicates (sort (map cdr iconset-entries) <)) '(16 32 64 128 256 512 1024))
  (check-not-false (assoc "icon_512x512@2x.png" iconset-entries))
  (for ([px '(16 32 1024)])
    (define bm (render-icon px))
    (check-equal? (list (send bm get-width) (send bm get-height)) (list px px))))

(test-case "Info.plist: identity, a numeric pre-1.0 version, and Markdown/text document types"
  (check-equal? (hash-ref plist-settings 'CFBundleIdentifier) "cl.skpt.rackmac")
  (check-equal? (hash-ref plist-settings 'CFBundleName) "Rackmac")
  (check-regexp-match #px"^0[.][0-9]+[.][0-9]+$" app-version)
  (check-equal? (hash-ref plist-settings 'CFBundleShortVersionString) app-version)
  (define exts (append-map (lambda (t) (hash-ref t 'CFBundleTypeExtensions))
                           (hash-ref plist-settings 'CFBundleDocumentTypes)))
  (check-equal? (sort exts string<?) '("markdown" "md" "txt"))
  (for ([t (hash-ref plist-settings 'CFBundleDocumentTypes)])
    (check-equal? (hash-ref t 'LSHandlerRank) "Alternate")))
