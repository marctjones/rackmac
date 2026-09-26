# Rackmac Assistant: LLM support that controls, reviews and edits, on the person's terms

_Status: design proposal for the owner (2026-09-26), answering the direction "add LLM support to Rackmac that
automates the control of Rackmac and can be used to automate or review or control or edit any content in Rackmac."
It follows [PRODUCT.md](PRODUCT.md) (lawyers writing confidential notes; an office app), [REPLAN.md](REPLAN.md)
(releases and epics), [DEVELOPMENT.md](DEVELOPMENT.md) (rules) and [UI-DESIGN.md](UI-DESIGN.md) (native controls,
Skeptical Engineering). It proposes epic **E21 Assistant** in a new release **v0.6 Assistant** (§8). Nothing here
touches v0.3. API facts come from the Claude API reference current on 2026-09-26; items marked **verify** are the
first things the implementing session checks._

**Standing rules honored.** No new dependencies: the app talks to `https://api.anthropic.com/v1/messages` with
`net/http-client` + `openssl`, parses JSON with `json`, serves the automation endpoint with `web-server` and
`racket/tcp`, and stores the key with `/usr/bin/security`, all in the standard distribution. Native controls only;
no Emacs vocabulary; every issue adds tests that run with no network and no key; v0.x forever.

## 0. The short version

- **One assistant, four doors.** An **Assistant panel** (chat beside the document), **inline actions** on a
  selection (Rewrite, Summarize, Fix Grammar, Draft from Outline), **Review Document** (suggestions the person accepts
  or rejects, one undo step each), and **recipes** (saved prompts run from the palette, on one note or read-only
  over a Library folder). External agents such as Claude Code use a fifth door: a **localhost MCP endpoint**, off by
  default, that exposes the same tools under the same permissions.
- **The model never touches a document directly.** It gets a small set of typed tools over the command registry
  and the document buffers; every change arrives as a *proposal* (a range replacement or one of the token-based
  Markdown edits of MARKDOWN-DESIGN §4.4) that the app previews, the person approves, and `text%` records as one
  undo step. Commands run through `run-command` with `#:when` respected and a risk class deciding whether to ask.
- **Two gates, kept apart.** The *privacy gate* asks whether this content may leave the Mac at all (per-folder
  opt-in, visible indicator, redaction). The *permission gate* asks whether the model may act (read-only, ask per
  change, trusted for this session; guarded commands always ask).
- **Cost and choice.** `claude-opus-5` for editing and review, `claude-sonnet-5` for bulk and drafts,
  `claude-haiku-4-5` for titles and summaries; prompt caching laid out from day one; every choice a setting.
- **Testable without a key.** A recorded-response fake API server runs in the test suite; CI never sees a key.

## 1. Surfaces

### 1.1 Assistant panel

A `vertical-panel%` 320 px on the right of the tab area (mirroring the Library on the left), **View > Show
Assistant** `⌥⌘A` (a `#:checked` command like Show Library; ⌥⌘A is free in the defaults and passes
`shortcuts-test`). Top to bottom: a header row (`message%`: model name and geography, e.g. "Opus 5 · US", and the
privacy indicator of §4.2), the **transcript** (a read-only `text%` in an `editor-canvas%` styled with the same
tokens as notes: the person's turns in `text`, the assistant's in `text`, tool calls as one dim `text-2` line each,
"Stopped" and errors in `warning`/`error`), an **approval row** (hidden unless a proposal is pending: one sentence,
**Show Changes**, **Allow**, **Allow for This Session**, **Deny**, an InfoBar-shaped row inside the panel since
`racket/gui` has no popovers), a multi-line `text-field%` for the prompt with **Send** (`⌘↩` inside the field only)
and **Stop**, and a footer line with tokens used this session and the estimated cost. Empty state: "Ask about this
note, or choose an action from the Assistant menu. Nothing is sent until you press Send."

The conversation is per window and per session; **Assistant > New Conversation** clears it. Transcripts are saved
under `<config>/assistant/transcripts/` as `.rktd` (never in a Library folder, which may sync), a setting turns
that off.

### 1.2 Inline actions

An **Assistant** menu between Tools and Help (owner decision §9.5), the same commands in the context menu group
`assistant` and one toolbar button `assistant` (Workbench icon **verify**; letter tile otherwise). All are
`define-command`s in `rackmac/assistant/commands.rkt`, `#:when` the current document is prose and, for selection
actions, a selection exists:

| Command | What it sends | What comes back | Applies as |
|---|---|---|---|
| **Rewrite Selection…** | the selection, a one-line instruction asked in a small `dialog%` ("Shorter", "Plainer", "More formal", or typed) | a replacement | preview, then one `propose_edit` over the selection |
| **Summarize** | the selection or the document | a summary | inserted below the selection or at the top, after preview; **Copy** instead is offered |
| **Fix Grammar** | the selection or the document | a list of suggestions | the review flow of §1.3 |
| **Draft from Outline** | the document's headings (from `mdlib`) and any body text | body paragraphs under empty headings | one proposal per heading, review flow |
| **Ask About This Note** | opens the panel with the document as context | conversation | nothing until asked |

Each action is a **recipe** (§1.5) with a fixed system prompt, a fixed tool subset and a default model, so the panel,
the menu and the palette share one implementation. Nothing is applied without the preview.

### 1.3 Review Document

**Assistant > Review Document…** asks what to review for (a `choice%`: Clarity, Grammar and typos, Consistency of
names and dates, Missing information, Anything) and runs the `review` recipe. The model works through
`propose_edit` and `add_comment`. The panel shows a **Suggestions** list (`list-box%`): one row per suggestion,
"line 12 · replace · reason", with **Accept**, **Reject**, **Accept All**, **Reject All**; selecting a row
selects the range in the document and shows original and replacement in the approval row. Accept applies the edit
as one undo step; a stale range (the document changed since the proposal) is marked "outdated" and cannot be
accepted. Comments (no replacement) are listed the same way and are never written into the file: PRODUCT.md says
no tracked changes or comments in documents. **Save Review as Note** writes `<title> — Review.md` in the same folder
with each finding as a list item linking back (`[[title]]`, and the quoted line), which is the durable form for a
lawyer who wants the review on record.

