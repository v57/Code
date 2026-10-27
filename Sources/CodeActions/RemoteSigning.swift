import Foundation

/// How an Xcode build on another Mac over SSH signs (`SSHExecutor.Target.signing`). The login keychain stays locked
/// in an SSH session even while it's unlocked on the Mac's screen, so codesign fails there
/// (`errSecInternalComponent`) unless the build unlocks a keychain first.
public enum RemoteSigning: String, Sendable, Hashable, Codable, CaseIterable {
  /// No signing (`CODE_SIGNING_ALLOWED=NO`): the code compiles and tests run, but no signed app comes out to copy
  /// and run elsewhere.
  case unsigned
  /// Unlocks the login keychain with the user's password first (`SSHExecutor.secrets`, never in the command line
  /// the log shows).
  case loginKeychain
  /// Unlocks a keychain that holds only the Mac's signing identities, made on the Mac by `setupScript`, with the
  /// password it keeps there.
  case signingKeychain

  public var title: String {
    switch self {
    case .unsigned: "Don’t Sign"
    case .loginKeychain: "Login Keychain"
    case .signingKeychain: "Signing Keychain"
    }
  }

  public var symbolName: String {
    switch self {
    case .unsigned: "xmark.seal"
    case .loginKeychain: "person.badge.key"
    case .signingKeychain: "key.horizontal"
    }
  }

  public var detail: String {
    switch self {
    case .unsigned: "Builds and tests without signing; makes no app to run elsewhere"
    case .loginKeychain: "Unlocks the login keychain with your Mac password"
    case .signingKeychain: "Unlocks a keychain set up on the Mac for signing"
    }
  }

  /// The shell variable the login password reaches the remote shell in (`SSHExecutor.secrets`).
  public static let passwordVariable = "CODE_LOGIN_PASSWORD"
  /// The signing keychain and its password on the Mac, and where `setupScript` goes for the user to run there.
  public static let keychainPath = "$HOME/Library/Keychains/remote-signing.keychain-db"
  public static let passwordPath = "$HOME/.config/v57/remote-signing.password"
  public static let setupPath = ".config/v57/remote-signing-setup.sh"
  /// What the user runs in Terminal on the Mac.
  public static let setupCommand = "sh ~/\(setupPath)"

  /// `xcodebuild <arguments> <action>` signed this way. The unlock and the build run in one shell, as an SSH session
  /// keeps its own keychain state; `exec` drops the shell, whose command line held the password, before building.
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
    case .signingKeychain:
      let keychain = Self.keychainPath
      return
        "{ [ -f \"\(keychain)\" ] && [ -f \"\(Self.passwordPath)\" ] || { echo 'error: Remote signing isn’t set up on this Mac: run \(Self.setupCommand) in Terminal there.'; exit 1; }; } && "
        + "security unlock-keychain -p \"$(cat \"\(Self.passwordPath)\")\" \"\(keychain)\" && "
        + "exec xcodebuild \(arguments) OTHER_CODE_SIGN_FLAGS=\"\\$(inherited) --keychain \(keychain)\" \(action)"
    }
  }

  /// Run once in Terminal on the Mac (its screen, where the login keychain is unlocked): makes the signing keychain
  /// with a random password kept in `passwordPath` (readable by the user only), copies the login keychain's signing
  /// identities into it (macOS asks to allow each export), lets codesign use them without asking, and adds it to
  /// the user's keychain list. Running it again starts over, picking up renewed certificates.
  public static let setupScript = """
    #!/bin/sh
    # Remote signing for Code: a keychain holding this Mac's signing identities, which builds started over SSH
    # unlock (the login keychain stays locked in an SSH session). Run it in Terminal on this Mac.
    set -eu
    umask 077
    keychain="\(keychainPath)"
    password_file="\(passwordPath)"
    mkdir -p "$(dirname "$password_file")"
    [ -s "$password_file" ] || /usr/bin/openssl rand -base64 32 > "$password_file"
    password=$(cat "$password_file")

    # Start over: a renewed certificate replaces the old ones.
    security delete-keychain "$keychain" 2>/dev/null || true
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings "$keychain"
    security unlock-keychain -p "$password" "$keychain"

    echo "Copying the signing identities from the login keychain (allow each one macOS asks about)…"
    folder=$(mktemp -d)
    trap 'rm -rf "$folder"' EXIT
    export_password=$(/usr/bin/openssl rand -hex 16)
    security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 \\
      -P "$export_password" -o "$folder/identities.p12"
    security import "$folder/identities.p12" -k "$keychain" -P "$export_password" \\
      -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" > /dev/null

    # In the user's keychain list, after the ones there, so xcodebuild finds its identities.
    set --
    while IFS= read -r line; do
      line=${line#*\\"}
      set -- "$@" "${line%\\"}"
    done <<EOF
    $(security list-keychains -d user)
    EOF
    security list-keychains -d user -s "$@" "$keychain"

    echo "Remote signing is set up:"
    security find-identity -v -p codesigning "$keychain"
    """
}
