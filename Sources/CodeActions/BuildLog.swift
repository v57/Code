import Foundation

/// An error, warning or note from a build or test log, at a place in a file
/// when the tool said where.
public struct BuildIssue: Hashable, Sendable, Identifiable {
  public enum Severity: String, Sendable, Comparable {
    case error, warning, note

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
      lhs.rank < rhs.rank
    }

    var rank: Int {
      switch self {
      case .error: return 0
      case .warning: return 1
      case .note: return 2
      }
    }
  }

  public var severity: Severity
  public var message: String
  public var url: URL?
  /// From 1; nil when the tool gave none.
  public var line: Int?
  public var column: Int?

  public init(severity: Severity, message: String, url: URL?, line: Int?, column: Int?) {
    self.severity = severity
    self.message = message
    self.url = url
    self.line = line
    self.column = column
  }

  public var id: String {
    "\(severity.rawValue)|\(url?.path ?? "")|\(line ?? 0)|\(column ?? 0)|\(message)"
  }
}

/// How far a build got: a fraction when the tool counts its steps
/// ("[12/40] Compiling …"), and what it is doing.
public struct ActionProgress: Equatable, Sendable {
  public var fraction: Double?
  public var message: String

  public init(fraction: Double? = nil, message: String) {
    self.fraction = fraction
    self.message = message
  }
}

/// Reads a build or test log line by line and picks out issues (in the
/// formats of Swift/Clang, Go, Rust, TypeScript, Kotlin, Java, C#, Dart,
/// Elixir, Python and Zig) and progress.
public struct BuildLogParser {
  public let directory: URL
  /// A Rust or Elixir message waiting for the line with its location.
  private var pendingMessage: (severity: BuildIssue.Severity, message: String)?
  /// The last "File …, line N" of a Python traceback.
  private var tracebackLocation: (url: URL, line: Int)?

  public init(directory: URL) {
    self.directory = directory
  }

  public enum Event: Equatable, Sendable {
    case issue(BuildIssue)
    case progress(ActionProgress)
  }

  public mutating func consume(_ rawLine: String) -> [Event] {
    let line = rawLine.trimmingCharacters(in: .newlines)
    var events: [Event] = []
    if let issue = issue(in: line) { events.append(.issue(issue)) }
    if let progress = Self.progress(in: line) { events.append(.progress(progress)) }
    return events
  }

  // MARK: - Issues

  private mutating func issue(in line: String) -> BuildIssue? {
    // Rust: "error[E0425]: message" then "  --> src/main.rs:3:5".
    if let pending = pendingMessage, let groups = Self.first(Self.arrowLocation, in: line) {
      pendingMessage = nil
      return make(pending.severity, pending.message, groups[0], groups[1], groups[2])
    }
    if let groups = Self.first(Self.rustHeader, in: line) {
      pendingMessage = (Self.severity(groups[0]), groups[1])
      return nil
    }
    // Elixir: "warning: message" / "error: message" then "└─ lib/a.ex:12:5".
    if let pending = pendingMessage, let groups = Self.first(Self.elixirLocation, in: line) {
      pendingMessage = nil
      return make(pending.severity, pending.message, groups[0], groups[1], groups[2])
    }
    // Swift, Clang, Go vet, Zig, GCC: "path:line:col: error: message".
    if let groups = Self.first(Self.clangStyle, in: line) {
      pendingMessage = nil
      return make(Self.severity(groups[3]), groups[4], groups[0], groups[1], groups[2])
    }
    // Swift Testing: "… recorded an issue at File.swift:12:5: message".
    if let groups = Self.first(Self.swiftTesting, in: line) {
      return make(.error, groups[3], groups[0], groups[1], groups[2])
    }
    // TypeScript: "src/a.ts(3,5): error TS2304: message" / C#: "a.cs(3,5): error CS0103: …".
    if let groups = Self.first(Self.parenthesized, in: line) {
      return make(Self.severity(groups[3]), groups[4], groups[0], groups[1], groups[2])
    }
    // TypeScript --pretty: "src/a.ts:3:5 - error TS2304: message".
    if let groups = Self.first(Self.dashed, in: line) {
      return make(Self.severity(groups[3]), groups[4], groups[0], groups[1], groups[2])
    }
    // Kotlin: "e: file:///path/A.kt:12:5 message".
    if let groups = Self.first(Self.kotlin, in: line) {
      return make(groups[0] == "w" ? .warning : .error, groups[4], groups[1], groups[2], groups[3])
    }
    // Dart: "  error - lib/a.dart:3:5 - message - code".
    if let groups = Self.first(Self.dart, in: line) {
      return make(Self.severity(groups[0]), groups[4], groups[1], groups[2], groups[3])
    }
    // Java: "/path/A.java:12: error: message".
    if let groups = Self.first(Self.javaStyle, in: line) {
      return make(Self.severity(groups[2]), groups[3], groups[0], groups[1], nil)
    }
    // Go build: "./main.go:12:5: undefined: x" (no severity).
    if let groups = Self.first(Self.goStyle, in: line) {
      return make(.error, groups[3], groups[0], groups[1], groups[2])
    }
    if let groups = Self.first(Self.elixirHeader, in: line) {
      pendingMessage = (Self.severity(groups[0]), groups[1])
      return nil
    }
    // Python traceback: remember the innermost frame in the project.
    if let groups = Self.first(Self.pythonFrame, in: line) {
      let url = resolve(groups[0])
      if url.path.hasPrefix(directory.path), let number = Int(groups[1]) {
        tracebackLocation = (url, number)
      }
      return nil
    }
    if let location = tracebackLocation, let groups = Self.first(Self.pythonException, in: line) {
      tracebackLocation = nil
      return BuildIssue(
        severity: .error, message: groups[0], url: location.url, line: location.line, column: nil)
    }
    return nil
  }

