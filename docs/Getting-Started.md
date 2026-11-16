# Getting Started

Install Code, open your first project and find your way around. Pick your platform: on the Mac, Linux and Windows,
Code opens a folder on your computer and edits, runs, builds and tests it there; on iPhone and iPad, Code runs Build,
Test and Clean on your Macs and shows you what happened.

## On the Mac

### Install

<!-- only: mac -->
Download **Code.dmg** or **Code.zip** from [Code's releases on GitHub](https://github.com/v57/Code/releases) and move
**Code** to your Applications folder. It needs macOS 14 or later on a Mac with Apple silicon.
<!-- /only -->

<!-- only: linux -->
On Linux, download **Code-Linux-x64.tar.gz** or **Code-Linux-arm64.tar.gz** from
[Code's releases on GitHub](https://github.com/v57/Code/releases). It holds the app's folder, with a `.desktop` file
and its icon, made to go in `/opt/Code`.
<!-- /only -->

<!-- only: windows -->
On Windows, download **Code-Windows-x64.zip** or **Code-Windows-arm64.zip** from
[Code's releases on GitHub](https://github.com/v57/Code/releases), unzip it and open **Code** from the folder.
<!-- /only -->

### Open a folder

1. Open Code. The first time, you see the welcome window.
2. Click **Open…** and choose a folder, or drop a folder on the window. You can also choose **File ▸ Open Folder…**
   (⇧⌘O, or ⌘O in a window without a project) at any time.
3. When the folder isn't one you trusted before, Code asks **Trust the authors of “*folder*”?**
   - Click **Trust Folder** if you know where the code comes from. Its language servers, formatters and build tools
     can then run.
   - Click **Don’t Trust** to look at it safely. Code uses only its built-in language server and the formatters on
     your PATH, and resolves no packages. The status bar shows **Restricted Mode**; click it to be asked again.

   [Privacy and Security](Privacy-and-Security.md#trusting-a-folder) explains what each answer means.
4. The folder opens in the window: the files in the sidebar, the editor on the right and the toolbar on top.

Each window shows one folder. When you open Code again, it opens the last project you opened, unless you opened Code
with a folder or file. A folder you open in Code is also added to your vault's projects, so your other v57 apps and
devices can see it.

### Open a file and edit it

- Click a file in the sidebar to open it in a tab. A single click opens a preview tab, shown in italics, which the
  next file you click replaces. Double-click the file, or start typing, to keep the tab open.
- Code saves on its own about a second after you stop typing, and when you switch tabs, switch apps or quit.
  **File ▸ Save** (⌘S) also formats the file when a formatter applies. See
  [Languages and Formatting](Languages-and-Formatting.md).
- Press ⌘O (**Go ▸ Open Quickly…**) and type part of a file's name to open it without the sidebar, or a symbol's
  (`MessageView.body`) to jump to its declaration.

### Find your way around

- **The sidebar** shows the project's files. With projects in your vault, the **Projects** card above them lists
  your other projects on this computer; click one to show it in this window. At the bottom of the sidebar,
  **Open Folder…** opens another folder and the eye button shows or hides hidden files.
- **The toolbar** has **Go Back** and **Go Forward**, Run (▶) and Stop (■), the project's title with what it's doing,
  the number of errors and warnings, then the scheme and the run destination, and **Preview**.
- **The status bar** under the editor shows the line and column, and **Restricted Mode** while the folder isn't
  trusted.
- The **Go** menu moves between files, tabs and definitions, the **Product** menu runs, builds and tests, and the
  **Debug** menu has the breakpoints and the debugger.

<!-- only: linux windows -->
On Linux and Windows, the shortcuts written with ⌘ in this guide use Ctrl: Ctrl+O for Open Quickly, Ctrl+R for Run.
Settings is **Edit ▸ Preferences…** on Linux.
<!-- /only -->

### Run your project

Code finds the projects in the folder (Xcode, Swift packages, Cargo, Go, Node and more) and lists their schemes in
the toolbar. Pick a scheme and a run destination, then click Run (▶) or press ⌘R. A circle at the editor's right edge
follows the run; click it for its output, or click the toolbar's title for the console. See
[Run, Build and Test](Run-Build-and-Test.md).

## On iPhone and iPad

Code on iPhone and iPad runs Build, Test and Clean on your Macs. It needs one Mac set up first.

1. On the Mac, turn on **Remote Login** in System Settings ▸ General ▸ Sharing.
2. Open Code on your iPhone or iPad once, so it publishes this device's key to your vault.
3. On the Mac, open Code's settings (⌘,) and choose **Remote** (the Vault app has the same page). Turn on
   **Let Your Devices In**, then turn on **Can Sign In** for your iPhone or iPad. Instead, you can connect the Mac to
   your Hub.
4. On the Mac, open the project's folder in Code once, so it's in your vault.
5. On your iPhone or iPad, the project appears in the list with the Mac's name under it. Tap it to open it.

Until a project is available, Code shows **No Projects on Your Devices** with these steps. If you turned iCloud off,
tap **Privacy** to turn **Use iCloud** back on: Code finds your projects through the vault, which syncs over iCloud.

See [iPhone and iPad](iPhone-and-iPad.md) for the rest.

## Next

- [Projects and Files](Projects-and-Files.md): the welcome window, the sidebar, hidden files, tabs and windows.
- [Run, Build and Test](Run-Build-and-Test.md): schemes, destinations, the console and debugging.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md): every menu command that has keys.
