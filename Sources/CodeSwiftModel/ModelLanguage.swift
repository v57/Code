import CodeModel

extension Model: LanguageModel {}

extension ModelLanguage {
  /// Swift: `.swift` files, read again when a `Package.swift` changes. A trusted folder's manifest is evaluated.
  public static let swift = ModelLanguage(name: "Swift", extensions: ["swift"], manifests: ["Package.swift"]) { root, trusted in
    Model(project: Project(root: root, runsManifest: trusted))
  }
}
