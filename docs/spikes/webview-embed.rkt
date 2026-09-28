#lang racket/base
;; Spike (#422): embed a WebKit WKWebView beside the editor in a racket/gui window, through
;; ffi/unsafe/objc (the route rackmac/pasteboard.rkt uses). Write-up: docs/spikes/webview-embed.md.
;;
;;   racket docs/spikes/webview-embed.rkt            ; checks, window invisible (alpha 0)
;;   racket docs/spikes/webview-embed.rkt --visible  ; same, window briefly visible (never frontmost)
;;   racket docs/spikes/webview-embed.rkt --cycles 20
;;
;; Every check is verified without looking: page title and body text read back through JS,
;; geometry compared numerically, focus read from [NSWindow firstResponder], and releases
;; counted by a WKWebView subclass whose -dealloc bumps a counter. Prints one line per check
;; and exits 0 only when all pass. A watchdog exits the process after 90 s whatever happens.

;; Must be instantiated before racket/gui: keeps the app from coming to the front (tests/no-front.rkt).
(module no-front racket/base
  (require ffi/unsafe/global)
  (void (register-process-global #"Racket-GUI-no-front" #"yes")))
(require 'no-front
         racket/class racket/gui/base racket/file racket/string racket/list racket/system
         (only-in racket/os getpid)
         ffi/unsafe ffi/unsafe/objc)

(define visible? (member "--visible" (vector->list (current-command-line-arguments))))
(define cycles
  (let ([l (member "--cycles" (vector->list (current-command-line-arguments)))])
    (if (and l (pair? (cdr l))) (string->number (cadr l)) 20)))

;; ---------------------------------------------------------------- results
(define failures 0)
(define (check name ok? [detail ""])
  (unless ok? (set! failures (add1 failures)))
  (printf "~a  ~a~a\n" (if ok? "PASS" "FAIL") name (if (equal? detail "") "" (format "  [~a]" detail)))
  (flush-output))
(define (note fmt . args) (printf "      ~a\n" (apply format fmt args)) (flush-output))

;; An error must end the run: racket/gui would otherwise keep the process alive for the open frame.
(uncaught-exception-handler
 (lambda (e) (eprintf "ERROR ~a\n" (if (exn? e) (exn-message e) e)) (exit 2)))

(define watchdog
  (thread (lambda () (sleep 90) (printf "FAIL  watchdog: spike did not finish in 90 s\n") (exit 3))))
;; A second, OS-level watchdog: SIGALRM kills the process even if the main thread is stuck
;; inside a foreign call, where Racket threads (the watchdog above) cannot run.
(void ((get-ffi-obj "alarm" #f (_fun _uint -> _uint)) 120))

;; ---------------------------------------------------------------- availability
;; Off macOS, or with WebKit missing, the answer is "no embedded preview", never an error.
(define WKWebView-before-load
  (and (eq? (system-type 'os) 'macosx) (objc_lookUpClass "WKWebView")))
(define webkit-lib
  (and (eq? (system-type 'os) 'macosx)
       (ffi-lib "/System/Library/Frameworks/WebKit.framework/WebKit" #:fail (lambda () #f))))
(define (webview-available?) (and webkit-lib (objc_lookUpClass "WKWebView") #t))

(unless (webview-available?)
  (printf "SKIP  no WKWebView on this system: no embedded preview (browser preview #421 applies)\n")
  (exit 0))

;; Plain `racket` (no racket/gui) finds no WKWebView until WebKit is loaded. racket/gui itself
;; happens to load it already (mred/private/wx/cocoa/procs.rkt loads the Carbon umbrella,
;; which pulls in Quartz -> ImageKit -> WebKit), so "before" is #t here; do not rely on that.
(check "WKWebView resolves once WebKit.framework is loaded explicitly"
       (and (objc_lookUpClass "WKWebView") #t)
       (format "already present via racket/gui before ffi-lib: ~a" (and WKWebView-before-load #t)))

;; ---------------------------------------------------------------- Cocoa helpers
(define-cstruct _NSPoint ([x _double] [y _double]))
(define-cstruct _NSSize ([width _double] [height _double]))
(define-cstruct _NSRect ([origin _NSPoint] [size _NSSize]))
(define (rect->list r)
  (list (NSPoint-x (NSRect-origin r)) (NSPoint-y (NSRect-origin r))
        (NSSize-width (NSRect-size r)) (NSSize-height (NSRect-size r))))

(import-class NSObject NSString NSURL NSThread NSEvent NSView NSApplication
              NSBitmapImageRep NSColorSpace
              WKWebView WKWebViewConfiguration WKUserContentController)

(define (ns s) (tell NSString stringWithUTF8String: #:type _string s))  ; autoreleased
(define (from-ns o) (and o (tell #:type _string o UTF8String)))
(define (class-name o) (and o (from-ns (tell (tell o class) description))))
(define (main-thread?) (tell #:type _BOOL NSThread isMainThread))
(define (kind-of? o cls) (and o (tell #:type _BOOL o isKindOfClass: (objc_lookUpClass cls))))

(define (wait-until pred [timeout 5.0])
  (define end (+ (current-inexact-milliseconds) (* 1000 timeout)))
  (let loop ()
    (cond [(pred) #t]
          [(> (current-inexact-milliseconds) end) #f]
          [else (sleep/yield 0.02) (loop)])))

;; ---------------------------------------------------------------- callbacks
;; racket/gui waits for Cocoa events inside a *blocking* foreign call, and WebKit delivers
;; delegate calls, script messages, completion blocks and deallocs from that wait. Racket CS
;; requires every callback that can arrive during a blocking call to have an #:async-apply
;; (without one it prints "non-async in callback during blocking"). These callbacks are short
;; and touch no Racket synchronization, so running the thunk at once is safe (Racket docs).
(define (run-now thunk) (thunk))

;; ---------------------------------------------------------------- blocks
;; ffi/unsafe/objc has no Objective-C blocks, and WebKit wants them both ways: it hands us one
;; to call (the navigation delegate's decisionHandler) and takes ours (completion handlers).
;; Clang's block ABI: {void *isa; int flags; int reserved; invoke; descriptor *}, and invoke
;; receives the block itself first. A global block (isa _NSConcreteGlobalBlock, flag
;; BLOCK_IS_GLOBAL) is never copied or freed by Block_copy/Block_release, so non-moving 'raw
;; memory that we never free is a valid one.
(define (block-invoke blk fun-type) (cast (ptr-ref blk _pointer 2) _pointer fun-type))
(define kept-callbacks '())       ; callbacks must stay reachable while WebKit holds the block
(define (make-global-block proc fun-type)
  (define desc (malloc 16 'raw))
  (ptr-set! desc _ulong 0 0)
  (ptr-set! desc _ulong 1 32)     ; sizeof the block literal
  (define cb (function-ptr proc fun-type))
  (set! kept-callbacks (cons cb kept-callbacks))
  (define blk (malloc 32 'raw))
  (ptr-set! blk _pointer 0 (ffi-obj-ref "_NSConcreteGlobalBlock" #f))
  (ptr-set! blk _int32 2 (arithmetic-shift 1 28)) ; BLOCK_IS_GLOBAL
  (ptr-set! blk _int32 3 0)
  (ptr-set! blk _pointer 2 cb)
  (ptr-set! blk _pointer 3 desc)
  blk)

;; ---------------------------------------------------------------- ObjC classes
;; Messages from the page: JS calls window.webkit.messageHandlers.rackmac.postMessage(string).
;; This stands in for evaluateJavaScript:'s completion block (passed as nil), so reading a value
;; back needs no hand-built block; one channel serves every value and page event.
(define messages '())             ; newest first
(define callback-threads '())     ; isMainThread seen inside every ObjC callback
(define (last-message prefix)
  (for/first ([m (in-list messages)] #:when (string-prefix? m prefix))
    (substring m (string-length prefix))))

(define-objc-class RackmacMessageHandler NSObject
  #:protocols ((objc_getProtocol "WKScriptMessageHandler"))
  []
  (-a #:async-apply run-now _void (userContentController: [_id ucc] didReceiveScriptMessage: [_id msg])
      (set! callback-threads (cons (main-thread?) callback-threads))
      (define body (tell msg body))
      (set! messages (cons (if (kind-of? body "NSString") (from-ns body) "<non-string>") messages))))

(define finished-navigations 0)
(define-objc-class RackmacNavDelegate NSObject
  #:protocols ((objc_getProtocol "WKNavigationDelegate"))
  []
  (-a #:async-apply run-now _void (webView: [_id wv] didFinishNavigation: [_id nav])
      (set! callback-threads (cons (main-thread?) callback-threads))
      (set! finished-navigations (add1 finished-navigations)))
  ;; Keep the preview on local files: anything else is cancelled (production would hand it
  ;; to the default browser). decisionHandler is a block WebKit requires us to call.
  (-a #:async-apply run-now _void (webView: [_id wv] decidePolicyForNavigationAction: [_id action]
                      decisionHandler: [_pointer decide])
      (set! callback-threads (cons (main-thread?) callback-threads))
      (define url (from-ns (tell (tell (tell action request) URL) absoluteString)))
      (set! policy-log (cons url policy-log))
      ((block-invoke decide (_fun _pointer _long -> _void))
       decide (if (string-prefix? url "file:") 1 0)))) ; WKNavigationActionPolicyAllow / Cancel
(define policy-log '())

;; A WKWebView that counts its own deallocation (define-objc-class appends [super dealloc]).
(define deallocs 0)
(define-objc-class RackmacWebView WKWebView
  []
  (-a #:async-apply run-now _void (dealloc) (set! deallocs (add1 deallocs))))

;; ---------------------------------------------------------------- the page
;; Under /tmp, not $TMPDIR: WebKit's content process can read the per-user $TMPDIR
;; (/var/folders/.../T) whatever read access was granted, which would hide the scope check.
(define root
  (make-temporary-directory "rackmac-webview-spike-~a" #:base-dir (or (getenv "SPIKE_ROOT") "/tmp")))
(note "site directory: ~a" root)
(define dir (build-path root "site"))
(make-directory dir)
(define page (build-path dir "page.html"))
(define (write-page! n)
  (with-output-to-file page #:exists 'truncate
    (lambda ()
      (printf "<!doctype html><html><head><meta charset=utf-8><title>Rackmac spike ~a</title>" n)
      (printf "<link rel=stylesheet href=style.css><link rel=stylesheet href=../outside.css></head><body>")
      (printf "<h1 id=marker>Version ~a</h1>" n)
      (for ([i 300]) (printf "<p>Paragraph ~a of the preview, long enough to scroll.</p>" i))
      (printf "<script>document.addEventListener('keydown',function(e){window.webkit.messageHandlers.rackmac.postMessage('key:'+e.key)});</script>")
      (printf "</body></html>"))))
(with-output-to-file (build-path dir "style.css") #:exists 'truncate
  (lambda () (printf "body { background-color: rgb(200, 30, 60); }")))
;; Outside the read-access directory: should NOT apply.
(define outside-css (build-path root "outside.css"))

;; ---------------------------------------------------------------- the pane
(define (post-js wv js) (tellv wv evaluateJavaScript: (ns js) completionHandler: #f))
;; Evaluate `expr` in the page and wait for its String() to come back under `tag`.
(define (js-value wv tag expr [timeout 3.0])
  (when (getenv "SPIKE_DEBUG") (eprintf "js-value ~a\n" tag))
  (set! messages (filter (lambda (m) (not (string-prefix? m (string-append tag ":")))) messages))
  (post-js wv (format "window.webkit.messageHandlers.rackmac.postMessage('~a:'+String(~a))" tag expr))
  (and (wait-until (lambda () (last-message (string-append tag ":"))) timeout)
       (last-message (string-append tag ":"))))

(define (file-url p) (tell NSURL fileURLWithPath: (ns (path->string p))))

;; Builds a frame: editor (editor-canvas% + text%) on the left, web pane (panel%) on the right.
;; Returns a hash of everything the checks need, and a close procedure.
(define (open-pane)
  (define frame (new frame% [label "Webview spike"] [width 900] [height 600]))
  (define win (send frame get-handle))
  (unless visible?
    (tellv win setAlphaValue: #:type _double 0.0)
    (tellv win setIgnoresMouseEvents: #:type _BOOL #t))
  (define split (new horizontal-panel% [parent frame]))
  (define keys '())
  (define text (new text%))
  (define editor-canvas%*
    (class editor-canvas%
      (define/override (on-char e)
        (set! keys (cons (send e get-key-code) keys))
        (super on-char e))
      (super-new)))
  (define editor (new editor-canvas%* [parent split] [editor text] [min-width 300] [stretchable-width #f]))
  (define host (new panel% [parent split]))
  (define host-view (send host get-client-handle))
  (define cfg (tell (tell WKWebViewConfiguration alloc) init))
  (define ucc (tell cfg userContentController))
  (define handler (tell (tell RackmacMessageHandler alloc) init))
  (tellv ucc addScriptMessageHandler: handler name: (ns "rackmac"))
  (define nav (tell (tell RackmacNavDelegate alloc) init))
  (define wv (tell (tell RackmacWebView alloc)
                   initWithFrame: #:type _NSRect (tell #:type _NSRect host-view bounds)
                   configuration: cfg))
  (tellv cfg release)
  (tellv wv setAutoresizingMask: #:type _uint64 18) ; NSViewWidthSizable | NSViewHeightSizable
  (tellv wv setNavigationDelegate: nav)
  (tellv host-view addSubview: wv)
  (send frame show #t)
  (define (close!)
    (send frame show #f)
    (tellv wv stopLoading)
    (tellv wv setNavigationDelegate: #f)
    (tellv (tell (tell wv configuration) userContentController)
           removeScriptMessageHandlerForName: (ns "rackmac"))
    (tellv wv removeFromSuperview)
    (tellv wv release)
    (tellv handler release)
    (tellv nav release))
  (hash 'frame frame 'win win 'split split 'editor editor 'text text 'host host
        'host-view host-view 'wv wv 'keys (lambda () keys) 'close! close!))

(define (load! wv)
  (define before finished-navigations)
  (tell wv loadFileURL: (file-url page) allowingReadAccessToURL: (file-url dir))
  (wait-until (lambda () (> finished-navigations before)) 10.0))

(define (frames-match? p)
  (equal? (map round (rect->list (tell #:type _NSRect (hash-ref p 'wv) frame)))
          (map round (rect->list (tell #:type _NSRect (hash-ref p 'host-view) bounds)))))

;; ================================================================ checks
(define app (tell NSApplication sharedApplication))
(define active-at-start (tell #:type _BOOL app isActive))
(write-page! 1)
(with-output-to-file outside-css #:exists 'truncate
  (lambda () (printf "h1 { color: rgb(9, 8, 7); }")))

(check "get-handle facts"
       (let ([p (new frame% [label "probe"])])
         (define c (new canvas% [parent p]))
         (define pn (new panel% [parent p]))
         (begin0 (and (kind-of? (send p get-handle) "NSWindow")
                      (kind-of? (send pn get-client-handle) "NSView")
                      (kind-of? (send c get-client-handle) "NSView"))
           (note "frame%: ~a; panel% handle/client: ~a / ~a; canvas% handle/client: ~a / ~a"
                 (class-name (send p get-handle))
                 (class-name (send pn get-handle)) (class-name (send pn get-client-handle))
                 (class-name (send c get-handle)) (class-name (send c get-client-handle))))))

(define p (open-pane))
(define wv (hash-ref p 'wv))
(define win (hash-ref p 'win))

;; (1) local HTML from file:// renders in the pane
(check "(1) file:// page loads (didFinishNavigation)" (load! wv))
(check "(1) title read natively ([wv title])" (equal? (from-ns (tell wv title)) "Rackmac spike 1")
       (from-ns (tell wv title)))
(check "(1) body text read through JS" (equal? (js-value wv "h1" "document.getElementById('marker').textContent") "Version 1"))
(check "(1) sibling CSS inside the read-access directory applies"
       (equal? (js-value wv "bg" "getComputedStyle(document.body).backgroundColor") "rgb(200, 30, 60)"))
(let ([c (js-value wv "col" "getComputedStyle(document.getElementById('marker')).color")])
  (check "(1) CSS outside the read-access directory is blocked" (not (equal? c "rgb(9, 8, 7)")) c))

;; (1) pixels: WKWebView's own snapshot (a completion block of ours) shows the page background.
(define snapshot #f)
(define snapshot-block
  (make-global-block (lambda (blk img err)
                       (set! callback-threads (cons (main-thread?) callback-threads))
                       (set! snapshot (if img (tell img retain) 'error)))
                     (_fun #:async-apply run-now _pointer _id _id -> _void)))
(tellv wv takeSnapshotWithConfiguration: #f completionHandler: #:type _pointer snapshot-block)
(let ([ok (wait-until (lambda () snapshot) 5.0)])
  (define rgb
    (and ok (not (eq? snapshot 'error))
         (let* ([rep (tell (tell NSBitmapImageRep alloc) initWithData: (tell snapshot TIFFRepresentation))]
                [c (tell (tell rep colorAtX: #:type _long 3 y: #:type _long 3)
                         colorUsingColorSpace: (tell NSColorSpace sRGBColorSpace))]
                [v (for/list ([m (list (lambda () (tell #:type _double c redComponent))
                                       (lambda () (tell #:type _double c greenComponent))
                                       (lambda () (tell #:type _double c blueComponent)))])
                     (inexact->exact (round (* 255 (m)))))])
           (tellv rep release)
           v)))
;; The snapshot is not in sRGB-exact values (display color space), so check "clearly that red".
  (check "(1) snapshot pixels show the page (CSS background rgb(200, 30, 60))"
         (and rgb (> (car rgb) 150) (< (cadr rgb) 100) (< (caddr rgb) 100))
         (format "snapshot ~a, size ~a, pixel ~a"
                 (and ok (not (eq? snapshot 'error)))
                 (and ok (not (eq? snapshot 'error))
                      (let ([sz (tell #:type _NSSize snapshot size)]) (list (NSSize-width sz) (NSSize-height sz))))
                 rgb)))

;; Navigation policy: a script navigating away is stopped by our decisionHandler call.
(post-js wv "location.href = 'https://example.invalid/elsewhere'")
(check "(1) navigation to the web is seen and cancelled (decisionHandler block called)"
       (and (wait-until (lambda () (member "https://example.invalid/elsewhere" policy-log)) 3.0)
            (begin (sleep/yield 0.3) (equal? (from-ns (tell wv title)) "Rackmac spike 1")))
       (format "policy saw ~a" (reverse policy-log)))

;; (2) resize with the window and with the pane
(sleep/yield 0.2)
(check "(2) web view fills the pane at start" (frames-match? p)
       (format "wv ~a host ~a" (rect->list (tell #:type _NSRect wv frame))
               (rect->list (tell #:type _NSRect (hash-ref p 'host-view) bounds))))
(define w0 (NSSize-width (NSRect-size (tell #:type _NSRect wv frame))))
(send (hash-ref p 'frame) resize 1100 700)
(sleep/yield 0.3)
(define w1 (NSSize-width (NSRect-size (tell #:type _NSRect wv frame))))
(check "(2) follows a window resize" (and (frames-match? p) (> w1 w0)) (format "width ~a -> ~a" w0 w1))
(send (hash-ref p 'editor) min-width 600)
(sleep/yield 0.3)
(define w2 (NSSize-width (NSRect-size (tell #:type _NSRect wv frame))))
(check "(2) follows a pane (split) resize" (and (frames-match? p) (< w2 w1)) (format "width ~a -> ~a" w1 w2))
(let ([iw (js-value wv "iw" "window.innerWidth")])
  (check "(2) page layout width matches the pane" (and iw (= (string->number iw) (round w2)))
         (format "innerWidth ~a, pane ~a" iw w2)))

;; (3) scrolling
(let ([sh (js-value wv "sh" "document.documentElement.scrollHeight")]
      [ih (js-value wv "ih" "window.innerHeight")])
  (check "(3) the page is taller than the pane" (and sh ih (> (string->number sh) (string->number ih)))
         (format "scrollHeight ~a innerHeight ~a" sh ih)))
(post-js wv "window.scrollTo(0, 1500)")
(check "(3) scrolls programmatically" (wait-until (lambda () (equal? (js-value wv "sy" "window.scrollY" 0.3) "1500"))))
;; A wheel event built in-process (never posted to the window server) and handed to the view.
(define cg (ffi-lib "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"))
(define CGEventCreateScrollWheelEvent2
  (get-ffi-obj "CGEventCreateScrollWheelEvent2" cg (_fun _pointer _uint32 _uint32 _int32 _int32 _int32 -> _pointer)))
(define CGEventSetLocation (get-ffi-obj "CGEventSetLocation" cg (_fun _pointer _NSPoint -> _void)))
(define CFRelease (get-ffi-obj "CFRelease" #f (_fun _pointer -> _void)))
(define (wheel! dy)
  (define ev (CGEventCreateScrollWheelEvent2 #f 0 1 dy 0 0)) ; kCGScrollEventUnitPixel
  (define wf (tell #:type _NSRect win frame))
  (define screen-h (NSSize-height (NSRect-size (tell #:type _NSRect (tell win screen) frame))))
  (define in-win (tell #:type _NSPoint wv convertPoint: #:type _NSPoint (make-NSPoint 200.0 200.0) toView: #f))
  (CGEventSetLocation ev (make-NSPoint (+ (NSPoint-x (NSRect-origin wf)) (NSPoint-x in-win))
                                       (- screen-h (+ (NSPoint-y (NSRect-origin wf)) (NSPoint-y in-win)))))
  (tellv wv scrollWheel: (tell NSEvent eventWithCGEvent: #:type _pointer ev))
  (CFRelease ev))
(wheel! -400)
(let ([ok (wait-until (lambda () (let ([y (js-value wv "sy" "window.scrollY" 0.3)]) (and y (> (string->number y) 1500)))) 3.0)])
  (check "(3) scrolls from a wheel event delivered to the view" ok
         (format "scrollY after wheel: ~a" (js-value wv "sy" "window.scrollY"))))

;; (4) keyboard focus: into the web view, keys go to the page; back to the editor, keys go to the text.
(define (first-responder) (tell win firstResponder))
(define (responder-in? view)
  (let ([r (first-responder)])
    (and (kind-of? r "NSView") (tell #:type _BOOL r isDescendantOf: view))))
(define (key! ch code)
  (define ev (tell NSEvent keyEventWithType: #:type _uint64 10 location: #:type _NSPoint (make-NSPoint 0.0 0.0)
                   modifierFlags: #:type _uint64 0 timestamp: #:type _double 0.0
                   windowNumber: #:type _long (tell #:type _long win windowNumber) context: #f
                   characters: (ns ch) charactersIgnoringModifiers: (ns ch)
                   isARepeat: #:type _BOOL #f keyCode: #:type _uint16 code))
  (tellv win sendEvent: ev))
(define (click! view)
  (define pt (tell #:type _NSPoint view convertPoint: #:type _NSPoint (make-NSPoint 100.0 100.0) toView: #f))
  (for ([type '(1 2)]) ; left mouse down, up
    (tellv win sendEvent:
           (tell NSEvent mouseEventWithType: #:type _uint64 type location: #:type _NSPoint pt
                 modifierFlags: #:type _uint64 0 timestamp: #:type _double 0.0
                 windowNumber: #:type _long (tell #:type _long win windowNumber) context: #f
                 eventNumber: #:type _long 0 clickCount: #:type _long 1 pressure: #:type _float 1.0))))

(send (hash-ref p 'editor) focus)
(sleep/yield 0.1)
(check "(4) editor starts with focus" (responder-in? (send (hash-ref p 'editor) get-handle)))
(define (key-count) (length ((hash-ref p 'keys))))
(click! wv)
(sleep/yield 0.3)
(note "window isKeyWindow: ~a; after a click sent to the non-key window, firstResponder is ~a"
      (tell #:type _BOOL win isKeyWindow) (class-name (first-responder)))
;; In a background (no-front) app no window can be key (makeKeyWindow is refused), and a
;; mouseDown sent to a non-key window only asks for key status. So the synthetic click cannot
;; stand in for a real one here; hand focus over the way WKWebView's own mouseDown: does.
(tellv win makeKeyWindow)
(note "after makeKeyWindow: isKeyWindow ~a (a background app cannot own the key window)"
      (tell #:type _BOOL win isKeyWindow))
(unless (responder-in? wv)
  (note "synthetic click did not focus the web view; using [window makeFirstResponder: wv]")
  (tellv win makeFirstResponder: wv))
(check "(4) focus can move into the web view" (responder-in? wv)
       (format "firstResponder class ~a" (class-name (first-responder))))
(note "racket/gui get-focus-window while the web view has focus: ~a"
      (send (hash-ref p 'frame) get-focus-window))
(define k0 (key-count))
(key! "q" 12)
(check "(4) keys typed then reach the page, not the editor"
       (and (wait-until (lambda () (last-message "key:")) 2.0)
            (equal? (last-message "key:") "q")
            (= k0 (key-count)))
       (format "page saw ~s, editor on-char count ~a -> ~a" (last-message "key:") k0 (key-count)))
(send (hash-ref p 'editor) focus)
(sleep/yield 0.1)
(check "(4) (send editor focus) takes first responder back" (responder-in? (send (hash-ref p 'editor) get-handle))
       (format "firstResponder class ~a" (class-name (first-responder))))
(note "racket/gui get-focus-window after (send editor focus): ~a"
      (send (hash-ref p 'frame) get-focus-window))
(define text0 (send (hash-ref p 'text) get-text))
(key! "x" 7)
(sleep/yield 0.3)
(check "(4) keys reach the editor again"
       (equal? (send (hash-ref p 'text) get-text) (string-append text0 "x"))
       (format "text ~s -> ~s" text0 (send (hash-ref p 'text) get-text)))
(check "(4) the app never became active (owner kept focus)"
       (or active-at-start (not (tell #:type _BOOL app isActive))))

;; Reload with new HTML while keeping the scroll position (live preview).
(post-js wv "window.scrollTo(0, 2000)")
(void (wait-until (lambda () (equal? (js-value wv "sy" "window.scrollY" 0.3) "2000"))))
(define y-before-reload (js-value wv "sy" "window.scrollY"))
(note "scrollY asked for 2000 by scrollTo after the wheel scroll: ~a" y-before-reload)
(write-page! 2)
(let ([before finished-navigations])
  (tellv wv reload)
  (void (wait-until (lambda () (> finished-navigations before)) 10.0)))
(let* ([t (js-value wv "h1" "document.getElementById('marker').textContent")]
       [y (js-value wv "sy" "window.scrollY")]
       [y2 (begin (sleep/yield 0.5) (js-value wv "sy" "window.scrollY"))])
  (check "(reload) [wv reload] shows the new file" (equal? t "Version 2") t)
  (note "scrollY after [wv reload]: ~a at didFinishNavigation, ~a 0.5 s later" y y2)
  ;; Finding: reload restores the position WebKit saved in its history item, which follows
  ;; user (wheel) scrolling, not a later window.scrollTo. Not reliable on its own.
  (note "=> [wv reload] ~a the pre-reload position ~a"
        (if (equal? y2 y-before-reload) "kept" "did NOT keep") y-before-reload))
(post-js wv "window.scrollTo(0, 2000)")
(void (wait-until (lambda () (equal? (js-value wv "sy" "window.scrollY" 0.3) "2000"))))
(write-page! 3)
(void (load! wv))
(let ([y (js-value wv "sy" "window.scrollY")])
  (note "scrollY right after loadFileURL: of the same URL: ~a" y))
(post-js wv "window.scrollTo(0, 2000)")
(check "(reload) loadFileURL: then scrollTo(saved) restores the position"
       (void (wait-until (lambda () (equal? (js-value wv "sy" "window.scrollY" 0.3) "2000")))))
(post-js wv "document.getElementById('marker').textContent='Version 4 (in place)'")
(check "(reload) in-place DOM update keeps scroll without navigating"
       (and (equal? (js-value wv "h1" "document.getElementById('marker').textContent") "Version 4 (in place)")
            (equal? (js-value wv "sy" "window.scrollY") "2000")))

;; (6) threads
(check "(6) module body / eventspace handler runs on the main OS thread" (main-thread?)
       (format "handler thread = current thread: ~a" (eq? (eventspace-handler-thread (current-eventspace)) (current-thread))))
(let ([seen #f])
  (sync (thread (lambda () (set! seen (main-thread?)) (post-js wv "window.webkit.messageHandlers.rackmac.postMessage('bg:ok')"))))
  (check "(6) a plain Racket thread is also on the main OS thread (CS green threads)" seen)
  (check "(6) a WebKit call from that Racket thread works"
         (wait-until (lambda () (member "bg:ok" messages)) 2.0)))
(check "(6) every ObjC callback (message handler, navigation delegate) ran on the main thread"
       (and (pair? callback-threads) (andmap values callback-threads))
       (format "~a callbacks" (length callback-threads)))

;; (5) close releases it; repeated open/close neither crashes nor leaks
((hash-ref p 'close!))
(check "(5) closing releases the web view"
       (wait-until (lambda () (collect-garbage 'minor) (= deallocs 1)) 5.0)
       (format "deallocs ~a" deallocs))

(define (rss-kb)
  (define o (open-output-string))
  (parameterize ([current-output-port o])
    (system* "/bin/ps" "-o" "rss=" "-p" (number->string (getpid))))
  (string->number (string-trim (get-output-string o))))

(define rss-samples '())
(for ([i cycles])
  (define q (open-pane))
  (load! (hash-ref q 'wv))
  (js-value (hash-ref q 'wv) "h1" "document.title")
  ((hash-ref q 'close!))
  (collect-garbage)
  (sleep/yield 0.05)
  (when (or (= i 0) (zero? (modulo (add1 i) 10)))
    (set! rss-samples (cons (list (add1 i) (rss-kb) (quotient (current-memory-use) 1024)) rss-samples))))
(check (format "(5) ~a open/close cycles without a crash, every view deallocated" cycles)
       (wait-until (lambda () (collect-garbage 'minor) (= deallocs (add1 cycles))) 5.0)
       (format "deallocs ~a of ~a" deallocs (add1 cycles)))
(note "(cycle RSS-KB Racket-heap-KB): ~a" (reverse rss-samples))

;; What happens if the production pane forgets the explicit cleanup: hide only.
(let ([q (open-pane)] [before deallocs])
  (load! (hash-ref q 'wv))
  (send (hash-ref q 'frame) show #f)
  (collect-garbage) (sleep/yield 0.5) (collect-garbage)
  (note "hide-only close (no removeFromSuperview/release): deallocs went ~a -> ~a" before deallocs)
  ((hash-ref q 'close!))
  (note "after the explicit cleanup: deallocs ~a"
        (begin (wait-until (lambda () (= deallocs (add1 before))) 3.0) deallocs)))

(delete-directory/files root #:must-exist? #f)
(printf "~a\n" (if (zero? failures) "ALL PASS" (format "~a FAILED" failures)))
(kill-thread watchdog)
(exit (if (zero? failures) 0 1))
