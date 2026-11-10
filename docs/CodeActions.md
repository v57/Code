# CodeActions

## Purpose

CodeActions finds what a project folder can build and run, and runs it, the way Xcode's toolbar does:

- **Schemes** (`ActionScheme`): detectors read a folder and its subfolders a couple of levels down and find Xcode
  schemes, Swift packages, Cargo, Go, Gradle and Android, Maven, Node, Python, CMake, Make, Zig, Dart, .NET, Elixir,
  Ruby, PHP and Docker Compose projects, each with its Run, Build, Test, Clean and Lint commands, and Install, Export
  (notarized) and Upload for Xcode apps.
- **Run destinations** (`RunDestination`): this Mac, iOS simulators and devices, Android devices, emulators and
  virtual devices, another machine over SSH, a container.
- **Running** (`ActionController`): an action as steps on a pseudo-terminal with the login shell's environment, the
  log, the issues parsed from it, and progress estimated from earlier runs ([CodeProgress](CodeProgress.md)).
- **Other places**: another machine over SSH (`SSHExecutor`, the system's `ssh` or SSHKit's in-process client) or a
  container on a local Docker or Colima runtime (`ContainerExecutor`).
- **Release tools** (`ReleaseTools`, `Sources/CodeActions/Release/`): the scripts every v57 Mac app's release archive
  goes through.

It has no UI: the sheets are in [CodeActionsUI](CodeActionsUI.md). v57's Shell offers these same schemes as its smart
actions and runs `terminalCommand(for:)` in a terminal. The user guide's [Run, Build and Test](Run-Build-and-Test.md)
shows the result in Code.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeActions", package: "Code"),
```

CodeActions depends on [CodeProgress](CodeProgress.md), [CodeFolders](CodeFolders.md) and SSHKit from
[v57/SSH](https://github.com/v57/SSH) (so an `<App>-Local.xcworkspace` that lists `../Code` lists `../SSH` too).

List a folder's schemes:

```swift
import CodeActions
import Foundation

let root = URL(fileURLWithPath: "/path/to/project")
for scheme in ProjectScanner.scan(root: root) {
  let actions = ActionKind.allCases.filter { scheme.supports($0) }.map(\.title)
  print(scheme.projectName, scheme.name, scheme.toolchain.displayName, actions)
}
```

Build one and watch it finish:

```swift
@MainActor
final class Builder {
  let actions: ActionController

  init(root: URL) {
    actions = ActionController(root: root)
    actions.addFinishHandler { [unowned self] kind, succeeded in
      print(kind.title, succeeded ? "succeeded" : "failed", self.actions.errorCount, "errors")
    }
  }

