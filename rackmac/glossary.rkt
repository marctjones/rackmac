#lang racket/base
;; Emacs term -> Rackmac term. Shown by the Glossary command and copied into README.md
;; (a test checks the README table matches this list).
(require racket/string)
(provide glossary glossary-text glossary-markdown)

(define glossary
  '(("buffer"                  "Document, Tab")
    ("window / frame"          "Pane / Window")
    ("point, mark, region"     "Cursor, Selection")
    ("kill / yank"             "Cut / Paste")
    ("kill ring"               "Clipboard History")
    ("M-x"                     "Command Palette")
    ("minibuffer, echo area"   "Command bar, Status message")
    ("mode line"               "Status bar")
    ("major mode"              "Language")
    ("minor mode"              "Option")
    ("keymap, key binding"     "Shortcut")
    ("hook"                    "Trigger")
    ("init file"               "Customize with Code")
    ("evaluate"                "Run")
    ("*scratch*"               "Scratch Pad")
    ("*Messages*"              "Activity log")
    ("describe-key"            "What Does This Key Do?")
    ("describe-function"       "Explain a Command")
    ("package"                 "Extension")))

(define (pad s n) (string-append s (make-string (max 1 (- n (string-length s))) #\space)))

(define (glossary-text)
  (string-append
   "Glossary: Emacs terms and what Rackmac calls them\n\n"
   (pad "Emacs" 26) "Rackmac\n" (pad "-----" 26) "-------\n"
   (string-join (for/list ([g glossary]) (string-append (pad (car g) 26) (cadr g))) "\n")
   "\n\nThe command palette understands both names: typing an Emacs term finds the Rackmac command.\n"))

(define (glossary-markdown)
  (string-append
   "| Emacs | Rackmac |\n|---|---|\n"
   (string-join (for/list ([g glossary]) (format "| ~a | ~a |" (car g) (cadr g))) "\n")
   "\n"))
