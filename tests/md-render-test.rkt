#lang racket/base
;; The Formatted view of a Markdown note (#268, docs/UI-DESIGN.md §2.2): headings sized and
;; bold, markup small in text-2 but never hidden, strong/emphasis, code in the mono face on
;; line-highlight, links in accent and underlined, quotes and list items indented. Styling
;; leaves the text byte-identical to the file and never enters undo. The visual checks render
;; with the editor itself at 1x and 2x, light and dark, and measure structure, not golden images.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/list
         "ui-harness.rkt" "../rackmac/editor.rkt" "../rackmac/theme.rkt" "../rackmac/md-style.rkt"
         "../rackmac/ui/tokens.rkt")

(define (note text)
  (define b (new-buffer! "render" #:mode 'markdown-mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  b)

(define (style-at b pos) (send (send b find-snip pos 'after) get-style))
(define (font-at b pos) (send (style-at b pos) get-font))
(define (size-at b pos) (send (font-at b pos) get-point-size))
(define (fg-at b pos) (color->hex (send (style-at b pos) get-foreground)))
(define (index-of s sub) (let ([m (regexp-match-positions (regexp-quote sub) s)]) (caar m)))

(define sample
  (string-append
   "# Engagement letter\n\n"
   "## Scope\n\n"
   "### Fees\n\n"
   "#### Notes\n\n"
   "The **client** agrees to *review* the `draft()` and [the memo](https://example.com/memo).\n\n"
   "> Quoted from the hearing.\n\n"
   "- first item that is long enough\n  to continue on a lazy line\n- second\n  - nested\n\n"
   "```\n(define x 1)\n```\n"))

(test-case "headings: 1.6x, 1.35x, 1.15x, then 1.0x, bold, in the heading color"
  (define b (note sample))
  (define body (size-at b (index-of sample "agrees")))
  (define (heading-size text) (size-at b (+ 2 (index-of sample text))))
  (check-equal? (heading-size "Engagement") (inexact->exact (truncate (* 1.6 body))))
  (check-equal? (heading-size "Scope") (inexact->exact (truncate (* 1.35 body))))
  (check-equal? (heading-size "Fees") (inexact->exact (truncate (* 1.15 body))))
  (check-equal? (heading-size "Notes") body)
  (for ([t '("Engagement" "Scope" "Fees" "Notes")])
    (check-equal? (send (font-at b (+ 2 (index-of sample t))) get-weight) 'bold t)
    (check-equal? (fg-at b (+ 2 (index-of sample t))) (token-hex 'heading) t)))

(test-case "markup characters stay in the text, smaller and in text-2"
  (define b (note sample))
  (define hash-pos (index-of sample "# Engagement"))
  (check-equal? (send b get-text hash-pos (add1 hash-pos)) "#")
  (check-equal? (fg-at b hash-pos) (token-hex 'text-2))
  (check-true (< (size-at b hash-pos) (size-at b (+ 2 hash-pos))) "smaller than the heading text")
  (define stars (index-of sample "**client"))
  (check-equal? (fg-at b stars) (token-hex 'text-2))
  (check-true (< (size-at b stars) (size-at b (index-of sample "agrees"))) "smaller than body text")
  (check-true (> (size-at b stars) 1) "de-emphasized, never hidden"))

(test-case "strong, emphasis, inline code, fenced code, links and quotes"
  (define b (note sample))
  (define body (index-of sample "agrees"))
  (check-equal? (send (font-at b (index-of sample "client")) get-weight) 'bold)
  (check-equal? (send (font-at b (index-of sample "review")) get-style) 'italic)
  (check-equal? (send (font-at b body) get-face) prose-face)
  (for ([code (list (index-of sample "draft()") (index-of sample "(define x"))])
    (check-equal? (send (font-at b code) get-face) mono-face "inline code and fenced code (#267) are mono")
    (check-equal? (color->hex (send (style-at b code) get-background)) (token-hex 'line-highlight))
    (check-false (send (style-at b code) get-transparent-text-backing) "its background is painted"))
  (check-true (send (style-at b body) get-transparent-text-backing) "prose paints no background")
  (define link (index-of sample "the memo"))
  (check-equal? (fg-at b link) (token-hex 'accent))
  (check-true (send (font-at b link) get-underlined))
  (define dest (index-of sample "https://example.com/memo"))
  (check-equal? (fg-at b dest) (token-hex 'text-2) "the destination is markup")
  (check-false (send (font-at b dest) get-underlined))
  (check-equal? (fg-at b (index-of sample "Quoted")) (token-hex 'text-2)))

(test-case "the note styles are named in the shared style list and follow the theme"
  (define b (note sample))
  (for ([e (in-list note-style-names)])
    (check-not-false (send editor-style-list find-named-style (car e)) (car e)))
  (define other (if (eq? (current-theme-name) 'dark) 'light 'dark))
  (with-appearance other
    (lambda ()
      (send b rehighlight!)
      (check-equal? (fg-at b (+ 2 (index-of sample "Engagement"))) (token-hex 'heading other))
      (check-equal? (color->hex (send (send editor-style-list find-named-style "Heading 1") get-foreground))
                    (token-hex 'heading other))))
  (send b rehighlight!)
  (check-equal? (fg-at b (+ 2 (index-of sample "Engagement"))) (token-hex 'heading) "and back again"))

(test-case "zoom scales headings and code with the body"
  (define b (note sample))
  (define h (+ 2 (index-of sample "Engagement")))
  (define before font-size)
  (define h0 (size-at b h))
  (set-font-size! (+ before 6))
  (check-true (> (size-at b h) (+ h0 6)) "the heading grows by more than the body")
  (set-font-size! before)
  (check-equal? (size-at b h) h0))

;; Where the first character of each paragraph is drawn, in a hidden canvas.
(define (line-x b para)
  (define x (box 0))
  (send b position-location (send b paragraph-start-position para) x #f)
  (unbox x))

(test-case "quotes and list items are indented; items hang their marker"
  (define b (note sample))
  (new editor-canvas% [parent (new frame% [label "layout"])] [editor b])   ; never shown
  (define (para-of text) (send b position-paragraph (index-of sample text)))
  (define plain (line-x b (para-of "The **client")))
  (check-= (- (line-x b (para-of "> Quoted")) plain) indent-step 0)
  (check-= (- (line-x b (para-of "- first")) plain) (- indent-step hang-indent) 0 "the item's first line hangs")
  (check-= (- (line-x b (para-of "  to continue")) plain) indent-step 0 "its lazy line aligns with the text")
  (check-= (- (line-x b (para-of "  - nested")) plain) (- (* 2 indent-step) hang-indent) 0)
  ;; typing a line break inside an item keeps the layout right on both sides
  (define at (index-of sample "long enough"))
  (send b insert "\n  " at)
  (check-= (- (line-x b (send b position-paragraph (add1 at))) plain) indent-step 0)
  (check-= (- (line-x b (para-of "- first")) plain) (- indent-step hang-indent) 0)
  (send b delete at (+ at 3))
  (check-equal? (send b get-text) sample)
  ;; a Language without the Formatted view has no indents
  (send b set-mode! 'text-mode)
  (check-= (line-x b (para-of "> Quoted")) plain 0))

(test-case "a note opened from a file keeps its bytes, its undo history and its modified flag"
  (define dir (make-temporary-file "rackmac-render~a" 'directory))
  (define p (build-path dir "sample.md"))
  (define bytes (string->bytes/utf-8 (string-append sample "Café — naïve “quotes” ✓\n")))
  (call-with-output-file p (lambda (o) (write-bytes bytes o)))
  (define b (new-buffer! "file"))
  (send b load-path! p)
  (check-eq? (send b get-mode) 'markdown-mode)
  (check-not-eq? (style-at b 2) (style-at b 25) "it is formatted")
  (check-equal? (string->bytes/utf-8 (send b get-text)) bytes "get-text is the file, byte for byte")
  (check-false (send b is-modified?))
  (check-false (send b can-do-edit-operation? 'undo) "formatting left nothing to undo")
  (define out (build-path dir "saved.md"))
  (send b save-to! out)
  (check-equal? (file->bytes out) bytes)
  (delete-directory/files dir))

;; ---- visual checks (tests/ui-harness.rkt) -----------------------------------------------------

;; How many device-pixel rows hold anything but the page color.
(define (ink-rows bm bg)
  (define s (send bm get-backing-scale))
  (for/sum ([y (in-range 0 (send bm get-height) (/ 1 s))])
    (if (for/or ([x (in-range 0 (send bm get-width) (/ 1 s))]) (not (equal? (bitmap-pixel-hex bm x y) bg))) 1 0)))

(define (darkest bm bg) (argmax (lambda (c) (contrast-ratio c bg)) (hash-keys (bitmap-colors bm))))

(define (hex-distance a b)
  (define (ch h i) (string->number (substring h i (+ i 2)) 16))
  (for/sum ([i '(1 3 5)]) (abs (- (ch a i) (ch b i)))))

(define (name-of what app scale) (format "md-~a-~a-~ax" what app (inexact->exact scale)))

(test-case "rendered notes: headings taller than body, markup in text-2, code on line-highlight"
  (for* ([app appearances] [scale scales])
    (with-appearance app
      (lambda ()
        (define bg (token-hex 'surface app))
        (define (draw text) (render-document text 'markdown-mode #:scale scale #:width 240 #:height 60))
        (define heading (draw "# Hello\n"))
        (define body (draw "Hello\n"))
        (define markup (draw "---\n"))          ; a line that is nothing but markup
        (define code (draw "`code`\n"))
        (write-tour-png! (name-of "heading" app scale) heading)
        (write-tour-png! (name-of "markup" app scale) markup)
        (check-true (> (ink-rows heading bg) (* 1.3 (ink-rows body bg)))
                    (format "~a: heading ~a rows, body ~a" (name-of "size" app scale)
                            (ink-rows heading bg) (ink-rows body bg)))
        ;; glyph cores, within a tolerance: rasterization differs between machines
        (check-true (<= (hex-distance (darkest heading bg) (token-hex 'heading app)) 12) (name-of "heading color" app scale))
        (check-true (<= (hex-distance (darkest body bg) (token-hex 'text app)) 12) (name-of "body color" app scale))
        ;; markup ink is visible but never as strong as body text; at 2x its glyph cores are text-2
        (define m (darkest markup bg))
        (check-true (< 1.2 (contrast-ratio m bg) (+ 0.05 (contrast-ratio (token-hex 'text-2 app) bg)))
                    (format "~a: ~a" (name-of "markup" app scale) m))
        (when (= scale 2.0)
          (check-true (<= (hex-distance m (token-hex 'text-2 app)) 12) (format "~a: ~a" (name-of "markup color" app scale) m)))
        (check-true (> (hash-ref (bitmap-colors code) (token-hex 'line-highlight app) 0) 0)
                    (name-of "code background" app scale))))))
