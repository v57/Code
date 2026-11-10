# Projects and Files

This page is about the Mac app. On iPhone and iPad, see [iPhone and iPad](iPhone-and-iPad.md).

## The welcome window

The welcome window shows while no folder is open, and in a project window while no file is open. It has:

- your account picker, when your vault has more than one account, with the number of projects;
- **Open…**, to choose a folder (you can also drop one on the window);
- a **Recent** / **Projects** switch. **Recent** lists the folders you opened. **Projects** lists your vault's
  projects that are on this Mac, in their groups. Click a group to close or open it.

Right-click a project for more:

- **Open With**: Xcode, Finder or Terminal;
- **Open in New Window**: opens it in its own window and keeps this one;
- **Copy Path**;
- **Remove from Recents** and **Clear Recents** (in Recent): the folders stay on disk;
- **Remove from List** (in Projects), and **Remove Group from List** on a group.

When you drop a folder that holds several repositories without being one, Code offers to add each one as a project
in your vault. Choose **Open as One Project** to open the folder as it is instead.

The Dock icon's menu also lists your recent projects.

## The sidebar

The sidebar shows the project's files in a card. Folders load when you open them, and the list follows changes on
disk. File extensions are hidden unless you turn on **Show file extensions** in [Settings ▸ Files](Settings.md#files).

At the top of the sidebar, **Open Folder…** opens another folder, and the eye button shows or hides hidden files.

### Work with files

Right-click a file or folder for:

- **New File…** and **New Folder…**: a name with "/" in it creates the folders too;
- **Open in New Tab** and **Open in New Window**;
- **Open With**: Xcode, Finder, or the file's default app;
- **Copy Path** and **Copy Relative Path**;
- **Rename**;
- **Move to Trash**, which asks first;
- **Hide from List** (or **Show in List** for a hidden one) and **Add to .gitignore**;
- **Edit Hidden Files**.

The **…** button on the project's card (**Project**) has the same commands for the whole project, plus **Open With**
(Xcode, Git, Finder, Terminal), **Copy Path** and **Reload**, which reads the files from disk again.

### Switch projects

The sidebar's **Projects** card lists your vault's projects on this Mac, with the open project's files under its row.
Click another project to show it in this window. Right-click a project for **Open in New Window**. A project that is
still running something after you switched away shows a green ▶; right-click it and choose **Stop** to end it.

## Hidden files

Code hides files listed in `.gitignore` (the project's own, the ones above it up to the repository's root, and the
repository's exclude file), plus `.git`, `.svn`, `.hg` and `.DS_Store`. They stay out of the sidebar and Open
Quickly.

Use **View ▸ Hidden Files**:

- **Show Hidden Files** (⇧⌘.) lists them, dimmed. **Hide Hidden Files** hides them again.
- **Edit Hidden Files** puts a checkbox on every file and folder. Turn one off to hide it in this project, or on to
  show it, whatever `.gitignore` says. Click **Done** when you're finished.
- **Hide Files Listed in .gitignore** turns the `.gitignore` rule on or off for this project.
- **Restore Defaults** forgets this project's choices.

**Settings ▸ Files ▸ Hide files listed in .gitignore** sets the default for projects that haven't chosen.

## Package dependencies

Under the files, **Package Dependencies** lists the packages the project uses, as in Xcode, each with its version or
"local". Expand one to browse its sources when they're on disk. Code reads them from the project's manifests and
lockfiles and resolves nothing. It knows Swift packages, npm, Yarn and pnpm, Cargo, Go modules, Python, RubyGems,
Composer, Dart and Flutter, CocoaPods, Hex, NuGet, and Gradle and Maven.

The list updates when a manifest or lockfile changes. Right-click it and choose **Refresh Package Dependencies** to
read them again. A package's menu only opens, reveals and copies: nothing in it changes the package.

## Tabs

- A single click in the sidebar opens a preview tab (in italics). Double-click, or edit the file, to keep it.
- A dot on a tab means it has unsaved changes.
- Drag tabs to reorder them.
- Right-click a tab for **Close**, **Close Others**, **Close All**, **Keep Open**, **Open in New Window**,
  **Reveal in Sidebar** and **Copy Path**.
- **Go ▸ Next Tab** (⇧⌘]) and **Go ▸ Previous Tab** (⇧⌘[) move between tabs.
- **File ▸ Close Tab** (⌘W) closes the tab, or the window when no tab is open.

## Windows

- **File ▸ New Window** (⇧⌘N) opens another window.
- **File ▸ Open in New Window** (⇧⌘D) opens the current file in a window of its own.
- **File ▸ Open Recent** lists recent folders. **Clear Menu** empties it.
- Opening a folder that's already open brings its window forward.
- You can open folders and files from Finder or the Dock.

## Files Code can't show

Binary files, files over 20 MB and files Code can't read show a placeholder, with **Open with Default App**. Files
over 2 MB open without highlighting.
