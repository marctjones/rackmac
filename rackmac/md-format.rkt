#lang racket/base
;; Formatting commands for notes (#335, docs/UI-DESIGN.md §2.3-2.4): Bold, Italic, Inline Code,
;; Strikethrough, Insert Link, Heading 1-3, Body Text, Bulleted/Numbered/Checklist, Quote and
;; Mark Done. Office shortcuts; toggle semantics on the selection or the word at the caret,
;; computed by rackmac-markdown/edits.rkt and applied as one undo step (md-doc.rkt). They work
;; the same in the Formatted and Markdown Source views (md-doc.rkt's `current-md-document`), and
;; only apply to prose documents (`#:when markdown-document?`), which is also what shows the
;; Format menu (frame.rkt hides an otherwise-empty top menu; see rebuild-menus!).
(require racket/class
         "command.rkt" "editor.rkt" "md-doc.rkt" "md-view-commands.rkt"
         "../rackmac-markdown/main.rkt")

;; ---- inline: bold, italic, inline code, strikethrough -----------------------------------------

(define (toggle-emphasis! kind)
  (define b (current-buffer))
  (when (markdown-document? b)
    (define-values (s e) (selection-range b))
    (define-values (edits ns ne) (toggle-emphasis-edits (current-md-document b) s e kind))
    (apply-md-edits! b edits)
    (send b set-position ns ne)))

(define-command (toggle-bold)
  #:title "Bold" #:menu "Format" #:menu-order 10 #:keys ("Mod-b")
  #:aliases ("bold" "strong")
  #:help "Make the selection, or the word at the cursor, bold."
  #:when markdown-document?
  (toggle-emphasis! 'strong))

(define-command (toggle-italic)
  #:title "Italic" #:menu "Format" #:menu-order 11 #:keys ("Mod-i")
  #:aliases ("italic" "emphasis")
  #:help "Make the selection, or the word at the cursor, italic."
  #:when markdown-document?
  (toggle-emphasis! 'emph))

(define-command (toggle-inline-code)
  #:title "Inline Code" #:menu "Format" #:menu-order 12 #:keys ("Shift-Mod-c")
  #:aliases ("inline code" "code span" "code formatting")
  #:help "Format the selection, or the word at the cursor, as inline code."
  #:when markdown-document?
  (toggle-emphasis! 'code))

(define-command (toggle-strikethrough)
  #:title "Strikethrough" #:menu "Format" #:menu-order 13
  #:aliases ("strikethrough" "strike through" "cross out")
  #:help "Cross out the selection, or the word at the cursor."
  #:when markdown-document?
  (toggle-emphasis! 'strike))

;; ---- link ---------------------------------------------------------------------------------
;; The library has no wrap-link operation (it needs no parse-tree awareness): the selection (or
;; nothing, at a bare caret) becomes `[text](|)`, the cursor left inside the empty URL, as Word's
;; Insert Hyperlink does when nothing is selected. On an existing link (the caret inside it, or
;; a selection within it) it edits that link instead, as Word's ⌘K on a hyperlink does: its URL
;; is selected for typing over (the cursor goes inside an empty one); an autolink `<url>` has its
;; URL selected, a reference link `[text][label]` its label.

;; The innermost link containing [s, e) (a caret strictly inside, or a selection within it).
(define (link-around doc s e)
  (define leaf (block-at doc s))
  (define (kids x)
    (cond [(emph? x) (emph-children x)] [(strong? x) (strong-children x)] [(strike? x) (strike-children x)]
          [(link? x) (link-children x)] [(image? x) (image-children x)] [else '()]))
  (and leaf (leaf-block? leaf)
       (let loop ([xs (block-inlines leaf)] [found #f])
         (for/fold ([found found]) ([x (in-list xs)])
           (define hit? (and (link? x) (<= (inline-start x) s) (<= e (inline-end x))
                             (if (= s e) (< (inline-start x) s (inline-end x)) #t)))
           (loop (kids x) (if hit? x found))))))

;; The range to select in link `l` for editing it.
(define (link-edit-range l)
  (define (tok role) (for/first ([t (in-list (inline-tokens l))] #:when (eq? (token-role t) role)) t))
  (cond
    [(tok 'link-dest) => (lambda (t) (cons (token-start t) (token-end t)))]
    [(tok 'link-dest-open) => (lambda (t) (cons (token-end t) (token-end t)))]
    [(eq? (link-kind l) 'autolink)
     (define ts (filter (lambda (t) (eq? (token-role t) 'autolink-bracket)) (inline-tokens l)))
     (if (= (length ts) 2) (cons (token-end (car ts)) (token-start (cadr ts))) (cons (inline-start l) (inline-end l)))]
    [(tok 'link-label) => (lambda (t) (cons (add1 (token-start t)) (sub1 (token-end t))))]
    [else (cons (inline-start l) (inline-end l))]))

(define-command (insert-link)
  #:title "Insert Link…" #:menu "Format" #:menu-order 20 #:icon "link" #:keys ("Mod-k")
  #:aliases ("insert link" "hyperlink" "link" "edit link")
  #:help "Wrap the selection as a Markdown link, with the cursor in the URL; on a link, select its URL."
  #:when markdown-document?
  (define b (current-buffer))
  (when (markdown-document? b)
    (define-values (s e) (selection-range b))
    (define l (link-around (current-md-document b) s e))
    (cond
      [l (define r (link-edit-range l))
         (send b set-position (car r) (cdr r))]
      [else
       (define label (send b get-text s e))
       (apply-md-edits! b (list (edit s e (string-append "[" label "](" ")"))))
       (define caret (+ s (string-length label) 3))     ; after "[label](" -- inside the empty URL
       (send b set-position caret caret)])))

;; ---- headings and body text -----------------------------------------------------------------

(define (set-heading! level)
  (define b (current-buffer))
  (when (markdown-document? b)
    (define-values (s e) (selection-range b))
    (define edits (set-heading-level-edits (current-md-document b) s e level))
    (define ns (map-position edits s 'after)) (define ne (map-position edits e 'before))
    (apply-md-edits! b edits)
    (send b set-position ns ne)))

(define-command (heading-1)
  #:title "Heading 1" #:menu "Format" #:menu-order 30 #:keys/mac ("Mod-Alt-1")
  #:aliases ("heading 1" "heading one" "h1")
  #:help "Make the current paragraph a level 1 heading."
  #:when markdown-document?
  (set-heading! 1))

(define-command (heading-2)
  #:title "Heading 2" #:menu "Format" #:menu-order 31 #:keys/mac ("Mod-Alt-2")
  #:aliases ("heading 2" "heading two" "h2")
  #:help "Make the current paragraph a level 2 heading."
  #:when markdown-document?
  (set-heading! 2))

(define-command (heading-3)
  #:title "Heading 3" #:menu "Format" #:menu-order 32 #:keys/mac ("Mod-Alt-3")
  #:aliases ("heading 3" "heading three" "h3")
  #:help "Make the current paragraph a level 3 heading."
  #:when markdown-document?
  (set-heading! 3))

(define-command (body-text)
  #:title "Body Text" #:menu "Format" #:menu-order 33 #:keys/mac ("Mod-Alt-0")
  #:aliases ("body text" "normal text" "paragraph text" "remove heading")
  #:help "Make the current paragraph plain body text."
  #:when markdown-document?
  (set-heading! 0))

;; ---- lists and quote -------------------------------------------------------------------------

(define (toggle-list! kind)
  (define b (current-buffer))
  (when (markdown-document? b)
    (define-values (s e) (selection-range b))
    (define edits (toggle-list-edits (current-md-document b) s e kind))
    (define ns (map-position edits s 'after)) (define ne (map-position edits e 'before))
    (apply-md-edits! b edits)
    (send b set-position ns ne)))

(define-command (toggle-bulleted-list)
  #:title "Bulleted List" #:menu "Format" #:menu-order 40 #:keys ("Shift-Mod-8")
  #:aliases ("bulleted list" "bullet list" "bullets")
  #:help "Make the selected lines a bulleted list, or plain paragraphs again."
  #:when markdown-document?
  (toggle-list! 'bullet))

(define-command (toggle-numbered-list)
  #:title "Numbered List" #:menu "Format" #:menu-order 41 #:keys ("Shift-Mod-7")
  #:aliases ("numbered list" "ordered list" "numbering")
  #:help "Make the selected lines a numbered list, or plain paragraphs again."
  #:when markdown-document?
  (toggle-list! 'ordered))

(define-command (toggle-checklist)
  #:title "Checklist" #:menu "Format" #:menu-order 42 #:icon "checklist" #:keys ("Shift-Mod-l")
  #:aliases ("checklist" "to-do list" "task list" "checkbox list")
  #:help "Make the selected lines a checklist, or plain paragraphs again."
  #:when markdown-document?
  (toggle-list! 'task))

(define-command (toggle-quote)
  #:title "Quote" #:menu "Format" #:menu-order 43 #:keys ("Shift-Mod-9")
  #:aliases ("quote" "block quote" "blockquote")
  #:help "Quote the selected lines, or remove one level of quoting."
  #:when markdown-document?
  (define b (current-buffer))
  (when (markdown-document? b)
    (define-values (s e) (selection-range b))
    (define edits (toggle-quote-edits (current-md-document b) s e))
    (define ns (map-position edits s 'after)) (define ne (map-position edits e 'before))
    (apply-md-edits! b edits)
    (send b set-position ns ne)))

;; ---- task checkbox ----------------------------------------------------------------------------

(define-command (mark-done)
  #:title "Mark Done" #:menu "Format" #:menu-order 50 #:icon "check" #:keys ("Shift-Mod-u")
  #:aliases ("mark done" "toggle checkbox" "check off" "mark complete")
  #:help "Toggle the checkbox of the current list item."
  #:when markdown-document?
  (define b (current-buffer))
  (when (markdown-document? b)
    (define pos (send b get-start-position))
    (define edits (toggle-task-edits (current-md-document b) pos))
    (define np (map-position edits pos 'after))
    (apply-md-edits! b edits)
    (send b set-position np np)))
