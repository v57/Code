# CodeActions

## Purpose

CodeActions finds what a project folder can build and run, and runs it, the way Xcode's toolbar does:

- **Schemes** (`ActionScheme`): detectors read a folder and its subfolders a couple of levels down and find Xcode
  schemes, Swift packages, Cargo, Go, Gradle and Android, Maven, Node, Python, CMake, Make, Zig, Dart, .NET, Elixir,
  Ruby, PHP and Docker Compose projects, each with its Run, Build, Test, Clean and Lint commands, and Install, Export
  (notarized) and Upload for Xcode apps.
- **Run destinations** (`RunDestination`): this Mac, iOS simulators and devices, Android devices, emulators and
  virtual devices, another machine over SSH, a container.
- **Running** (`ActionController`): an action as steps (`ActionStep`), several runs at once, each with its log, the
  issues parsed from it, and progress estimated from earlier runs ([CodeProgress](CodeProgress.md)).
- **Other places**: another machine over SSH (`SSHExecutor`, the system's `ssh` or SSHKit's in-process client) or a
  container on a local Docker or Colima runtime (`ContainerExecutor`).
- **Run presets** (`RunPreset`): an action with its build source, project, scheme and destination, kept in a project's
  `.dev/actions.json`.
- **Release tools** (`ReleaseTools`, `Sources/CodeActions/Release/`): the scripts every v57 Mac app's release archive
  goes through.

CodeActions is not a build system. A scheme's commands are the project's own tools (`xcodebuild`, `swift`, `cargo`,
`go`, `gradle`, `npm`…), found on the login shell's PATH; nothing is bundled, and a tool that isn't installed fails
like it would in Terminal. It has no UI: the sheets and run blocks are in [CodeActionsUI](CodeActionsUI.md). v57's
Shell offers these same schemes as its smart actions and runs `terminalCommand(for:)` in a terminal. The user guide's
[Run, Build and Test](Run-Build-and-Test.md) shows the result in Code.

## Platforms

<!-- platforms: macos ios=partial linux=partial windows=partial -->

- **macOS**: everything. Commands run on a pseudo-terminal (`PTYProcess`) with the login shell's environment.
- **iOS (iPadOS)**: builds, but runs nothing locally: `LocalExecutor` throws `ActionError.missing`. Actions run on
  another machine through `SSHExecutor` with a `login`, as in Code's iPhone and iPad app. Xcode schemes come from the
  scheme files and `project.pbxproj`, as there is no `xcodebuild -list`.
- **Windows**: commands run through `cmd /d /s /c` with the user's environment, their output read from pipes; Stop
  ends the whole process tree (`taskkill /T`). The local destination is This PC. `shellQuote(_:)` follows cmd's rules.
  Part of Code's early Windows build.
- **Linux**: commands run through `bash -c` (`ChildProcess`), their output read from pipes; Stop ends the process
  group. The local destination is This Computer. Part of Code's early Linux build.
- **Mac only**: `AppInstall`'s steps, `Notarization`'s checks (elsewhere they report that notarization needs a Mac),
  and `XcodeCompilationDatabase.write(scheme:destination:to:environment:)`.
- **Android**: not yet as a host. Android apps are a destination: they install with Gradle, launch with `adb` and
  stream logcat.

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

## Main API

### Finding schemes

`ProjectScanner.scan(root:depth:excluded:)` returns every scheme under a folder, the root's first.
`scanProjects(root:depth:excluded:picks:allowing:isMirror:)` returns a `Scan` with the schemes and the containers
found (Xcode workspaces, projects, packages), and takes one picked container per folder. `schemes(in:)` reads one
`ProjectFolder` only. Build output, dependency and source folders are skipped (`skippedFolders`), and the home folder
and those above it are only looked at themselves.

```swift
let folder = ProjectFolder(listing: root)
let key = ProjectScanner.fingerprint(of: folder)  // unchanged: the cached scan still holds
let schemes = ProjectScanner.schemes(in: folder)
let test = schemes.first?.terminalCommand(for: .test)  // one shell line, for a terminal
```

- `ProjectFolder`: a folder's entries, listed once and shared by every detector (`hasFile(_:)`, `hasDirectory(_:)`,
  `first(withSuffix:)`, `read(_:)`, `subfolder(_:)`, `containers`, `pickedContainer`, `isMirror`).
