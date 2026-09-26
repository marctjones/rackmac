#lang racket/base
;; mdlib-ext (#320, design §2.3): our syntax -- wiki links, tags, dates, heading keywords, front
;; matter -- and GFM's tables, task items, strikethrough and autolink literals, checked node by
;; node with positions and tokens, plus the style-run roles the editor gets for them, the HTML
;; they render to, the keyword parameters (and the parser's snapshot of them), and
;; `no-extensions` leaving all of it plain CommonMark.
(require racket/list rackunit "../main.rkt" "ext-corpus.rkt")

(define (parse s [exts all-extensions]) (parse-document s #:extensions exts))

(define (kids x)
  (cond [(emph? x) (emph-children x)] [(strong? x) (strong-children x)] [(strike? x) (strike-children x)]
        [(link? x) (link-children x)] [(image? x) (image-children x)] [else '()]))
(define (toks x) (for/list ([t (in-list (if (block? x) (block-tokens x) (inline-tokens x)))])
                   (list (token-role t) (token-start t) (token-end t))))
;; An inline node as (kind start end fields... tokens... children...)
(define (summ x)
  (append
   (cond
     [(text? x) (list 'text (inline-start x) (inline-end x) (text-value x))]
     [(wiki-link? x) (list 'wiki (inline-start x) (inline-end x) (wiki-link-target x) (wiki-link-heading x) (wiki-link-alias x))]
     [(tag? x) (list 'tag (inline-start x) (inline-end x) (tag-name x))]
     [(date-ref? x) (list 'date (inline-start x) (inline-end x) (date-ref-date x) (date-ref-keyword x))]
     [(state-keyword? x) (list 'keyword (inline-start x) (inline-end x) (state-keyword-keyword x))]
     [(link? x) (list 'link (inline-start x) (inline-end x) (link-kind x) (link-dest x))]
     [(strike? x) (list 'strike (inline-start x) (inline-end x))]
     [(emph? x) (list 'emph (inline-start x) (inline-end x))]
     [(strong? x) (list 'strong (inline-start x) (inline-end x))]
     [(code-span? x) (list 'code (inline-start x) (inline-end x))]
     [else (list 'other (inline-start x) (inline-end x))])
   (toks x)
   (map summ (kids x))))

(define (first-leaf doc)
  (let loop ([bs (document-children doc)])
    (for/or ([b (in-list bs)])
      (cond [(leaf-block? b) b]
            [(block-quote? b) (loop (block-quote-children b))]
            [(list-block? b) (loop (list-block-children b))]
            [(list-item? b) (loop (list-item-children b))]
            [(table? b) (loop (table-head b))]
            [else #f]))))
(define (inl s) (map summ (block-inlines (first-leaf (parse s)))))

(define (roles-at doc p)
  (for/first ([r (in-list (style-runs doc))] #:when (and (<= (run-start r) p) (< p (run-end r)))) (run-roles r)))

(test-case "wiki links"
  (check-equal? (inl "[[Title]]") '((wiki 0 9 "Title" #f #f (wiki-open 0 2) (wiki-close 7 9))))
  (check-equal? (inl "[[Title|text]]") '((wiki 0 14 "Title" #f "text" (wiki-open 0 2) (wiki-pipe 7 8) (wiki-close 12 14))))
  (check-equal? (inl "a [[T#H|al]] b")
                '((text 0 2 "a ") (wiki 2 12 "T" "H" "al" (wiki-open 2 4) (wiki-pipe 7 8) (wiki-close 10 12)) (text 12 14 " b")))
  (check-equal? (inl "[[]]") '((text 0 4 "[[]]")))
  (check-equal? (inl "[[a]b]]") '((text 0 7 "[[a]b]]")))
  (check-equal? (inl "[[a\nb]]") '((text 0 3 "[[a") (other 3 4) (text 4 7 "b]]")))
  (check-equal? (inl "*[[a]]*") '((emph 0 7 (emph-delim 0 1) (emph-delim 6 7) (wiki 1 6 "a" #f #f (wiki-open 1 3) (wiki-close 4 6)))))
  (check-equal? (inl "> x [[Q]]") '((text 2 4 "x ") (wiki 4 9 "Q" #f #f (wiki-open 4 6) (wiki-close 7 9))))
  ;; off: CommonMark reads [[x]] as brackets around a shortcut reference
  (check-equal? (inl "[[Title]]" ) '((wiki 0 9 "Title" #f #f (wiki-open 0 2) (wiki-close 7 9))))
  (check-equal? (map summ (block-inlines (first-leaf (parse "[[Title]]" no-extensions)))) '((text 0 9 "[[Title]]"))))

(test-case "tags"
  (check-equal? (inl "#tag") '((tag 0 4 "tag" (tag-hash 0 1))))
  (check-equal? (inl "a #client/acme-1 b")
                '((text 0 2 "a ") (tag 2 16 "client/acme-1" (tag-hash 2 3)) (text 16 18 " b")))
  (check-equal? (inl "a#no (#yes)") '((text 0 6 "a#no (") (tag 6 10 "yes" (tag-hash 6 7)) (text 10 11 ")")))
  (check-equal? (inl "#1 x") '((text 0 4 "#1 x")))
  (check-equal? (inl "`#code` #t") '((code 0 7 (code-delim 0 1) (code-delim 6 7)) (text 7 8 " ") (tag 8 10 "t" (tag-hash 8 9))))
  (check-equal? (inl "see http://e.com/#frag")
                '((text 0 4 "see ") (link 4 22 literal "http://e.com/#frag" (text 4 22 "http://e.com/#frag"))))
  (check-equal? (inl "[a #b](/u)") '((link 0 10 inline "/u" (link-open 0 1) (link-close 5 6) (link-dest-open 6 7) (link-dest 7 9) (link-dest-close 9 10) (text 1 5 "a #b"))))
  (check-equal? (inl "&#35;x \\#y") '((text 0 10 "#x #y" (entity 0 5) (escape 7 8))))
  (check-equal? (inl "# Heading #t") '((text 2 10 "Heading ") (tag 10 12 "t" (tag-hash 10 11)))))

(test-case "dates"
  (check-equal? (inl "2026-09-30") '((date 0 10 "2026-09-30" #f)))
  (check-equal? (inl "due 2026-09-30") '((date 0 14 "2026-09-30" "due")))
  (check-equal? (inl "x Due 2026-09-30.") '((text 0 2 "x ") (date 2 16 "2026-09-30" "due") (text 16 17 ".")))
  (check-equal? (inl "overdue 2026-09-30") '((text 0 8 "overdue ") (date 8 18 "2026-09-30" #f)))
  (check-equal? (inl "(Smith, 2019-04-06)") '((text 0 8 "(Smith, ") (date 8 18 "2019-04-06" #f) (text 18 19 ")")))
  (check-equal? (inl "x2026-09-30 2026-13-01 2026-09-3 2026-09-30x") '((text 0 44 "x2026-09-30 2026-13-01 2026-09-3 2026-09-30x")))
  (check-equal? (inl "- [ ] brief due 2026-10-15")
                '((text 6 12 "brief ") (date 12 26 "2026-10-15" "due"))))

(test-case "heading keywords"
  (define d (parse "# TODO Call #urgent\n\n## WAITING x\n\n### DONE\n\n# TODOx y\n\n# todo z\n\nTODO para"))
  (define hs (filter heading? (document-children d)))
  (check-equal? (map heading-keyword hs) '("TODO" "WAITING" #f #f #f))
  (check-equal? (map summ (block-inlines (car hs)))
                '((keyword 2 6 "TODO") (text 6 12 " Call ") (tag 12 19 "urgent" (tag-hash 12 13))))
  (check-equal? (map summ (block-inlines (cadr hs))) '((keyword 24 31 "WAITING") (text 31 33 " x")))
  (check-equal? (inl "TODO para") '((text 0 9 "TODO para")))
  (check-equal? (heading-keyword (car (document-children (parse "DONE it\n===")))) "DONE")
  ;; the lists are parameters; parse-document reads them, make-parser snapshots them
  (parameterize ([heading-keywords '("NEXT")] [date-keywords '("by")])
    (define d2 (parse "# NEXT a\n\nby 2026-01-02"))
    (check-equal? (heading-keyword (car (document-children d2))) "NEXT")
    (check-equal? (map summ (block-inlines (cadr (document-children d2)))) '((date 10 23 "2026-01-02" "by"))))
  (define p (make-parser #:extensions all-extensions))
  (parameterize ([heading-keywords '("NEXT")])
    (define d3 (parser-parse! p "# TODO a\n\n# NEXT b"))
    (check-equal? (map heading-keyword (document-children d3)) '("TODO" #f) "the parser keeps its snapshot")))

(test-case "front matter"
  (define d (parse ext-note))
  (define fm (car (document-children d)))
  (check-true (front-matter? fm))
  (check-equal? (list (block-start fm) (block-end fm)) '(0 76))
  (check-equal? (toks fm) '((front-matter-fence 0 3) (front-matter-fence 73 76)))
  (check-equal? (front-matter-fields fm) '(("title" . "Matter review") ("tags" "client" "draft") ("attendees" "Ana" "Bo")))
  (check-equal? (front-matter-fields (car (document-children (parse "---\na: \"q\"\nb: []\nc:\n# comment\n...\nx"))))
                '(("a" . "q") ("b") ("c" . "")))
  (check-false (front-matter-fields (car (document-children (parse "---\nnot yaml {\n---\n")))))
  (check-false (front-matter? (car (document-children (parse "---\nunterminated\n")))))
  (check-false (front-matter? (car (document-children (parse "text\n---\na: 1\n---\n")))))
  (check-true (thematic-break? (car (document-children (parse "---\na: 1\n---\n" no-extensions)))))
  (check-equal? (roles-at d 1) '(front-matter markup))
  (check-equal? (roles-at d 10) '(front-matter))
  (check-equal? (document->html (parse "---\na: 1\n---\nbody")) "<p>body</p>\n"))

(test-case "tables"
  (define d (parse "| Party | Due |\n| :--- | ---: |\n| Ana | 2026-09-30 |\n| Bo \\| Co |\n"))
  (define t (car (document-children d)))
  (check-true (table? t))
  (check-equal? (table-alignments t) '(left right))
  (check-equal? (toks t) '((table-pipe 0 1) (table-pipe 8 9) (table-pipe 14 15) (table-delim-row 16 31)
                           (table-pipe 32 33) (table-pipe 38 39) (table-pipe 51 52)
                           (table-pipe 53 54) (table-pipe 64 65)))
  (check-equal? (for/list ([c (in-list (table-head t))]) (list (block-start c) (block-end c))) '((2 7) (10 13)))
  (define rows (table-rows t))
  (check-equal? (map summ (block-inlines (cadr (car rows)))) '((date 40 50 "2026-09-30" #f)))
  (define bo (car (cadr rows)))
  (check-equal? (toks bo) '((escape 58 59)))
  (check-equal? (map summ (block-inlines bo)) '((text 55 63 "Bo | Co")))
  (check-equal? (list (block-start (cadr (cadr rows))) (block-end (cadr (cadr rows)))) '(65 65) "a padding cell")
  (check-equal? (roles-at d 0) '(markup))
  (check-equal? (roles-at d 58) '(markup))
  (check-equal? (roles-at d 40) '(date))
  ;; the paragraph before keeps its earlier lines; lists and quotes hold tables
  (define d2 (parse "para\n| a |\n| - |\n| 1 |"))
  (check-equal? (map (lambda (b) (list (vector-ref (struct->vector b) 0) (block-start b) (block-end b))) (document-children d2))
                '((struct:paragraph 0 4) (struct:table 5 22)))
  (check-true (table? (car (list-item-children (car (list-block-children (car (document-children (parse "- | a |\n  | - |\n  | 1 |")))))))))
  (check-true (table? (car (block-quote-children (car (document-children (parse "> | a |\n> | - |")))))))
  (check-true (paragraph? (car (document-children (parse "| a | b |\n| - |\n"))))))

(test-case "task items"
  (define (item s) (car (list-block-children (car (document-children (parse s))))))
  (check-equal? (list-item-task (item "- [ ] a")) 'open)
  (check-equal? (list-item-task (item "- [x] a")) 'done)
  (check-equal? (list-item-task (item "- [X] a")) 'done)
  (check-equal? (list-item-task (item "- [-] a")) 'cancelled)
  (check-equal? (list-item-task (item "1. [x] a")) 'done)
  (check-false (list-item-task (item "- [ ]")))
  (check-false (list-item-task (item "- [ ]a")))
  (check-false (list-item-task (item "- [y] a")))
  (check-false (list-item-task (car (list-block-children (car (document-children (parse "- [ ] a" no-extensions)))))) "...unless extensions are off")
  (void))

(test-case "task items (detail)"
  (define it (car (list-block-children (car (document-children (parse "- [x] done *it*"))))))
  (check-equal? (toks it) '((bullet 0 1) (task-marker 2 5)))
  (define p (car (list-item-children it)))
  (check-equal? (list (block-start p) (block-end p)) '(6 15))
  (check-equal? (map summ (block-inlines p)) '((text 6 11 "done ") (emph 11 15 (emph-delim 11 12) (emph-delim 14 15) (text 12 14 "it"))))
  (define d (parse "- [x] a\n- [-] b\n- [ ] c"))
  (check-equal? (roles-at d 6) '(task-done))
  (check-equal? (roles-at d 3) '(markup))
  (check-equal? (roles-at d 14) '(task-cancelled))
  (check-equal? (roles-at d 22) '())
  (check-false (list-item-task (car (list-block-children (car (document-children (parse "- [x] a" no-extensions))))))))

(test-case "strikethrough"
  (check-equal? (inl "~~a~~ ~b~ ~~~c~~~ ~~d~")
                '((strike 0 5 (strike-delim 0 2) (strike-delim 3 5) (text 2 3 "a")) (text 5 6 " ")
                  (strike 6 9 (strike-delim 6 7) (strike-delim 8 9) (text 7 8 "b")) (text 9 22 " ~~~c~~~ ~~d~")))
  (check-equal? (inl "*~~a~~*") '((emph 0 7 (emph-delim 0 1) (emph-delim 6 7) (strike 1 6 (strike-delim 1 3) (strike-delim 4 6) (text 3 4 "a")))))
  (check-equal? (roles-at (parse "x ~~a~~") 4) '(strike))
  (check-equal? (roles-at (parse "x ~~a~~") 2) '(strike markup))
  (check-equal? (inl "\\~~a~~") '((text 0 6 "~~a~~" (escape 0 1)))))

(test-case "autolink literals"
  (check-equal? (inl "go www.a.b/c. now") '((text 0 3 "go ") (link 3 12 literal "http://www.a.b/c" (text 3 12 "www.a.b/c")) (text 12 17 ". now")))
  (check-equal? (inl "https://x.y/(a)b)") '((link 0 16 literal "https://x.y/(a)b" (text 0 16 "https://x.y/(a)b")) (text 16 17 ")")))
  (check-equal? (inl "mail a.b-c@d.e.") '((text 0 5 "mail ") (link 5 14 literal "mailto:a.b-c@d.e" (text 5 14 "a.b-c@d.e")) (text 14 15 ".")))
  (check-equal? (inl "www.a_b.c_d http://localhost x@y") '((text 0 32 "www.a_b.c_d http://localhost x@y")))
  (check-equal? (inl "[www.a.b](/u)") '((link 0 13 inline "/u" (link-open 0 1) (link-close 8 9) (link-dest-open 9 10) (link-dest 10 12) (link-dest-close 12 13) (text 1 8 "www.a.b"))))
  (check-equal? (inl "`www.a.b`") '((code 0 9 (code-delim 0 1) (code-delim 8 9))))
  (check-equal? (roles-at (parse "x www.a.b") 4) '(link)))

(test-case "the corpus renders, and every extension node gets its role"
  (define d (parse ext-note))
  (check-not-exn (lambda () (document->html d)))
  (define roles (remove-duplicates (append-map run-roles (style-runs d))))
  (for ([r (in-list '(front-matter heading-1 heading-2 keyword tag date wiki-link link strike task-done task-cancelled markup code))])
    (check-not-false (memq r roles) (format "role ~a appears" r)))
  (check-equal? (document->html (parse "# TODO a #t\n\n[[T#H|x]] [[U]] due 2026-09-30 ~~s~~")
                                #:resolve-wiki (lambda (t h) (string-append "note:" t (if h (string-append "#" h) ""))))
                (string-append "<h1><span class=\"keyword\">TODO</span> a <span class=\"tag\">#t</span></h1>\n"
                               "<p><a class=\"wiki\" href=\"note:T#H\">x</a> <a class=\"wiki\" href=\"note:U\">U</a> "
                               "<time datetime=\"2026-09-30\">due 2026-09-30</time> <del>s</del></p>\n"))
  (check-equal? (document->html (parse "- [-] c")) "<ul>\n<li><input class=\"cancelled\" disabled=\"\" type=\"checkbox\"> c</li>\n</ul>\n"))

(test-case "no-extensions: the corpus is plain CommonMark"
  (for ([s (in-list ext-corpus)])
    (define d (parse s no-extensions))
    (define roles (remove-duplicates (append-map run-roles (style-runs d))))
    (for ([r (in-list '(front-matter keyword tag date wiki-link strike task-done task-cancelled))])
      (check-false (memq r roles) (format "~s: no ~a" s r)))
    (check-equal? (document->html d) (document->html (parse-document s)))))
