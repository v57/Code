/// The core every language's model shares: what CodeCSharpModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// C#: `.cs` files, read again when a project, solution or the build's shared props change.
  public static let cSharp = ModelLanguage(
    name: "C#", extensions: ["cs"], manifests: ["*.csproj", "*.sln", "*.slnx", "Directory.Build.props", "global.json"]
  ) { root, _ in CSharpModel(root: root) }
}
