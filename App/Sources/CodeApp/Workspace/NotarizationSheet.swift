import CodeKit
import CodeActionsUI
import Foundation
import SwiftUI

/// What opened the Notarization sheet: an Export waiting for it, or
/// Product › Notarization Settings.
struct NotarizationSetupRequest: Identifiable {
  let id = UUID()
  var exportsWhenDone = false
  /// The project the Export is for when no window shows it (the Projects list's Export…); else this window's.
  var target: WindowModel?
}

/// What opened the Upload to App Store sheet: the scheme waiting for its build number.
struct AppStoreUploadRequest: Identifiable {
  let id = UUID()
  let scheme: ActionScheme
  /// The project it uploads when no window shows it (the Projects list's Upload to App Store); else this window's.
  var target: WindowModel?
}

/// The notarytool keychain profile Export passes as `NOTARY_PROFILE`, saved
/// once the Notarization sheet checked it; nil until then.
enum NotarySettings {
  private static let key = "notarization.profile"

  static var profile: String? {
    get { UserDefaults.standard.string(forKey: key) }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }
}

/// CodeActionsUI's Notarization sheet for this window: it saves the checked
/// profile and runs the Export that waited for it.
struct NotarizationSheet: View {
  let request: NotarizationSetupRequest
  @Environment(WindowModel.self) private var model

  var body: some View {
    NotarizationSetupView(profile: NotarySettings.profile, exportsWhenDone: request.exportsWhenDone) { profile in
      NotarySettings.profile = profile
      if request.exportsWhenDone { (request.target ?? model).perform(.export) }
    }
  }
}
