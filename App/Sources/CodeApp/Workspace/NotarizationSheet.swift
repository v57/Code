import CodeKit
import CodeActionsUI
import Foundation
import SwiftUI

/// What opened the Notarization sheet: an Export waiting for it, or
/// Product › Notarization Settings.
struct NotarizationSetupRequest: Identifiable {
  let id = UUID()
  var exportsWhenDone = false
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
      if request.exportsWhenDone { model.perform(.export) }
    }
  }
}
