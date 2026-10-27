import CodeProgress
import Foundation

/// How an Xcode build on another Mac over SSH signs (`SSHExecutor.Target.signing`). The login keychain stays locked
/// in an SSH session even while it's unlocked on the Mac's screen, so codesign fails there
/// (`errSecInternalComponent`) unless the build unlocks it, or runs in the desktop session instead.
public enum RemoteSigning: String, Sendable, Hashable, Codable, CaseIterable {
  /// No signing (`CODE_SIGNING_ALLOWED=NO`): the code compiles and tests run, but no signed app comes out to copy
  /// and run elsewhere.
  case unsigned
  /// Unlocks the login keychain with the user's password first (`SSHExecutor.secrets`, never in the command line
  /// the log shows).
  case loginKeychain
  /// Runs the build in the desktop session of the user logged in on the Mac (`DesktopJob`), whose login keychain is
  /// unlocked: no password, and the build goes on while the connection is down.
  case desktopSession

  public var title: String {
    switch self {
    case .unsigned: "Don’t Sign"
    case .loginKeychain: "Login Keychain"
    case .desktopSession: "Desktop Session"
    }
  }

  public var symbolName: String {
    switch self {
    case .unsigned: "xmark.seal"
    case .loginKeychain: "person.badge.key"
    case .desktopSession: "menubar.dock.rectangle"
    }
  }

  public var detail: String {
    switch self {
    case .unsigned: "Builds and tests without signing; makes no app to run elsewhere"
    case .loginKeychain: "Unlocks the login keychain with your Mac password"
    case .desktopSession: "Builds as your logged-in user on the Mac; goes on while Code is in the background"
    }
  }

  /// The shell variable the login password reaches the remote shell in (`SSHExecutor.secrets`).
  public static let passwordVariable = "CODE_LOGIN_PASSWORD"

  /// The step running `xcodebuild <arguments> <action>` signed this way.
  func step(_ title: String, _ arguments: String, _ action: String) -> ActionStep {
    switch self {
    case .desktopSession: DesktopJob(command: "xcodebuild \(arguments) \(action)").step(title)
    default: .shell(title, xcodebuild(arguments, action))
    }
  }

  /// The command for the SSH session. The unlock and the build run in one shell, as an SSH session keeps its own
  /// keychain state; `exec` drops the shell, whose command line held the password, before building.
  func xcodebuild(_ arguments: String, _ action: String) -> String {
    switch self {
    case .unsigned:
      return "xcodebuild \(arguments) CODE_SIGNING_ALLOWED=NO \(action)"
    case .loginKeychain:
      let variable = Self.passwordVariable
      return
        "{ [ -n \"$\(variable)\" ] || { echo 'error: No login password is saved for this Mac to unlock its keychain.'; exit 1; }; } && "
        + "security unlock-keychain -p \"$\(variable)\" \"$HOME/Library/Keychains/login.keychain-db\" && unset \(variable) && "
        + "exec xcodebuild \(arguments) \(action)"
    case .desktopSession:
      return "xcodebuild \(arguments) \(action)"
    }
  }
}