  private func make(
    _ severity: BuildIssue.Severity, _ message: String, _ path: String, _ line: String,
    _ column: String?
  ) -> BuildIssue {
    BuildIssue(
      severity: severity, message: message.trimmingCharacters(in: .whitespaces),
      url: resolve(path), line: Int(line), column: column.flatMap { Int($0) })
  }

  private func resolve(_ path: String) -> URL {
    var path = path
    if path.hasPrefix("file://") { path = URL(string: path)?.path ?? String(path.dropFirst(7)) }
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
    return url.standardizedFileURL
  }

  static func severity(_ text: String) -> BuildIssue.Severity {
    switch text.lowercased() {
    case "warning", "warn", "w": return .warning
    case "note", "info", "hint", "remark": return .note
    default: return .error
    }
  }

  private static let file = #"((?:/|\./|\.\./|[A-Za-z0-9_@~-])[^:()\s][^:()]*?\.[A-Za-z0-9]+)"#
  static let clangStyle = try! NSRegularExpression(
    pattern: #"^\s*"# + file + #":(\d+):(?:(\d+):)?\s*(fatal error|error|warning|note|remark):\s*(.*)$"#)
  static let swiftTesting = try! NSRegularExpression(
    pattern: #"recorded an issue at ([^\s:]+\.swift):(\d+):(\d+):\s*(.*)$"#)
  static let parenthesized = try! NSRegularExpression(
    pattern: #"^\s*"# + file + #"\((\d+),(\d+)\):\s*(error|warning|info)\s*(?:[A-Z]+\d+:)?\s*(.*?)(?:\s+\[[^\]]+\])?$"#)
  static let dashed = try! NSRegularExpression(
    pattern: #"^\s*"# + file + #":(\d+):(\d+)\s+-\s+(error|warning)\s*(?:[A-Z]+\d+:)?\s*(.*)$"#)
  static let kotlin = try! NSRegularExpression(
    pattern: #"^([ew]):\s+(?:file://)?(/[^:]+\.kts?):(\d+):(\d+)\s+(.*)$"#)
  static let dart = try! NSRegularExpression(
    pattern: #"^\s*(error|warning|info)\s+-\s+([^\s:]+\.dart):(\d+):(\d+)\s+-\s+(.*?)(?:\s+-\s+[a-z_]+)?$"#)
  static let javaStyle = try! NSRegularExpression(
    pattern: #"^\s*([^\s:]+\.(?:java|scala|groovy)):(\d+):\s*(error|warning):\s*(.*)$"#)
  static let goStyle = try! NSRegularExpression(
    pattern: #"^\s*((?:\./|\.\./|/)?[^\s:]+\.go):(\d+):(\d+):\s*(.*)$"#)
  static let rustHeader = try! NSRegularExpression(
    pattern: #"^(error|warning)(?:\[[A-Z]\d+\])?:\s*(.*)$"#)
  static let arrowLocation = try! NSRegularExpression(
    pattern: #"^\s*-->\s*([^\s:]+):(\d+):(\d+)"#)
  static let elixirHeader = try! NSRegularExpression(
    pattern: #"^\s*(?:\*\*\s*\([A-Za-z.]+Error\)|(warning|error)):\s*(.*)$"#)
  static let elixirLocation = try! NSRegularExpression(
    pattern: #"^\s*(?:└─|│)?\s*((?:lib|test|config|apps)/[^\s:]+\.exs?):(\d+)(?::(\d+))?"#)
  static let pythonFrame = try! NSRegularExpression(
    pattern: #"^\s*File "([^"]+\.py)", line (\d+)"#)
  static let pythonException = try! NSRegularExpression(
    pattern: #"^((?:[A-Za-z_][A-Za-z0-9_.]*)?(?:Error|Exception|Exit|Interrupt)\b.*)$"#)

  static func first(_ regex: NSRegularExpression, in line: String) -> [String]? {
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, range: range) else { return nil }
    return (1..<match.numberOfRanges).map { index in
      Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
    }.map { $0 }
  }

  // MARK: - Progress

  static let counted = try! NSRegularExpression(pattern: #"^\s*\[(\d+)/(\d+)\]\s*(.*)$"#)
  static let cargoBar = try! NSRegularExpression(
    pattern: #"^\s*Building\s*\[[=> ]*\]\s*(\d+)/(\d+):?\s*(.*)$"#)
  static let gradlePercent = try! NSRegularExpression(
    pattern: #"(\d+)%\s+(?:EXECUTING|CONFIGURING|INITIALIZING)"#)
  static let verbs = [
    "Compiling", "Building", "Linking", "Downloading", "Downloaded", "Fetching", "Resolving",
    "Checking", "Installing", "Running", "Testing", "Updating", "Packaging", "Signing",
  ]
  static let xcodeTasks: [(String, String)] = [
    ("SwiftCompile", "Compiling"), ("CompileSwift", "Compiling"), ("CompileC", "Compiling"),
    ("Ld ", "Linking"), ("CodeSign", "Signing"), ("CompileAssetCatalog", "Compiling assets"),
    ("ProcessInfoPlistFile", "Processing Info.plist"), ("CompileStoryboard", "Compiling"),
    ("CompileXIB", "Compiling"), ("SwiftEmitModule", "Emitting module"),
    ("SwiftDriver", "Planning"), ("ProcessProductPackaging", "Packaging"),
    ("Copy", "Copying"), ("CpResource", "Copying"), ("GenerateDSYMFile", "Generating dSYM"),
    ("ResolvePackageGraph", "Resolving packages"), ("Validate", "Validating"),
  ]

  static func progress(in line: String) -> ActionProgress? {
    if let groups = first(counted, in: line), let done = Double(groups[0]),
      let total = Double(groups[1]), total > 0
    {
      return ActionProgress(fraction: min(1, done / total), message: groups[2])
    }
    if let groups = first(cargoBar, in: line), let done = Double(groups[0]),
      let total = Double(groups[1]), total > 0
    {
      return ActionProgress(fraction: min(1, done / total), message: "Building " + groups[2])
    }
    if let groups = first(gradlePercent, in: line), let percent = Double(groups[0]) {
      return ActionProgress(fraction: percent / 100, message: "Gradle")
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("> Task ") {
      return ActionProgress(message: String(trimmed.dropFirst(2)))
    }
    for (task, verb) in xcodeTasks where trimmed.hasPrefix(task) {
      // "SwiftCompile normal arm64 Compiling\ A.swift /path/A.swift …"
      let file = trimmed.split(separator: " ").last { $0.hasPrefix("/") }
        .map { ($0 as NSString).lastPathComponent } ?? ""
      return ActionProgress(message: file.isEmpty ? verb : "\(verb) \(file)")
    }
    for verb in verbs where trimmed.hasPrefix(verb + " ") {
      return ActionProgress(message: String(trimmed.prefix(120)))
    }
    return nil
  }
}
