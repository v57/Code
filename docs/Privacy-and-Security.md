# Privacy and Security

## Trusting a folder

A project's own files can contain code that runs when an editor opens them: a language server's build settings, a
formatter installed in the project, or a package manifest that fetches packages. So the first time you open a folder
that Code didn't create, Code asks **Trust the authors of “*folder*”?**

- **Trust Folder**: the folder's own code may run. Language servers read its build settings (for an Xcode project,
  Xcode reads them and fetches its packages), its formatters run when you save, and Swift reads the project.
- **Don’t Trust**: the folder opens in **Restricted Mode**. You can read and edit every file, and nothing in the folder
  runs on its own.

In Restricted Mode:

- Only Code's built-in language server runs. It runs inside Code and contacts nothing.
- Formatters come only from your PATH, never from inside the project, and a formatter whose config is code (a
  JavaScript Prettier config, Prettier plugins, a `prettier` key in `package.json`, or `mix format`) doesn't run.
- Code doesn't ask Xcode or Swift about the project, so no packages are resolved. Code still finds Xcode schemes from
  the project's scheme files.

The status bar shows **Restricted Mode** while the folder isn't trusted. Click it to be asked again.

A folder inside a trusted folder is trusted too. Your answers are kept in Code's item in this Mac's keychain. They
aren't synced to your other devices.

Trusting a folder doesn't make Build, Test or Run automatic: those still run only when you choose them, and they run
the project's own commands.

Code on the Mac isn't sandboxed, because it runs build tools, language servers, formatters, simulators, devices and
LLDB for you. Trust only folders whose authors you trust.

## Signing in to your Macs from iPhone and iPad

- Code signs in with this device's own SSH key, kept in its Secure Enclave. A Mac lets it in only after you turn on
  **Can Sign In** for this device on that Mac (Code's or the Vault app's **Remote** settings).
- Before the first connection to a Mac whose key your vault doesn't know, Code asks **Trust this server's key?** and
  sends nothing until you answer. If a Mac's key changes, Code refuses to connect without asking.
- If this device's key requires it, Face ID or Touch ID asks before Code signs in.
- **Login Keychain** signing keeps your Mac password in iCloud Keychain and sends it to that Mac only, to unlock the
  login keychain before each signed build. It's never written to the build log. **Don’t Sign** and
  **Desktop Session** need no password.

## What Code sends over the network

Code contacts no server on its own. Here's everything it can contact, and when.

### When you open a folder

- **An untrusted folder**: nothing. Reading and editing files, the built-in language server and the scanner stay on
  your Mac.
- **A trusted folder**: listing an Xcode project's schemes fetches nothing. Code reads them from the project's files,
  or asks Xcode only when every package the project pins is already checked out on this Mac. When you pick an Xcode
  scheme, Xcode reads its build settings for the Swift language server, and that fetches every Swift package the
  project names, as Xcode does. Language servers may download toolchains or dependencies, depending on the server.

### Only when you choose it

- **Run**, **Build**, **Test**, **Clean**, **Install** and **Export**: the project's own commands, which may fetch
  dependencies.
- **Other Machines** and **Containers** destinations, and **Build From**: building, testing or running there signs
  in to that machine over SSH, or starts a container, which may download its image first. Picking a machine under
  **Build From**, or its **Refresh**, asks that machine what it can build; the machines listed under
  **Find on Another Machine** aren't contacted until you pick one.
- **Install** in Settings ▸ Languages or Settings ▸ Formatting: runs the shown command (Homebrew, npm, gem and so on),
  which downloads the tool from its source.
- **Export…** and **Upload to App Store**: send the app to Apple for notarization or to App Store Connect.
  **Check with Apple** in Notarization Settings asks Apple's notary service.
- **Check for Updates…**: asks GitHub for Code's latest release, which shows GitHub your IP address. **Check for
  Updates Automatically** is off at first; when you turn it on, Code asks once a day.
- On iPhone and iPad, opening a project, building and reading files: an SSH connection to your own Mac, directly or
  through your Hub.

### While iCloud is on

Your vault's records (projects, devices and hosts) sync through your own iCloud account, as in every v57 app. Turn
**Use iCloud** off in **Settings ▸ Privacy** (on iPhone and iPad, the hand button) to keep them on this device.
