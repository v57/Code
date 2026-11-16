# Run, Build and Test

Run, build, test and debug the projects in a folder, here, on another machine or in a container, and follow what
they print. For Xcode apps, Code also installs, exports and uploads them.

## On the Mac

### Schemes

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

### Build From

When there's another machine or a container runtime to build from, the toolbar shows **Build From** before the
scheme. Its menu lists:

- **This Mac**, which builds here from this folder;
- **Other Machines**: your other devices that have this project, which build it there from their own files;
- **Containers**: a container runtime such as Docker, which builds in a new container with this folder in it and
  keeps the products in a volume. A stopped runtime has **Start**, which runs its start command;
- **Find on Another Machine**: your machines that may have the project. Nothing is contacted until you pick one.

With a machine picked, **Set Folder on *machine*…** asks where the project is on it, then lists its schemes from
there. **Refresh** looks for your machines and runtimes again. A machine that can't be reached stays picked, with a
warning that says why.

A Windows machine works too: Code speaks PowerShell there, and Run opens the program in that machine's desktop
session. On a Linux machine, Run opens it on the signed-in user's desktop.

### Run destinations

Click the destination to choose where Run puts the app. Depending on the scheme and what's connected, the menu lists:

- this Mac;
- **Other Machines**: your other devices that have this project, reached over SSH or through your Hub;
- **Containers**;
- **Devices**: connected iPhones and iPads;
- **iPhone Simulators** and **iPad Simulators**: a simulator that isn't running starts first;
- **Android Devices** and **Android Emulators**: an emulator that isn't running starts first.

**Refresh Devices** lists them again. Android needs the Android Debug Bridge; **Settings ▸ Run** shows whether Code
found it.

### Run, build, test and clean

- Click Run (▶) or choose **Product ▸ Run** (⌘R) to build the scheme and run it on the destination. A scheme with
  nothing to run gets a Build button instead.
- Right-click Run for **Run**, **Test**, **Build**, **Clean** and **Save Preset…**. Each item says what it will do.
- **Product ▸ Test** (⌘U) builds and runs the tests.
- **Product ▸ Build** (⌘B) builds without running.
- **Product ▸ Clean Build Folder** (⇧⌘K) deletes the scheme's build products, so the next build starts over.
- Stop (■) or **Product ▸ Stop** (⌘.) ends the action and everything it started.

The toolbar's title shows the project, what it's doing and a progress bar, then the result. Commands run with your
login shell's environment, so your PATH applies. Builds go where each project's own tools put them: Xcode's
DerivedData, SwiftPM's `.build`, Cargo's `target`.

Turn off **Run, Build and Test** in **Settings ▸ Run** to hide these buttons from the toolbar, with the presets and
the preview.

<!-- only: linux windows -->
On Linux and Windows, the toolbar's first choice reads **This Computer** on Linux and **This PC** on Windows, in
place of **This Mac**.
<!-- /only -->

### Follow a run

Every build, test and run, of this project and of your other open projects, shows as a circle at the editor's right
edge, the newest at the bottom.

- Point at a circle to see its name and status, with **Stop**.
- Click it to open its card: what it's doing, for how long, and the last lines of its output as it runs, with
  **Open in Console**, **Restart** and **Stop**. A failed run's card has **Show Issues**, **Restart** and
  **Dismiss**. Esc or a click elsewhere closes the card.
- Right-click a circle for **Show Output**, **Restart**, **Stop**, **Dismiss**, **Stop All** and **Hide Finished**.

A run that succeeded leaves after a few seconds, a stopped one at once, and a failed one stays until you dismiss it.

### Presets

A preset saves an action with the toolbar's choices (where to build from, the project, the scheme and the
destination), so one click runs it again without changing the toolbar.

- Right-click Run and choose **Save Preset…**, or choose **Product ▸ Save Preset…**. Pick the **Action** (Run, Test
  or Build), change any of the choices, give it a **Name**, and choose where to **Keep in**: **This Mac** writes it to
  `.dev/actions.json` in the project, a file you can commit; **Vault** syncs it to your other Macs and your iPad.
