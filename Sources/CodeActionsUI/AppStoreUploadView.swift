import CodeActions
import ComponentKit
import SwiftUI

/// The sheet Upload to App Store (`ActionKind.upload`) opens: the build number it carries, prefilled with the commit
/// count of the scheme's repository, the number Install and releases stamp too (`SourceFingerprint.commitCount`).
///
/// Present it with `.kitSheet(item:)`; it closes itself (`kitDismiss`) before calling `onUpload`.
///
/// ```swift
/// .kitSheet(item: $model.upload) { request in
///   AppStoreUploadView(scheme: request.scheme) { buildNumber in
///     actions.perform(.upload, environment: [AppStoreUpload.buildNumberVariable: buildNumber])
///   }
/// }
/// ```
public struct AppStoreUploadView: View {
  let scheme: ActionScheme
  let onUpload: (String) -> Void
  @Environment(\.kitDismiss) private var dismiss
  @State private var buildNumber = ""

  /// - Parameters:
  ///   - scheme: what uploads, named in the sheet; the commit count comes from its folder's repository.
  ///   - onUpload: the build number, once the sheet has closed.
  public init(scheme: ActionScheme, onUpload: @escaping (String) -> Void) {
    self.scheme = scheme
    self.onUpload = onUpload
  }

  private var isValid: Bool { AppStoreUpload.isValidBuildNumber(buildNumber) }

  public var body: some View {
    KitSheet(
      title: "Upload to App Store", meta: "Archives \(scheme.plainName) and uploads it to App Store Connect.",
      systemImage: ActionKind.upload.symbolName, width: 420
    ) {
      FormCard("Build number", footer: "App Store Connect wants it higher than the last build uploaded.") {
        FormRow(
          "Build number", help: "Prefilled with the commit count", systemImage: "number", hue: .gray,
          error: buildNumber.isEmpty || isValid ? nil : "Up to three numbers separated by periods",
          field: TextField("Build number", text: $buildNumber).onSubmit(upload))
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Upload") { upload() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!isValid)
    }
    .task {
      let folder = scheme.directory
      let count = await Task.detached { SourceFingerprint.commitCount(in: folder) }.value
      if buildNumber.isEmpty { buildNumber = String(count ?? 1) }
    }
  }

  private func upload() {
    guard isValid else { return }
    let number = buildNumber
    dismiss()
    onUpload(number)
  }
}

private extension ActionScheme {
  /// The name without the "(Project project)" that tells two schemes of a name apart.
  var plainName: String {
    name.replacingOccurrences(of: #" \([^()]+\)$"#, with: "", options: .regularExpression)
  }
}
