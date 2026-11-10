# Editing

This page is about the Mac app. On iPhone and iPad, files open read-only: see [iPhone and iPad](iPhone-and-iPad.md).

## The editor

Code colors code in about twenty languages, among them Swift, Objective-C, C, C++, Rust, Go, JavaScript, TypeScript,
Python, Java, Kotlin, C#, Ruby, PHP, Dart, Scala, Lua, Haskell, PowerShell and shell scripts. It also colors JSON,
YAML, TOML, HTML and XML, CSS, SQL, Markdown, Makefiles and Dockerfiles.

The editor shows line numbers and highlights the current line. The status bar under it shows **Line:** and
**Col:**, and the size of the selection. Click it to go to a line.

### Saving

You don't need to save. Code saves a file about a second after you stop typing, and right away when you switch tabs,
close it, switch to another app or quit. It writes the file in its own encoding.

**File ▸ Save** (⌘S) does a bit more: it trims trailing whitespace on the lines you edited, and formats the file when
a formatter applies (see [Languages and Formatting](Languages-and-Formatting.md)). **File ▸ Save All** (⌥⌘S) saves
every open file. If a save fails, the status bar says **Couldn’t save** and why.

When a file changes on disk, the editor shows the new text, and you can undo back to yours.

### Typing helps

Code edits like Xcode's source editor:

- Brackets and quotes close as you type the opening one. Typing the closing one steps over it, and Backspace deletes
  the pair.
- Select text and type a bracket or quote to wrap the selection.
- Return after an unclosed `{` adds the `}`. A closing bracket on a blank line lines up with its opener.
- `///` comments continue on the next line when you press Return.
- Backspace in the indentation deletes one level. ⌘← goes to the indentation first, then to the start of the line.
- The matching bracket flashes. Double-click a bracket to select the whole block.
- You can scroll past the last line.

Use the **Editor** menu for **Toggle Comment** (⌘/), **Indent** (⌘]) and **Outdent** (⌘[). Tab and ⇧Tab indent and
outdent a selection.

Turn **Close brackets and quotes**, **Trim trailing whitespace**, the tab width and **Insert spaces when pressing Tab**
on or off in [Settings ▸ Editor](Settings.md#editor).

### View options

In the **View** menu:

- **Wrap Lines** (⌥Z): long lines wrap, indented past their indentation. It's on at first.
- **Line Numbers**.
- **Minimap** (⌃⇧⌘M): a small map of the file beside the editor, with `MARK:` sections as titles and the issues and
  breakpoints marked. Click or drag in it to scroll.
- **Zoom In** (⌘+), **Zoom Out** (⌘-) and **Actual Size** (⌃⌘0) change the font size.

Choose the theme (Xcode Light and Dark, or GitHub Light and Dark), the font and the size in
[Settings ▸ Editor](Settings.md#editor).

## Completion

The completion list opens while you type a name, or after a "." in languages that use one.

- Type more letters to narrow it. The letters you typed show in bold.
- Use ↑ and ↓ to choose, and Return or Tab to insert. Esc closes the list.
- **Editor ▸ Show Completions** (⌃Space) opens or closes it at any time.
- A function's arguments come in as placeholders. Press Tab and ⇧Tab, or **Editor ▸ Select Next Placeholder** (⌃/)
  and **Select Previous Placeholder** (⌃⇧/), to move between them. Click a placeholder to select it whole.

Suggestions come from the language server, from Code's own Swift model for Swift, and from the file's words and the
language's keywords. Turn off **Suggest completions** in Settings ▸ Editor to open the list only with ⌃Space.

## Find

- Press ⌘F to open the find bar over the current file.
- **Find in Project…** (⇧⌘F, or **View ▸ Show Find Navigator**, ⌘3) searches every file Open Quickly would list,
  including unsaved changes. Choose **Containing**, **Matching Word** or **Regular Expression**, and **Ignoring Case**
  or **Matching Case**. Results come in by file as they're found. Click one to open the file with the match selected.
  Text you selected in the editor becomes the search.
- **View ▸ Show Project Navigator** (⌘1) goes back to the files.

## Move around

- **Go ▸ Open Quickly…** (⌘O): before you type, it lists the files and projects you opened lately and your last
  search's results. Type part of a file's, a symbol's (a type, function, property or case, in every language) or a
  project's name. Matches don't need to be next to each other, and names you typed in full rank first. Qualify a
  symbol to jump straight to its declaration: `MessageView.body`, `Outer.Inner.value` or `Some::value`, and `Some.`
  lists everything declared in `Some` and its extensions. Press ⇧⌘. while it's open to include hidden files, listed
  after the others. Symbols come from Code's scanner, so they're off when it's turned off in Settings. Return opens
  the selected result, ⌘Return the first one in the second group (a matching project, say).
- **Go ▸ Go to Line…** (⌘L): type a line number, or `line:column`.
- **Go ▸ Reveal in Sidebar** (⇧⌘J): shows the current file in the sidebar.
- **Go ▸ Go Back** (⌃⌘←) and **Go Forward** (⌃⌘→), or the arrows above the editor, go through the places you've
  been.
- **View ▸ Hide Navigator** (⌘0) hides the sidebar, and **Show Navigator** brings it back.

## Jump to a definition

⌘-click a name, or put the caret in it and choose **Go ▸ Jump to Definition** (⌃⌘J). Hold ⌘ over a name to see it
underlined with its declaration.

Code asks up to three sources at once: its own scanner (fast guesses, any language), its Swift model (Swift only,
usually exact) and the language server. When the answer is sure and there's one place, Code jumps there. When it's a
guess, or there are several places, a menu under the name lists them; it fills in as slower sources answer, without
moving the rows you've already passed.

[Languages and Formatting](Languages-and-Formatting.md#jumping-and-completion) explains how to turn each source on or
off.

## Quick Help

⌥-click a name, or choose **Go ▸ Show Quick Help** (⌃⇧⌘/), to see its declaration and documentation in a popover.

## Issues in the editor

Errors and warnings from builds and language servers show on their lines: the line is tinted and the message shows at
its end. Click the message to see all of the line's messages. An issue that both the build and the language server
report counts once.

Turn **Show issues in the editor** and **Show issue messages** on or off in Settings ▸ Editor. For the list of every
issue, see [Run, Build and Test](Run-Build-and-Test.md#issues).