- `ProjectDetector`: `schemes(in:) -> [ActionScheme]`. One per kind of project, in `ProjectScanner.detectors`:
  `XcodeDetector`, `SwiftPackageDetector`, `CargoDetector`, `GoDetector`, `GradleDetector`, `MavenDetector`,
  `NodeDetector`, `PythonDetector`, `CMakeDetector`, `ZigDetector`, `DartDetector`, `DotnetDetector`,
  `ElixirDetector`, `RubyDetector`, `PHPDetector`, `DockerComposeDetector`, and `MakeDetector` when nothing else
  matched.
- `ActionScheme`: `name`, `toolchain`, `directory`, `commands` (`[ActionKind: String]`), `platforms`,
  `xcodeContainer`, `androidApplicationID`, `androidModule`, `executable`, `derivedDataPath`, `system` (set for a
  scheme that builds only on another system, such as a WinUI app); `id`, `projectName`, `supports(_:)`,
  `terminalCommand(for:)`, `inBuildFolders(_:)`, `inContainer()`.
- `ActionKind` (`run`, `build`, `test`, `clean`, `lint`, `install`, `export`, `upload`, with `title`,
  `progressTitle`, `symbolName`, `isDistribution`, `needsNotarization`), `Toolchain` (with `displayName` and
  `symbolName`), `Platform` (`mac`, `iOS`, `android`).
