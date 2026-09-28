# Spike #422: an embedded web view (WKWebView) in a Rackmac pane

_Milestone E22.M1, epic E22 Publishing (#429). Prototype: `docs/spikes/webview-embed.rkt`. Tested 2026-09-28 on
macOS 26 (Darwin 25.6), Apple Silicon, Racket 9.3 [cs]._

## Verdict: GO (macOS), with conditions

A `WKWebView` can live inside a racket/gui window, beside an `editor-canvas%`, as a subview of an ordinary `panel%`.
It loads local HTML from `file://`, renders, follows window and pane resizes, scrolls, gives keyboard focus back to the
editor, and is released on close with no crash or measurable leak across 20 to 60 open/close cycles. Every check in
the script passes, repeatedly (7 full runs after the final fix, invisible and visible; about 35 runs in all). The production pane (#423)
is worth building. It is not free: WebKit needs Objective-C blocks, which `ffi/unsafe/objc` lacks, so the pane
carries a small hand-built block shim, and every callback must be written the way racket/gui's own are (below).

The three facts that decide it:

1. **The host view is real and stable.** `(send panel get-client-handle)` is a `RacketPanelView` (an `NSView`
   subclass). A `WKWebView` added with `addSubview:` and autoresizing mask 18 (width + height sizable) tracks it
   exactly: 600 -> 800 wide on a window resize, 800 -> 500 on a split change, with the page's `innerWidth` equal to the
   pane width.
2. **Everything runs on the main OS thread already.** In Racket CS all Racket threads of the main place run on the
   process's main thread; `[NSThread isMainThread]` was true in the module body, in a plain `(thread ...)`, and inside
   every one of ~25 WebKit callbacks per run. No dispatching to the main queue is needed.
3. **Close is clean when the pane cleans up explicitly.** A `WKWebView` subclass counting its own `-dealloc` saw 21 of
   21 (and 61 of 61) views freed; RSS wandered between 342 and 463 MB with no upward trend over 60 cycles, and the
   Racket heap stayed flat (~136-152 MB). Hiding the frame alone frees nothing: cleanup is the pane's job.

If a later finding turns this into NO-GO, the fallback is the one already planned: the built HTML opens in the
default browser, rebuilt on save (#421). The script also shows the "not macOS" path: it checks for WebKit and prints
`SKIP ... no embedded preview` instead of failing.

## How to run it

```
racket docs/spikes/webview-embed.rkt              # all checks, window invisible (alpha 0, ignores the mouse)
racket docs/spikes/webview-embed.rkt --visible    # same, window briefly on screen (never frontmost)
racket docs/spikes/webview-embed.rkt --cycles 60  # longer open/close loop (default 20)
```

It prints one `PASS`/`FAIL` line per check plus indented notes, exits 0 only when all pass, and takes about 15 s.
Nothing is judged by looking: title and text come back from the page, geometry is compared numerically, pixels come
from WebKit's own snapshot, focus is read from `[NSWindow firstResponder]`, and releases are counted in `-dealloc`.
It requires a no-front process global before racket/gui loads (as `tests/no-front.rkt` does), so the app never becomes
active, which the script also checks. Two watchdogs (a Racket thread, and a libc `alarm` for a main thread stuck in
a foreign call) and an `uncaught-exception-handler` that exits make sure no window or process is left behind.

## The calls that worked

| Step | Call |
|---|---|
| Load WebKit | `(ffi-lib "/System/Library/Frameworks/WebKit.framework/WebKit")`, then `import-class WKWebView WKWebViewConfiguration ...` |
| Host view | `(send panel get-client-handle)` -> `RacketPanelView` |
| Create | `[[WKWebViewConfiguration alloc] init]`; `[[WKWebView alloc] initWithFrame: hostBounds configuration: cfg]` (`_NSRect` defined locally as a cstruct of doubles) |
| Fit the pane | `setAutoresizingMask: 18`, `[hostView addSubview: wv]` |
| Load a file | `loadFileURL: [NSURL fileURLWithPath: page] allowingReadAccessToURL: [NSURL fileURLWithPath: dir]` |
| Know it loaded | navigation delegate (`define-objc-class`, protocol `WKNavigationDelegate`), `webView:didFinishNavigation:` |
| Read the title | `[wv title]` (no JS needed) |
| Run JS | `evaluateJavaScript: js completionHandler: nil` |
| Get values back | `[[cfg userContentController] addScriptMessageHandler: h name: @"rackmac"]`; JS posts `window.webkit.messageHandlers.rackmac.postMessage(String(x))`; `h` implements `userContentController:didReceiveScriptMessage:` |
| Keep links out | `webView:decidePolicyForNavigationAction:decisionHandler:`; call the handler block with 1 (allow) for `file:` URLs, 0 (cancel) otherwise |
| Snapshot | `takeSnapshotWithConfiguration: nil completionHandler: block` (our block) |
| Focus in / out | `[window makeFirstResponder: wv]`; back with `(send editor-canvas focus)` |
| Close | `stopLoading`, `setNavigationDelegate: nil`, `removeScriptMessageHandlerForName:`, `removeFromSuperview`, `release` (and release the handler and delegate) |

## Results, check by check

**(1) Local HTML renders.** The file:// page loads; `[wv title]` and the `<h1>` text (read through JS) match; a sibling
`style.css` in the read-access directory applies; a CSS file one level up, outside it, is blocked. WebKit's own
snapshot of the pane is 600 x 572 and its pixels are the page's red background (the values come back in the display
color space, about (212, 53, 76) for CSS rgb(200, 30, 60), so the check is "clearly that red", not exact).

**(2) Resizes.** Exact frame match to the host's bounds at start, after a window resize and after a split resize;
the page's `innerWidth` follows.

**(3) Scrolls.** A 10,280 px page in a 672 px pane scrolls from `window.scrollTo`, and from a scroll-wheel event
(built with `CGEventCreateScrollWheelEvent2` and handed straight to `[wv scrollWheel:]`, never posted to the window
server): 1500 -> 1900.

**(4) Focus.** Measured with the web view focused, a keyDown sent through the window reaches the page (`keydown` with
`q`) and not the editor; after `(send editor-canvas focus)` first responder is the editor's `RacketView` again, and the
next keyDown lands in the `text%` (`"" -> "x"`). The app never became active.

**(5) Close and repeat.** One close frees the view; 20 cycles free 20 more; 60 cycles also clean (see the RSS numbers
above). No crash in any run after the fixes below.

**(6) Threads.** See fact 2. What would be wrong: calling WebKit from another place or from an
`ffi/unsafe/os-thread` thread; those are not the main thread.

**Live reload keeping the scroll position.** Three ways tried:

| Method | Result |
|---|---|
| `[wv reload]` after rewriting the file | Shows the new file, and restores *a* scroll position: the one WebKit saved from the last user (wheel) scroll (1900), not a later `scrollTo(2000)`. Not dependable by itself. |
| `loadFileURL:` again, then `scrollTo(saved)` | Comes back at 0; reading `scrollY` first and scrolling after `didFinishNavigation` restores it exactly. Works. May flash the top for a frame (not seen: not looked at). |
| Replace content in place through JS (no navigation) | Scroll position untouched. Works, and is the smoothest for a live preview, but only for content changes a script can apply (body swap), not a new `<head>`. |

## Crashes, leaks and limits found

- **Callbacks need `#:async-apply`.** racket/gui waits for Cocoa events inside a blocking foreign call, and WebKit
  delivers callbacks from that wait. Without an `#:async-apply` Racket CS printed `non-async in callback during
  blocking` for the snapshot completion. The fix, as racket/gui does for `drawRect:`, is `#:async-apply` on every
  delegate method, message handler, block and `-dealloc` (the script uses `(lambda (thunk) (thunk))`: safe because
  the callbacks are short and touch no Racket synchronization). The warning has not appeared since.
- **One unexplained crash.** The very first run died with `invalid memory reference` in the `get-handle` probe,
  before any WKWebView, delegate or block existed, so no WebKit callback can explain it. Cause unknown; not
  reproduced in about 35 runs since. #423 should keep the stress loop as a regression test.
- **A synthetic click cannot focus the web view in a background test.** In a no-front process no window can become
  key (`makeKeyWindow` is refused), and a mouseDown sent to a non-key window only asks for key status. So the script
  hands focus over with `makeFirstResponder:` (what WKWebView's own mouseDown does). **A real click into the page and
  back into the editor has not been exercised**; it needs the owner at the keyboard (add it to the #283-style live
  check).
- **racket/gui's focus bookkeeping was not verifiable here.** `get-focus-window` was `#f` throughout, because the
  window is never active in a no-front run. Whether the editor gets `on-kill-focus`/`on-focus` when the page takes and
  gives back focus must be checked live.
- **Wheel scrolling was tested with one synthetic event**, not a trackpad gesture with phases and momentum.
- **Read-access scope has an exception.** Outside `$TMPDIR` the `allowingReadAccessToURL:` directory is enforced.
  Inside the per-user `$TMPDIR` (`/var/folders/.../T`) WebKit's content process read a file outside the granted
  directory anyway. Not a security boundary to rely on; build the preview in a directory of its own either way.
- **WebKit is already loaded by racket/gui.** `objc_lookUpClass "WKWebView"` is `#f` in plain `racket`, but racket/gui
  loads the Carbon umbrella framework (mred/private/wx/cocoa/procs.rkt), which pulls in Quartz -> ImageKit -> WebKit.
  So a lookup finds nothing only in plain `racket` without racket/gui. Load WebKit explicitly anyway.
- **Hiding is not closing.** A frame hidden without the cleanup keeps its web view (and its WebContent process) alive.
- **Memory.** A web view adds tens of MB to a ~135 MB Racket process (RSS ~380-460 MB with the GUI; the
  WebContent process is separate and not counted).
- **Occlusion.** With the window at alpha 0, results were identical to the visible run; WebKit may throttle timers and
  animation in an unseen pane, which a preview does not need.

## What the production pane (#423) must handle

1. **Availability.** macOS only: load WebKit with `#:fail`, and without it show no embedded preview (the browser
   preview of #421), never an error. Keep a setting to turn the pane off.
2. **A block shim** (about 20 lines, in the script): call WebKit's blocks (`decisionHandler`) through the invoke
   pointer at offset 16, and make our own as global blocks (`_NSConcreteGlobalBlock`, flag `1 << 28`, `'raw`
   memory, callback kept reachable). Such a block is never freed (WebKit may still hold it), so build each one
   once and reuse it; building one per call leaks 48 bytes and a callback each time. Every WebKit callback gets
   `#:async-apply`.
3. **Navigation policy.** Allow `file:` inside the build directory; send `http(s):` and `mailto:` to the default browser
   (`NSWorkspace openURL:`) and cancel. Without this a clicked link replaces the preview.
4. **Lifecycle.** Remove the message handler, clear delegates, `removeFromSuperview` and `release` when the pane
   closes, when its tab closes and when the window closes; hiding is not enough. One pane per window, reused
   across rebuilds rather than recreated.
5. **Reload that keeps the place.** Read `scrollY` (message handler), `loadFileURL:` the rebuilt page, `scrollTo` after
   `didFinishNavigation`; or swap the body in place when only content changed. Do not rely on `[wv reload]`.
6. **Focus.** Tab/Shift-Tab and Escape out of the page back to the editor; verify racket/gui's `on-focus` events and
   menu shortcuts (Cmd-S, Cmd-W) while the page has focus, live, with the owner.
7. **Appearance.** Follow light/dark: the page sees `prefers-color-scheme`; the Scribble CSS and the pane background
   (`setValue:@NO forKey:@"drawsBackground"` or a matching page background) should use the app's tokens.
8. **Safety** (docs/PUBLISHING-DESIGN.md principle 4). The HTML is the output of running a document's code; the
   page itself runs JavaScript in WebKit's sandboxed content process. Keep the read-access directory to the build
   output, outside `$TMPDIR`, and consider turning JavaScript off for untrusted builds (the script-based features
   above then fall back to `loadFileURL:` alone).
9. **Tests.** The dealloc-counting subclass and the numeric checks here port directly to `raco test` with
   `tests/no-front.rkt`; keep the 20-cycle loop.
10. **Live check** by the owner: a real click into the page and back, trackpad scrolling, text selection and copy
    from the page, dark mode.

## Confidence

High that embedding works and is stable on this Mac with Racket 9.3 CS: every behavior asked for was measured, not
assumed, over many runs. Medium on focus with a real mouse and on racket/gui's focus events, which a background
test cannot reach. Older macOS versions and x86_64 were not tested.
