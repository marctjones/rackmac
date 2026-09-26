#lang racket/base
;; The command registry: the spine of the editor. Menus, the palette, keymaps and
;; help all read from it. Pure (no GUI).
(require (for-syntax racket/base syntax/parse "keymap.rkt")
         racket/list racket/string
         "keymap.rkt" "hook.rkt" "platform.rkt" "owner.rkt")
(provide (struct-out command) define-command register-command!
         find-command all-commands run-command run-command/safe
         default-title command-shortcut extending-selection?
         command-enabled? command-checked? command-search-text command-search-fields command-category-label recent-commands
         default-key-strings command-menu-label)

;; title is the name users see; name is the stable symbol used by keymaps and scripts.
;; aliases are extra search terms (plain words people might type); help is one plain sentence;
;; icon names a toolbar/menu icon; when is a thunk saying whether the command applies now.
;; menu is a string ("File") or #f; menu-order groups items (a new tens digit adds a separator).
;; checked: #f or a thunk saying whether the command's state is on (a checkable menu item,
;; #333); checked-title / checked-icon: what a toolbar button shows instead while it is on
;; (button% has no pressed state, so a swapped label is the native way to show a toggle).
(struct command (name title doc category menu menu-order proc aliases help icon when
                 checked checked-title checked-icon))

(define registry (make-hasheq))
;; name -> (list keys keys/mac keys/windows), as declared, so the defaults for EITHER
;; platform can be listed (cheat sheets, tests) regardless of which one we are running on.
(define key-specs (make-hasheq))
(define definition-order (make-hasheq))
(define counter 0)

