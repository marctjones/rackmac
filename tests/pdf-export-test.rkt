#lang racket/base
;; Export as PDF (#279): a note becomes a PDF drawn by the editor itself on a pdf-dc%, headless.
;; Checks the page count read back from the file's bytes, that headings, lists and links are
;; styled as the Formatted view styles them (in the light appearance whatever the screen's), that
;; the screen's appearance survives an export, the paper from the locale, the footer's page
;; number, the 40-page time budget, and the command's dialog and message.
;; The file opens in Preview: checked by hand with `qlmanage -t` (not here: CI has no window
;; server), docs/UI-DESIGN.md §5.4.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/file racket/string racket/port racket/list racket/gui/base
         file/gunzip
         "ui-harness.rkt"
         "../rackmac/pdf-export.rkt" "../rackmac/command.rkt" "../rackmac/editor.rkt"
         "../rackmac/hook.rkt" "../rackmac/theme.rkt" "../rackmac/md-style.rkt"
         "../rackmac/settings.rkt" "../rackmac/office.rkt" "../rackmac/ui/tokens.rkt")

(void (putenv "RACKMAC_HOME" (path->string (make-temporary-file "rackmac-pdf~a" 'directory))))
(define dir (make-temporary-file "rackmac-pdf-docs~a" 'directory))

;; ---- reading a PDF back (no dependency: zlib streams through file/gunzip) --------------------

;; cairo puts page objects in compressed object streams, so every Flate stream is inflated and
;; searched along with the plain bytes.
(define (pdf-texts file)
  (define bs (file->bytes file))
  (cons bs
        (for/list ([m (in-list (regexp-match-positions* #rx#"(?<!end)stream\r?\n" bs))]
                   #:when (and (< (+ (cdr m) 2) (bytes-length bs)) (= (bytes-ref bs (cdr m)) #x78)))
          (with-handlers ([exn:fail? (lambda (e) #"")])
            (define in (open-input-bytes bs))
            (file-position in (+ 2 (cdr m)))      ; past the 2-byte zlib header
            (with-output-to-bytes (lambda () (inflate in (current-output-port))))))))

(define (pdf-page-count file)
  (for/sum ([t (in-list (pdf-texts file))]) (length (regexp-match* #rx#"/Type */Page[^s]" t))))

(define (pdf-media-box file)
  (for/or ([t (in-list (pdf-texts file))])
    (define m (regexp-match #rx#"/MediaBox *\\[ *0 +0 +([0-9.]+) +([0-9.]+) *\\]" t))
    (and m (list (string->number (bytes->string/utf-8 (cadr m))) (string->number (bytes->string/utf-8 (caddr m)))))))

;; ---- notes ----------------------------------------------------------------------------------

(define section
  (string-append
   "## Open points\n\n"
   "A paragraph of plain prose that runs long enough to wrap across the measure of the page, "
   "with *emphasis*, **strong** text, `code` and [the lease](https://example.com/lease).\n\n"
   "- first bullet\n- second bullet with more words\n  - nested item\n\n1. one\n2. two\n\n"
   "> a quoted line\n\n"))
(define (note-of n) (string-append "# Harbor Street lease\n\n" (string-join (for/list ([i n]) section) "")))

(define (index-of-text s sub) (caar (regexp-match-positions (regexp-quote sub) s)))

;; ---- tests ----------------------------------------------------------------------------------

(test-case "a short note writes a one-page PDF on the chosen paper"
  (define out (build-path dir "short.pdf"))
  (check-equal? (export-pdf! (note-of 1) 'markdown-mode out #:paper 'letter) 1)
  (check-true (regexp-match? #rx#"^%PDF-" (file->bytes out)))
  (check-equal? (pdf-page-count out) 1)
  (check-equal? (pdf-media-box out) '(612 792))
  (define a4 (build-path dir "short-a4.pdf"))
  (export-pdf! (note-of 1) 'markdown-mode a4 #:paper 'a4)
  (check-equal? (pdf-media-box a4) '(595 842)))

(test-case "a long note paginates: the file's page count matches the pages drawn"
  (define out (build-path dir "long.pdf"))
  (define pages (export-pdf! (note-of 30) 'markdown-mode out #:paper 'letter))
  (check-true (> pages 5) (format "~a pages" pages))
  (check-equal? (pdf-page-count out) pages)
  ;; A4 is taller and narrower: a different count, still read back exactly
  (define a4 (build-path dir "long-a4.pdf"))
  (define a4-pages (export-pdf! (note-of 30) 'markdown-mode a4 #:paper 'a4))
  (check-equal? (pdf-page-count a4) a4-pages))

(test-case "headings, lists and links are styled as the Formatted view styles them, in light"
  (define text (note-of 1))
  (with-appearance 'dark
    (lambda ()
      (call-with-print-look
       (lambda ()
         (define b (prepare-export-buffer text 'markdown-mode #:width 468))
         (define (style-at pos) (send (send b find-snip pos 'after) get-style))
         (define (x-of pos) (let ([x (box 0)]) (send b position-location pos x #f) (unbox x)))
         (define h1 (index-of-text text "Harbor"))
         (define h2 (index-of-text text "Open points"))
         (define body (index-of-text text "A paragraph"))
         (define link (index-of-text text "the lease"))
         (define item (index-of-text text "first bullet"))
         (define nested (index-of-text text "nested item"))
         (check-equal? (current-theme-name) 'light "printed in the light appearance")
         (check-equal? (send (send (style-at h1) get-font) get-weight) 'bold)
         (check-true (> (send (style-at h1) get-size) (send (style-at h2) get-size) (send (style-at body) get-size))
                     "Heading 1 > Heading 2 > body")
         (check-equal? (send (style-at body) get-size) (add1 print-font-size) "body text is 12 pt")
         (check-equal? (color->hex (send (style-at h1) get-foreground)) (token-hex 'heading))
         (check-true (send (send (style-at link) get-font) get-underlined) "links are underlined")
         (check-equal? (color->hex (send (style-at link) get-foreground)) (token-hex 'accent))
         (check-true (> (x-of item) (x-of body)) "list items are indented")
         (check-true (> (x-of nested) (x-of item)) "nested items are indented further")
         (check-true (<= (send b get-max-width) 468) "wrapped at the page's measure, not the window's")))
      ;; the screen is dark again, heading styles included
      (check-equal? (current-theme-name) 'dark)
      (define h (send editor-style-list find-named-style "Heading 1"))
      (check-equal? (color->hex (send h get-foreground)) (token-hex 'heading)))))

(test-case "the zoom level is put back after an export"
  (define before font-size)
  (set-font-size! 20)
  (export-pdf! "# Zoomed\n\ntext\n" 'markdown-mode (build-path dir "zoom.pdf") #:paper 'letter)
  (check-equal? font-size 20)
  (set-font-size! before))

(test-case "code and plain text documents export too"
  (define code (build-path dir "code.pdf"))
  (check-equal? (export-pdf! (string-append "(define (f x)\n  " (make-string 400 #\a) ")\n") 'racket-mode code
                             #:paper 'letter)
                1)
  (check-equal? (pdf-page-count code) 1)
  (define plain (build-path dir "plain.pdf"))
  (check-equal? (export-pdf! "Plain words.\n" 'text-mode plain #:paper 'a4) 1))

(test-case "the footer carries the page number in the bottom margin"
  (define bm (render-bitmap 612 792 (lambda (dc) (draw-footer dc 7 612 792)) #:background (make-color 255 255 255)))
  (define (ink-in y0 y1)
    (for*/or ([y (in-range y0 y1 2)] [x (in-range 280 332)])
      (not (equal? (bitmap-pixel-hex bm x y) "#FFFFFF"))))
  (check-true (ink-in (- 792 72) 792) "drawn in the bottom margin")
  (check-false (ink-in 0 (- 792 72)) "nothing above it"))

(test-case "the paper follows the locale's region"
  (for ([c '(("en_US" letter) ("en_US.UTF-8" letter) ("fr_CA" letter) ("es-MX" letter)
             ("en_GB" a4) ("de_DE.UTF-8" a4) ("ja_JP" a4) ("en_GB@rg=uszzzz" letter)
             ("en_US@rg=dezzzz" a4) ("C" a4) (#f a4))])
    (check-equal? (paper-for-locale (car c)) (cadr c) (format "~a" (car c))))
  (check-not-false (memq (system-paper) '(letter a4)))
  (setting-set! 'pdf-paper-size 'a4)
  (check-equal? (export-paper) 'a4)
  (setting-set! 'pdf-paper-size 'letter)
  (check-equal? (export-paper) 'letter)
  (setting-set! 'pdf-paper-size 'automatic)
  (check-equal? (export-paper) (system-paper)))

(test-case "a 40-page note exports in under 3 s of CPU"
  (define slack (if (getenv "CI") 5 1))
  ;; about 40 Letter pages: grow the note until it is
  (define text (note-of 92))
  (define out (build-path dir "forty.pdf"))
  (define t0 (current-process-milliseconds))
  (define pages (export-pdf! text 'markdown-mode out #:paper 'letter))
  (define ms (- (current-process-milliseconds) t0))
  (printf "pdf-export-test: ~a pages in ~a ms CPU\n" pages ms)
  (check-true (>= pages 40) (format "~a pages" pages))
  (check-true (< ms (* slack 3000)) (format "~a ms" ms))
  (check-equal? (pdf-page-count out) pages))

(test-case "Export as PDF asks where, writes the file, says so and reveals it"
  (define b (new-buffer! "Exported note.md" #:mode 'markdown-mode))
  (send b insert (note-of 2))
  (set-current-buffer! b)
  (define said '())
  (add-hook! 'echo (lambda (s) (set! said (cons s said))))
  (define out (build-path dir "Exported note.pdf"))
  (define revealed #f)
  (parameterize ([ask-pdf-path (lambda (suggested d) (check-equal? (path->string suggested) "Exported note.pdf") out)]
                 [reveal-after-export (lambda (p) (set! revealed p))])
    (run-command 'export-pdf))
  (check-true (file-exists? out))
  (check-equal? revealed out)
  (check-true (for/or ([s said]) (regexp-match? #rx"Exported to .*page" s)))
  (check-false (for/or ([x (all-buffers)]) (equal? (send x get-name) "PDF export")) "the copy is never a tab")
  ;; cancelling the dialog does nothing
  (set! said '())
  (parameterize ([ask-pdf-path (lambda (s d) #f)]) (run-command 'export-pdf))
  (check-false (for/or ([s said]) (regexp-match? #rx"Exported" s))))
