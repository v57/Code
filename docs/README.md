# Code user guide

Code is a folder-based code editor for the Mac. You open a folder, browse it in the sidebar, edit files in tabs, and
run, build, test and debug it from an Xcode-style toolbar, in any of the languages it knows. On iPhone and iPad, Code
has no editor: it runs Build, Test and Clean on your own Macs over SSH and shows you the log, the issues and the files.

## Platforms

- **Mac** (macOS 14 or later, Apple silicon): the full editor, with language servers, formatting, Run, Build, Test,
  debugging with LLDB, and Install, Export and Upload for Xcode apps.
- **iPhone and iPad** (iOS 17 or later): lists the projects on your other devices and runs Build, Test and Clean there.
  You can read the project's files, but not edit them.
- **Linux and Windows**: Code builds there from the same sources, but these builds are early and not released yet.
  This guide describes the Mac, iPhone and iPad apps.

## Pages

- [Getting Started](Getting-Started.md): open your first folder on the Mac, or your first project on iPhone and iPad.
- [Projects and Files](Projects-and-Files.md): the welcome window, the sidebar, hidden files, package dependencies,
  tabs and windows.
- [Editing](Editing.md): the editor, completion, finding, jumping to definitions, Quick Help and the minimap.
- [Languages and Formatting](Languages-and-Formatting.md): language servers, Code's own scanner and Swift model, and
  formatting on save.
- [Run, Build and Test](Run-Build-and-Test.md): schemes, run destinations, the console, issues, breakpoints, and
  Install, Export and Upload.
- [iPhone and iPad](iPhone-and-iPad.md): build and test on your Mac from your iPhone or iPad.
- [Settings](Settings.md): every pane in Code's settings.
- [Privacy and Security](Privacy-and-Security.md): trusting a folder, Restricted Mode, sign-in to your Macs, and what
  Code sends over the network.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md): the Mac app's shortcuts.

## Works with other v57 apps

- **[Vault](https://github.com/v57/Vault/blob/main/docs/README.md)** keeps your projects, devices and SSH hosts. A
  folder you open in Code becomes a project there, so Git, Markdown, Dev and Code on your other devices can show it.
  Code's iPhone and iPad app reaches your Macs through the hosts and device keys in the vault.
- **[Shell](https://github.com/v57/Shell/blob/main/Docs/README.md)**'s smart actions are Code's schemes: the projects
  Code detects are the ones Shell offers to run in a terminal.
- **[Git](https://github.com/v57/Git/blob/main/docs/README.md)**: open a project in Git from the project's menu in
  Code's sidebar, and see the same project list in both apps.
- **Dev** lists the same Xcode projects, with the app icons Code finds for them.
- **[Hub](https://github.com/v57/hub-app/blob/main/docs/README.md)**: a Mac joined to your Hub can be reached from
  your iPhone or iPad through it.
- Code's highlighter also colors code in Git's diffs, Markdown's code blocks and Database's query editors.

## Network

Code contacts no server on its own. Opening a folder you haven't trusted contacts nothing. Trusting a folder lets its
own tools run, and those may fetch packages. iCloud syncs your vault's projects and hosts when it's on. The details
are in [Privacy and Security](Privacy-and-Security.md).
