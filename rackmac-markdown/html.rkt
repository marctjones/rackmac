#lang racket/base
;; The HTML renderer (design §4.2): cmark's exact formatting, so the spec runner compares strings
;; exactly -- block tags each on their own line, `<br />`, entity-escaped text, destinations
;; escaped as cmark's houdini_escape_href does. Leaf inline content is rendered from the
;; content-relative inline tree and the leaf's content string (a raw-HTML node is a slice of the
;; content, never of the document text, which would include container prefixes). mdlib-html
;; (#319) completes the renderer; this is the half the spec sections of mdlib-inlines need.
(require racket/string racket/list "ast.rkt" "entities.rkt" "inlines.rkt")
(provide document->html escape-href)

;; Writes unescaped stretches with one write-string each (per-character writes made a 12 MB
;; paragraph cost several hundred ms).
(define (write-escaped s out)
  (define n (string-length s))
  (let loop ([from 0] [i 0])
    (cond
      [(= i n) (write-string s out from n)]
      [else
       (define rep
         (case (string-ref s i)
           [(#\&) "&amp;"] [(#\<) "&lt;"] [(#\>) "&gt;"] [(#\") "&quot;"] [else #f]))
       (cond
         [rep (write-string s out from i) (write-string rep out) (loop (add1 i) (add1 i))]
         [else (loop from (add1 i))])])))

;; cmark escapes &, <, >, and " everywhere it emits text (not just inside attributes).
(define (escape-html s)
  (if (for/or ([c (in-string s)]) (memv c '(#\& #\< #\> #\")))
      (let ([out (open-output-string)]) (write-escaped s out) (get-output-string out))
      s))

;; cmark's houdini_escape_href: alphanumerics and -_.+!*(),%#@?=;:/$~ pass through (so existing
;; %XX sequences survive), & and ' become entities, everything else is %XX per UTF-8 byte.
(define (href-safe? c)
  (or (and (char>=? c #\a) (char<=? c #\z)) (and (char>=? c #\A) (char<=? c #\Z))
      (and (char>=? c #\0) (char<=? c #\9))
      (memv c '(#\- #\_ #\. #\+ #\! #\* #\( #\) #\, #\% #\# #\@ #\? #\= #\; #\: #\/ #\$ #\~))))

(define (escape-href s)
  (define out (open-output-string))
  (for ([c (in-string s)])
    (cond
      [(href-safe? c) (write-char c out)]
      [(eqv? c #\&) (write-string "&amp;" out)]
      [(eqv? c #\') (write-string "&#x27;" out)]
      [else
       (for ([b (in-bytes (string->bytes/utf-8 (string c)))])
         (write-string (string-append "%" (string-upcase (if (< b 16)
                                                              (string-append "0" (number->string b 16))
                                                              (number->string b 16))))
                       out))]))
  (get-output-string out))

(define (line-text source l) (string-append (make-string (third l) #\space)
                                             (substring source (first l) (second l))))

(define (lines->content source lines)
  (if (null? lines) "" (string-append (string-join (map (lambda (l) (line-text source l)) lines) "\n") "\n")))

;; --- Inlines ------------------------------------------------------------------------------------

(define (render-inlines content xs unsafe?)
  (define out (open-output-string))
  (for ([x (in-list xs)]) (render-inline x content unsafe? out))
  (get-output-string out))

(define (render-inline x content unsafe? out)
  (cond
    [(text? x) (write-escaped (text-value x) out)]
    [(soft-break? x) (write-string "\n" out)]
    [(hard-break? x) (write-string "<br />\n" out)]
    [(code-span? x)
     (write-string "<code>" out) (write-escaped (code-span-value x) out) (write-string "</code>" out)]
    [(emph? x)
     (write-string "<em>" out) (render-children (emph-children x) content unsafe? out) (write-string "</em>" out)]
    [(strong? x)
     (write-string "<strong>" out) (render-children (strong-children x) content unsafe? out)
     (write-string "</strong>" out)]
    [(link? x)
     (write-string "<a href=\"" out) (write-string (escape-href (link-dest x)) out) (write-string "\"" out)
     (write-title (link-title x) out)
     (write-string ">" out) (render-children (link-children x) content unsafe? out) (write-string "</a>" out)]
    [(image? x)
     (write-string "<img src=\"" out) (write-string (escape-href (image-dest x)) out)
     (write-string "\" alt=\"" out)
     (write-escaped (let ([p (open-output-string)]) (plain-text (image-children x) content p) (get-output-string p)) out)
     (write-string "\"" out)
     (write-title (image-title x) out)
     (write-string " />" out)]
    [(raw-html? x)
     (write-string (if unsafe?
                        (nul->replacement (substring content (inline-start x) (inline-end x)))
                        "<!-- raw HTML omitted -->")
                    out)]
    [else (void)]))

(define (render-children xs content unsafe? out)
  (for ([x (in-list xs)]) (render-inline x content unsafe? out)))

(define (write-title title out)
  (when (and title (> (string-length title) 0))
    (write-string " title=\"" out) (write-escaped title out) (write-string "\"" out)))

;; An image's alt text: the plain text of its description (cmark: breaks become spaces).
(define (plain-text xs content out)
  (for ([x (in-list xs)])
    (cond
      [(text? x) (write-string (text-value x) out)]
      [(code-span? x) (write-string (code-span-value x) out)]
      [(or (soft-break? x) (hard-break? x)) (write-string " " out)]
      [(raw-html? x) (write-string (substring content (inline-start x) (inline-end x)) out)]
      [(emph? x) (plain-text (emph-children x) content out)]
      [(strong? x) (plain-text (strong-children x) content out)]
      [(link? x) (plain-text (link-children x) content out)]
      [(image? x) (plain-text (image-children x) content out)]
      [else (void)])))

(define (leaf-html cell unsafe?)
  (render-inlines (inline-cell-content cell) (cell-relative-inlines cell) unsafe?))

;; --- Blocks -------------------------------------------------------------------------------------
;; Written to one output port, never by nested string-append: a 50,000-deep block quote would
;; otherwise copy its inner HTML once per level (quadratic; tests/pathological-test.rkt).

;; `unsafe?` #f replaces raw HTML (blocks and inline) with cmark's placeholder comment.
(define (document->html doc #:unsafe? [unsafe? #t] #:resolve-wiki [resolve-wiki (lambda (t h) t)])
  (define source (document-text doc))
  (define out (open-output-string))
  (for ([b (in-list (document-children doc))]) (render-block source b #f unsafe? out))
  (get-output-string out))

;; `bare-paragraph?` is #t only for a paragraph that is the direct child of a tight list item.
;; Returns 'newline when the output ended with a line ending, 'inline when it did not (a bare
;; paragraph), 'none when nothing was written; list items need this to place separators.
(define (render-block source b bare-paragraph? unsafe? out)
  (define (emit . strs) (for ([x (in-list strs)]) (write-string x out)) 'newline)
  (cond
    [(paragraph? b)
     (define content (leaf-html (paragraph-inlines b) unsafe?))
     (cond [bare-paragraph? (write-string content out) (if (equal? content "") 'none 'inline)]
           [else (emit "<p>" content "</p>\n")])]
    [(heading? b)
     (define lvl (number->string (heading-level b)))
     (emit "<h" lvl ">" (leaf-html (heading-inlines b) unsafe?) "</h" lvl ">\n")]
    [(thematic-break? b) (emit "<hr />\n")]
    [(code-block? b)
     (define content (escape-html (nul->replacement (lines->content source (code-block-lines b)))))
     (define lang (code-block-info b))
     ;; cmark decodes escapes and entities in the info string, then takes its first word.
     (define first-word (and lang (let ([t (unescape-string (string-trim lang))])
                                     (and (> (string-length t) 0)
                                          (car (string-split t))))))
     (if first-word
         (emit "<pre><code class=\"language-" (escape-html first-word) "\">" content "</code></pre>\n")
         (emit "<pre><code>" content "</code></pre>\n"))]
    [(html-block? b)
     (if unsafe?
         (let ([content (nul->replacement (lines->content source (html-block-lines b)))])
           (write-string content out)
           (cond [(equal? content "") 'none]
                 [(eqv? (string-ref content (sub1 (string-length content))) #\newline) 'newline]
                 [else 'inline]))
         (emit "<!-- raw HTML omitted -->\n"))]
    [(block-quote? b)
     (write-string "<blockquote>\n" out)
     (for ([c (in-list (block-quote-children b))]) (render-block source c #f unsafe? out))
     (emit "</blockquote>\n")]
    [(list-block? b)
     (define tag (if (list-block-ordered? b) "ol" "ul"))
     (if (and (list-block-ordered? b) (not (equal? (list-block-start-number b) 1)))
         (emit "<" tag " start=\"" (number->string (list-block-start-number b)) "\">\n")
         (emit "<" tag ">\n"))
     (for ([i (in-list (list-block-children b))])
       (render-list-item source i (list-block-tight? b) unsafe? out))
     (emit "</" tag ">\n")]
    [else 'none]))

;; A list item's children, always exactly one "\n" apart, with one exception (cmark's own
;; rendering, verified against spec examples 300/321/325 among others): a tight list's first
;; child, if it's a paragraph, is glued directly onto "<li>" with no newline at all -- which is
;; what collapses a single-paragraph item onto one line ("<li>foo</li>") while a heading- or
;; code-first item still gets "<li>\n...".
(define (render-list-item source item tight? unsafe? out)
  (write-string "<li>" out)
  (for/fold ([ends-with-newline? #f]) ([k (in-list (list-item-children item))] [idx (in-naturals)])
    (define bare? (and tight? (paragraph? k)))
    (unless (or (and (= idx 0) bare?) ends-with-newline?) (write-string "\n" out))
    (case (render-block source k bare? unsafe? out)
      [(newline) #t]
      [(inline) #f]
      [else (or ends-with-newline? (not (and (= idx 0) bare?)))]))
  (write-string "</li>\n" out))
