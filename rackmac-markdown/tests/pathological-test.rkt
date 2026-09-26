#lang racket/base
;; Pathological inputs (design §5): the cases of cmark's test/pathological_tests.py, at cmark's
;; repetition counts (10^4-10^5), must each parse, relocate every inline and render in under
;; 1 s of CPU -- linear-looking time; the quadratic versions of these algorithms take seconds to
;; minutes (before the fixes that came with this test: nested block quotes 39 s, many
;; references 159 s).
;; Inline cases are mdlib-inlines' (#318) acceptance; the block cases ride along so the phase-1
;; parser is watched too. Each case also checks the output shape where it is cheap to state.
(require racket/string racket/list rackunit "../main.rkt")

(define (rep s n) (string-append* (for/list ([i (in-range n)]) s)))

;; (name markdown expected-html-regexp-or-#f)
(define inline-cases
  (list
   (list "nested strong emph"
         (string-append (rep "*a **a " 65000) "b" (rep " a** a*" 65000))
         (pregexp (string-append "^<p>" (rep "<em>a <strong>a " 10))))
   (list "many emph closers with no openers" (rep "a_ " 65000) #px"^<p>(a_ ){20}")
   (list "many emph openers with no closers" (rep "_a " 65000) #px"^<p>(_a ){20}")
   (list "many link closers with no openers" (rep "a]" 65000) #px"^<p>(a\\]){20}")
   (list "many link openers with no closers" (rep "[a" 65000) #px"^<p>(\\[a){20}")
   (list "mismatched openers and closers" (rep "*a_ " 50000) #px"^<p>([*]a_ ){20}")
   (list "openers and closers multiple of 3" (string-append "a**b" (rep "c* " 50000)) #px"^<p>a[*][*]b(c[*] ){20}")
   (list "link openers and emph closers" (rep "[ a_" 50000) #px"^<p>(\\[ a_){20}")
   (list "pattern [ (]( repeated" (rep "[ (](" 80000) #px"^<p>(\\[ \\(\\]\\(){20}")
   (list "pattern ![[]() repeated" (rep "![[]()" 160000) #px"^<p>(!\\[<a href=\"\"></a>){20}")
   (list "hard link/emph case" "**x [a*b**c*](d)"
         #px"^<p>[*][*]x <a href=\"d\">a<em>b[*][*]c</em></a></p>\n$")
   (list "nested brackets" (string-append (rep "[" 50000) "a" (rep "]" 50000)) #px"^<p>\\[{50000}a\\]{50000}</p>\n$")
   (list "backticks" (string-append* (for/list ([i (in-range 1 5000)]) (string-append "e" (make-string i #\`))))
         #px"^<p>e`e``e```")
   (list "unclosed links A" (rep "[a](<b" 30000) #px"^<p>(\\[a\\]\\(&lt;b){20}")
   (list "unclosed links B" (rep "[a](b" 30000) #px"^<p>(\\[a\\]\\(b){20}")
   (list "unclosed <!--" (string-append "</" (rep "<!--" 30000)) #px"^<p>&lt;/(&lt;!--){20}")
;; (a leading "x " keeps these inline: at a line start they would open HTML blocks 3-5)
   (list "unclosed <?" (string-append "x " (rep "<?" 30000)) #px"^<p>x (&lt;[?]){20}")
   (list "unclosed <![CDATA[" (string-append "x " (rep "<![CDATA[" 30000)) #px"^<p>x (&lt;!\\[CDATA\\[){20}")
   (list "unclosed <!A" (string-append "x " (rep "<!A " 30000)) #px"^<p>x (&lt;!A ){20}")
   (list "many entities and escapes" (rep "&amp;\\*&#35;&#x41;" 30000) #px"^<p>(&amp;[*]#A){20}")
   (list "U+0000 in input" (string-append "abc\u0000de\u0000" (rep "x" 100)) #px"^<p>abc�de�")))

(define block-cases
  (list
   (list "nested block quotes" (string-append (rep ">" 50000) "a") #px"^(<blockquote>\n){20}")
   (list "deeply nested lists" (string-append* (for/list ([i (in-range 1000)]) (string-append (make-string (* 2 i) #\space) "* a\n")))
         #px"^<ul>\n<li>a\n<ul>")
   (list "many references"
         (string-append (string-append* (for/list ([i (in-range 50000)]) (format "[~a]: u\n" i))) (rep "[0] " 1000))
         #px"^<p>(<a href=\"u\">0</a> ){20}")))

(define (time-case! name md expected)
  (define-values (html ms)
    ;; Process CPU time (GC included), not wall time: other sessions share this Mac and CI
    ;; runners are noisy, and the property under test is the algorithm's cost.
    (let ([t0 (current-process-milliseconds)])
      (define doc (parse-document md))
      ;; Force the absolute (relocated) trees as well: consumers pay for those, not just HTML.
      (let walk ([bs (document-blocks doc)])
        (for ([b (in-list bs)])
          (cond [(leaf-block? b) (block-inlines b)]
                [(block-quote? b) (walk (block-quote-children b))]
                [(list-block? b) (walk (list-block-children b))]
                [(list-item? b) (walk (list-item-children b))])))
      (define html (document->html doc #:unsafe? #t))
      (values html (- (current-process-milliseconds) t0))))
  (printf "  ~a: ~a ms (~a chars)\n" name (round ms) (string-length md))
  (test-case (format "pathological: ~a under 1 s" name)
    (check-true (< ms budget-ms) (format "~a took ~a ms (budget ~a ms)" name (round ms) budget-ms))
    (when expected
      (check-true (regexp-match? expected html)
                  (format "~a: unexpected output ~s..." name (substring html 0 (min 200 (string-length html))))))))

;; The design's budget is 1 s. Shared CI runners (GitHub sets CI=true) measure about 4x slower
;; than a developer Mac for the same work, so they get 5x; a real quadratic blow-up is still
;; caught there, since those take tens of seconds (nested quotes were 39 s before #318's fix).
(define budget-ms (if (getenv "CI") 5000 1000))

(printf "\n== pathological inputs (cmark's pathological_tests.py) ==\ninline:\n")
(for ([c (in-list inline-cases)]) (apply time-case! c))
(printf "block:\n")
(for ([c (in-list block-cases)]) (apply time-case! c))
