import CodeActions
import ComponentKit
import SwiftUI
import UniformTypeIdentifiers

/// The Notarization sheet: sets up what an Xcode scheme's Export (`ActionKind.needsNotarization`) needs, a Developer ID
/// Application certificate and a notarytool keychain profile, either an existing one (checked with notarytool) or a
/// new one saved from an app-specific password or an App Store Connect API key. The credentials go straight to
/// notarytool, which keeps them in the keychain; the app keeps only the profile's name, which `onDone` hands back.
///
/// Present it with `.kitSheet(item:)`; it closes itself (`kitDismiss`) before calling `onDone`.
///
/// ```swift
/// .kitSheet(item: $model.notarizationSetup) { request in
///   NotarizationSetupView(profile: settings.notaryProfile, exportsWhenDone: request.exportsWhenDone) { profile in
///     settings.notaryProfile = profile
///     if request.exportsWhenDone { model.perform(.export) }
///   }
/// }
/// ```
public struct NotarizationSetupView: View {
  let savedProfile: String?
  let exportsWhenDone: Bool
  let onDone: (String) -> Void
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  /// - Parameters:
  ///   - profile: the profile name saved before, or nil for notarytool's default (`Notarization.defaultProfile`).
  ///   - exportsWhenDone: an Export waits for the sheet: its primary button says Export instead of Done.
  ///   - onDone: the checked profile's name, once the sheet has closed.
  public init(profile: String?, exportsWhenDone: Bool = false, onDone: @escaping (String) -> Void) {
    self.savedProfile = profile
    self.exportsWhenDone = exportsWhenDone
    self.onDone = onDone
  }

  private enum Mode: Hashable { case existing, new }
  private enum Method: Hashable { case appleID, apiKey }
  private enum ProfileCheck: Equatable {
    case idle, checking
    case done(NotaryProfileStatus)
  }

  /// nil while `security find-identity` runs.
  @State private var identities: [DeveloperIDIdentity]?
  @State private var mode: Mode = .existing
  @State private var profile = ""
  /// The last check, for `checkedProfile`; editing the name makes it stale.
  @State private var lastCheck: ProfileCheck = .idle
  @State private var checkedProfile = ""

  @State private var method: Method = .appleID
  @State private var newProfile = Notarization.defaultProfile
  @State private var appleID = ""
  @State private var teamID = ""
  @State private var password = ""
  @State private var keyURL: URL?
  @State private var keyID = ""
  @State private var issuerID = ""
  @State private var showingKeyImporter = false
  @State private var saving = false
  @State private var saveError: String?

  private var hasDeveloperID: Bool { !(identities ?? []).isEmpty }
  private var check: ProfileCheck { checkedProfile == trimmed(profile) ? lastCheck : .idle }
  private var profileIsValid: Bool { mode == .existing && check == .done(.valid) }

  private var canSave: Bool {
    guard !saving, !trimmed(newProfile).isEmpty else { return false }
    switch method {
    case .appleID: return !trimmed(appleID).isEmpty && !trimmed(teamID).isEmpty && !password.isEmpty
    case .apiKey: return keyURL != nil && !trimmed(keyID).isEmpty
    }
  }

