#lang racket/base
;; The HTML renderer's `#:unsafe?` posture (design §4.2, #319): defaults to #f, so a note with
;; embedded raw HTML never leaks it into rendered output unless a caller opts in. Previously
;; untested (design #319's notes: "the #f path ... has no test yet").
(require rackunit "../main.rkt")

(define (html md #:unsafe? [u #f]) (document->html (parse-document md) #:unsafe? u))

(test-case "default is unsafe? = #f"
  ;; No #:unsafe? argument at all: raw HTML block and inline raw HTML are both omitted.
  (check-equal? (document->html (parse-document "<div>x</div>\n"))
                "<!-- raw HTML omitted -->\n")
  (check-equal? (document->html (parse-document "hi <span>there</span>\n"))
                "<p>hi <!-- raw HTML omitted -->there<!-- raw HTML omitted --></p>\n"))

(test-case "unsafe? #f: an HTML block becomes the placeholder comment plus a newline"
  (check-equal? (html "<div>\n  <p>x</p>\n</div>\n" #:unsafe? #f)
                "<!-- raw HTML omitted -->\n"))

(test-case "unsafe? #f: inline raw HTML becomes the placeholder comment, no newline added"
  (check-equal? (html "a <em class=\"x\">b</em> c\n" #:unsafe? #f)
                "<p>a <!-- raw HTML omitted -->b<!-- raw HTML omitted --> c</p>\n")
  (check-equal? (html "a <!-- a comment --> b\n" #:unsafe? #f)
                "<p>a <!-- raw HTML omitted --> b</p>\n"))

(test-case "unsafe? #t: raw HTML passes through unchanged"
  (check-equal? (html "<div>\n  <p>x</p>\n</div>\n" #:unsafe? #t)
                "<div>\n  <p>x</p>\n</div>\n")
  (check-equal? (html "a <em class=\"x\">b</em> c\n" #:unsafe? #t)
                "<p>a <em class=\"x\">b</em> c</p>\n"))

;; Trap (pin, don't "fix"): an image's alt text is always plain text (`plain-text` takes the raw
;; slice, but the whole alt string is then HTML-escaped as ordinary attribute text), so a raw-HTML
;; node inside an image description renders the same, entity-escaped, regardless of `unsafe?` --
;; never as the omitted-HTML placeholder, matching cmark.
(test-case "unsafe? #f: raw HTML inside an image's alt text is escaped text, not a placeholder"
  (check-equal? (html "![a <b>c</b> d](/u)" #:unsafe? #f)
                "<p><img src=\"/u\" alt=\"a &lt;b&gt;c&lt;/b&gt; d\" /></p>\n")
  (check-equal? (html "![a <b>c</b> d](/u)" #:unsafe? #t)
                "<p><img src=\"/u\" alt=\"a &lt;b&gt;c&lt;/b&gt; d\" /></p>\n"))

;; Percent-encoding of link destinations and entity-escaping of titles/text (design §4.2), while
;; we're in this file: a non-ASCII destination byte-encodes, and `&` in a title escapes.
(test-case "percent-encoding and entity escaping"
  (check-equal? (html "[a](/ü \"t&t\")")
                "<p><a href=\"/%C3%BC\" title=\"t&amp;t\">a</a></p>\n"))
