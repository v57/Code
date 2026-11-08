# iPhone and iPad

Code on iPhone and iPad runs Build, Test and Clean on your own Macs and shows you the log, the issues and the files.
It has no editor and runs nothing on the iPhone or iPad itself. To set up your first Mac, see
[Getting Started](Getting-Started.md#on-iphone-and-ipad).

## Your projects

The list shows the projects in your vault that are on your other devices, sorted by name. Each row has the project's
icon (or its initial on a coloured tile) and the devices that have it.

- Type in **Search Projects** to filter the list.
- The status line at the bottom says how many devices have projects. Tap the hand button there for **Privacy**, where
  **Use iCloud** turns iCloud on or off for every v57 app on this device. Turning it off asks first.
- When your vault has more than one account, the account picker heads the list. Pick an account to see its projects.
  It also has **New Account…** and **Manage Accounts…**.

The list updates when Code opens and each time you come back to it. A project gets into the list when you open its
folder in Code (or Git, Markdown or Dev) on a Mac.

**On iPhone**, tap a project to open it, and go back to return to the list. **On iPad**, the projects are in a
sidebar and the open project fills the rest. Before you pick one, the detail lists the same projects under
**On Your Devices**. In a narrow window the iPad works like an iPhone.

## Open a project

Tap a project. Code connects to the first device that answers, says **Connecting to *Mac***, then
**Reading the project on *Mac***, and shows the project.

Code signs in over SSH with this device's own key, which it keeps in the device's Secure Enclave. It tries each
address it knows for the Mac, such as its local address and its Hub Network address.

- The first time, iOS asks to let Code find devices on your local network. Allow it, or Code can't reach a Mac on
  your network.
- If your vault doesn't know the Mac's key yet, Code asks **Trust this server's key?** before sending anything. Check
  the fingerprint, then tap **Trust and Connect**. The key is saved for every v57 app. A Mac that published its key
  through the vault, or that you reach through your Hub, doesn't ask.
- If the Mac's key has changed, Code refuses to connect without asking. If you know why it changed, forget the old
  key in the Vault app and try again.
- If this device's key needs your confirmation, Face ID or Touch ID asks before Code signs in.

If no device answers, Code shows **Couldn’t Open *project*** with each device's reason. Fix the cause (the Mac is
asleep, Remote Login is off, this device isn't allowed under **Can Sign In**) and tap **Try Again**.

A folder in the project that the Mac doesn't let you read is skipped, and a banner names it.

## Build, Test and Clean

The project's title says what it's doing: **Ready**, **Reading the project…**, the current step while building, then
**Build succeeded**, **Build failed** or **Build stopped**.

- **On iPhone**, the scheme and device are under the title, and **Build**, **Test** and **Clean** are in the bottom
  bar.
- **On iPad**, Build, Test and Clean lead the top bar, and the scheme, device and **Files** button are on its right.

Tap **Build**, **Test** or **Clean** to run it on the Mac. Tap **Stop** to end it there. The buttons are off while an
action runs, or when the scheme can't do that action. Clean deletes the scheme's build products on the Mac.

The project stays connected while you look at its files, and a running build keeps running. Leaving the project (going
back to the list on iPhone, or picking another project on iPad) closes the connection and stops what's running.

### Pick the scheme and the device

- Tap the scheme to choose another one. Code finds schemes the same way as on the Mac, from the project's files on
  the Mac. Xcode schemes come from the project's scheme files.
- Tap the device to pick another one under **Other Machines**. Each says whether it's reached over SSH or through your
  Hub; one that can't be reached is greyed out.

### Signing for Xcode projects

An SSH session on a Mac can't use the login keychain, where signing certificates live. So for an Xcode scheme, the
device menu has a **Signing** section, which you set once per Mac:

- **Don’t Sign**: builds and tests without signing. It makes no app you can run elsewhere.
- **Login Keychain**: unlocks the login keychain with your Mac password before each build. The first time, Code asks
  for the **Mac password** and keeps it in iCloud Keychain.
- **Desktop Session**: builds as the user who is logged in at the Mac, which signs without a password. The build goes
  on while Code is in the background, and Code picks up the log where it left off when you come back.

Your choice is saved in the vault for that Mac, so your other devices use it too.

## Log and Issues

Switch between **Log** and **Issues** under the title.

- **Log** shows each command the action ran, with its status, progress, warnings and output. Before any action it
  says **No Output**.
- **Issues** lists the errors and warnings, with the count, each with its whole message and its file and line. Touch
  and hold a message to select and copy it. With no problems it says **No Issues**.

## Files

Tap the folder button to browse the project's folder on the Mac. Folders come first; hidden files are left out. Tap a
folder to go into it, or a file to read it.

- Text files open highlighted for their language. You can select and copy text, but not edit it.
- Pictures and PDFs show as previews. Other files show their kind and size.
- Files over 2 MB aren't shown: Code says how big they are.
- A folder you can't read says **Couldn’t List** and why.

## Rotation and windows

Code works in portrait and landscape, and in Split View, Slide Over and Stage Manager on iPad.
