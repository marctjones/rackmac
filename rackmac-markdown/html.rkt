#lang racket/base
;; The block-level half of the HTML renderer (design §4.2, §6.3 mdlib-blocks row): cmark's exact
;; block formatting (each block tag on its own line, entity-escaped text). Since mdlib-inlines has
;; not landed, every leaf's inline content is emitted as HTML-escaped literal text -- no emphasis,
;; links, code spans, or entity/backslash decoding yet.
(require racket/string racket/list "ast.rkt")
(provide document->html)

;; cmark escapes &, <, >, and " everywhere it emits text (not just inside attributes).
(define (escape-html s)
  (regexp-replace* #rx"[&<>\"]" s
                    (lambda (m) (case (string-ref m 0)
                                  [(#\&) "&amp;"] [(#\<) "&lt;"] [(#\>) "&gt;"] [(#\") "&quot;"]))))

;; Percent-encodes a link destination the way cmark does; unused until mdlib-inlines, kept here
;; since html.rkt owns the escaping rules (design §4.2).
(define unreserved-chars (string->list "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~!*'();:@&=+$,/?#[]%"))
(define (percent-encode-dest s)
  (apply string-append
         (for/list ([ch (in-string s)])
           (if (memv ch unreserved-chars)
               (string ch)
               (apply string-append (map (lambda (b) (format "%~a" (string-upcase (number->string b 16))))
                                          (bytes->list (string->bytes/utf-8 (string ch)))))))))

(define (line-text source l) (string-append (make-string (third l) #\space)
                                             (substring source (first l) (second l))))

(define (lines->content source lines)
  (if (null? lines) "" (string-append (string-join (map (lambda (l) (line-text source l)) lines) "\n") "\n")))

;; Rebuilds a leaf's content string exactly as build-segments+content did, from its segments.
;; Re-inserts the "\n" that separated consecutive source lines when the segments were built
;; (build-segments+content joins line-texts with "\n"; consecutive segments whose content ranges
;; are not adjacent are separated by exactly one such newline).
(define (leaf-content/joined source segs)
  (let loop ([segs segs] [prev-end 0] [first? #t] [parts '()])
    (cond
      [(null? segs) (apply string-append (reverse parts))]
      [else
       (define s (car segs))
       (define gap? (and (not first?) (> (segment-content-start s) prev-end)))
       (define text (if (= (segment-source-length s) 0)
                         (make-string (segment-content-length s) #\space)
                         (substring source (segment-source-start s) (+ (segment-source-start s) (segment-source-length s)))))
       (loop (cdr segs) (+ (segment-content-start s) (segment-content-length s)) #f
             (cons text (if gap? (cons "\n" parts) parts)))])))

(define (document->html doc #:unsafe? [unsafe? #t] #:resolve-wiki [resolve-wiki (lambda (t h) t)])
  (define source (document-text doc))
  (apply string-append (map (lambda (b) (render-block source b #f)) (document-children doc))))

;; `bare-paragraph?` is #t only for a paragraph that is the direct child of a tight list item.
(define (render-block source b bare-paragraph?)
  (cond
    [(paragraph? b)
     (define content (escape-html (leaf-content/joined source (paragraph-segments b))))
     (if bare-paragraph? content (string-append "<p>" content "</p>\n"))]
    [(heading? b)
     (define lvl (heading-level b))
     (define content (escape-html (leaf-content/joined source (heading-segments b))))
     (format "<h~a>~a</h~a>\n" lvl content lvl)]
    [(thematic-break? b) "<hr />\n"]
    [(code-block? b)
     (define content (escape-html (lines->content source (code-block-lines b))))
     (define lang (code-block-info b))
     (define first-word (and lang (let ([t (string-trim lang)])
                                     (and (> (string-length t) 0)
                                          (car (string-split t))))))
     (if first-word
         (format "<pre><code class=\"language-~a\">~a</code></pre>\n" (escape-html first-word) content)
         (format "<pre><code>~a</code></pre>\n" content))]
    [(html-block? b) (lines->content source (html-block-lines b))]
    [(block-quote? b)
     (string-append "<blockquote>\n"
                    (apply string-append (map (lambda (c) (render-block source c #f)) (block-quote-children b)))
                    "</blockquote>\n")]
    [(list-block? b)
     (define tag (if (list-block-ordered? b) "ol" "ul"))
     (define open-tag
       (if (and (list-block-ordered? b) (not (equal? (list-block-start-number b) 1)))
           (format "<~a start=\"~a\">\n" tag (list-block-start-number b))
           (format "<~a>\n" tag)))
     (string-append open-tag
                    (apply string-append (map (lambda (i) (render-list-item source i (list-block-tight? b)))
                                               (list-block-children b)))
                    (format "</~a>\n" tag))]
    [else ""]))

;; Concatenates a list-item's children, always exactly one "\n" apart, with one exception (cmark's
;; own rendering, verified against spec examples 300/321/325 among others): a tight list's first
;; child, if it's a paragraph, is glued directly onto "<li>" with no newline at all -- not even
;; the usual one-newline separator -- which is what collapses a single-paragraph item onto one
;; line ("<li>foo</li>") while a heading- or code-first item still gets "<li>\n...".
(define (render-list-item source item tight?)
  (define kids (list-item-children item))
  (let loop ([kids kids] [idx 0] [acc "<li>"])
    (cond
      [(null? kids) (string-append acc "</li>\n")]
      [else
       (define k (car kids))
       (define bare? (and tight? (paragraph? k)))
       (define rendering (render-block source k bare?))
       (define first-bare-exception? (and (= idx 0) bare?))
       (define need-sep?
         (and (not first-bare-exception?)
              (> (string-length acc) 0)
              (not (eqv? (string-ref acc (sub1 (string-length acc))) #\newline))))
       (loop (cdr kids) (add1 idx) (string-append acc (if need-sep? "\n" "") rendering))])))