### 1.4 Bulk operations over the Library

**Assistant > Run on Folder…** picks a recipe and a Library folder (or the Tags filter). Bulk runs are
**read-only**: the recipe reads each note and the result is one new note ("Summary of Matters — 2026-09-26.md",
with one section per note and a link back), never an in-place edit of files that are not open in a tab. That keeps
"the file is the truth" and the approval model intact: a person approves edits in a document they can see. Files are
sent one request per note (a note is one context; nothing needs cross-note context in v1); the setting
`assistant-bulk-mode` chooses **Now** (sequential, progress in the status message, Stop cancels) or **Overnight**
(Message Batches at half price, §5.7). Privacy gating applies per folder (§4.1); a folder that is not opted in is
refused before anything is read.

### 1.5 Recipes and automation

A recipe is a named prompt with a tool subset, a model, an effort and where its result goes (panel, replace,
insert, review, new note). Built-ins live in `rackmac/assistant/recipes.rktd`; the person's own live in
`<config>/assistant/recipes/*.rktd` (Assistant > Recipes… edits them in a generated dialog) and extensions define them
with `(define-recipe name #:prompt … #:tools '(…) #:model … #:result 'review)` from `rackmac/api`, with ownership
undo like every registry. Every recipe is a palette entry "Assistant: <name>" and can take a shortcut. A recipe can
be run on the current note, the selection, or a folder.

**Scheduling is out of scope.** Rackmac is not a service (PRODUCT.md): no daemon, no timer that sends client
material while nobody is looking. Power users can call `run-recipe!` from a hook in `init.rkt` (for example after
save); the permission gate still applies and the default product ships no such hook. The MCP endpoint (§3) is how
an external scheduler (a Claude Code routine, `launchd`) drives Rackmac when the person wants that.

## 2. The tool surface and the permission model

### 2.1 Tools

Thirteen tools, `strict: true`, `additionalProperties: false`, serialized sorted by name (cache stability, §5.4).
Document ranges are character offsets into the document's **source text** (`document-text`, snip-aware from
#292 `doc-text`), so they are the same in Formatted and Source views; every read returns a `version` (the buffer's
edit counter) that every proposal must echo, so a stale proposal is rejected instead of landing in the wrong place.

