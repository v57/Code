# Code

A folder-based code editor for macOS, in the style of VS Code and Zed: open a
folder, browse it in the sidebar, edit files in tabs with syntax highlighting.

Two parts, like `../Markdown`: the libraries (this package) and a thin
SwiftUI app (`Code.xcodeproj`, sources in `Code/`).

Libraries

  Each library can be used on its own; CodeKit is all of them plus what
  connects them. Future libraries (language servers, code navigation,
  linting) join the same way.

    CodeHighlighting   languages, incremental highlighter, bracket matching,
                       themes (platform-neutral, no dependencies)
    CodeWorkspace      file tree, file watching, Quick Open index, text
                       documents with autosave, tabs and sessions (neutral)
    CodeEditor         the AppKit editor: CodeTextView, line numbers,
                       CodeEditorScrollView, SwiftUI CodeTextEditor(text:)
    CodeKit            re-exports the three; CodeEditorView(document:) edits a
                       workspace document (autosave, reload, ⌘S trimming)

Layout

    Sources/CodeHighlighting/   CodeScanner, LanguageSpec, LanguageCatalog(+Formats),
                                SyntaxHighlighter, LineIndex, Language, Delimiters,
                                CodeColorScheme, EditorTheme
    Sources/CodeWorkspace/      FileTree, FileNode, FileWatcher, FileIndex,
                                FuzzyMatch, TextDocument, Workspace
    Sources/CodeEditor/         CodeTextView (+EditAssists), LineNumberRuler,
                                CodeEditorScrollView, CodeTextEditor,
                                EditorConfiguration
    Sources/CodeKit/            CodeKit (re-exports), CodeEditorView
    Code/                       the app
      CodeApp.swift, CodeCommands.swift, AppState.swift, AppDelegate.swift
      Welcome/, Workspace/, Settings/

Architecture

  Highlighting is the code half of Md's highlighter (CodeScanner,
  LanguageSpec, LanguageCatalog, CodeColorScheme keep Md's public API, so Md
  can import CodeKit for fenced code later), extended with per-line state:
  `SyntaxHighlighter` stores the state each line starts in and rescans only
  edited lines plus the lines whose start state changed, in batches when an
  edit opens a long comment. Data, markup and build formats (JSON, YAML, TOML,
  HTML/XML, CSS, SQL, Markdown, Makefile, Dockerfile) join the 20 languages.

  The editor never writes colors into the text storage. `CodeTextView` hands
  token colors to the layout manager at draw time
  (`layoutManager(_:shouldUseTemporaryAttributes:…)`), so only visible text is
  colored, edits only invalidate display, and undo never sees colors.

  Documents autosave about a second after typing pauses, and right away when
  switching tabs, closing, deactivating and quitting (coordinated atomic
  writes in the file's own encoding). The editor supplies its text on demand,
  so a keystroke never copies the file.

  The window follows Xcode's layout for what Code has: the project as the
  navigator's top row with extensions hidden (Settings › Files to show them),
  a "+" footer, a capsule tab bar, a path bar, the gutter and current-line bar
  at Xcode's metrics, and "Line: Col:" in the bottom bar. Tabs keep their own
  width instead of stretching. Xcode's per-kind fonts live in the text storage
  (applied only after an edit settles); colors stay draw-time.

  Each window shows one folder. Folders and files opened from Finder or the
  Dock arrive through `onOpenURL` with `handlesExternalEvents` accepting all
  events, as in the Markdown app. `AppState` keeps the registry of open
  projects: opening a folder that is open focuses its window. The open
  projects are saved at quit and reopened at launch; each project restores its
  tabs and expanded folders.

Features

  - Sidebar file tree: lazy folders, live updates from disk, hidden names
    (.git, node_modules, … configurable), New File/Folder (paths with "/"
    create folders), Rename, Move to Trash, Show in Finder, Copy Path.
  - Tabs: preview tab on single click (italic), kept on double click or edit,
    unsaved dot, drag to reorder, Close Others/All.
  - Editor: line numbers, current-line highlight, Xcode's Default
    (Light/Dark) themes (default; exact colors, per-kind fonts such as bold
    keywords and proportional doc comments, Xcode's 18 pt lines at 13 pt) and
    GitHub Light/Dark, font and size, wrap toggle, soft tabs, auto-indent (and
    bracket split), Tab/⇧Tab block indent, ⌘/ comment toggle, find bar (⌘F).
  - Editing like Xcode's source editor (its edit assists, by name):
    overscroll past the last line; auto-closed ( [ and quotes with type-over
    and pair delete; a selection wrapped by a typed delimiter; a closer on a
    blank line indented to its opener; Return after an unclosed "{" adds the
    "}"; "///" continues on Return; Backspace in indentation deletes a level;
    ⌘← to the indentation, then column 0; the matching bracket flashes, a
    double-click on a bracket selects the block; wrapped lines (on by
    default) indent past their indentation; ⌘S trims trailing whitespace on
    edited lines.
  - Open Quickly (⇧⌘O, fuzzy), Go to Line (⌘L, "line:column"), ⌘0 toggles
    the navigator, "Line: Col:" in the bottom bar.
  - Binary files, files over 20 MB and unreadable files show a placeholder;
    files over 2 MB open without highlighting.

Verification

    swift build && swift test        # CodeKitTests
    swift build --triple arm64-apple-ios17.0-simulator \
      --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
    xcodebuild -project Code.xcodeproj -scheme Code -destination 'platform=macOS' build

Not yet: terminal, git, jump to definition. The app is not sandboxed so those
can run tools later.
