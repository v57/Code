import CodeProgress
import Foundation

/// A command run in the desktop session of the Mac an action runs on over SSH (`RemoteSigning.desktopSession`): a
/// launchd job in the logged-in user's `gui/<uid>` domain, where the login keychain is unlocked, so codesign signs
/// as it does in Xcode with no password sent; an SSH session's own keychain stays locked. The job writes its output to
/// a log in `~/Library/Caches/dev.v57.code/runs/<id>`, which the SSH command follows; when the connection drops (the
/// iPhone puts Code in the background) the job keeps running, and the step follows it again from the first line it
/// hadn't shown. Stop boots the job out.
struct DesktopJob: Sendable {
  var id: String
  /// The command, run by the user's login shell in the folder the SSH command was in.
  var command: String

  init(id: String = String(UUID().uuidString.lowercased().prefix(12)), command: String) {
    self.id = id
    self.command = command
  }

  var label: String { "dev.v57.code.run.\(id)" }
  static let runs = "$HOME/Library/Caches/dev.v57.code/runs"
  var folder: String { "\(Self.runs)/\(id)" }
  /// The follower's last line: the job's exit status, never shown in the log.
  static let exitMarker = "CODE-JOB-EXIT "

  /// Makes the job (its script, plist and log) and starts it, then follows its log. Runs in the project's folder,
  /// which becomes the job's.
  var startScript: String {
    """
    mkdir -p "\(Self.runs)" && find "\(Self.runs)" -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null
    J="\(folder)"; P="$J/job.plist"; mkdir -p "$J" && : > "$J/log"
    cat > "$J/job.sh" <<'CODEJOB'
    (
    \(command)
    )
    echo $? > "$(dirname "$0")/status.part" && mv "$(dirname "$0")/status.part" "$(dirname "$0")/status"
    CODEJOB
    plutil -create xml1 "$P" && plutil -insert Label -string \(label) "$P" \\
      && plutil -insert ProgramArguments -array "$P" && plutil -insert ProgramArguments -string "$SHELL" -append "$P" \\
      && plutil -insert ProgramArguments -string -l -append "$P" \\
      && plutil -insert ProgramArguments -string "$J/job.sh" -append "$P" \\
      && plutil -insert WorkingDirectory -string "$PWD" "$P" && plutil -insert StandardOutPath -string "$J/log" "$P" \\
      && plutil -insert StandardErrorPath -string "$J/log" "$P" && plutil -insert RunAtLoad -bool YES "$P" \\
      || { echo "error: Couldn’t write the build’s launchd job on this Mac."; echo "\(Self.exitMarker)1"; exit 1; }
    if ! launchctl bootstrap "gui/$(id -u)" "$P" 2> "$J/bootstrap.log"; then
      echo "error: Couldn’t start the build in this Mac’s desktop session (is someone logged in on its screen?): $(cat "$J/bootstrap.log")"
      echo "\(Self.exitMarker)1"; exit 1
    fi
    \(followScript(from: 1))
    """
  }

  /// Prints the log from line `line` on as it grows, then the exit marker once the job has finished.
  func followScript(from line: Int) -> String {
    """
    J="\(folder)"
    [ -f "$J/log" ] || { echo "error: This Mac has no log of the build any more."; echo "\(Self.exitMarker)1"; exit 1; }
    tail -n +\(line) -f "$J/log" & t=$!
    while [ ! -f "$J/status" ]; do
      sleep 1
      # A job that ended without writing its status (killed): it failed.
      case "$(launchctl print "gui/$(id -u)/\(label)" 2>/dev/null)" in
        "" | *"state = not running"*) sleep 2; [ -f "$J/status" ] || echo 1 > "$J/status" ;;
      esac
    done
    sleep 1; kill $t 2>/dev/null; wait $t 2>/dev/null
    launchctl bootout "gui/$(id -u)/\(label)" 2>/dev/null
    echo "\(Self.exitMarker)$(cat "$J/status")"
    """
  }

  /// Ends the job and marks it stopped, so a follower still running ends too.
  var stopScript: String {
    "launchctl bootout \"gui/$(id -u)/\(label)\" 2>/dev/null; echo 130 > \"\(folder)/status\""
  }

  /// The step: starts the job, and follows it again after each dropped connection until it ends.
  func step(_ title: String, resource: ProgressResource = .cpu) -> ActionStep {
    let job = self
    return ActionStep(title, resource: resource) { context in
      let state = FollowState()
      let filter: @Sendable (ActionLine) -> Bool = { line in
        if !line.isTransient, line.text.hasPrefix(Self.exitMarker) {
          state.finish(Int32(line.text.dropFirst(Self.exitMarker.count).trimmingCharacters(in: .whitespaces)) ?? 1)
          return false
        }
        if !line.isTransient { state.countLine() }
        return true
      }
      let executor = context.executor
      let directory = context.directory
      context.onStop {
        Task.detached {
          guard let stop = try? executor.start(job.stopScript, directory: directory, environment: [:]) else { return }
          _ = await stop.run { _ in }
        }
      }
      try await context.run(job.startScript, title: title, allowFailure: true, shown: job.command, filter: filter)
      var attempts = 0
      while state.exitStatus == nil {
        // The connection dropped (or the follower ended early): the job goes on there; follow it again.
        attempts += 1
        if attempts > 30 { throw ActionError.launchFailed("lost the connection to the build and couldn’t get it back") }
        try await Task.sleep(for: .seconds(attempts == 1 ? 1 : 3))
        if attempts == 1 { context.log("Reconnecting: the build goes on on the Mac.") }
        try await context.run(
          job.followScript(from: state.lines + 1), title: title, allowFailure: true, shown: "", filter: filter)
      }
      if let status = state.exitStatus, status != 0 { throw ActionError.failed(status: status, step: title) }
    }
  }

  /// What the follower has shown so far, and the job's exit status once known.
  private final class FollowState: @unchecked Sendable {
    private let lock = NSLock()
    private var shown = 0
    private var status: Int32?

    var lines: Int { lock.withLock { shown } }
    var exitStatus: Int32? { lock.withLock { status } }
    func countLine() { lock.withLock { shown += 1 } }
    func finish(_ status: Int32) { lock.withLock { self.status = status } }
  }
}
