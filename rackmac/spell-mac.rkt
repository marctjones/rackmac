#lang racket/base
;; macOS's own spell checker (NSSpellChecker) through ffi/unsafe/objc, for spell checking in notes
;; (#351). Loaded only on macOS (spell.rkt lazy-requires it), so other platforms never touch AppKit.
;; The user's language, learned words and dictionary are the ones every other Mac app uses.
;;
;; Spike findings (2026-09-26, Racket 9.3 CS, macOS 26 / Darwin 25.6, Apple silicon arm64):
;;
;; - Works from plain Racket (no racket/gui needed) once AppKit is loaded with ffi-lib:
;;   `+[NSSpellChecker sharedSpellChecker]`, `language` ("en" here), `+uniqueSpellDocumentTag`,
;;   `checkSpellingOfString:startingAt:` (returns an NSRange, read with `tell #:type _NSRange`;
;;   length 0 means no more misspellings), the long form `checkSpellingOfString:startingAt:
;;   language:wrap:inSpellDocumentWithTag:wordCount:`, `guessesForWordRange:inString:language:
;;   inSpellDocumentWithTag:` (NSArray of NSString: "lazzy" -> ("lazy" "jazzy")), `learnWord:`,
;;   `unlearnWord:`, `hasLearnedWord:`, `ignoreWord:inSpellDocumentWithTag:` and
;;   `closeSpellDocumentWithTag:`. An ignored word is skipped only by checks that pass the same tag.
;; - `learnWord:` writes the user's system dictionary (~/Library/Spelling), so learned words
;;   persist across launches and are shared with other apps; tests must unlearn what they learn.
;; - Words macOS autocorrects ("teh", "adress") are not reported as misspelled; the checker
;;   defers them to autocorrection. Accepted: we match what the system reports.
;; - NSRange offsets are UTF-16 code units, Racket strings are code points: after an emoji every
;;   range was one character off ("isspeled " instead of "misspeled"). The checked text replaces
;;   every character above U+FFFF with a space first, so the two agree (spell.rkt masks it).
;; - `checkString:range:types:options:...` (NSTextCheckingResult batch) also works but returned
;;   extra long ranges and cost 10x the CPU; `checkSpellingOfString:startingAt:` in a loop is used.
;; - Timings, 283 KB / 5,004-line generated note (rackmac-markdown/tests/notes-gen.rkt; `meeting`
;;   misspelled as `meetting`, 577 misspellings); the checking runs in the AppleSpell service, so
;;   wall time is mostly waiting and Racket's own CPU is small:
;;     one call per paragraph, all 5,004:  ~2.3 s wall, ~0.37 s CPU (clean text: ~1.0 s wall)
;;     the whole note as one string:       ~1.05 s wall, ~0.1 s CPU
;;     one paragraph (75-100 chars):       0.2-1.6 ms wall, ~0.25 ms CPU
;;     guesses for one word:               ~9 ms wall
;;   So a keystroke never checks: edits only mark paragraphs, and an idle timer checks marked
;;   paragraphs in slices of a few milliseconds, so a whole-note check never freezes the window.
;; - x86_64: not run (no Intel Racket on this machine). NSRange is two NSUIntegers (16 bytes),
;;   which x86_64 returns in registers, not through objc_msgSend_stret; ffi/unsafe/objc's `tell`
;;   chooses the send variant per architecture, and racket/gui's own Cocoa backend reads
;;   `_NSRange` results the same way (list-box.rkt), so no x86_64-specific code is expected.
;; - Fallback: none needed on macOS. Elsewhere spell.rkt could drive `hunspell -a` or `aspell -a`
;;   (the ispell pipe protocol) when one is installed; until then the checker there finds nothing.
(require ffi/unsafe ffi/unsafe/objc)
(provide mac-spell-available? mac-misspellings mac-guesses
         mac-learn-word! mac-unlearn-word! mac-has-learned-word?)

(define appkit (ffi-lib "/System/Library/Frameworks/AppKit.framework/AppKit" #:fail (lambda () #f)))
(define-cstruct _NSRange ([location _ulong] [length _ulong]))

(import-class NSString NSAutoreleasePool)
(define checker
  (and appkit
       (let ([cls (objc_lookUpClass "NSSpellChecker")])
         (and cls (tell cls sharedSpellChecker)))))

(define (mac-spell-available?) (and checker #t))

(define (ns s)
  (tell (tell NSString alloc) initWithUTF8String: #:type _bytes
        (bytes-append (string->bytes/utf-8 s) #"\0")))
(define (ns->string o) (and o (tell #:type _string/utf-8 o UTF8String)))

;; Every call runs in its own autorelease pool: the checker returns autoreleased objects, and
;; outside the GUI's event loop (tests, idle timers) nothing else would drain them.
(define (with-pool thunk)
  (define pool (tell (tell NSAutoreleasePool alloc) init))
  (dynamic-wind void thunk (lambda () (tell pool drain))))

;; The misspelled ranges of `s` as (start . end), in order. `s` must have no characters above
;; U+FFFF (see the findings above), so offsets are the same in both encodings.
(define (mac-misspellings s)
  (define n (string-length s))
  (if (zero? n)
      '()
      (with-pool
       (lambda ()
         (define o (ns s))
         (begin0
           (let loop ([start 0] [acc '()])
             (define r (tell #:type _NSRange checker checkSpellingOfString: o startingAt: #:type _long start))
             (define loc (NSRange-location r))
             (define len (NSRange-length r))
             ;; the search wraps to the start of the string once it passes the end
             (if (or (zero? len) (>= loc n) (< loc start))
                 (reverse acc)
                 (loop (+ loc len) (cons (cons loc (min n (+ loc len))) acc))))
           (tell o release))))))

(define (mac-guesses word)
  (with-pool
   (lambda ()
     (define o (ns word))
     (define arr (tell checker guessesForWordRange: #:type _NSRange (make-NSRange 0 (string-length word))
                       inString: o language: (tell checker language) inSpellDocumentWithTag: #:type _long 0))
     (begin0
       (if arr
           (for/list ([i (in-range (tell #:type _ulong arr count))])
             (ns->string (tell arr objectAtIndex: #:type _ulong i)))
           '())
       (tell o release)))))

(define (word-call! sel word)
  (with-pool (lambda () (define o (ns word)) (begin0 (sel o) (tell o release)))))
(define (mac-learn-word! word) (word-call! (lambda (o) (tell checker learnWord: o)) word) (void))
(define (mac-unlearn-word! word) (word-call! (lambda (o) (tell checker unlearnWord: o)) word) (void))
(define (mac-has-learned-word? word) (word-call! (lambda (o) (tell #:type _BOOL checker hasLearnedWord: o)) word))