  public var body: some View {
    KitSheet(
      title: "Notarization", meta: "What Export needs: a Developer ID certificate and a notary profile.",
      systemImage: "checkmark.seal", width: 500
    ) {
      developerIDSection
      profileSection
      if mode == .new {
        newProfileSection
      }
    } footer: {
      SheetStatus(footerStatus.text, systemImage: "checkmark.seal", status: footerStatus.status)
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(exportsWhenDone ? "Export" : "Done") { finish() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!hasDeveloperID || !profileIsValid)
    }
    .animation(.kit, value: mode)
    .animation(.kit, value: method)
    .task {
      let saved = savedProfile ?? Notarization.defaultProfile
      profile = saved
      newProfile = saved
      await loadIdentities()
      await checkProfile()
      // Nothing saved under that name yet: go straight to creating it.
      if check == .done(.missing) { mode = .new }
    }
    .fileImporter(
      isPresented: $showingKeyImporter,
      allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]
    ) { result in
      if case .success(let url) = result {
        keyURL = url
        // AuthKey_<KEYID>.p8 is how App Store Connect names the download.
        let name = url.deletingPathExtension().lastPathComponent
        if keyID.isEmpty, name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst("AuthKey_".count)) }
      }
    }
  }

  /// The footer's line: what Export still waits for.
  private var footerStatus: (text: String, status: WorkStatus) {
    if identities == nil || check == .checking { return ("Checking…", .working) }
    if !hasDeveloperID { return ("No Developer ID certificate", .failed) }
    if profileIsValid { return ("Ready to export", .done) }
    return ("Choose a notary profile", .idle)
  }

  // MARK: - Sections

  private var developerIDSection: some View {
    FormCard(
      "Developer ID",
      footer: identities?.isEmpty == true
        ? "Create one in Xcode: Settings → Accounts → your team → Manage Certificates → + → Developer ID Application. Only the team's Account Holder can create it."
        : "Export signs the app with the certificate of the project's team."
    ) {
      if let identities {
        if identities.isEmpty {
          FormRow(
            "No certificate", systemImage: "xmark.seal",
            error: "No Developer ID Application certificate in the keychain"
          ) {
            Button("Check Again") { Task { await loadIdentities() } }
              .buttonStyle(.kit)
          }
        } else {
          ForEach(identities, id: \.self) { identity in
            FormRow(identity.name, help: "In the keychain", systemImage: "checkmark.seal.fill", hue: .green)
          }
        }
      } else {
        FormRow("Looking for certificates…", systemImage: "checkmark.seal", hue: .gray) {
          LiveIcon(systemImage: "magnifyingglass", status: .working, size: 20)
        }
      }
    }
  }

  private var profileSection: some View {
    FormCard(
      "Notary profile",
      footer:
        "A notarytool keychain profile, the one `xcrun notarytool store-credentials` saves. Checking it asks Apple's notary service, so it needs a network connection."
    ) {
      KitSegmented(selection: $mode, options: [("Use existing", Mode.existing), ("Create new", Mode.new)])
        .padding(10)
      if mode == .existing {
        FormRow(
          "Profile name", help: checkHelp, systemImage: "person.badge.key", hue: checkHue, error: checkError,
          status: checkFieldStatus,
          field: TextField("Profile name", text: $profile).onSubmit { Task { await checkProfile() } })
        if check == .done(.missing) {
          FormRow("Not in the keychain", help: "Create it with your credentials", systemImage: "plus", hue: .orange) {
            Button("Create It") {
              newProfile = trimmed(profile)
              mode = .new
            }
            .buttonStyle(.kit)
          }
        } else {
          FormRow("Check with Apple", help: "Asks the notary service", systemImage: "network", hue: .gray) {
            Button("Check") { Task { await checkProfile() } }
              .buttonStyle(.kit)
              .disabled(trimmed(profile).isEmpty || check == .checking)
          }
        }
      }
    }
  }

  private var checkHelp: String? {
    switch check {
    case .idle: return nil
    case .checking: return "Checking with Apple…"
    case .done(.valid): return "Profile works"
    case .done(.missing): return "No profile named “\(trimmed(profile))” in the keychain"
    case .done(.failed): return nil
    }
  }

  private var checkHue: Hue {
    switch check {
    case .done(.valid): return .green
    case .done(.missing): return .orange
    default: return .accent
    }
  }

  private var checkError: String? {
    if case .done(.failed(let message)) = check { return "The profile doesn't work: \(message)" }
    return nil
  }

  private var checkFieldStatus: WorkStatus {
    switch check {
    case .checking: return .working
    case .done(.valid): return .done
    case .done(.failed): return .failed
    default: return .idle
    }
  }

  private var newProfileSection: some View {
    FormCard(
      "New profile",
      footer:
        "notarytool checks the credentials with Apple, then keeps them in your keychain. Only the profile's name is saved here."
    ) {
      FormRow("Profile name", systemImage: "person.badge.key", field: TextField("Profile name", text: $newProfile))
      FormRow("Sign in with", systemImage: "key", hue: .gray) {
        KitPicker(
          "Sign in with", selection: $method,
          options: [("App-specific password", Method.appleID), ("App Store Connect API key", Method.apiKey)])
      }
      switch method {
      case .appleID:
        FormRow(
          "Apple ID", systemImage: "person.crop.circle",
          field: TextField("Apple ID", text: $appleID).textContentType(.username))
        FormRow("Team ID", systemImage: "person.3", field: TextField("Team ID", text: $teamID))
        FormRow(
          "App-specific password", systemImage: "lock",
          field: SecureField("App-specific password", text: $password))
        FormRow("Create an app-specific password", help: "On account.apple.com", systemImage: "link", hue: .gray) {
          Button("Open…") { open("https://account.apple.com/account/manage") }
            .buttonStyle(.kit)
        }
      case .apiKey:
        FormRow("Key file", help: keyURL?.lastPathComponent ?? "None", systemImage: "doc", hue: .gray) {
          Button("Choose…") { showingKeyImporter = true }
            .buttonStyle(.kit)
        }
        FormRow("Key ID", systemImage: "key", field: TextField("Key ID", text: $keyID))
        FormRow(
          "Issuer ID", help: "Team keys", systemImage: "building.2", field: TextField("Issuer ID", text: $issuerID))
        FormRow("Create an API key", help: "In App Store Connect", systemImage: "link", hue: .gray) {
          Button("Open…") { open("https://appstoreconnect.apple.com/access/integrations/api") }
            .buttonStyle(.kit)
        }
      }
      FormRow(
        "Save to Keychain", help: saving ? "Checking with Apple and saving…" : nil, systemImage: "lock.shield",
        error: saveError
      ) {
        HStack(spacing: 8) {
          if saving { LiveIcon(systemImage: "lock.shield", status: .working, size: 20) }
          Button("Save") { Task { await save() } }
            .buttonStyle(.kit)
            .disabled(!canSave)
        }
      }
    }
  }

  // MARK: - Actions

  private func open(_ address: String) {
    if let url = URL(string: address) { openURL(url) }
  }

  private func loadIdentities() async {
    identities = nil
    let found = await Notarization.developerIDIdentities()
    identities = found
    if teamID.isEmpty, let team = found.first?.teamID { teamID = team }
  }

  private func checkProfile() async {
    let name = trimmed(profile)
    guard !name.isEmpty else { return }
    checkedProfile = name
    lastCheck = .checking
    let status = await Notarization.checkProfile(name)
    // A newer check (another name) owns the status now.
    guard checkedProfile == name else { return }
    lastCheck = .done(status)
  }

  private func save() async {
    let name = trimmed(newProfile)
    saving = true
    saveError = nil
    let result: (exitCode: Int32, output: String)
    switch method {
    case .appleID:
      result = await Notarization.storeAppleIDProfile(
        name, appleID: trimmed(appleID), teamID: trimmed(teamID), password: password
      )
    case .apiKey:
      guard let keyURL else {
        saving = false
        return
      }
      let scoped = keyURL.startAccessingSecurityScopedResource()
      result = await Notarization.storeAPIKeyProfile(
        name, path: keyURL.path, keyID: trimmed(keyID), issuerID: trimmed(issuerID)
      )
      if scoped { keyURL.stopAccessingSecurityScopedResource() }
    }
    saving = false
    guard result.exitCode == 0 else {
      let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      saveError = message.isEmpty ? "notarytool exited with status \(result.exitCode)." : message
      return
    }
    password = ""
    // notarytool validated the credentials before saving them.
    profile = name
    checkedProfile = name
    lastCheck = .done(.valid)
    mode = .existing
  }

  private func finish() {
    let name = trimmed(profile)
    dismiss()
    onDone(name)
  }

  private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