- `shellQuote(_:)` for commands on this computer (cmd's rules on Windows), `posixShellQuote(_:)` for anything sent to
  another machine or a container.

### Run destinations and steps

```swift
let destinations = await DestinationProvider.load(platforms: Set(scheme.platforms))
let steps = ActionPlanner.steps(for: .run, scheme: scheme, destination: destinations.first)
print(steps.map(\.title))  // build, install and launch for an app on a device
```

- `RunDestination` (`id`, `name`, `kind`, `detail`, `isAvailable`, `model`, `platform`; `.mac` is this computer) and
  `DestinationProvider.load(platforms:)`: simulators (`simctl`), devices (`devicectl`), `adb` devices and the Android
  SDK's virtual devices.
- `ActionPlanner.steps(for:scheme:destination:signing:)`: an action's `ActionStep`s: plain commands for most
  toolchains; build, install and launch for apps on simulators, devices and Android.
- `ActionStep(_:resource:timing:work:)` and `ActionStep.shell(_:_:environment:resource:timing:)`: a step, with what
  bounds its speed for the progress estimate. Its work gets an `ActionContext` (`directory`, `environment`,
  `executor`, `run(_:title:in:environment:allowFailure:shown:filter:)`, `capture(_:in:timeout:)`, `log(_:)`, `onStop(_:)`, `isCancelled`).

### Running actions

`ActionController(root:)` is the toolbar's model for one folder (`@MainActor`, `@Observable`). Choices are kept in
`UserDefaults` per folder.

```swift
actions.scan()
actions.selectedSchemeID = actions.schemes.first?.id  // nil uses the first scheme
if actions.canPerform(.test) { actions.perform(.test) }
```

- Schemes and choices: `scan()`, `isScanning`, `schemes`, `selectedSchemeID`, `selectedScheme`, `containers`,
  `selectContainer(_:)`, `refreshDestinations()`, `destinations`, `selectedDestinationID`, `selectedDestination`,
  `excludedNames`.
- Running: `canPerform(_:)`, `perform(_:environment:)` (the selected scheme and destination),
  `perform(_:scheme:destination:environment:source:tag:)`, `restart(_:)`, `stop()` (the newest run), `stop(_:)`,
  `stopAll()`, `dismiss(_:)`, `hideFinished()`, `clearFinished()`.
- State: `runs` (`ActionRun`s, several at once; `keptRuns` of them are kept), `current`, `state` (`State`: `idle`,
  `running`, `succeeded`, `failed`, `stopped`), `isRunning`, `runningKind`, `progress`, `stepTitle`, `issues`,
  `errorCount`, `warningCount`, `log` (`ActionLog`), `notes`.
- Hooks: `addFinishHandler(_:)`, `didFinish`, `willPerform` (the app saves open files), `confirm` (asked before a step
  does something the user may mind, such as Install quitting the running app), `stepsOverride` (steps to run instead
  of the planned ones; the debugger replaces Run this way), `localExecutor` (where this computer's commands run),
  `progressHistory`.
- `ActionRun`: one run's `kind`, `scheme`, `destination`, `tag`, `phase`, `progress`, `stepTitle`, `issues`, `log`,
  `title`, `isWorking`, `duration(at:)`.
- `ActionError`: `launchFailed`, `failed(status:step:)`, `missing`, `cancelled`.

### Logs, issues and progress

```swift
var parser = BuildLogParser(directory: scheme.directory)
for event in parser.consume("Sources/App/main.swift:3:5: error: cannot find 'x' in scope") {
  if case .issue(let issue) = event { print(issue.severity, issue.message, issue.line ?? 0) }
}
```

- `BuildLogParser.consume(_:)` returns `Event`s (`issue`, `progress`, `unit`, `count(done:total:)`): diagnostics from
  Swift and Clang, Go, Rust, TypeScript, Kotlin, Java, C#, Dart, Elixir, Python and Zig, and progress such as
  "[n/m]" or Cargo's and Gradle's.
- `BuildIssue` (`severity`, `message`, `url`, `line`, `column`), `ActionProgress` (`fraction`, `message`,
  `remaining`).
- `ActionLog`: `entries` (each `Entry` an `output`, `command`, `status` or `failure` line), `revision`, `text`,
  `onAppend`, `onClear`, `clear()`; at most `ActionLog.limit` lines.
- `ANSI.strip(_:)`.

### Where commands run

An `ActionExecutor` starts a shell command and returns an `ActionCommand` (`run(onLine:)`, `stop()`). Detectors, the
planner and log parsing are the same on every executor.

```swift
let command = try LocalExecutor().start("swift build", directory: root, environment: ShellEnvironment.shared.variables)
let status = await command.run { line in print(line.text) }
```

- `LocalExecutor` (a pseudo-terminal here, `PTYProcess`), `SSHExecutor`, `ContainerExecutor`,
  `LowPriorityExecutor(base:clamp:niceness:)` (background priority, for queued installs).
- `ShellEnvironment.shared`: the login shell's environment (`variables`, `path`, `which(_:)`, `androidSDK`, `adb`,
  `androidEmulator`), so tools are found as in Terminal even when the app was opened from the Dock.
  `SubprocessCapture.run(_:_:directory:environment:timeout:requireSuccess:)` runs a listing command and returns its
  output.

### Another machine or a container

`SSHExecutor(target:localRoot:login:secrets:system:)` runs the same steps on another machine: the project's folder
there (`Target.directory`, standing for `localRoot` here), its login shell's environment, output streamed back, and
Stop closing the connection. Commands sent there are quoted for POSIX shells on every client.

```swift
let target = SSHExecutor.Target(
  id: "build-mac", name: "Build Mac", host: "build.local", port: 22, user: "me", directory: "/Users/me/MyApp")
actions.machineTargets = [target]
actions.selectBuildSource(BuildSource(place: .machine(target)))
actions.perform(.build)
```

- With a `login` (an SSHKit `SSHServer`), SSHKit's in-process client runs the commands, as on iPhone and iPad, which
  have no `ssh`. Without one, the system's `ssh` client runs on a pseudo-terminal here, with the user's keys and
  agent. `ActionController.remoteLogin` gives the login per target.
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
- `BuildSource` (`place`: `.local`, `.machine(SSHExecutor.Target)`, `.container(ContainerRuntime)`; `BuildSource.local`)
  and `BuildCapabilities` (`canBuild(_:)`, `canUse(_:)`) pick where a project is built from. `ActionController` keeps
  a scheme, container and destination per source: `buildSources`, `selectBuildSource(_:)`, `selectedBuildSource`,
  `selectedBuildSourceStatus`, `refreshBuildSources()`, `setBuildFolder(_:for:)`.
- `ContainerRuntimes.detect(environment:)` lists Colima and Docker runtimes without starting anything;
  `ContainerExecutor(runtime:image:toolchain:localRoot:)` runs a new container per command with the folder at
  `/workspace` and a build volume at `/build`; `ContainerImages.image(for:root:)` picks the `.devcontainer` image,
  else the toolchain's official one.

### Run presets

```swift
let preset = actions.presetFromToolbar(.test)
var presets = (try? RunPresetFile.read(in: actions.root)) ?? []
presets.append(preset)
try RunPresetFile.write(presets, in: actions.root)  // .dev/actions.json
actions.perform(preset: preset)
```

- `RunPreset` (`name`, `action`, `from`, `project`, `scheme`, `target`, every part a name so the file survives a
  clone; `RunPreset.actions` are Run, Test and Build).
- `RunPresetFile`: `read(in:)`, `write(_:in:)`, `decode(_:)`, `encode(_:)`, `url(in:)`; `ReadError`.
- On `ActionController`: `presetFromToolbar(_:)`, `autoName(for:)`, `state(of:)` (`RunPresetState`: `ready` or
  `unavailable` with why), `resolve(_:)` (a `ResolvedRunPreset`), `perform(preset:tag:)` (its own choices, leaving
  the toolbar's), `useInToolbar(_:)`, `refreshPresetDestinations(for:)`, `isRunning(tag:)`, `run(tag:)`.

### Xcode apps

```swift
let status = InstallStatus.evaluate(
  installed: InstalledApp(at: AppInstall.destination(of: scheme)), record: nil,
  sourceBuild: SourceFingerprint.commitCount(in: scheme.directory)
) { SourceFingerprint.of(scheme) }
```

- `AppInstall`: Install's steps (archive stamped with the repository's commit count, exported with Developer ID when
  the keychain has that identity; quit the running copy; replace the one in `~/Applications`, else `/Applications`;
  reopen in the background if it was running). `destination(appName:)`, `destination(of:)`, `InstalledApp`,
  `InstallRecord`, `InstallStatus.evaluate(installed:record:sourceBuild:fingerprint:)` (`notInstalled`, `current`,
  `outdated`).
- `Notarization`: Export's checks. `developerIDIdentities()` (`DeveloperIDIdentity`), `checkProfile(_:)`
  (`NotaryProfileStatus`), `storeAPIKeyProfile(_:path:keyID:issuerID:)`, `storeAppleIDProfile(_:appleID:teamID:password:)`,
  `storeArguments(profile:credentials:)` with `NotaryCredentials` (credentials go to `notarytool`, which keeps them
  in the keychain), `defaultProfile` ("notary", the one Export uses when `NOTARY_PROFILE` is unset).
- `AppStoreUpload.buildNumberVariable` (`CODE_BUILD_NUMBER`) and `isValidBuildNumber(_:)`.
- `SourceFingerprint` and `LocalDependencies`: whether an installed app was built from the source as it is now (Git
  blob ids of the working tree, or dates outside Git); `SourceFingerprint.commitCount(in:)`.
- `XcodeCompilationDatabase.make(fromIndexSettings:directory:workingDirectory:architecture:)`: an Xcode scheme's
  compiler arguments as `compile_commands.json`, for SourceKit-LSP, which doesn't read Xcode projects;
  `write(scheme:destination:to:environment:)` runs xcodebuild for them and writes the files (macOS).

### Build folders

`BuildFolders` is off by default, so each tool builds where it always does (Xcode's DerivedData, `.build`, `target`).
Opted in (`V57_BUILD_FOLDERS` in the environment, or the `V57BuildFolders` user default, `defaults write -g` for every
app: `1` for `~/Developer/Builds` or a folder's path), builds go to an instance `<kind>/<project>/<n>` of that folder,
the agents' build-lease layout, shared by every checkout of a repository, so dependencies build once.
`ActionScheme.inBuildFolders()` moves Xcode's derived data, SwiftPM's scratch path and Cargo's target folder there when
an action starts. Archives go to `.build/<scheme>` in the scheme's folder.

```swift
let folders = BuildFolders.standard
let scheme = scheme.inBuildFolders(folders)  // unchanged while build folders are off
```

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

## Release tools

`Sources/CodeActions/Release/` is the one copy of the tools v57's Mac release archives link with. Install and Export
use them through `ReleaseTools.xcodebuild` (in CodeActions' resources; `ReleaseTools.folder` is the folder); release
scripts call them from a checkout of this repository.

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

`ActionController.stepsOverride` and `localExecutor` let a host or a test replace what runs.

## Related

- [CodeActionsUI](CodeActionsUI.md): the Notarization and Upload sheets and the run blocks for an `ActionController`.
- [CodeProgress](CodeProgress.md): the progress estimate behind `ActionProgress`.
- [CodeFolders](CodeFolders.md): `ProjectContainer` and folder scope, shared with CodeWorkspace.
- [CodeKit](CodeKit.md): `ProjectServices` follows the builds (compiler arguments for SourceKit-LSP) and the debugger
  replaces Run.
- [SSHKit](https://github.com/v57/SSH/blob/main/docs/SSHKit.md): the in-process SSH and SFTP client behind
  `SSHExecutor` and `ProjectMirror`.
- [ShellIntegrations](https://github.com/v57/Shell/blob/main/Docs/ShellIntegrations.md): Shell's smart actions,
  which are these schemes.
