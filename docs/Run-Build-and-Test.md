# Run, Build and Test

This page is about the Mac app. To build on your Mac from an iPhone or iPad, see [iPhone and iPad](iPhone-and-iPad.md).

## Schemes

Code looks through the folder and its subfolders, two levels down, and finds the projects in it. It knows Xcode
projects and workspaces, Swift packages, Cargo, Go, Gradle and Android, Maven, Node and Bun, Python, CMake, Make,
Zig, Dart, .NET, Elixir, Ruby, PHP and Docker Compose. Each project's targets become schemes in the toolbar, so a
folder with several projects gets all of their schemes.

The toolbar shows **scheme › destination**:

- Click the scheme to pick another one. Schemes are grouped by folder, with **Other Folders** for those further down.
  The menu has a filter field. **Refresh Schemes** looks again.
- When a folder holds more than one workspace, project or package to build from, a menu before the scheme chooses
  which one.
- While Code is still looking, the scheme reads **Finding Schemes…**; a folder with nothing to run reads **No Scheme**.

**Product ▸ Refresh Schemes** and **Product ▸ Refresh Run Destinations** do the same from the menu bar.

## Run destinations

Click the destination to choose where Run puts the app. Depending on the scheme and what's connected, the menu lists:

- this Mac;
- **Other Machines**: your other devices that have this project, reached over SSH or through your Hub;
- **Containers**;
- **Devices**: connected iPhones and iPads;
- **iPhone Simulators** and **iPad Simulators**: a simulator that isn't running starts first;
- **Android Devices** and **Android Emulators**: an emulator that isn't running starts first.

**Refresh Devices** lists them again. Android needs the Android Debug Bridge; **Settings ▸ Run** shows whether Code
found it.

## Run, build, test and clean

- Click Run (▶) or choose **Product ▸ Run** (⌘R) to build the scheme and run it on the destination. A scheme with
  nothing to run gets a Build button instead.
- Right-click Run for **Run**, **Test**, **Build** and **Clean**. Each item says what it will do.
- **Product ▸ Test** (⌘U) builds and runs the tests.
- **Product ▸ Build** (⌘B) builds without running.
- **Product ▸ Clean Build Folder** (⇧⌘K) deletes the scheme's build products, so the next build starts over.
- Stop (■) or **Product ▸ Stop** (⌘.) ends the action and everything it started.

The toolbar's title shows the project, what it's doing and a progress bar, then the result. Commands run with your
login shell's environment, so your PATH applies.

Turn off **Run, Build and Test** in **Settings ▸ Run** to hide these buttons from the toolbar.

## The console

The console shows what each command prints, one block per command, with its status and progress. It opens on its own
when a program you run starts, never while building.

- Click the toolbar's title, or choose **View ▸ Show Console** (⇧⌘Y), to show or hide it.
- **Filter** shows only the lines that contain your text.
- **Copy Log** copies everything, and **Clear Console** empties it.
- **Open in Window** moves the console to a window of its own. **Show Under Title** puts it back under the toolbar.

## Issues

Code reads errors and warnings from build output for Swift, C and Objective-C, Go, Rust, TypeScript, Kotlin, Java, C#,
Dart, Elixir, Python and Zig, and from the language servers.

- The toolbar shows the number of errors and warnings. Click them, or choose **View ▸ Show Issues** (⌘5), for the
  list, grouped by file. Each row shows its line and whether it came from the build. Choose one to go to it.
- Issues also show on their lines in the editor (see [Editing](Editing.md#issues-in-the-editor)).

## Debugging

With breakpoints set, Run builds the program and runs it under LLDB.

- Click a line number to add or remove a breakpoint, or choose **Debug ▸ Add or Remove Breakpoint at Current Line**
  (⌘\\).
- **Debug ▸ Deactivate Breakpoints** (⌘Y) turns them all off without removing them; **Activate Breakpoints** turns
  them back on. **Delete All Breakpoints** removes them.
- When the program stops, the line shows in green and the console shows its variables.
- **Continue** or **Pause** (⌃⌘Y), **Step Over** (F6), **Step Into** (F7) and **Step Out** (F8) are in the **Debug**
  menu and the console's bar.
- Type LLDB commands in the console's **Command** field.

Breakpoints are kept per project and move with your edits. Turn **Breakpoints** off in **Settings ▸ Run** if you
don't use them.

## Install, Export and Upload (Xcode apps)

For an Xcode scheme that builds an app, the **Product** menu has more:

- **Install**: archives the app in Release, with the repository's commit count as its build number, and installs it
  on this Mac. It replaces the copy in your Applications folder (your home folder's first, else the main one). If the
  app is running, Code asks before quitting it, and reopens it in the background afterwards.
- **Export…**: archives the app and exports it signed with your Developer ID and notarized by Apple, ready to share.
- **Upload to App Store**: archives the app and uploads it to App Store Connect. A sheet asks for the **Build number**,
  prefilled with the commit count; App Store Connect wants it higher than the last build you uploaded.
- **Notarization Settings…**: checks what Export needs. It looks for a **Developer ID** certificate in your keychain
  and lets you pick or create a **Notary profile**. **Check with Apple** asks Apple's notary service whether the
  profile works.

A command-line tool has no Install, Export or Upload, and a library only has Build, Test and Clean.

Export, Upload and the profile check contact Apple, and only when you choose them.
