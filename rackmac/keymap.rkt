#lang racket/base
;; Keys, key sequences and keymaps. Pure (no GUI).
;;
;; A key is a base (lowercase char, or a symbol such as 'enter 'up 'f5) plus a
;; canonical list of modifiers. "Mod" resolves to Cmd on macOS and Ctrl elsewhere.
(require racket/list racket/string "platform.rkt" "owner.rkt")
(provide (struct-out key)
         parse-key parse-key-sequence key->string key-sequence->string
         make-keymap make-keymap/pairs keymap? keymap-name
         keymap-bind! keymap-unbind! lookup-key keymap-bindings keymap-keys-for
         global-keymap)

(struct key (base mods) #:transparent)

(define mod-order '(ctrl alt shift cmd))
(define (canonical-mods ms) (for/list ([m (in-list mod-order)] #:when (memq m ms)) m))

(define named-keys
  (hash "enter" 'enter "return" 'enter "tab" 'tab "escape" 'escape "esc" 'escape
        "backspace" 'backspace "delete" 'delete "del" 'delete "space" 'space
        "up" 'up "down" 'down "left" 'left "right" 'right
        "home" 'home "end" 'end "pageup" 'pageup "pagedown" 'pagedown "insert" 'insert))

(define (modifier-symbol s)
  (case (string-downcase s)
    [("mod") (if (mac?) 'cmd 'ctrl)]
    [("ctrl" "control") 'ctrl]
    [("cmd" "command") 'cmd]
    [("alt" "opt" "option") 'alt]
    [("shift") 'shift]))

(define (base-symbol s whole)
  (define lower (string-downcase s))
  (cond [(hash-ref named-keys lower #f) => values]
        [(regexp-match? #px"^f[0-9]{1,2}$" lower) (string->symbol lower)]
        [(= (string-length s) 1) (char-downcase (string-ref s 0))]
        [else (raise-user-error 'parse-key "unrecognised key ~s in ~s" s whole)]))

(define (parse-key str)
  (let loop ([s str] [mods '()])
    (define m (regexp-match #rx"^(?i:(mod|ctrl|control|cmd|command|alt|opt|option|shift))-(.+)$" s))
    (if m
        (loop (caddr m) (cons (modifier-symbol (cadr m)) mods))
        (key (base-symbol s str) (canonical-mods mods)))))

(define (parse-key-sequence str) (map parse-key (string-split str)))

;; ---- display -------------------------------------------------------------

(define (base->string b)
  (cond [(char? b) (string (char-upcase b))]
        [(mac?) (case b [(up) "↑"] [(down) "↓"] [(left) "←"] [(right) "→"] [(enter) "↩"]
                  [(tab) "⇥"] [(backspace) "⌫"] [(delete) "⌦"] [(escape) "⎋"]
                  [(space) "Space"] [(pageup) "PgUp"] [(pagedown) "PgDn"]
                  [else (string-upcase (symbol->string b))])]
        [else (case b [(up) "Up"] [(down) "Down"] [(left) "Left"] [(right) "Right"]
                [(enter) "Enter"] [(tab) "Tab"] [(backspace) "Backspace"] [(delete) "Delete"]
                [(escape) "Esc"] [(space) "Space"] [(pageup) "PgUp"] [(pagedown) "PgDn"]
                [(home) "Home"] [(end) "End"] [(insert) "Insert"]
                [else (string-upcase (symbol->string b))])]))

(define (key->string k)
  (define mods (key-mods k))
  (if (mac?)
      (string-append (if (memq 'ctrl mods) "⌃" "") (if (memq 'alt mods) "⌥" "")
                     (if (memq 'shift mods) "⇧" "") (if (memq 'cmd mods) "⌘" "")
                     (base->string (key-base k)))
      (string-join (append (for/list ([m (in-list mods)])
                             (case m [(ctrl) "Ctrl"] [(alt) "Alt"] [(shift) "Shift"] [(cmd) "Win"]))
                           (list (base->string (key-base k))))
                   "+")))

(define (key-sequence->string ks) (string-join (map key->string ks) " "))

;; ---- keymaps -------------------------------------------------------------
;; A keymap maps keys to either a command name (symbol) or a nested keymap (a prefix).

(struct keymap (name table))

(define (make-keymap [name 'anonymous]) (keymap name (make-hash)))

(define (keymap-bind! km seq cmd)
  (let loop ([km km] [ks (parse-key-sequence seq)])
    (define t (keymap-table km))
    (cond [(null? (cdr ks))
           (define prev (hash-ref t (car ks) #f))
           (hash-set! t (car ks) cmd)
           (register-undo! 'key (lambda () (if prev (hash-set! t (car ks) prev) (hash-remove! t (car ks)))))]
          [else
           (define existing (hash-ref t (car ks) #f))
           (define sub (if (keymap? existing)
                           existing
                           (let ([n (make-keymap)])
                             (hash-set! t (car ks) n)
                             ;; turning a key (maybe bound to a command) into a prefix is undoable too
                             (register-undo! 'key (lambda () (if existing (hash-set! t (car ks) existing) (hash-remove! t (car ks)))))
                             n)))
           (loop sub (cdr ks))])))

(define (make-keymap/pairs name pairs)
  (define km (make-keymap name))
  (for ([p (in-list pairs)]) (keymap-bind! km (car p) (cdr p)))
  km)

(define (keymap-unbind! km seq)
  (let loop ([km km] [ks (parse-key-sequence seq)])
    (define t (keymap-table km))
    (if (null? (cdr ks))
        (let ([prev (hash-ref t (car ks) #f)])
          (when prev
            (hash-remove! t (car ks))
            (register-undo! 'key (lambda () (hash-set! t (car ks) prev)))))
        (let ([sub (hash-ref t (car ks) #f)])
          (when (keymap? sub) (loop sub (cdr ks)))))))

(define (walk km ks)
  (let loop ([e km] [ks ks])
    (cond [(null? ks) e]
          [(keymap? e) (loop (hash-ref (keymap-table e) (car ks) #f) (cdr ks))]
          [else #f])))

;; Look up `ks` in `kms` (highest priority first).
;; Returns (values 'command name), (values 'prefix #f) or (values 'none #f).
;; The first (highest-priority) layer that has anything for `ks` decides: a minor mode's
;; chord prefix is not hidden by a single-key global binding for the same key.
(define (lookup-key kms ks)
  (let/ec return
    (for ([km (in-list kms)])
      (define e (walk km ks))
      (cond [(symbol? e) (return 'command e)]
            [(and (keymap? e) (positive? (hash-count (keymap-table e)))) (return 'prefix #f)]))
    (values 'none #f)))

;; All bindings as (list key-sequence command), for help and menus.
(define (keymap-bindings km)
  (let loop ([km km] [prefix '()])
    (for/fold ([acc '()]) ([(k v) (in-hash (keymap-table km))])
      (append acc (if (keymap? v)
                      (loop v (append prefix (list k)))
                      (list (list (append prefix (list k)) v)))))))

(define (keymap-keys-for km cmd)
  (for/list ([b (in-list (keymap-bindings km))] #:when (eq? (cadr b) cmd)) (car b)))

(define global-keymap (make-keymap 'global))
