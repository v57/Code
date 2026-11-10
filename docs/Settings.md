# Settings

On the Mac, open settings with **Code ▸ Settings…** (⌘,). Most panes show a live preview of what each setting does.
The iPhone and iPad app has no settings window: its only setting is **Privacy** (see
[iPhone and iPad](iPhone-and-iPad.md#your-projects)).

## Editor

- **Appearance**: **Theme** (**Xcode (Match System)** and **GitHub (Match System)** follow the system's light and dark
  appearance; you can also pick one light or dark theme), **Font** (any installed fixed-pitch font) and
  **Font size**. ⌘+ and ⌘− change the size too.
- **Editing**: **Tab width**, **Insert spaces when pressing Tab**, **Close brackets and quotes**, **Trim trailing
  whitespace** (when saving) and **Suggest completions** (while typing).
- **Display**: **Wrap lines**, **Line numbers**, **Highlight current line** and **Minimap**.
- **Issues**: **Show issues in the editor**, and **Show issue messages** at the end of their lines.

## Files

- **Show file extensions** in the sidebar, tabs and path bar. They're hidden at first.
- **Hide files listed in .gitignore**: the default for projects that haven't chosen their own hidden files. See
  [Projects and Files](Projects-and-Files.md#hidden-files).

## Languages

Language servers, Code's scanner and Swift model, and which servers are installed. See
[Languages and Formatting](Languages-and-Formatting.md).

## Formatting

**Format when saving**, **Code’s formatter** and the list of formatters. See
[Languages and Formatting](Languages-and-Formatting.md#formatting-on-save).

## Run

- **Run, Build and Test**: shows these buttons in the toolbar.
- **Breakpoints**: click a line number to set one; Run then debugs with LLDB.
- **Android Debug Bridge**: where Code found `adb`, or how to install it.

## Privacy

**Use iCloud** turns iCloud sync on or off for every v57 app on this device. Turning it off asks first. With iCloud
off, your projects, hosts and devices stay on this device and your other devices stop seeing changes from it.

## Accounts

Your vault's accounts. **Personal** is always there. Use **New Account…** to keep a set of projects apart, for
example for work. Each window shows one account. Deleting an account deletes its projects, hosts, passwords and
settings on every device; Personal keeps everything. See the
[Vault guide](https://github.com/v57/Vault/blob/main/docs/README.md) for more.

## Remote

Which of your devices may sign in to this Mac over SSH, so Code on your iPhone or iPad (and other v57 apps) can work
here. It needs **Remote Login** on in System Settings ▸ General ▸ Sharing.

- **Let Your Devices In** turns it on for this Mac.
- **Can Sign In** on each device allows it.
- **Apps on Your Devices** lists apps that sign in with their own key, only to run a command or read files.
- **Other Keys** lists other keys that can sign in to this Mac as you. **Add Key…** adds one, and **Remove…** takes
  one away.

The Vault app has the same page.

## Updates

The **Code** menu has **Check for Updates…** and **Check for Updates Automatically**. See
[Privacy and Security](Privacy-and-Security.md#what-code-sends-over-the-network).
