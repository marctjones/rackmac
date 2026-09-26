#lang racket/base
;; A corpus of the extension syntax (design §2.3, §7 risk 3, mdlib-ext #320): wiki links, tags,
;; dates, heading keywords, front matter, tables, task items, strikethrough and autolink
;; literals, alone and inside other constructs, with the corner cases the design names (a `#`
;; inside a URL, a date inside a citation). Shared by ext-test, positions-test, runs-test and
;; incremental-test, which parse it with `all-extensions`.
(provide ext-corpus ext-note)

(define ext-note
  (string-append
   "---\ntitle: Matter review\ntags: [client, draft]\nattendees:\n  - Ana\n  - Bo\n---\n"
   "# TODO Call the client #urgent\n\n"
   "## WAITING Reply from [[Opposing Counsel|counsel]] due 2026-09-30\n\n"
   "### DONE Filed the motion\n\n"
   "See [[Matter 12#Timeline]] and [[Notes]]; tags #client/acme #follow-up, date 2026-10-01.\n"
   "Per Smith (2019-04-06) at www.example.com/cases?id=7 or https://example.org/a_(b).\n"
   "Mail ana@example.com, not a@b. Also ~~struck~~ and ~single~ and ~~~three~~~.\n\n"
   "- [ ] draft the brief due 2026-10-15\n"
   "- [x] send the invoice #billing\n"
   "- [-] cancelled hearing\n"
   "  - [ ] nested *task* with [[Link]]\n\n"
   "1. [ ] numbered task\n2. plain item\n\n"
   "| Party | Role | Due |\n| :--- | :---: | ---: |\n| Ana | client | 2026-09-30 |\n"
   "| Bo \\| Co | counsel | #tag |\n| only one |\n\n"
   "> | a | b |\n> | - | - |\n> | [[x]] | ~~y~~ |\n\n"
   "`#not-a-tag` and `[[not a link]]` and <https://example.com/#frag> and [a #b](http://x.y/#c)\n"))

(define ext-corpus
  (list
   ext-note
   ;; wiki links
   "[[Title]]" "[[Title|text]]" "[[Title#Heading]]" "[[Title#Heading|alias]]" "[[]]" "[[a]b]]"
   "[[a\nb]]" "[[[a]]]" "x [[a|b]] y [[c]]" "*[[a]]*" "[link [[w]]](/u)" "[[a|]]" "\\[[a]]"
   ;; tags
   "#tag" "#tag at start" "a #tag b" "a#notag" "(#paren)" "#1" "#a/b-c_d" "#tag." "# heading #tag"
   "*#emph-tag*" "http://example.com/#frag" "www.example.com/#frag" "&#35;x" "\\#x"
   ;; dates
   "2026-09-30" "due 2026-09-30" "Due 2026-09-30" "overdue 2026-09-30" "x2026-09-30" "2026-13-01"
   "2026-09-30x" "(Smith, 2019-04-06)" "due  2026-09-30" "a due 2026-09-30." "2026-09-3"
   ;; heading keywords
   "# TODO x" "# TODO" "# TODOx y" "## DONE *done* #t" "TODO x\n===" "# todo x" "WAITING in text"
   "- # TODO in list"
   ;; front matter
   "---\na: 1\n---\nbody" "---\n---\n" "---\na: [x, 'y', \"z\"]\nb:\n  - p\n  - q\nc:\n...\n# H"
   "---\nnot yaml at all {\n---\n" "---\nunterminated\n" "text\n---\na: 1\n---\n" " ---\na: 1\n---\n"
   ;; tables
   "| a | b |\n|---|---|\n| 1 | 2 |" "a | b\n- | -\n1 | 2" "para\n| a |\n| - |\n| 1 |"
   "| a |\n|:-:|\n" "| a | b |\n| - |\n" "| a |\n| - |\n\nafter" "| a |\n| - |\n# h"
   "- | a |\n  | - |\n  | 1 |" "| `a|b` | c |\n| - | - |" "| \\| |\n| - |\n| x \\\\| y |"
   "|a|\n|-|\n|b|c|d|" "| a |\n| --- |\n    | code? |" "\t| a |\n\t| - |"
   ;; task items
   "- [ ] a" "- [x] a" "- [X] a" "- [-] a" "- [ ]" "- [ ]a" "- [y] a" "* [ ] a\n\n  more"
   "1. [x] a" "- [ ]\n  next line" "> - [ ] quoted" "- [x] [link](/u)" "- [ ] [ref]: /u"
   ;; strikethrough
   "~~a~~" "~a~" "~~a~" "~~~a~~~" "a~~b~~c" "~~ a ~~" "*~~a~~*" "~~*a*~~" "\\~~a~~"
   ;; autolink literals
   "www.commonmark.org" "http://a.b/c?d=e&f=g" "https://x.y/(a)b)" "x@y.z" "a.b@c" "(www.a.b)"
   "www.a_b.c_d" "http://localhost" "ftp://a.b." "*www.a.b*" "[www.a.b](/u)" "`www.a.b`"
   "www.a.b&amp;c" "a www.b.c/d&e; f" "http://a.b/&copy;"))