| Tool | Class | Input | Result |
|---|---|---|---|
| `list_commands` | read | `{query?}` | name, title, help, enabled-now, risk class |
| `run_command` | per class | `{name}` | ok, or "not available now" when `#:when` is false, or "denied" |
| `list_documents` | read | — | open documents: name, path, language, modified, current |
| `get_document` | read | `{doc?, start?, end?}` | text, version, language, length; a window of at most `assistant-max-read` characters (default 60,000) with "truncated" set |
| `get_selection` | read | — | text, start, end, version |
| `find_in_document` | read | `{doc?, pattern, regex?}` | matches with offsets and the line |
| `list_library` | read | `{folder?}` | notes with title, path, modified (opted-in folders only) |
| `search_library` | read | `{query}` | `lib-search` results (#306), opted-in folders only |
| `read_note` | read | `{path}` | text and version (opens nothing; reads the file) |
| `propose_edit` | edit | `{doc, version, start, end, text, reason}` | queued, applied, or rejected (stale/denied) |
| `propose_markdown_edit` | edit | `{doc, version, op, start, end, arg?}`; `op` ∈ toggle_strong, toggle_emph, set_heading, toggle_task, set_list, wrap_link | as above; edits computed by `mdlib-edits` (#323), so the diff touches only the tokens named |
| `add_comment` | read | `{doc, start, end, text}` | listed in the panel; never written to the file |
| `create_note` | guarded | `{folder, title, text}` | a new `.md` in an opted-in Library folder; always asks (it writes a file) |

`run_command` respects `command-enabled?` exactly as menus do. Commands that need input (Open…, Save As…, Insert
Link…) run their dialogs for the person, never for the model; the tool result says "asked the user".

### 2.2 Risk classes

`rackmac/assistant/policy.rkt` classifies commands in a table (not a `define-command` keyword: that would touch
`commands.rkt`, the collision point of HANDOFF; a `#:effect` keyword can be added at API 2):

- **read**: navigation, view toggles, find, show/hide panels, zoom, palette, Go to Line.
- **edit**: anything that changes document text (undo, redo, paste, formatting, sort lines, …) and `propose_*`.
- **guarded**: quit, close tab(s), save, save as, save all, reload from disk, revert, Move to Trash, New Note, run
  selection/document (executes code), reload extensions, customize with code, print, export, import, set line
  endings, and every command not in the table (extensions included).

### 2.3 Permission modes

Per session, chosen in the panel header (`choice%`) and per external client (§3.3):

| Mode | read | edit | guarded |
|---|---|---|---|
| **Read only** (default) | runs | denied | denied |
| **Ask** (set automatically when an inline action or Review starts) | runs | approval row with **Show Changes** (diff in the compare view #314, else a two-pane `dialog%`) | approval row, names the command |
| **Trusted for this session** | runs | applied at once as one undo step; listed in the transcript and the Activity log | approval row, always |

Guarded commands never run without a click, in any mode, from any client. "Allow for This Session" on an edit
switches to Trusted; on a guarded command it allows that one command. A denied tool returns `is_error: true` with
"The user declined" so the model can continue. Parallel tool calls are answered in one user message, in order.

### 2.4 Undo and the Activity log

Every applied proposal is wrapped in `begin-edit-sequence`/`end-edit-sequence` on the `text%` so ⌘Z removes it
whole; the transcript line says "Applied: replaced 42 characters at line 12 (⌘Z undoes)". Every tool call, its
decision (ran, asked, denied, stale) and its duration go to the Activity log with topic `assistant` (on the v0.5
loggers #341; `log-message` until then), plus the request id, model, tokens and cache hits per API call. The log
never contains document text.

## 3. External control: the automation endpoint

**Decision: an MCP server over Streamable HTTP on 127.0.0.1, inside the app, off by default.** Not a CLI, and not
stdio MCP, for the first release:

- A double-clicked GUI app cannot be a stdio MCP server (the client spawns the server process); it would need a
  bridge process that talks to the app over a socket anyway, so the socket is the primitive either way.
- Claude Code, Claude Desktop and other agents speak MCP natively and get typed tool schemas: `claude mcp add
  --transport http rackmac http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <token>"` (**verify** the
  header flag). A CLI would need the same tools plus a parser and its own docs, and a CLI can be written later as a
  thin MCP client script.
- The tools, the policy and the Activity log are the same modules as §2, so nothing is exposed twice.

### 3.1 Protocol

JSON-RPC 2.0 over HTTP POST at `/mcp` (`web-server`'s `serve` bound to `127.0.0.1` on a random free port).
Responses are `application/json` (the transport allows a plain JSON response instead of SSE; **verify** against
the current spec revision). Methods: `initialize`, `tools/list`, `tools/call`, `ping`; notifications are ignored.
Long-running approvals block the `tools/call` request until the person clicks (with a 120 s timeout returning
"pending; ask again"). No resources, no prompts in v1.

### 3.2 Security

Setting `automation-endpoint` (off by default; Settings… > Assistant > "Allow other apps on this Mac to control
Rackmac"). Turning it on generates a 32-byte token, writes `<config>/automation.rktd` (`port`, `token`) with mode
0600, and shows it once in a dialog with **Copy Command** (the `claude mcp add` line). Every request must carry
`Authorization: Bearer <token>`, come from a loopback peer, and carry no `Origin` or a loopback `Origin`/`Host`
(DNS-rebinding guard); anything else is 403 and logged. Token rotates on every enable. The listener stops when the
setting is turned off or the app quits.

### 3.3 Per-client trust

The first authenticated call from a new client name (from `initialize`) raises an InfoBar: "Claude Code wants to
control Rackmac" with **Read only**, **Ask me for each change**, **Trust for this session**, **Deny**. The choice
scopes to that client until quit and is shown in the status bar ("Automation: Claude Code (trusted)"). Without a
trusted mode an automation is useless, so the mode exists; guarded commands still ask (§2.3), and an optional
folder scope in the same InfoBar limits reads and `create_note` to one Library folder.

## 4. Privacy and trust for confidential material

### 4.1 Nothing leaves without opt-in

Setting `assistant-allowed-folders` (a list of Library folder paths; empty by default). Library sidebar folder
context menu: **Allow Assistant in This Folder** (checkable). A document outside an allowed folder (or untitled,
or a code file) triggers, on first use in a session, "Allow the Assistant to read *Call with J. Roe.md*?" with
**This document**, **This folder (remember)**, **Cancel**. `list_library` and `search_library` see opted-in folders
only, and the Library index is queried with a folder filter, so nothing about other matters leaks through search
results. Bulk runs refuse non-opted folders before reading.

### 4.2 The indicator

While a request is in flight the status bar shows a segment "Sending to Anthropic…" with the cloud icon in `accent`,
and the panel header names the model and geography. After the request the segment shows "Assistant: 3.2k tokens" for
ten seconds. The indicator is drawn, not only colored (RM-147). The transcript records exactly which documents were
sent in each turn ("Sent: Call with J. Roe.md (2,140 words)").

### 4.3 API key storage

The key lives in the login Keychain as a generic password (service "Rackmac", account "anthropic-api-key") through
`/usr/bin/security add-generic-password -U -s Rackmac -a anthropic-api-key -w <key>` and is read with
`find-generic-password -w`. Settings… > Assistant has a **Set API Key…** button (a `dialog%` with a password
`text-field%`; the Settings dialog gains an action-row kind, §7) and **Remove Key**. Two caveats, documented in the
issue: the key passes through `argv` for the instant the `security` command runs (a single-user Mac; **verify**
whether `-w` reads stdin when no value follows); and an unsigned `Rackmac.app` (#18, signing iceboxed #20) makes
Keychain re-prompt after every rebuild, so `ANTHROPIC_API_KEY` in the environment is honored for development and
tests, never written anywhere. The key is never a setting, never in `settings.rktd`, never in a transcript.

### 4.4 Redaction

Setting `assistant-redact` (off by default) runs `rackmac/assistant/redact.rkt` over everything sent: email
addresses, phone numbers, SSN/passport-like numbers, and a user list of names (`assistant-redact-names`) become
`⟦PERSON-1⟧`, `⟦EMAIL-1⟧` … with a per-turn map; replacements coming back are un-redacted before preview. The
transcript shows the redacted form. Pure module, tested on a corpus.

### 4.5 Retention, geography, local models

- **Retention.** Standard API retention applies unless the organization has zero-data-retention; setting
  `assistant-retention` (**Standard** / **Zero data retention (my organization has it)**) is informational except
  that under ZDR the model picker hides `claude-fable-5-1`, which requires 30-day retention and returns 400 on ZDR
  organizations. Help text states plainly that content is processed by Anthropic under the API terms and never used
  for training.
- **Geography.** Setting `assistant-inference-geo` (`us` / `global`, default `us`) is sent as the top-level
  `inference_geo` parameter on every request (Claude API only; availability table).
- **Local models.** Setting `assistant-base-url` (default `https://api.anthropic.com`) already lets a local proxy
  that speaks the Messages API serve the app with no new code; the transport is a `provider` struct (base URL,
  headers, request shaper) so a second provider shape can be added later without touching the loop. Not scheduled.
- **Server-side tools** (web search, fetch, code execution) are never sent: the request contains only our tools.

## 5. The agent loop in Racket

### 5.1 Modules

```
rackmac/assistant/http.rkt       POST /v1/messages via net/http-client + openssl; headers; retries; SSE stream reader
rackmac/assistant/sse.rkt        pure SSE/event parser -> message_start, content_block_*, message_delta, message_stop
rackmac/assistant/loop.rkt       messages, tool_use -> tool results, budgets, cancellation, cache layout, refusals
rackmac/assistant/tools.rkt      schemas (sorted) and implementations over the registry and buffers
rackmac/assistant/policy.rkt     risk table, modes, approval queue (a parameter answers it in tests)
rackmac/assistant/keychain.rkt   security CLI, env fallback
rackmac/assistant/redact.rkt     pure
rackmac/assistant/recipes.rkt    built-ins, user files, define-recipe
rackmac/assistant/review.rkt     suggestions model, staleness, apply as one undo step, Save Review as Note
rackmac/assistant/commands.rkt   the Assistant menu (define-command), required from app.rkt on its own line
rackmac/assistant/mcp.rkt        localhost MCP server
rackmac/assistant/batch.rkt      Message Batches: submit, persist ids, poll on launch
rackmac/ui/assistant-panel.rkt   the panel
rackmac/ui/diff-preview.rkt      two-pane preview until compare-view (#314) exists; then a thin wrapper
tests/assistant/fake-api.rkt     recorded-response server on 127.0.0.1 (no TLS)
tests/assistant/recordings/      *.rktd scripts: request matcher -> SSE events
```

### 5.2 Threads and cancellation

Each request runs in a `thread` under its own `custodian`. Tool implementations that touch `text%` or the window
run on the handler thread through `queue-callback` and return through a channel; the loop thread never touches GUI
objects. Streamed text reaches the transcript through `queue-callback` too. **Stop** (button, Esc in the panel,
`cancel-assistant` command) calls `custodian-shutdown-all`, which closes the TLS socket; the loop marks the turn
"Stopped" and drops the partial assistant message (a partial `tool_use` is never executed). Closing the window
cancels everything.

### 5.3 Request shape

`stream: true` always. `model`, `max_tokens` 16,000 (setting), `thinking` omitted (Opus 5 and Sonnet 5 then run
adaptive thinking; nothing is sent for other models), `output_config.effort` from the recipe (default `medium`;
`low` for summaries and titles), sent only when the model's `/v1/models` capabilities report `effort.supported`
(cached per model id by `as-models-refresh`, so the cheap path never gets a 400), `tools` (sorted, `strict: true`), `tool_choice` `auto` always (Fable 5.1 rejects `any`/`tool`),
`inference_geo`, `system` = one frozen block per recipe (no date, no document, no user name) with
`cache_control: {"type": "ephemeral"}`, and top-level `cache_control` for the growing tail. Dynamic context (today's
date, the document, the selection) goes in the first user turn of the conversation, never in `system`. Effort and
model are fixed for a conversation; changing either starts a new conversation (caches are model-scoped).
`eager_input_streaming` is off: our tool inputs are small and the server-validated block is simpler than a tolerant
parser.

### 5.4 Prompt caching layout

`tools` → `system` (breakpoint) → first user turn with the document → conversation tail (automatic breakpoint).
Tools and system are byte-stable across a session, so the breakpoint pays for itself on the second turn; the
document is cached through the tail. A test replays two requests through the fake server and asserts the second
request's prefix bytes equal the first's (the silent-invalidator check). The footer reports
`cache_read_input_tokens` so the person sees the effect; a "cache: 0" for several turns is logged as a warning.
Haiku 4.5's 4,096-token cache minimum means short bulk prompts do not cache; that is expected and noted.

### 5.5 Stop reasons, refusals, errors

- `end_turn`: done. `tool_use`: run the tools per policy, append results, continue; hard cap
  `assistant-max-tool-turns` (25) then stop with a message.
- `max_tokens` with a `tool_use` block: do not execute; retry once with `max_tokens` doubled; then report.
- `refusal`: show "Claude declined this request." and never execute that turn's tools. With `claude-fable-5-1` the
  request carries `fallbacks: "default"` and header `anthropic-beta: server-side-fallback-2026-07-01` (the scalar
  form's header; the array form uses the 06-01 header and mixing them is a 400); the transcript names the model
  that answered (`usage.iterations` / `fallback` blocks).
- HTTP 429, 529 and 5xx: exponential backoff 1, 2, 4, 8 s honoring `retry-after`, four attempts, then an error line
  with **Retry**. 401: "Your API key was not accepted" with **Set API Key…**. 400: the API's message, plainly.
  Network failure: one line, no modal.
- Budgets: `assistant-request-budget` (tokens for one Send across all its tool turns, default 100,000) stops that
  turn with "Budget reached" and offers **Continue**; `assistant-session-budget` (tokens, default 500,000) stops the
  session with a message; the estimated cost uses a price table setting (`assistant-prices`, per model, editable) because prices change faster than releases.

### 5.6 Testability

`assistant-base-url` and `assistant-api-key-source` (`keychain` / `env` / a parameter in tests) point the loop at
`tests/assistant/fake-api.rkt`: a `tcp-listen` server on 127.0.0.1 port 0 speaking enough HTTP/1.1 to serve
recorded SSE scripts, matching requests by recipe and by a hash of the last user turn, failing the test on an
unexpected request. Recordings are `.rktd` written by `tools/record-assistant.rkt`, which the maintainer runs with a
real key on scrubbed sample notes; a recording carries the request's `tools`+`system` bytes so the cache-prefix test
has ground truth. The approval queue and every dialog are parameters (DEVELOPMENT.md), so tests answer "Allow" or
"Deny" and assert through hooks, buffer text and undo. CI runs all of it with no key.

### 5.7 Message Batches (bulk, Overnight)

`POST /v1/messages/batches` with one request per note (no tool loop in a batch; bulk recipes are single-shot by
design), ids persisted in `<config>/assistant/batches.rktd`, polled on launch and every ten minutes while the app
runs; results land in the summary note when complete (within 24 h; an expired batch is reported). `fallbacks` is not
accepted on Batches, so Overnight never uses Fable.

## 6. Model choice per feature

| Feature | Default model | Effort | Why |
|---|---|---|---|
| Panel conversation, Rewrite, Draft from Outline, Review | `claude-opus-5` | medium | edits to a lawyer's text need the strongest judgment at Opus pricing; caching keeps the multi-turn cost down |
| Fix Grammar | `claude-sonnet-5` | low | many small suggestions; near-Opus quality at lower cost |
| Summarize, Ask About This Note | `claude-sonnet-5` | medium | reading, not writing to the file |
| Titles, tags, classification (recipes that produce a word or a line) | `claude-haiku-4-5` | — | fastest and cheapest; no thinking |
| Bulk Now | `claude-sonnet-5` | low | per-note, unattended |
| Bulk Overnight | `claude-sonnet-5` via Batches | low | 50% off every token |
| Optional "most capable" | `claude-fable-5-1` | medium | user-selectable when not ZDR; refusals fall back server-side |

Settings: `assistant-model`, `assistant-quick-model`, `assistant-bulk-model`, `assistant-effort`, and a per-recipe
override. The picker lists the aliases above (only IDs from the catalog); **Refresh** calls `GET /v1/models` to show
what the key can use. Model ids are settings, so a new model needs no release.

## 7. What must change in the codebase first

1. **Risk table, not a keyword** (§2.2): `policy.rkt` owns it, so `commands.rkt` is untouched; unknown = guarded.
2. **`doc-text` (#292)** must land before `get_document`, or the model reads snip placeholders in Formatted view.
3. **`mdlib-edits` (#323)** is the basis of `propose_markdown_edit`; it is in flight for v0.3.
4. **InfoBar (#259)** carries the external-client trust prompt and the privacy prompt outside the panel.
5. **Settings dialog** needs an action-row kind (a button that opens a dialog) for Set API Key…; `define-setting`
   itself is unchanged (the key is not a setting).
6. **Loggers (#341)** give the Activity log its `assistant` topic; `log-message` works until then.
7. **`app.rkt`** gains one require line per new module; `vocab-test` gains the new command symbols; `shortcuts-test`
   sees `⌥⌘A`; `menu-snapshot-test` gains the Assistant menu.
8. **Bundle check (#286)**: **verify** that `raco distribute` ships the `openssl` native libraries so HTTPS works
   from `Rackmac.app` on a Mac without Racket.
9. `compare-view` (#314) is optional: `diff-preview.rkt` stands in and becomes a wrapper when #314 lands.
10. **UI-DESIGN.md** follow-up: the window tree (§2) gains the right-hand Assistant panel and the module list (§5.2)
    gains `assistant-panel.rkt` and `diff-preview.rkt`; the `as-panel` issue carries that edit.

## 8. Epic E21 Assistant, release v0.6

**Epic number.** E20 (#350) is the highest; **E21** is free.

**Release.** A new phase **v0.6 Assistant** after v0.5 Code review; later phases shift by one: v0.6 Workspace → v0.7,
v0.7 Open → v0.8, v0.8 Emacs preset → v0.9 (still v0.x). Why not earlier: E21 depends on v0.4's `doc-text`, InfoBar
and Library index/search, and benefits from v0.5's loggers and compare view; nothing in E21 is a dependency of v0.3
or v0.4, so v0.3 First notes is untouched. Why not later: the owner's direction, and every milestone below ends in
something a person uses. The pure modules of M1 (transport, SSE, keychain, redact, fake server, recordings) have no
GUI or Library dependency and can be built in their own lane during v0.5 without collisions.

REPLAN §1 table, revised rows:

| Tag | Theme | Epics |
|---|---|---|
| **v0.6.0 Assistant** | Ask, edit with approval, review, recipes over the Library; Claude Code can drive Rackmac through a localhost endpoint that is off by default. | E21 |
| v0.7.0 Workspace | as v0.6 today | E9, E7, E5.M2–M3, E2.M2 |
| v0.8.0 Open | as v0.7 today | E10, E11, E20 (rest) |
| v0.9.0 Emacs preset | as v0.8 today | E13 |

**Lane.** A new lane **A, assistant**: `rackmac/assistant/`, `rackmac/ui/assistant-panel.rkt`,
`rackmac/ui/diff-preview.rkt`, `tests/assistant/`, `tools/record-assistant.rkt`. Shared files it touches, one line
each: `app.rkt`, `tests/vocab-test.rkt`, `tests/menu-snapshot-test.rkt`, `docs/`. The Settings-dialog action row
(`as-settings-action-row`) is the one change to a shared module and goes first.

### 8.1 Milestones

| Milestone | A person can… | Issues |
|---|---|---|
| **E21.M1 Ask about this note** | set a key, opt a folder in, open the panel, ask questions about the open note and the Library's commands, see the indicator, the tokens and the Activity log; stop a request | `as-settings-action-row`, `as-keychain`, `as-settings`, `as-sse`, `as-http`, `as-fake-api`, `as-loop-read`, `as-tools-read`, `as-policy-read`, `as-privacy-gate`, `as-panel`, `as-indicator`, `as-activity`, `as-recordings-1`, `as-docs-1` |
| **E21.M2 Edits you approve** | Rewrite, Summarize, Draft from Outline with a preview; approve, deny, trust for the session; undo any change with ⌘Z; run commands by asking | `as-policy-modes`, `as-tools-edit`, `as-diff-preview`, `as-run-command`, `as-recipes-core`, `as-inline-actions`, `as-redact`, `as-recordings-2` |
| **E21.M3 Claude Code drives Rackmac** | turn the endpoint on, paste one command into Claude Code, and have it read, edit (with approval) and run commands under a chosen trust level | `as-mcp-server`, `as-mcp-security`, `as-mcp-trust`, `as-mcp-docs`, `as-mcp-live` |
| **E21.M4 Review Document** | ask for a review, walk the suggestions, accept or reject each, save the review as a note; Fix Grammar | `as-review-model`, `as-review-panel`, `as-review-note`, `as-fix-grammar`, `as-recordings-3` |
| **E21.M5 Library and recipes** | run a recipe on a folder and get a summary note; write and share recipes; run bulk work overnight at half price | `as-tools-library`, `as-recipes-user`, `as-recipes-api`, `as-bulk-now`, `as-batches`, `as-models-refresh`, `as-docs-2` |

Each milestone closes with a `v0.6.0-alpha.K` tag and a Fable review of delivered-versus-acceptance, as HANDOFF
does for v0.3.

### 8.2 Issues

Sizes: S under half a day, M one to two days, L three to five. Every acceptance criterion includes tests that run
with no network and no key (`tests/assistant/*-test.rkt` through the fake server or pure modules). "Model" is the
implementing model: **Opus 5.5** where correctness propagates or design judgment is needed, **Sonnet 5** for
spec-driven modules with crisp acceptance, **Haiku 4.5** for mechanical work, **lead** for interactive testing and
anything needing a real key.

#### E21.M1 Ask about this note

| Key | Title | Size | Acceptance | Depends | Model |
|---|---|---|---|---|---|
| `as-settings-action-row` | Settings dialog: an action row (`#:kind 'action`, a button with a title and a thunk) so a category can hold Set API Key… / Remove Key; sequenced after (or merged into) #95/#97/#98, which touch the same file in v0.5 | S | row renders unshown; thunk runs on `command`; existing rows unchanged; `settings-dialog-test` extended | #291, #95 | Sonnet 5: contained UI change |
| `as-keychain` | `keychain.rkt`: set/get/delete the key through `/usr/bin/security`; `ANTHROPIC_API_KEY` fallback; `api-key-source` parameter | S | with the CLI stubbed (a parameter naming the executable) set→get→delete round-trips; env fallback wins only when Keychain is empty; key never logged; the argv/stdin question answered in the issue | — | Sonnet 5: small, well specified |
| `as-settings` | All `assistant-*` settings of §4–§6 (models, effort, budgets per request and per session, prices, folders, redaction, retention, geography, base URL, transcripts) with contracts, choices, docs, category "Assistant"; `automation-endpoint` off; model choices from the catalog; Set API Key… and Remove Key rows | S | every setting has a row; ZDR hides Fable in the picker; `settings-test` extended | `as-settings-action-row`, `as-keychain` | Sonnet 5: declarative |
| `as-sse` | `sse.rkt`: pure SSE parser producing typed events; accumulates `text_delta` and `input_json_delta` per block; strict JSON at `content_block_stop` | S | corpus of recorded streams incl. split chunks, CRLF, comments, multi-block tool_use; malformed JSON yields an error event, never an exception | — | Opus 5.5: everything downstream trusts it |
| `as-http` | `http.rkt`: `post-messages` over `net/http-client` with TLS, headers (`x-api-key`, `anthropic-version`, optional beta), streaming body to `sse.rkt`; retry policy of §5.5; provider struct with base URL | M | against the fake server: 200 stream, 429 with `retry-after`, 529 ×3 then 200, 401, 400 body surfaced; cancellation closes the socket within 100 ms; no real network in tests | `as-sse`, `as-fake-api` | Opus 5.5: retries, cancellation and streaming interact |
| `as-fake-api` | `tests/assistant/fake-api.rkt`: loopback HTTP/1.1 server serving `.rktd` recordings (request matcher → status, headers, SSE events or JSON), failing on unexpected requests; helper `with-fake-api` | M | serves streams chunked at arbitrary boundaries; records the raw request bytes for prefix assertions; runs in CI on port 0 | — | Opus 5.5: the test bed every other issue stands on |
| `as-loop-read` | `loop.rkt`: conversation state, request shaping of §5.3, cache layout of §5.4, stop-reason handling of §5.5, tool dispatch with parallel results in one user message, custodian per request, budgets, `queue-callback` bridge | L | recorded conversations replay end to end; second request's tools+system bytes equal the first's; refusal turn executes no tools; `max_tokens` retry once; the request budget stops a Send mid-loop and the session budget stops the session; Stop mid-stream leaves no partial message | `as-http`, `as-tools-read` | Opus 5.5: the core |
| `as-tools-read` | `tools.rkt`: schemas (sorted, strict) and implementations of the read tools (`list_commands`, `run_command` for class read only, `list_documents`, `get_document` with version and window, `get_selection`, `find_in_document`) | M | schemas validate against a JSON-schema subset checker in tests; `get_document` returns `document-text`; version changes on edit; `run_command` on a `#:when`-false command returns "not available now"; all through the hidden window | #292 | Opus 5.5: offsets and versions must be exact |
| `as-policy-read` | `policy.rkt`: risk table of §2.2 covering every built-in command (test asserts coverage), unknown = guarded; Read-only mode; approval queue as a parameter | S | every registered command classified; a new unclassified command fails the coverage test | — | Sonnet 5: a table with a test |
| `as-privacy-gate` | `assistant-allowed-folders`, sidebar context item **Allow Assistant in This Folder**, the per-document prompt (a parameter), refusal before any read | M | unopted document is refused without a prompt when the parameter says Cancel; "This folder (remember)" persists; code files always ask; tests through the hidden window and settings | `as-settings`, #273 | Sonnet 5: crisp rules |
| `as-panel` | `rackmac/ui/assistant-panel.rkt`: the panel of §1.1, `toggle-assistant` `⌥⌘A` with `#:checked`, transcript styling on tokens, Send/Stop, mode `choice%`, footer | L | built unshown; Send runs a recorded conversation and the transcript text matches; Stop cancels; hidden state persists; keyboard reachable (Tab order); `shortcuts-test`, `vocab-test`, `menu-snapshot-test` updated | `as-loop-read`, #333 | Opus 5.5: the largest new surface, layout judgment |
| `as-indicator` | Status segment "Sending to Anthropic…"/"Assistant: N tokens" with the cloud icon; panel header model + geography; transcript "Sent:" lines | S | segment appears during a replayed request and clears after; painted to a `bitmap-dc%` in the test | `as-loop-read` | Sonnet 5: follows status-bar patterns |
| `as-activity` | Every tool call, decision, API call (id, model, tokens, cache reads) to the Activity log with topic `assistant`; transcripts saved to the config dir (setting) | S | log lines present after a replay; no document text in the log (test greps) | `as-loop-read` | Sonnet 5: mechanical |
| `as-recordings-1` | `tools/record-assistant.rkt` and the M1 recordings (conversation, refusal, 429, cancellation) on scrubbed sample notes | S | recordings committed; the recorder scrubs key and ids; documented | `as-fake-api` | lead: needs a real key |
| `as-docs-1` | `docs/ASSISTANT.md` (this document's user-facing half), Help > Assistant note, README section; cheat sheet regenerated | S | drift tests pass | `as-panel` | Haiku 4.5: documentation from a spec |

#### E21.M2 Edits you approve

| Key | Title | Size | Acceptance | Depends | Model |
|---|---|---|---|---|---|
| `as-policy-modes` | Ask and Trusted modes; approval row in the panel (Show Changes, Allow, Allow for This Session, Deny); guarded always asks; denied results are `is_error` "The user declined" | M | mode matrix of §2.3 tested cell by cell with the approval parameter; Trusted never runs a guarded command | `as-policy-read`, `as-panel` | Opus 5.5: the safety core |
| `as-tools-edit` | `propose_edit`, `propose_markdown_edit` (via `mdlib-edits`), `add_comment`; staleness by version; apply as one undo step | M | stale version rejected; one ⌘Z removes a multi-range proposal; markdown ops touch only the named tokens; offsets valid in both views | `as-tools-read`, #323 | Opus 5.5: correctness propagates |
| `as-diff-preview` | `rackmac/ui/diff-preview.rkt`: two-pane `dialog%` (original / proposed, changed lines in `match`) from a pure line-diff; becomes a wrapper over #314 when it lands | M | pure diff tested on a corpus; dialog built unshown; Accept/Cancel through a parameter | — | Sonnet 5: bounded UI with a pure core |
| `as-run-command` | `run_command` for edit and guarded classes through the policy; dialogs run for the person; results describe what happened | S | `quit` never runs without approval in any mode; `bold` runs in Trusted; "asked the user" for dialog commands | `as-policy-modes` | Sonnet 5: glue with tests |
| `as-recipes-core` | `recipes.rkt`: recipe struct, built-ins `.rktd` (rewrite, summarize, draft, ask), palette entries "Assistant: …", `run-recipe!` on document/selection | M | each built-in registers a command with `#:when`; palette lists them; a recipe run replays its recording | `as-loop-read` | Sonnet 5: data-driven |
| `as-inline-actions` | Assistant menu, context group, toolbar button; Rewrite Selection… dialog; Summarize (insert/copy); Draft from Outline (per-heading proposals) | M | menu appears for prose only; each action replays and lands as proposals; icons added; `menu-snapshot-test` | `as-recipes-core`, `as-tools-edit` | Sonnet 5: crisp acceptance |
| `as-redact` | `redact.rkt` and `assistant-redact*` settings; un-redaction of replacements | S | corpus round-trips; names list case-insensitive; transcript shows redacted form | `as-loop-read` | Sonnet 5: pure |
| `as-recordings-2` | Recordings for rewrite, summarize, draft, denied edit, stale edit | S | committed and replayed by the M2 tests | `as-recordings-1` | lead: real key |

#### E21.M3 Claude Code drives Rackmac

| Key | Title | Size | Acceptance | Depends | Model |
|---|---|---|---|---|---|
| `as-mcp-server` | `mcp.rkt`: listener on 127.0.0.1 (**verify** that `web-server`'s `serve` reports the port it bound when given 0; otherwise pick a free port first and retry on in-use, or build on `racket/tcp` like `fake-api.rkt`); JSON-RPC `initialize`, `tools/list`, `tools/call`, `ping`; same `tools.rkt` and `policy.rkt`; blocking approvals with timeout | L | an in-test MCP client over `net/http-client` lists and calls tools; a denied call returns the MCP error shape; `initialize` reports the tool set; server stops on setting off | `as-tools-edit`, `as-policy-modes` | Opus 5.5: protocol correctness and threading |
| `as-mcp-security` | Token generation, `automation.rktd` 0600, bearer check, loopback peer, Origin/Host guard, rotation on enable, 403 logging; the Copy Command dialog | M | wrong token 403; non-loopback Origin 403; file mode asserted; token rotates | `as-mcp-server` | Opus 5.5: security boundary |
| `as-mcp-trust` | Per-client InfoBar (Read only / Ask / Trust / Deny), folder scope, status segment "Automation: <client> (mode)" | M | first call raises the InfoBar (parameter in tests); scope blocks `read_note` outside the folder; Deny returns an error to every later call from that client | `as-mcp-security`, #259 | Sonnet 5: follows the policy matrix |
| `as-mcp-docs` | `docs/AUTOMATION.md`: enabling, the `claude mcp add` line, trust levels, what an agent can and cannot do; a sample Claude Code prompt | S | reviewed; linked from Help | `as-mcp-trust` | Haiku 4.5: documentation |
| `as-mcp-live` | Live check: Claude Code connects to a running Rackmac, reads the open note, proposes an edit, the person approves; findings filed | S | checklist ticked in the issue; the header flag and JSON-response transport question (**verify** items of §3) answered | `as-mcp-docs` | lead: interactive |

#### E21.M4 Review Document

| Key | Title | Size | Acceptance | Depends | Model |
|---|---|---|---|---|---|
| `as-review-model` | `review.rkt`: suggestions (range, original, replacement, reason, kind), staleness tracking across edits, accept/reject/all, one undo step per accept | M | suggestions outdated after an overlapping edit; accept order independent; property test over random edits | `as-tools-edit` | Opus 5.5: offset bookkeeping under edits |
| `as-review-panel` | Suggestions `list-box%` in the panel, selection highlights the range, buttons, Review Document… dialog with the focus `choice%` | M | built unshown; row selection moves the caret; keyboard reachable | `as-review-model`, `as-panel` | Sonnet 5: bounded UI |
| `as-review-note` | Save Review as Note: `<title> — Review.md` next to the note with linked findings | S | file content golden test; link resolves through `[[…]]` | `as-review-model`, #304 | Sonnet 5: small |
| `as-fix-grammar` | Fix Grammar recipe on Sonnet 5, low effort, result kind review | S | replays into suggestions; `#:when` prose | `as-review-panel` | Sonnet 5 |
| `as-recordings-3` | Recordings for review and grammar | S | committed | `as-recordings-2` | lead |

#### E21.M5 Library and recipes

| Key | Title | Size | Acceptance | Depends | Model |
|---|---|---|---|---|---|
| `as-tools-library` | `list_library`, `search_library` (folder-filtered `lib-search`), `read_note`, `create_note` (guarded) | M | non-opted folders invisible in results; `create_note` asks; tests over a small Library | #302, #306, `as-privacy-gate` | Sonnet 5: over existing index APIs |
| `as-recipes-user` | User recipes in `<config>/assistant/recipes/`, Assistant > Recipes… generated dialog (name, prompt, tools, model, effort, result); import/export a recipe file | M | round-trip; a bad file is reported, never fatal; palette updates live | `as-recipes-core` | Sonnet 5 |
| `as-recipes-api` | `define-recipe` and `run-recipe!` on `rackmac/api` with `register-undo!` | S | an extension's recipe unloads cleanly; `init-test` extended | `as-recipes-user` | Sonnet 5 |
| `as-bulk-now` | Run on Folder… (recipe, folder or tag), sequential requests on the bulk model, progress in the status message, Stop, summary note | M | replay over three notes yields the golden note; refuses non-opted folders; Stop leaves a partial note marked | `as-tools-library` | Sonnet 5: composition |
| `as-batches` | `batch.rkt`: submit, persist ids, poll on launch and by timer, land results, expiry reporting; Overnight mode | M | fake server serves create/poll/results; ids survive restart; no Fable in batches | `as-bulk-now`, `as-fake-api` | Opus 5.5: persistence across launches |
| `as-models-refresh` | Refresh button calling `GET /v1/models`; picker shows what the key can use; catalog aliases pinned as defaults | S | recorded models list; unknown ids stay selectable with a hint | `as-settings` | Haiku 4.5: mechanical |
| `as-docs-2` | ASSISTANT.md recipes and bulk sections; Getting Started note gains "Ask the Assistant about this note" | S | drift tests | `as-bulk-now` | Haiku 4.5 |

**Count:** 15 + 8 + 5 + 5 + 7 = **40 issues**; 3 L, 17 M, 20 S; about six to seven weeks for one lane, less in
parallel.

### 8.3 Parallel lanes (files never shared)

- **Lane A1 (pure, can start during v0.5):** `as-sse` → `as-http` with `as-fake-api`; `as-keychain`; `as-redact`;
  `as-policy-read`. Files: `rackmac/assistant/{sse,http,keychain,redact,policy}.rkt`, `tests/assistant/`.
- **Lane A2 (settings and privacy):** `as-settings-action-row` → `as-settings` → `as-privacy-gate`. Files:
  `rackmac/ui/settings-dialog.rkt`, `rackmac/assistant/settings.rkt`, sidebar context item.
- **Lane A3 (after A1):** `as-tools-read` → `as-loop-read` → `as-panel` → `as-indicator`, `as-activity`.
- **M2:** `as-diff-preview` and `as-recipes-core` in parallel with `as-policy-modes` → `as-tools-edit` →
  `as-run-command` → `as-inline-actions`.
- **M3 and M4 in parallel:** `mcp.rkt` and `review.rkt` share nothing; `as-mcp-trust` and `as-review-panel` both
  touch the panel only through its public functions.
- **M5:** `as-tools-library` and `as-recipes-user` in parallel; `as-batches` after `as-bulk-now`.
- Recordings and docs (lead, Haiku) run alongside any lane.

## 9. Non-goals

- No autonomous edits: nothing changes a document without a preview and a click, except in a mode the person chose
  for this session, and then only in documents they can see.
- No in-place edits of files not open in a tab; bulk work writes new notes.
- No scheduling, no daemon, no background sending.
- No tracked changes or comments written into `.md` files (PRODUCT.md).
- No server-side tools (web search, fetch, code execution), no images, no voice, no Managed Agents.
- No Windows work (label `platform:windows` for the Credential Manager equivalent later).
- No cloud sync of transcripts, no telemetry, no Rackmac account.
- No fine-tuning, no evaluation harness beyond recordings, no "AI" branding in the product name.

## 10. Decisions for the owner

1. **Release.** v0.6 Assistant as a new phase (recommended, §8), or pull E21.M1 into v0.5 alongside Code review
   with `diff-preview.rkt` standing in for the compare view? Recommended: v0.6, with lane A1 starting during v0.5.
2. **Default model.** `claude-opus-5` for editing and review (recommended: the audience's text deserves it, and
   caching keeps a conversation cheap) or `claude-sonnet-5` everywhere for cost?
3. **Trusted-for-this-session mode.** Keep it (recommended: automation is useless without it; guarded commands
   still ask) or ship Ask-only in v0.6?
4. **Web search.** Never (recommended for confidential material) or an opt-in setting later?
5. **Menu placement.** A top-level **Assistant** menu (recommended: discoverable, matches Word's Copilot placement)
   or under Tools?
6. **Key storage.** Keychain via the `security` CLI with the argv caveat (recommended) or environment variable only
   until the app is signed?
7. **Endpoint protocol.** MCP only (recommended) or also a plain JSON-RPC surface for a future CLI?
8. **Batches.** Ship Overnight mode in M5 (recommended: half price for the one unattended workload) or defer.
9. **Local models.** Defer (recommended; the base-URL setting already admits a Messages-API proxy).
10. **Name.** "Assistant" in the UI with the model named in the panel header (recommended) or "Claude"?
