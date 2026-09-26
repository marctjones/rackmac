#lang racket/base
;; The HTML renderer (design §4.2): cmark's exact formatting, so the spec runner compares strings
;; exactly -- block tags each on their own line, `<br />`, entity-escaped text, destinations
;; escaped as cmark's houdini_escape_href does. Leaf inline content is rendered from the
;; content-relative inline tree and the leaf's content string (a raw-HTML node is a slice of the
;; content, never of the document text, which would include container prefixes). mdlib-html
;; (#319) completes the renderer; this is the half the spec sections of mdlib-inlines need.
(require racket/string racket/list "ast.rkt" "entities.rkt" "inlines.rkt")
(provide document->html escape-href)

(define (write-escaped s out)
  (for ([c (in-string s)])
    (case c
      [(#\&) (write-string "&amp;" out)]
      [(#\<) (write-string "&lt;" out)]
      [(#\>) (write-string "&gt;" out)]
      [(#\") (write-string "&quot;" out)]
      [else (write-char c out)])))

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
     (write-string (if unsafe? (substring content (inline-start x) (inline-end x)) "<!-- raw HTML omitted -->") out)]
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

;; `unsafe?` #f replaces raw HTML (blocks and inline) with cmark's placeholder comment.
(define (document->html doc #:unsafe? [unsafe? #t] #:resolve-wiki [resolve-wiki (lambda (t h) t)])
  (define source (document-text doc))
  (apply string-append (map (lambda (b) (render-block source b #f unsafe?)) (document-children doc))))

;; `bare-paragraph?` is #t only for a paragraph that is the direct child of a tight list item.
(define (render-block source b bare-paragraph? unsafe?)
  (cond
    [(paragraph? b)
     (define content (leaf-html (paragraph-inlines b) unsafe?))
     (if bare-paragraph? content (string-append "<p>" content "</p>\n"))]
    [(heading? b)
     (define lvl (heading-level b))
     (define content (leaf-html (heading-inlines b) unsafe?))
     (format "<h~a>~a</h~a>\n" lvl content lvl)]
    [(thematic-break? b) "<hr />\n"]
    [(code-block? b)
     (define content (escape-html (lines->content source (code-block-lines b))))
     (define lang (code-block-info b))
     ;; cmark decodes escapes and entities in the info string, then takes its first word.
     (define first-word (and lang (let ([t (unescape-string (string-trim lang))])
                                     (and (> (string-length t) 0)
                                          (car (string-split t))))))
     (if first-word
         (format "<pre><code class=\"language-~a\">~a</code></pre>\n" (escape-html first-word) content)
         (format "<pre><code>~a</code></pre>\n" content))]
    [(html-block? b) (if unsafe? (lines->content source (html-block-lines b)) "<!-- raw HTML omitted -->\n")]
    [(block-quote? b)
     (string-append "<blockquote>\n"
                    (apply string-append (map (lambda (c) (render-block source c #f unsafe?)) (block-quote-children b)))
                    "</blockquote>\n")]
    [(list-block? b)
     (define tag (if (list-block-ordered? b) "ol" "ul"))
     (define open-tag
       (if (and (list-block-ordered? b) (not (equal? (list-block-start-number b) 1)))
           (format "<~a start=\"~a\">\n" tag (list-block-start-number b))
           (format "<~a>\n" tag)))
     (string-append open-tag
                    (apply string-append (map (lambda (i) (render-list-item source i (list-block-tight? b) unsafe?))
                                               (list-block-children b)))
                    (format "</~a>\n" tag))]
    [else ""]))

;; Concatenates a list-item's children, always exactly one "\n" apart, with one exception (cmark's
;; own rendering, verified against spec examples 300/321/325 among others): a tight list's first
;; child, if it's a paragraph, is glued directly onto "<li>" with no newline at all -- not even
;; the usual one-newline separator -- which is what collapses a single-paragraph item onto one
;; line ("<li>foo</li>") while a heading- or code-first item still gets "<li>\n...".
(define (render-list-item source item tight? unsafe?)
  (define kids (list-item-children item))
  (let loop ([kids kids] [idx 0] [acc "<li>"])
    (cond
      [(null? kids) (string-append acc "</li>\n")]
      [else
       (define k (car kids))
       (define bare? (and tight? (paragraph? k)))
       (define rendering (render-block source k bare? unsafe?))
       (define first-bare-exception? (and (= idx 0) bare?))
       (define need-sep?
         (and (not first-bare-exception?)
              (> (string-length acc) 0)
              (not (eqv? (string-ref acc (sub1 (string-length acc))) #\newline))))
       (loop (cdr kids) (add1 idx) (string-append acc (if need-sep? "\n" "") rendering))])))
