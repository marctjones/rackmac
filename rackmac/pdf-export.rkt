#lang racket/base
;; Export as PDF (#279, docs/REPLAN.md E18.M1 `export-pdf-native`): File > Export as PDF… draws
;; the note as the Formatted view shows it onto Letter or A4 paper with Racket's own `pdf-dc%`;
;; no pandoc. Print… (⌘P) keeps the native print dialog, whose "Save as PDF" also works.
;;
;; How. The note's text goes into a private copy (never a tab), in the same Language, which the
;; editor itself styles (md-style.rkt for Markdown, always the Formatted view) and lays out at the
;; page's text width, so the measure follows the paper, not the window. text%'s own `print-to-dc`
;; paginates it inside 1 in margins onto a `pdf-dc%` whose `end-page` adds the page number in the
;; bottom margin. While the copy is styled and drawn the shared style list is switched to the
;; light appearance at the print size (body 12 pt), then put back, so a dark screen never
;; prints dark and the open notes look as before.
;;
;; Code documents print in the mono face, not centered, wrapped at the right margin (on screen
;; they do not wrap). Plain Text notes print in the serif face like Markdown ones.
;;
;; Not done: pdf-dc% writes no /Title, and its cairo surface is private, so the note's title is
;; not in the PDF's metadata (the file name carries it).
(require racket/class racket/gui/base racket/port racket/system racket/string
         "command.rkt" "editor.rkt" "buffer.rkt" "settings.rkt" "platform.rkt" "theme.rkt"
         "md-style.rkt" "ui/tokens.rkt"
         (only-in "office.rkt" reveal-after-export))
(provide export-pdf! export-document-pdf! ask-pdf-path
         paper-for-locale system-paper export-paper paper-size page-margin print-font-size
         prepare-export-buffer call-with-print-look draw-footer)

;; ---- paper ----------------------------------------------------------------------------------

;; Points (1/72 in). pdf-dc% rounds the page up to whole points, so A4 is 595 x 842.
(define paper-sizes '((letter 612 792) (a4 595 842)))
(define (paper-size paper) (apply values (cdr (assq paper paper-sizes))))
(define page-margin 72)                         ; 1 in on every side

;; Regions that use US Letter; everywhere else uses A4 (ISO 216).
(define letter-regions '("US" "CA" "MX" "PR" "PH" "CL" "CO" "VE" "CR" "GT" "PA" "SV" "DO" "NI" "BZ"))

;; A locale string ("en_US", "en_GB.UTF-8", "fr-CA", or macOS's "en_GB@rg=uszzzz", where the
;; region override after @rg= wins) -> 'letter or 'a4. Unknown regions get A4.
(define (paper-for-locale s)
  (define region
    (cond [(and s (regexp-match #px"@rg=([a-zA-Z]{2})" s)) => (lambda (m) (string-upcase (cadr m)))]
          [(and s (regexp-match #px"^[a-zA-Z]{2,3}[_-]([A-Z]{2})(?:[._@]|$)" s)) => cadr]
          [else #f]))
  (if (and region (member region letter-regions)) 'letter 'a4))

;; The locale's paper, read once: macOS's AppleLocale (an app bundle has no LANG), else the
;; environment's LC_PAPER, LC_ALL or LANG.
(define (read-system-locale)
  (define (env) (for/or ([v '("LC_PAPER" "LC_ALL" "LANG")])
                  (let ([s (getenv v)]) (and s (regexp-match? #px"^[a-zA-Z]{2,3}[_-]" s) s))))
  (or (and (mac?)
           (with-handlers ([exn:fail? (lambda (e) #f)])
             (let ([s (string-trim
                       (with-output-to-string
                         (lambda () (parameterize ([current-error-port (open-output-nowhere)])
                                      (system* "/usr/bin/defaults" "read" "-g" "AppleLocale")))))])
               (and (not (string=? s "")) s))))
      (env)))
(define system-paper
  (let ([cache #f]) (lambda () (or cache (begin (set! cache (paper-for-locale (read-system-locale))) cache)))))

(define-setting pdf-paper-size
  #:contract (lambda (v) (and (memq v '(automatic letter a4)) #t))
  #:default 'automatic
  #:category "Word and PDF"
  #:choices '((automatic . "From the Region Setting") (letter . "US Letter") (a4 . "A4"))
  #:doc "Paper size for Export as PDF: Letter or A4 as your region uses, or always one of them.")

(define (export-paper)
  (define v (setting-ref 'pdf-paper-size))
  (if (eq? v 'automatic) (system-paper) v))

;; ---- the print look -------------------------------------------------------------------------

;; The editor font size while printing: "Prose" is one point larger, so body text is 12 pt and
;; code 11 pt; headings scale from it as on screen.
(define print-font-size 11)

;; Runs `thunk` with the shared style list in the light appearance at the print size, then puts
;; the screen's appearance and size back, including the named note styles ("Heading 1", ...),
;; which md-style.rkt refreshes only when asked for a style.
(define (call-with-print-look thunk)
  (define theme (current-theme-name))
  (define size font-size)
  (dynamic-wind
   (lambda ()
     (unless (eq? theme 'light) (set-theme! 'light))
     (unless (= size print-font-size) (set-font-size! print-font-size)))
   thunk
   (lambda ()
     (unless (= size print-font-size) (set-font-size! size))
     (unless (eq? theme 'light) (set-theme! theme))
     (void (markdown-style-for "Prose" '())))))

;; One hidden canvas hosts the copy being exported (text% lays out and prints through an editor
;; admin); it is never shown and is reused by every export.
(define host #f)
(define (host-canvas)
  (unless host
    (set! host (new editor-canvas% [parent (new frame% [label "PDF export"])] [style '(no-hscroll)])))
  host)

;; A private copy of `text` in Language `mode`, styled as the editor styles it (Markdown always
;; Formatted) and wrapped at `width` points. Call inside call-with-print-look.
(define (prepare-export-buffer text mode #:width [width 468])
  (define b (new buffer% [name "PDF export"]))
  (send b insert text)
  (send b local-set! 'markdown-view 'formatted)     ; markdown-view-enable! keeps a set view
  (send b set-mode! mode)
  (when (send b large?)                             ; rehighlight! skips long documents
    (if (eq? mode 'markdown-mode) (render-markdown! b) (send b restyle-document!)))
  (send b auto-wrap #t)                             ; code too: nothing runs past the margin
  (send b set-position 0)
  (send (host-canvas) set-editor b)
  (send b set-max-width width)
  b)

;; ---- drawing --------------------------------------------------------------------------------

;; The page number, centered in the bottom margin, small and quiet.
(define (draw-footer dc page w h)
  (send dc set-origin 0 0)
  (send dc set-scale 1 1)
  (send dc set-clipping-region #f)
  (send dc set-font (make-font #:face prose-face #:family 'roman #:size 9 #:size-in-pixels? #t))
  (send dc set-text-foreground (token 'text-2))
  (define label (number->string page))
  (define-values (tw th _d _a) (send dc get-text-extent label))
  (send dc draw-text label (/ (- w tw) 2) (- h (/ page-margin 2) (/ th 2))))

;; A pdf-dc% that counts its pages and draws the footer on each before it ends.
(define footed-pdf-dc%
  (class pdf-dc%
    (init-field page-w page-h)
    (define pages 0)
    (define/public (page-count) pages)
    (define/override (start-page) (super start-page) (set! pages (add1 pages)))
    (define/override (end-page) (draw-footer this pages page-w page-h) (super end-page))
    (super-new)))

;; Writes `text` (Language `mode`) to the PDF `out`; returns the number of pages.
(define (export-pdf! text mode out #:paper [paper (export-paper)])
  (define-values (w h) (paper-size paper))
  (define ps (new ps-setup%))
  (send ps set-mode 'file)
  (send ps set-file out)
  (send ps set-orientation 'portrait)
  (send ps set-margin 0 0)
  (send ps set-translation 0 0)
  (send ps set-scaling 1 1)
  (send ps set-editor-margin page-margin page-margin)
  (call-with-print-look
   (lambda ()
     (define b (prepare-export-buffer text mode #:width (- w (* 2 page-margin))))
     (parameterize ([current-ps-setup ps])
       (define dc (new footed-pdf-dc% [interactive #f] [parent #f] [use-paper-bbox #f] [as-eps #f]
                       [width w] [height h] [output out] [page-w w] [page-h h]))
       (send dc start-doc "Export as PDF")
       (send b print-to-dc dc -1)
       (send dc end-doc)
       (send (host-canvas) set-editor #f)
       (send dc page-count)))))

;; A buffer's text, as its Language shows it.
(define (export-document-pdf! b out #:paper [paper (export-paper)])
  (export-pdf! (send b get-text) (send b get-mode) out #:paper paper))

;; ---- the command ----------------------------------------------------------------------------

(define ask-pdf-path
  (make-parameter (lambda (suggested dir) (put-file "Export as PDF" (ui-parent) dir (path->string suggested) "pdf"))))

(define (docs-dir-of b)
  (define p (send b get-path))
  (and p (let-values ([(dir name _) (split-path p)]) dir)))

(define-command (export-pdf)
  #:icon "save-as"
  #:aliases ("pdf" "save as pdf" "export pdf" "print to pdf")
  #:help "Save a copy of this note as a PDF, formatted as it looks here, on Letter or A4 paper."
  #:title "Export as PDF…" #:menu "File" #:menu-order 28
  (define b (current-buffer))
  (define out ((ask-pdf-path) (path-replace-extension (string->path (send b get-name)) #".pdf") (docs-dir-of b)))
  (when out
    (with-handlers ([exn:fail? (lambda (e) (message "PDF export failed: ~a" (exn-message e)))])
      (define pages (export-document-pdf! b out))
      (message "Exported to ~a (~a ~a)" (path->string out) pages (if (= pages 1) "page" "pages"))
      ((reveal-after-export) out))))
