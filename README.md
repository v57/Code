# Code

A folder-based code editor for macOS, in the style of VS Code and Zed: open a
folder, browse it in the sidebar, edit files in tabs with syntax highlighting,
and build, run, test and debug it from an Xcode-style toolbar, with language
servers for definitions and issues.

Two parts, like `../Markdown`: the libraries (this package) and a thin
SwiftUI app (`Code.xcodeproj`, sources in `Code/`).

Libraries

  Each library can be used on its own; CodeKit is all of them plus what
  connects them.

    CodeHighlighting   languages, incremental highlighter, bracket matching,
                       themes (platform-neutral, no dependencies)
    CodeWorkspace      file tree, .gitignore and hidden files, file watching,
                       Quick Open index, Find in Project, package
                       dependencies, text documents with autosave, tabs
                       and sessions (neutral)
    CodeEditor         the AppKit editor: CodeTextView, line numbers,
                       CodeEditorScrollView, SwiftUI CodeTextEditor(text:)
    CodeActions        schemes found in a folder (Xcode, SwiftPM, Cargo, Go,
                       Gradle/Android, Maven, Node, Python, CMake, Make, Zig,
                       Dart, .NET, Elixir, Ruby, PHP; ported from Shell's
                       integrations), run destinations (Mac, simulators, iOS
                       devices, Android devices and emulators), running
                       build/run/test/clean on a pseudo-terminal, build-log
                       issues and progress (macOS)
    CodeLSP            language server client (JSON-RPC over stdio), the
                       catalog of servers and how to install each from its
                       official source, a manager per workspace (macOS)
    CodeMinimap        Xcode's minimap drawn as shapes, MARK sections, marks
    CodeFormatting     formatters run on the text before an explicit save
                       (swift-format, Prettier, gofmt, rustfmt, Ruff, …)
    CodeAutocompletion Xcode's completion list over the editor: a provider
                       protocol (a language server, or the file's words and
                       the language's keywords), fuzzy ranking, LSP snippets
                       as Xcode placeholders (AppKit; the model is neutral)
    CodeKit            re-exports them all; CodeEditorView(document:) edits a
                       workspace document (autosave, reload, ⌘S trimming,
                       minimap, issues, breakpoints); ProjectServices connects
                       a window's actions, servers, formatting, issues,
                       breakpoints and the LLDB DebugSession

Layout

    Sources/CodeHighlighting/   CodeScanner, LanguageSpec, LanguageCatalog(+Formats),
                                SyntaxHighlighter, LineIndex, Language, Delimiters,
                                CodeColorScheme, EditorTheme
    Sources/CodeWorkspace/      FileTree, FileNode, FileWatcher, FileIndex,
                                FuzzyMatch, TextDocument, Workspace
    Sources/CodeEditor/         CodeTextView (+EditAssists), LineNumberRuler,
                                CodeEditorScrollView, CodeTextEditor,
                                EditorConfiguration
    Sources/CodeEditor/         + CodeTextView+Annotations (inline issues,
                                breakpoints, execution line, ⌘/⌥-click, format),
                                + Placeholders and EditorPlaceholder (<#…#>)
    Sources/CodeActions/        ActionScheme, ProjectScanner, Detectors/,
                                RunDestination, ShellEnvironment, PTYProcess,
                                BuildLog, ActionPlanner, ActionController
    Sources/CodeLSP/            JSONValue, LSPConnection, LanguageServerCatalog,
                                LanguageServer, LanguageServerManager,
                                LSPCompletion
    Sources/CodeMinimap/        MinimapView
    Sources/CodeFormatting/     Formatter (catalog and FormattingService)
    Sources/CodeAutocompletion/ CompletionItem (+ provider protocol),
                                CompletionMatcher, Snippet,
                                WordCompletionProvider, CompletionController,
                                CompletionWindow
    Sources/CodeKit/            CodeKit (re-exports), CodeEditorView,
                                ProjectServices, DebugSession, QuickHelpPopover,
                                DocumentCompletion
    Code/                       the app
      CodeApp.swift, CodeCommands.swift, AppState.swift, AppDelegate.swift
      Welcome/, Workspace/ (+ ProjectToolbar, ConsoleView), Settings/
      (+ ToolsSettingsView: Languages, Formatting, Run), DebugAutomation

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
  projects: opening a folder that is open focuses its window. Launching
  shows the Welcome window: projects aren't reopened (windows opt out of
  state restoration), but a project opened again restores its tabs and
  expanded folders. Welcome looks like Xcode's: a fixed 480-point window
  without a title bar (a round close button instead), the icon, name and
  version, capsule buttons and the recent projects with their Xcode project,
  package or folder icons. The same window becomes the project's when one is
  opened, getting its title bar back at full size.

  Actions. `ProjectScanner` lists the folder and its subfolders two levels
  down once and hands the entries to each detector, so a folder of several
  projects (one implementation per language) gets every project's schemes.
  Commands run with the login shell's environment (read once, with an
  interactive shell so .zshrc's PATH counts) on a pseudo-terminal, as Xcode
  runs products: programs flush line by line and show progress; each command
  is its own session, so Stop ends everything it started. `BuildLogParser`
  reads Swift/Clang, Go, Rust, TypeScript, Kotlin, Java, C#, Dart, Elixir,
  Python and Zig diagnostics and "[n/m]" or Cargo/Gradle progress.
  Xcode schemes run on this Mac (the executable itself, so its output shows),
  on simulators (simctl install and launch --console-pty) and devices
  (devicectl install and launch --console); Android apps install with Gradle
  (ANDROID_SERIAL), launch with adb and stream logcat; a virtual device that
  isn't running is started first.

  Language servers are never bundled: each is installed from its official
  source (Homebrew, npm, gems, .NET tools, or Xcode's), from Settings ›
  Languages. A server runs per project root (the nearest or outermost folder
  with its markers), so a workspace of several projects has one per project.
  Edits go as incremental changes positioned in the text before the edit.

  Formatting runs in `TextDocument.preSave` on ⌘S: the formatter reads the
  text on standard input (finding its own config from the file's path), the
  editor applies the result as one undoable "Format" edit touching only what
  changed, and the document writes once. Autosave doesn't format.

  Completion. `CompletionController` attaches to a `CodeTextView` through
  its hooks (`commandHandler` takes ↑ ↓ Return Tab Esc while the list shows,
  `onTyping`, `onCompletionRequest` for Esc and ⌃Space) and asks a
  `CompletionProvider` without blocking typing: the answer is filtered with
  what was typed since, and an incomplete list is asked for again as the
  word grows (a superseded request is cancelled with `$/cancelRequest`).
  Items keep their range in the text as it was when asked; accepting shifts
  its end by what was typed since. CodeKit's provider asks the file's
  language server and falls back to the file's words and keywords while the
  server starts or when there is none. Snippets become Xcode placeholders
  (`<#name#>` in the text, markers drawn as null glyphs, a token behind),
  which a click selects whole and Tab visits.

  Breakpoints are kept per project and move with edits; Run with
  breakpoints builds and runs the program under LLDB (the program on its own
  terminal), shows the stopped line in green and its variables in the
  console, with Continue, Step Over/Into/Out and an (lldb) prompt.

Features

  - Sidebar file tree: lazy folders, live updates from disk, New File/Folder
    (paths with "/" create folders), Rename, Move to Trash, Show in Finder,
    Copy Path.
  - Hidden files: files matching .gitignore (the project's, those above it up
    to the repository root, and .git/info/exclude) and .git, .svn, .hg,
    .DS_Store are hidden from the sidebar and Open Quickly. View › Hidden
    Files: Show Hidden Files (⇧⌘.) lists them dimmed; Edit Hidden Files
    (also in an item's context menu) puts a checkbox on every item to hide
    or show it in this project, overriding .gitignore; Hide Files Listed in
    .gitignore is the per-project switch; Restore Defaults. Open Quickly's Hidden Files button (⇧⌘. while it's open)
    searches them too, ranked below visible files. Add to .gitignore in an
    item's context menu appends it to the project's .gitignore.
  - Package Dependencies under the file tree, as in Xcode: each package with
    its version or "local", expanding to browse its sources where they are
    on disk. Read from manifests and lockfiles (nothing is resolved):
    Swift packages (Package.swift, Xcode projects' package references and
    Package.resolved, with checkouts in .build or Xcode's DerivedData),
    npm/Yarn/pnpm, Cargo (workspaces too), Go modules, Python (pyproject,
    requirements; the project's virtual environment), RubyGems, Composer,
    pub (Dart, Flutter), CocoaPods, Hex (Elixir), NuGet and Gradle/Maven.
    Swift lists every resolved package as Xcode does; the others list
    direct dependencies. They update when a manifest or lockfile changes.
  - Tabs: preview tab on single click (italic), kept on double click or edit,
    unsaved dot, drag to reorder, Close Others/All.
  - Editor: line numbers, current-line highlight, Xcode's Default
    (Light/Dark) themes (default; exact colors, per-kind fonts such as bold
    keywords and proportional doc comments, Xcode's 18 pt lines at 13 pt) and
    GitHub Light/Dark, font and size, line wrapping (⌥Z, on by default: the
    editor then scrolls only vertically), soft tabs, auto-indent (and
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
  - Find in Project (⇧⌘F, Xcode's Find navigator, ⌘3; ⌘1 back to the files):
    Containing, Matching Word or Regular Expression, Ignoring or Matching
    Case, over the files Open Quickly lists (open documents' unsaved edits
    included); results by file as they come, a selection opens its match
    selected. A selection in the editor becomes the query.
  - Binary files, files over 20 MB and unreadable files show a placeholder;
    files over 2 MB open without highlighting.
  - Xcode's toolbar: Run (⌘R; hold for Test, Build, Clean), Stop (⌘.), the
    scheme › destination picker, the activity view with a progress bar,
    status and issue counts (click for the issue list, ⌘5). The Product and
    Debug menus, the debug area (⇧⌘Y) with the log, filter and debug bar.
  - Issues from the build and language servers in the editor: a tinted line
    and a message banner (click for all of the line's messages), counted
    once when both report them.
  - Code completion as in Xcode: the list opens while typing an identifier
    or after "." (or the server's trigger characters), Esc or ⌃Space opens
    and closes it; fuzzy matching with the typed letters in bold, kind
    badges, types and documentation; Return or Tab inserts, arguments as
    placeholders (Tab and ⇧Tab, ⌃/ move between them; Backspace deletes
    one whole); imports a server adds come with it in one undo. "Suggest
    completions while typing" in Settings › Editor.
  - Jump to Definition (⌘-click, ⌃⌘J), Quick Help (⌥-click), Go Back and
    Forward (⌃⌘← ⌃⌘→). SourceKit-LSP doesn't read Xcode projects, so files
    of Xcode targets get the selected Xcode scheme's compiler arguments
    (`xcodebuild -showBuildSettingsForIndex`) as a compilation database in
    Caches, written when the scheme or destination changes and after
    builds; other modules resolve once the scheme has been built.
  - The minimap (⌃⇧⌘M): runs of text as rounded bars in their syntax colors,
    MARK sections as titles, issues, breakpoints and the debugger's line;
    click or drag to scroll. It replaces the vertical scroller while shown.
  - Breakpoints: click a line number (⌘\\ at the caret), ⌘Y deactivates
    them; F6/F7/F8 step.
  - Settings turn each part off: toolbar actions, language servers (each),
    formatting (each formatter, "only with a config file", a custom command
    such as a local swift-format build), minimap, inline issues, breakpoints.

Verification

    swift build && swift test        # all test targets (CodeLSPTests talk to
                                     # gopls, CodeFormattingTests run
                                     # swift-format and gofmt when installed)
    swift build --triple arm64-apple-ios17.0-simulator \
      --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
    xcodebuild -project Code.xcodeproj -scheme Code -destination 'platform=macOS' build

Not yet: terminal, git. The app is not sandboxed: it runs build tools,
language servers, formatters, simctl, devicectl, adb and LLDB.