- Presets show as small cards under the toolbar. Click one to run it; ⌥-click it to copy its choices into the
  toolbar. **Product ▸ Run Preset** lists them, and ⌘1 to ⌘9 run the first nine.
- Right-click a preset for **Run**, **Edit…**, **Rename**, **Use in Toolbar**, **Keep in Vault** and **Remove**. Drag
  presets to reorder them.

### The preview

The preview shows the app you run, floating over a corner of the editor. Click **Preview** in the toolbar, or choose
**View ▸ Show Preview** (⌥⌘P). Run brings it along on its own, folded into a capsule, when there will be a picture.

- With an **iOS Simulator** as the run destination, the preview shows the simulator's screen, and you can click and
  type in it. Its **More** menu has **Home**, **Lock**, **Dark Appearance** or **Light Appearance**,
  **Save Screenshot** and **Real Size**. While the preview shows the simulator, Run leaves the Simulator app closed.
- When you build from another machine (see [Build From](#build-from)), the preview shows the app's window on that
  machine through v57's Remote. If Remote isn't set up there, the preview lists the steps to set it up, with
  **Check Again**.

Drag the card's bar to move it to another corner, drag its free borders to resize it, or open it in a window of its
own. **Close Preview** (⌥⌘P) hides it.

### The console

The console shows what each command prints, one block per command, with its status and progress.

- Click the toolbar's title, or choose **View ▸ Show Console** (⇧⌘Y), to show or hide it. A run's card has
  **Open in Console**, which shows the console at that run.
- **Filter** shows only the lines that contain your text.
- **Copy Log** copies everything, and **Clear Console** empties it.
- **Open in Window** moves the console to a window of its own. **Show Under Title** puts it back under the toolbar.

### Issues

Code reads errors and warnings from build output for Swift, C and Objective-C, Go, Rust, TypeScript, Kotlin, Java, C#,
Dart, Elixir, Python and Zig, and from the language servers.

- The toolbar shows the number of errors and warnings. Click them, or choose **View ▸ Show Issues** (⌥⌘5), for the
  list, grouped by file. Each row shows its line and whether it came from the build. Choose one to go to it.
- Issues also show on their lines in the editor (see [Editing](Editing.md#issues-in-the-editor)).

### Debugging

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

<!-- only: linux windows -->
On Linux and Windows, Code debugs with the `lldb` it finds on your PATH, such as the one that comes with Swift.
<!-- /only -->

### Install, Export and Upload (Xcode apps)

For an Xcode scheme that builds an app, the **Product** menu has more:

- **Install**: archives the app in Release, with the repository's commit count as its build number, and installs it
  on this Mac. It replaces the copy in your Applications folder (your home folder's first, else the main one). If the
  app is running, Code asks before quitting it, and reopens it in the background afterwards.
- **Export…**: archives the app and exports it signed with your Developer ID and notarized by Apple, ready to share.
  Without a notary profile, it opens **Notarization Settings** first.
- **Upload to App Store**: archives the app and uploads it to App Store Connect. A sheet asks for the **Build number**,
  prefilled with the commit count; App Store Connect wants it higher than the last build you uploaded.
- **Notarization Settings…**: checks what Export needs. It looks for a **Developer ID** certificate in your keychain
  and lets you pick or create a **Notary profile**. **Check**, under **Check with Apple**, asks Apple's notary service
  whether the profile works.

A command-line tool has no Install, Export or Upload, and a library only has Build, Test and Clean.

Export, Upload and the profile check contact Apple, and only when you choose them.

<!-- only: linux windows -->
On Linux and Windows, Install, Export and Upload aren't available: they need Xcode on a Mac.
<!-- /only -->

## On iPhone and iPad

Code on iPhone and iPad runs Build, Test and Clean on your Macs and shows you the log and the issues. See
[iPhone and iPad](iPhone-and-iPad.md#build-test-and-clean).
