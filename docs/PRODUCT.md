# Rackmac: what it is and who it is for

_Owner's direction of 2026-09-25. This supersedes earlier product framing in `DESIGN.md` §1 and §10 where they
differ. The roadmap that follows from it is [REPLAN.md](REPLAN.md); the interface is [UI-DESIGN.md](UI-DESIGN.md)._

## Who it is for

Tech-savvy professionals who write for a living but are not programmers: lawyers first, and people with the same
shape of work. They take notes all day (calls, meetings, research, decisions), turn some of those notes into
documents that leave the building as PDF, Word or Markdown, keep a lot of files in folders they did not choose
(OneDrive, SharePoint libraries, a firm's document system), and do a little automation on the side: a Python
script that renames exhibits, a Racket script that fills a template. They also review scripts and small programs
written by others and need to read them comfortably without being able to break them.

Their daily tools are Outlook, Chrome, SharePoint, Word for the web, Pages and Keynote. Their colleagues use
Word and PowerPoint and nothing else. Rackmac is the place they stay in as much as possible, and it has to make
the handoff to those colleagues painless in both directions.

## Jobs to be done

1. **Capture a note in seconds** and find it again in seconds, weeks later, by folder, title, tag, date or a word
   inside it.
2. **Write a document that reads like a document** while it is being written: headings, emphasis, lists, checkboxes,
   links, without seeing a wall of symbols, and without the file becoming anything other than plain text.
3. **Keep notes connected:** a call note links to the matter note, the matter note lists what links to it, a
   task in one note shows up in one place with every other open task.
4. **Move work to and from Word people:** paste from Word and keep the structure, import a `.docx` a colleague sent,
   export a note as `.docx` or PDF that looks right, copy a passage as rich text into an Outlook message.
5. **Read and review code safely:** open a Python or Racket script with coloring and line numbers, mark it
   read-only while reviewing, jot a note that points at line 42, and run only what was meant to run.
6. **Trust the tool:** nothing is lost on a crash, files changed elsewhere are noticed, everything is plain files
   that sync, back up and open anywhere.

## The default experience

**First launch.** A window that looks like a small office app: a toolbar of familiar buttons (New, Open, Save,
Undo, Cut, Copy, Paste, Find, and, for notes, Bold, Italic, Link, Heading, lists, checklist, Export), a
Library sidebar on the left, a start screen in the middle with three buttons (New Note, Add Folder…, Open…) and
a Recent list. Adding a folder is the only setup: the dialog suggests Documents, the OneDrive and SharePoint
folders the sync client already keeps on the Mac, and iCloud Drive. A "Getting started" note is one click away and
is itself a note with checkboxes to tick. Nothing asks about keyboard styles, languages or configuration files.

**A day of notes.** ⌘N makes a note in the selected folder. Typing `# Call with J. Roe` shows a heading, sized and
bold, with the `#` small and grey; ⌘B bolds a phrase; a line starting `- [ ]` becomes a checkbox that can be
clicked; `due 2026-09-30` on that line turns the date into something the Today view will list; `[[Roe v. Doe]]`
offers the matching note as you type and becomes a link you ⌘-click. The document is centered at a page width in a
proportional font. If you want to see or fix the raw Markdown, one button (or ⌥⌘U, Chrome's View Source key)
switches this document to plain source and back, and it remembers which you prefer. The sidebar shows Recent,
Folders, Tags, the note's Outline and what links here. ⇧⌘F searches every note in the Library. The file on disk is
ordinary Markdown the whole time; Word, Obsidian, GitHub or a text editor would show the same words.

**Sharing with a Word user.** File > Export > Word… writes a `.docx` (with the firm's template if one is set) and
reveals it; Export > PDF… writes a PDF directly from the formatted view (no extra software); ⌘P prints, and macOS's
print dialog saves a PDF too. A `.docx` that comes back is imported as a Markdown note with headings, lists and
tables intact. Pasting a few paragraphs from Word keeps their bold and bullets; Copy as Rich Text puts formatted
text into an Outlook reply. Conversion uses pandoc when it is installed (the app finds it; Export items explain
how to install it otherwise) and Racket's own PDF output always.

**Reviewing a script.** Opening `rename_exhibits.py` switches the document area to monospace with line numbers and
coloring; the Format group gives way to Run (Racket) or Run in Terminal (Python); "Review (read-only)" locks the
text, and "Add Note About This Line" starts a note that links back to the line.

## Principles

- **The file is the truth.** Every document is a plain file a colleague can open elsewhere; rendering is styles
  over the same characters, and a test proves the file round-trips byte for byte.
- **An office app, not an editor for programmers.** Proportional text, page width, Office and Pages shortcuts
  (⌘B, ⌘I, ⌘K, ⌥⌘1–3, ⇧⌘L, ⌘,), menus called File, Edit, Format, View. Code looks like code only when the
  document is code.
- **Nothing named after Emacs** in the default product; the flexibility stays underneath and returns as an
  opt-in preset later.
- **Markdown with Org's good ideas.** Notes are `.md` files; outline, folding, checkboxes and states, tags, dates
  and links are layered on syntax other tools also understand. No `.org` files.
- **Native controls, modern layout and color.** `racket/gui` controls and one token module, light and dark.
- **Calm and safe.** Status messages and an information bar instead of modal errors; autosave and recovery; a
  banner when a file changes on disk.
- **Optional tools stay optional.** pandoc is used when present, never required to write, search or make a PDF;
  a Racket library is preferred when it gives the better experience.
- **macOS first, pre-release forever.** Releases are `v0.x`; each phase ends in a tag with a one-line meaning.

## What it is not

- **Not a Word replacement.** No page layout, styles galleries, tracked changes or comments. Word stays the
  drafting and negotiation tool; Rackmac hands documents to it and takes them back.
- **Not an IDE, in this iteration.** Coloring, a gutter, read-only review, compare and a Run for Racket scripts;
  no debugger, terminal, language server or project system. The community may build an IDE on the extension API
  later; the default product does not become one.
- **Not integrated with Outlook, SharePoint or Microsoft 365 through APIs.** Synced folders, the clipboard,
  import and export are the whole integration. No Graph, no sign-in, no mail filing, no PDF viewer or annotation
  engine. Those ideas stay recorded in `DESIGN.md` §10 and in the icebox.
- **Not a cloud service.** No account, no telemetry, no server. Files live where the person put them.
- **Not an Emacs.** Not in names, keys or habits, until someone turns the preset on.

## How the programming power stays available without being in the way

Everything visible is built on the same registries an extension uses: commands with titles, help, icons,
shortcuts and applicability rules; toolbar, context-menu and status-bar items; Languages with their own keys and
settings; hooks; settings with contracts. The Format group, the Library sidebar and the Export items are ordinary
registrations, which is how they appear for notes and disappear for code.

For the person who wants more, the path is graded. **Settings…** (⌘,) is a generated dialog of every setting; its
"Edit as code" button opens `init.rkt`, a Racket file in the `rackmac` module language with a commented template.
A command defined there appears in the palette and can take a shortcut; a hook can run a script after every save.
Extensions are files in an `ext/` folder, each unloadable and reloadable without duplicates, each failing on its own
and reporting in plain language with a Details button. Racket scripts run with ⌘↩ in code documents and only there;
the Scratch Pad lives under Tools, not on the start screen. The command palette (⇧⌘P) lists every command by its
plain name, so power is one search away and never in the way of writing a note.