  func build() {
    guard let scheme = ProjectScanner.scan(root: actions.root).first(where: { $0.supports(.build) }) else { return }
    actions.perform(.build, scheme: scheme, destination: .mac)
  }
}
```

For a toolbar, call `actions.scan()` and bind to `schemes`, `selectedSchemeID`, `destinations`,
`selectedDestinationID`, `state`, `progress`, `issues` and `log`; `perform(_:)` runs the selected scheme.

## Main API

Schemes

- `ProjectScanner.scan(root:depth:excluded:)`: every scheme under a folder, the root's first.
  `scanProjects(root:depth:excluded:picks:allowing:isMirror:)` also returns the containers found and takes one picked
  container per folder. `schemes(in:)` reads one folder only. `fingerprint(of:)` identifies a folder's entries plus
  the detectors' `revision`, for caching scans. Build output and dependency folders are skipped
  (`skippedFolders`), and the home folder is only looked at itself.
- `ProjectFolder`: a folder's entries, listed once and shared by every detector (`hasFile`, `hasDirectory`,
  `first(withSuffix:)`, `read`, `subfolder`, `containers`, `pickedContainer`).
- `ProjectDetector`: `schemes(in:) -> [ActionScheme]`. One per kind of project: `XcodeDetector`,
  `SwiftPackageDetector`, `CargoDetector`, `GoDetector`, `GradleDetector`, `MavenDetector`, `NodeDetector`,
  `PythonDetector`, `CMakeDetector`, `ZigDetector`, `DartDetector`, `DotnetDetector`, `ElixirDetector`,
  `RubyDetector`, `PHPDetector`, `DockerComposeDetector`, and `MakeDetector` when nothing else matched.
- `ActionScheme`: `name`, `toolchain`, `directory`, `commands` (`[ActionKind: String]`), `platforms`,
  `xcodeContainer`, Android ids, `executable`, `derivedDataPath`; `supports(_:)`, `terminalCommand(for:)` (one shell
  line, for a terminal), `inBuildFolders(_:)`.
- `ActionKind` (`run`, `build`, `test`, `clean`, `lint`, `install`, `export`, `upload`, with `title`,
  `progressTitle`, `symbolName`), `Toolchain`, `Platform` (`mac`, `iOS`, `android`).
- `shellQuote(_:)` for commands on this computer (cmd's rules on Windows), `posixShellQuote(_:)` for anything sent to
  another machine or a container.

Running

- `ActionController(root:)` (`@MainActor`, `@Observable`): `scan()`, `schemes`, `containers`, `selectContainer(_:)`,
  `refreshDestinations()`, `destinations`, `canPerform(_:)`, `perform(_:environment:)`,
  `perform(_:scheme:destination:environment:)`, `stop()`, `state`, `isRunning`, `runningKind`, `progress`,
  `stepTitle`, `issues`, `errorCount`, `warningCount`, `log` (`ActionLog`), `addFinishHandler(_:)`, `didFinish`,
  `willPerform`, `confirm` (asked before quitting a running app), `excludedNames`. Choices are kept in `UserDefaults`
  per folder.
- `ActionPlanner.steps(for:scheme:destination:signing:)`: the steps (`ActionStep`) of an action: plain commands for
  most toolchains; build, install and launch for apps on simulators, devices and Android.
- `RunDestination` and `DestinationProvider.load(platforms:)`: simulators (`simctl`), devices (`devicectl`), `adb`
  devices and the Android SDK's virtual devices.
- `BuildLogParser`, `BuildIssue`, `ActionProgress`: diagnostics from Swift and Clang, Go, Rust, TypeScript, Kotlin,
  Java, C#, Dart, Elixir, Python and Zig, and progress such as "[n/m]" or Cargo's and Gradle's.
- `ActionExecutor` and `ActionCommand`: where commands run. `LocalExecutor` (a pseudo-terminal here, `PTYProcess`),
  `SSHExecutor`, `ContainerExecutor`, `LowPriorityExecutor` (background priority, for queued installs).
- `ShellEnvironment.shared`: the login shell's environment (`variables`, `path`, `which(_:)`), so tools are found as
  in Terminal even when the app was opened from the Dock. `SubprocessCapture.run(...)` runs a listing command.
- `ActionError`: `launchFailed`, `failed(status:step:)`, `missing`, `cancelled`.

Xcode apps

- `AppInstall`: Install's steps (archive stamped with the repository's commit count, exported with Developer ID when
  the keychain has that identity; quit the running copy; replace the one in `~/Applications`, else `/Applications`;
  reopen in the background if it was running). `InstalledApp`, `InstallRecord`, `InstallStatus.evaluate(...)`.
- `Notarization`: Export's checks. `DeveloperIDIdentity`, `NotaryProfileStatus`, `NotaryCredentials`,
  `storeArguments(profile:credentials:)` (credentials go to `notarytool`, which keeps them in the keychain),
  `defaultProfile` ("notary", or `NOTARY_PROFILE`).
- `AppStoreUpload.buildNumberVariable` (`CODE_BUILD_NUMBER`) and `isValidBuildNumber(_:)`.
- `SourceFingerprint` and `LocalDependencies`: whether an installed app was built from the source as it is now (Git
  blob ids of the working tree, or dates outside Git); `SourceFingerprint.commitCount(in:)`.
- `XcodeCompilationDatabase.make(...)`: an Xcode scheme's compiler arguments as `compile_commands.json`, for
  SourceKit-LSP, which doesn't read Xcode projects.

Build folders

- `BuildFolders`: when `~/Developer/Builds` exists, builds go to an instance `<kind>/<project>/<n>` of it, shared by
  every checkout of a repository, so dependencies build once. `ActionScheme.inBuildFolders()` moves Xcode's derived
  data, SwiftPM's scratch path and Cargo's target folder there when an action starts. Without the folder, each tool
  builds where it always does. Archives go to `.build/<scheme>` in the scheme's folder.

## Adding a kind of project

New project kinds and commands go into CodeActions' detectors, never into an app (Shell picks them up from here).

1. Write a `ProjectDetector` in `Sources/CodeActions/Detectors/` (`AppleDetectors.swift`, `JVMDetectors.swift`,
   `ScriptDetectors.swift` or `SystemsDetectors.swift`). Read only the files it needs from the `ProjectFolder`, and
   return one `ActionScheme` per runnable thing with a shell command per `ActionKind` it supports.
2. If it is a new build system, add a `Toolchain` case with its `displayName` and `symbolName`.
3. Add the detector to `ProjectScanner.detectors`.
4. Bump `ProjectScanner.revision`, so scans cached under `fingerprint(of:)` are redone (Shell caches them).
5. As needed: diagnostics in `BuildLogParser`, an official image in `ContainerImages` (else it has none to build in a
   container), and steps in `ActionPlanner` if Run is more than one command.
6. Add tests in `Tests/CodeActionsTests` on a temporary folder, as the other detectors' tests do.

## Remote actions over SSH

`SSHExecutor(target:localRoot:login:secrets:)` runs the same steps on another machine: the project's folder there
(`Target.directory`, standing for `localRoot` here), its login shell's environment, output streamed back, and Stop
closing the connection. Commands sent there are quoted for POSIX shells on every client.

- With a `login` (an SSHKit `SSHServer`), SSHKit's in-process client runs them, as on iPhone and iPad, which have no
  `ssh`. Without one, the system's `ssh` client runs on a pseudo-terminal here, with the user's keys and agent.
- A host key the target names (`Target.hostKey`) is pinned for the connection. Any other host follows the login's
  `SSHServer.trust` or the user's `known_hosts`; a key nobody vouches for is refused.
- `fallbackHosts` are tried in order when `host` doesn't answer (in-process client).
- `ProjectMirror.fetch(_:projectID:client:)` copies a remote project's manifests and Xcode scheme files over SFTP, so
  the detectors find its schemes here; the schemes then run there. Folders the login can't read are copied empty and
  listed in `Copy.unreadable`.
- `RemoteSigning` decides how Xcode builds sign there, since the login keychain stays locked in an SSH session:
  `unsigned` (`CODE_SIGNING_ALLOWED=NO`), `loginKeychain` (unlocked with the password from `secrets`, which never
  appears in the logged command) or `desktopSession` (the build runs as a job in the desktop session of the user
  logged in on that Mac, whose keychain is unlocked, and goes on while the connection is down).
- `BuildSource` (`.local`, `.machine(Target)`, `.container(ContainerRuntime)`) and `BuildCapabilities` pick where a
  project is built from; `ActionController` keeps a scheme, container and destination per source
  (`buildSources`, `selectBuildSource(_:)`, `selectedBuildSourceStatus`).
- `ContainerRuntimes.detect()` lists Colima and Docker runtimes without starting anything; `ContainerExecutor` runs a
  new container per command with the folder at `/workspace` and a build volume at `/build`; `ContainerImages` picks
  the `.devcontainer` image, else the toolchain's official one.

## Release tools

`Sources/CodeActions/Release/` is the one copy of the tools v57's Mac release archives link with. Install and Export
use them through `ReleaseTools.xcodebuild` (in CodeActions' resources); release scripts call them from a checkout of
this repository.

- `xcodebuild-release <xcodebuild arguments>`: xcodebuild with Swift LTO (`-internalize-at-link`,
  `-conditional-runtime-records`), `ld-archive-prelink` as the linker and `actool-icon-slim` as the asset catalog
  compiler; for an `archive` with `-archivePath`, it then runs `release-languages` on the archive's app. Example:
  `xcodebuild-release -project App.xcodeproj -scheme App -archivePath build/App.xcarchive archive`.
- `ld-archive-prelink`: Xcode pre-links each Swift package target into one object, which keeps all of it in the app.
  For those links this writes a static archive instead, so the final link drops unused package code. Every other link
  goes to the real `ld`.
- `actool-icon-slim`: runs `actool`, then stores an Icon Composer icon's flattened fallback pictures as HEVC instead of
  lossless, after checking they decode to the same picture (`ACTOOL_ICON_QUALITY`, default 0.8).
- `release-languages`: copies the app's bundled translations from v57/Localizations into its bundle, writes a stub
  `.lproj` for each downloadable language, sets `CFBundleLocalizations` and `V57Languages`, and re-signs the app as it
  was signed. Its settings come from the project's `release.env` (`LANGUAGE_SOURCES`, `LANGUAGES_BUNDLED`,
  `LOCALIZATIONS_REF`) or `V57_…` variables. The files come from one pinned commit (a full 40-character hash); a
  release with sources and no commit is refused, and a file name that doesn't look like one fails the release.

The scripts need macOS with Xcode (`zsh`, `xcrun`, `python3`).

## Platform notes

- **macOS**: everything.
- **iOS (iPadOS)**: builds; runs nothing locally (`LocalExecutor` throws). Actions run on another machine through
  `SSHExecutor` with a `login`. Code's iPhone and iPad app works this way. Xcode schemes come from the scheme files and
  `project.pbxproj`, as there is no `xcodebuild -list`.
- **Windows**: commands run through `cmd` with the user's environment, stopping the whole process tree; the local
  destination is This PC. Notarization needs a Mac. Part of Code's early Windows build.
- **Linux**: commands run on a pseudo-terminal through `ChildProcess`; part of Code's early Linux build.
- **Android**: not yet as a host. Android apps are a destination: they install with Gradle, launch with `adb` and
  stream logcat.

## Testing

```bash
swift test --filter CodeActionsTests
```

The tests cover the detectors on temporary folders, the planner's commands, log parsing, build sources, build folders,
install records, notarization parsing, remote quoting, the project mirror and `release-languages`. Some need real
targets and are off unless asked:

- `CODE_SSH_TEST_HOST`, `CODE_SSH_TEST_PORT`, `CODE_SSH_TEST_USER` and `CODE_SSH_TEST_KEY` (a private key file the
  server accepts): runs over SSHKit's in-process client (`InProcessSSHTests`, the project mirror). A private
  `sshd -D -f <config>` on a high port with an ECDSA host key and an ECDSA client key works; libssh2 here does no
  ed25519. `CODE_SSH_TEST_HOST` alone, with `CODE_SSH_TEST_HOST_KEY` (an OpenSSH public key line), runs the system's
  `ssh` client with your own keys.
- `CODE_CONTAINER_TEST=1 swift test --filter ContainerExecutor`: needs a running Docker or Colima runtime, pulls small
  images and removes what it makes.
- `CODE_DESKTOP_JOB_TEST=1`: runs a desktop-session job; needs a user logged in on this Mac.

`ActionController.stepsOverride` (steps to run instead of the planned ones) and `localExecutor` (where this
computer's commands run) let a host or a test replace what runs.