;; Set by the key dispatcher when Shift was held on a motion key and the unshifted
;; binding is a command that can extend the selection (e.g. Shift+Alt+Left).
(define extending-selection? (make-parameter #f))

(define (default-title name)
  (string-titlecase (string-replace (symbol->string name) "-" " ")))

(define (register-command! name proc
                           #:title [title (default-title name)]
                           #:doc [doc ""]
                           #:category [category #f]
                           #:menu [menu #f]
                           #:menu-order [menu-order #f]
                           #:keys [keys '()]
                           #:keys/mac [keys/mac '()]
                           #:keys/windows [keys/windows '()]
                           #:aliases [aliases '()]
                           #:help [help ""]
                           #:icon [icon #f]
                           #:when [when-thunk #f]
                           #:checked [checked #f]
                           #:checked-title [checked-title #f]
                           #:checked-icon [checked-icon #f])
  (unless (hash-has-key? definition-order name)
    (set! counter (add1 counter))
    (hash-set! definition-order name counter))
  (define old (hash-ref registry name #f))
  (hash-set! registry name
             (command name title doc category menu
                      (or menu-order (* 1000 (hash-ref definition-order name)))
                      proc aliases help icon when-thunk checked checked-title checked-icon))
  (register-undo! 'command
                  (lambda ()
                    (if old (hash-set! registry name old) (hash-remove! registry name))
                    (run-hook 'command-registered name)))
  (hash-set! key-specs name (list keys keys/mac keys/windows))
  (for ([k (in-list (append keys (if (mac?) keys/mac keys/windows)))])
    (keymap-bind! global-keymap k name))
  (run-hook 'command-registered name))

;; Key strings are checked when the module is compiled, so a typo is a syntax error at
;; the offending string instead of a failure at startup.
(begin-for-syntax
  (define (check-key-strings! stxs)
    (when stxs
      (for ([s (in-list (syntax->list stxs))])
        (define v (syntax-e s))
        (unless (string? v)
          (raise-syntax-error 'define-command "key binding must be a string literal" s))
        (with-handlers ([exn:fail:user? (lambda (e) (raise-syntax-error 'define-command (exn-message e) s))])
          (parse-key-sequence v))))))

(define-syntax (define-command stx)
  (syntax-parse stx
    [(_ (name:id)
        (~or (~optional (~seq #:title title:expr))
             (~optional (~seq #:doc doc:expr))
             (~optional (~seq #:category cat:expr))
             (~optional (~seq #:keys keys:expr))
             (~optional (~seq #:keys/mac keys/mac:expr))
             (~optional (~seq #:keys/windows keys/win:expr))
             (~optional (~seq #:menu menu:expr))
             (~optional (~seq #:menu-order order:expr))
             (~optional (~seq #:aliases aliases:expr))
             (~optional (~seq #:help help:expr))
             (~optional (~seq #:icon icon:expr))
             (~optional (~seq #:when when:expr))
             (~optional (~seq #:checked checked:expr))
             (~optional (~seq #:checked-title checked-title:expr))
             (~optional (~seq #:checked-icon checked-icon:expr)))
        ...
        body:expr ...+)
     #:do [(check-key-strings! (attribute keys))
           (check-key-strings! (attribute keys/mac))
           (check-key-strings! (attribute keys/win))]
     #'(begin
         (define (name) body ...)
         (register-command! 'name name
                            #:title (~? title (default-title 'name))
                            #:doc (~? doc "")
                            #:category (~? cat #f)
                            #:menu (~? menu #f)
                            #:menu-order (~? order #f)
                            #:keys (~? 'keys '())
                            #:keys/mac (~? 'keys/mac '())
                            #:keys/windows (~? 'keys/win '())
                            #:aliases (~? 'aliases '())
                            #:help (~? help "")
                            #:icon (~? icon #f)
                            #:when (~? when #f)
                            #:checked (~? checked #f)
                            #:checked-title (~? checked-title #f)
                            #:checked-icon (~? checked-icon #f)))]))

(define (find-command name) (hash-ref registry name #f))

(define (all-commands)
  (sort (hash-values registry) string<? #:key command-title))

(define recent '())
(define (recent-commands) recent)
(define (note-recent! name)
  (unless (eq? name 'command-palette)               ; the palette launching itself is not "recent"
    (set! recent (take-up-to (cons name (remq name recent)) 8))))
(define (take-up-to l n) (if (> (length l) n) (take l n) l))

(define (run-command name)
  (define c (find-command name))
  (unless c (error 'run-command "unknown command: ~a" name))
  (run-hook 'before-command name)
  ((command-proc c))
  (note-recent! name)
  (run-hook 'after-command name))

;; Does the command apply right now? A predicate that raises is reported (Activity log)
;; and counts as enabled, so a buggy extension cannot hide a command.
(define (command-enabled? c)
  (define w (command-when c))
  (or (not w)
      (with-handlers ([exn:fail? (lambda (e) (report-error! (command-name c) e) #t)])
        (and (w) #t))))

;; #333: #f for a command with no on/off state, otherwise whether it is on now. A failing
;; thunk is reported and reads as off.
(define (command-checked? c)
  (define k (command-checked c))
  (and k (with-handlers ([exn:fail? (lambda (e) (report-error! (command-name c) e) #f)])
           (and (k) #t))))

;; Extra fields the palette matches besides the title: the internal name and the aliases.
(define (command-search-fields c) (cons (symbol->string (command-name c)) (command-aliases c)))

;; The palette's Category column: the command's own #:category, else its menu, else "General"
;; (docs/UI-DESIGN.md §2; RM-030).
(define (command-category-label c) (or (command-category c) (command-menu c) "General"))

;; The same as one string (kept for callers that want a single blob).
(define (command-search-text c)
  (string-join (list* (command-title c) (symbol->string (command-name c)) (command-aliases c)) " "))

;; For UI entry points (keys, menus, palette): report errors, don't propagate.
(define (run-command/safe name)
  (with-handlers ([exn:fail? (lambda (e) (report-error! name e))])
    (run-command name)))

;; The key strings a command gets by default on `platform` ('mac or 'windows).
(define (default-key-strings name platform)
  (define spec (hash-ref key-specs name #f))
  (if spec (append (car spec) (if (eq? platform 'mac) (cadr spec) (caddr spec))) '()))

;; First global binding for a command as display text ("⌘S"), or #f.
(define (command-shortcut name)
  (define ks (keymap-keys-for global-keymap name))
  (and (pair? ks) (key-sequence->string (car (sort ks < #:key length)))))

;; A menu label with its shortcut appended the way each platform expects (a tab on Windows;
;; Cocoa ignores "\t", so macOS gets inline spaces instead). Shared by the menu bar
;; (frame.rkt) and the context-menu popups (rackmac/ui/context-menu.rkt).
(define (command-menu-label name)
  (define c (find-command name))
  (define title (if c (command-title c) (symbol->string name)))
  (define s (command-shortcut name))
  (cond [(not s) title]
        [(mac?) (string-append title "    " s)]
        [else (string-append title "\t" s)]))
