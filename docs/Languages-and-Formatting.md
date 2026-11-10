# Languages and Formatting

This page is about the Mac app. Everything here is in **Settings ▸ Languages** and **Settings ▸ Formatting** (open
settings with ⌘,).

## Language servers

A language server gives Code a language's definitions, issues and completions. Code bundles none: you install each
one from its official source, and Code finds it on your PATH.

**Settings ▸ Languages ▸ Servers** lists every server Code knows, the installed ones first. Among them are
SourceKit-LSP (Swift, from Xcode), clangd, gopls, rust-analyzer, the TypeScript server, Pyright, Kotlin, Eclipse JDT
(Java), Dart, ZLS (Zig), ElixirLS, Ruby LSP, Intelephense (PHP), csharp-ls, Lua, Bash and YAML. Each row says which
languages it covers and where it's installed.

- **Install** runs the install command shown in the button's tooltip, for example a Homebrew, npm or gem command. It
  downloads the server from that source. A server that comes with Xcode or an SDK shows **Not installed** instead.
- **Uninstall** removes it, after asking.
- Each installed server has a switch, to turn it off without removing it.
- **Language servers** at the top turns them all on or off.

A server runs for each project in the folder, so a folder with several projects gets one per project.

### Code's built-in server

Code has its own language server for every language it colors. It runs inside Code and contacts nothing. It's used
for a language that has no other server installed, or when the others are off, and it's the only server in a folder
you haven't trusted (see [Privacy and Security](Privacy-and-Security.md#trusting-a-folder)).

### Swift in Xcode projects

SourceKit-LSP doesn't read Xcode projects by itself. In a trusted folder, Code gives it the build settings of the
Xcode scheme you picked in the toolbar, so files in Xcode targets get definitions and issues. Other modules resolve
once the scheme has been built.

## Jumping and completion

When you jump to a definition or complete a name, Code asks up to three sources together. The fastest answer shows
first and the slower ones update it. Turn a source off in **Settings ▸ Languages ▸ Jumping and completion** to save
memory and power:

- **Code’s scanner**: guesses from the code's words, in every language. It uses about 8 MB.
- **Swift model**: reads Swift's types from the source and answers in milliseconds. It can use 150–200 MB for a large
  app.
- **Ask the language server**: **When Unsure** (the default) asks it for definitions only when the Swift model isn't
  sure, and always in other languages. **Always** lets its answer decide each jump. **Never** stops asking it for
  definitions; it still reports issues and completes.

## Formatting on save

When **Format when saving** is on in **Settings ▸ Formatting**, ⌘S formats the file before writing it. The change is
one step you can undo, and only what changed is touched. Saving on its own (autosave) never formats.

Code knows these formatters: swift-format, Prettier, gofmt, rustfmt, Ruff, ClangFormat, zig fmt, mix format, ktlint
and shfmt. Each reads its own config file (`.swift-format`, `.prettierrc` and so on) from the file's folder upward.

For each formatter, under **Formatters**:

- **Install** runs its install command, and its switch turns it off.
- **Only with a config file** runs it only when the project has a config file for it. Its tooltip lists the file
  names.
- **Custom command** runs your own command instead, for example a local build of swift-format.

**Code’s formatter** formats files no formatter above applies to, in any language. It's off at first. If its result
would change the code's meaning, it leaves the file as it was.

In a folder you haven't trusted, Code uses only formatters from your PATH, never one installed inside the project,
and skips a formatter whose config is code, such as a JavaScript Prettier config. See
[Privacy and Security](Privacy-and-Security.md#trusting-a-folder).
