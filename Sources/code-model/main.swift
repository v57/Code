import CodeCSharpModel
import CodeClangModel
import CodeDartModel
import CodeGoModel
import CodeJavaModel
import CodeKotlinModel
import CodePHPModel
import CodeModel
import CodePythonModel
import CodeRustModel
import CodeSwiftModel
import CodeTypeScriptModel
import Foundation

#if os(Windows)
  import WinSDK
#endif

// code-model: any language's model, measured on a real project (swift-model's commands, for every registered language).
//
// code-model query --root <dir> --queries <reference.json> --out <answers.json> [--language go] [--details] [--no-references]
// code-model complete --root <dir> --at <relative path>:<line>:<character> [--text <file>] [--limit n]
// code-model complete-bench --root <dir> --cases <cases.json> --out <answers.json> [--limit n] [--full]
// code-model check --root <dir> [--language go]
// code-model bench --root <dir> --at <relative path>:<line>:<character>
// code-model files --root <dir> [--language go]: every file it reads, with its module
// code-model decls --root <dir> --at <relative path>: a file's declarations as its parser read them
//
// The language: --language (a name or an extension), else the file named by --at or the queries, else the root's
// manifest (go.mod, Package.swift, tsconfig.json).

/// Every language with a model. A new front end adds itself here and in CodeKit's `CodeTiers.languages`.
let languages: [ModelLanguage] = [.swift, .go, .typeScript, .clang, .python, .rust, .java, .kotlin, .cSharp, .dart, .php]

func option(_ flag: String) -> String? {
  guard let at = CommandLine.arguments.firstIndex(of: flag), at + 1 < CommandLine.arguments.count else { return nil }
  return CommandLine.arguments[at + 1]
}

func milliseconds(since start: DispatchTime) -> Double {
  Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

/// The process's peak resident memory in MB.
func peakRSS() -> Double {
  #if os(Windows)
    var counters = PROCESS_MEMORY_COUNTERS()
    counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
    guard K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) else { return 0 }
    return Double(counters.PeakWorkingSetSize) / 1_048_576
  #else
    var usage = rusage()
    #if canImport(Glibc)
      getrusage(RUSAGE_SELF.rawValue, &usage)
      return Double(usage.ru_maxrss) / 1024
    #else
      getrusage(RUSAGE_SELF, &usage)
      return Double(usage.ru_maxrss) / 1_048_576
    #endif
  #endif
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
}

guard CommandLine.arguments.count > 1, let rootOption = option("--root") else {
  print("code-model query|complete|complete-bench|check|bench|files --root <dir> [--language <name>] ...")
  exit(2)
}
let root = URL(fileURLWithPath: rootOption).standardizedFileURL.path

/// The language asked for, or the one the files in question are written in.
func chooseLanguage() -> ModelLanguage? {
  if let asked = option("--language")?.lowercased() {
    return languages.first { $0.name.lowercased() == asked || $0.extensions.contains(asked) }
  }
  var paths: [String] = []
  if let at = option("--at") { paths.append(String(at.split(separator: ":").first ?? "")) }
  if let queries = option("--queries") ?? option("--cases"), let data = FileManager.default.contents(atPath: queries), let json = try? JSONSerialization.jsonObject(with: data) {
    let list = (json as? [String: Any])?["queries"] as? [[String: Any]] ?? (json as? [[String: Any]]) ?? []
    paths += list.prefix(20).compactMap { $0["path"] as? String }
  }
  for path in paths { if let found = languages.first(where: { $0.handles(path) }) { return found } }
  let files = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
  for language in languages where files.contains(where: language.isManifest) { return language }
  return nil
}

guard let language = chooseLanguage() else {
  print("no language: pass --language (\(languages.map(\.name).joined(separator: ", ")))")
  exit(2)
}
let begin = DispatchTime.now()
let model = language.make(root, true)
let project = model.project
print(String(format: "%@ project: %d files in %.1f ms", language.name, project.projectUnits, milliseconds(since: begin)))

func rootPath(_ relative: String) -> String { relative.hasPrefix("/") ? relative : project.root + "/" + relative }

switch CommandLine.arguments[1] {
case "query":
  guard let queries = option("--queries"), let out = option("--out"),
    let data = FileManager.default.contents(atPath: queries),
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let list = json["queries"] as? [[String: Any]]
  else {
    print("needs --queries and --out")
    exit(2)
  }
  let withReferences = !CommandLine.arguments.contains("--no-references")
  var answers: [String: Any] = [:]
  var first: Double?
  var times: [Double] = []
  let start = DispatchTime.now()
  var referenceTime = 0.0
  for query in list {
    guard let key = query["key"] as? String, let path = query["path"] as? String, let line = query["line"] as? Int, let character = query["character"] as? Int else { continue }
    let startAnswer = DispatchTime.now()
    let answer = model.answer(path: rootPath(path), line: line, character: character)
    let answerTime = milliseconds(since: startAnswer)
    times.append(answerTime)
    if first == nil { first = milliseconds(since: begin) }
    var definitions: [[Any]] = []
    for site in answer.sites {
      if let place = model.place(of: site) { definitions.append([place.path, place.line]) }
    }
    var entry: [String: Any] = ["state": answer.state.rawValue, "definitions": definitions, "ms": answerTime]
    if CommandLine.arguments.contains("--details") {
      entry["details"] = answer.state == .unknown ? [] : answer.sites.prefix(30).compactMap { model.details(of: $0) }.map { String(describing: $0) }
      entry["locations"] = answer.sites.prefix(30).compactMap { model.location(of: $0) }.map { "\($0.path):\($0.line):\($0.character) \($0.name) | \($0.preview)" }
    }
    if withReferences {
      let startReferences = DispatchTime.now()
      entry["references"] = model.references(of: answer).map { [$0.path, $0.line] as [Any] }
      entry["referencesMs"] = milliseconds(since: startReferences)
      referenceTime += milliseconds(since: startReferences)
    }
    answers[key] = entry
  }
  let output = try JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys, .prettyPrinted])
  FileManager.default.createFile(atPath: out, contents: output)
  print(String(format: "first answer %.1f ms; %d positions in %.1f ms (median %.3f ms, p95 %.3f ms), of which references %.1f ms; %d files loaded, %.1f MB of source; peak RSS %.1f MB",
    first ?? 0, list.count, milliseconds(since: start), percentile(times, 0.5), percentile(times, 0.95), referenceTime, project.units.count, Double(project.loadedBytes) / 1_048_576, peakRSS()))

case "check":
  let start = DispatchTime.now()
  let found = model.allFindings()
  for finding in found { print("\(finding.path):\(finding.line): \(finding.message)") }
  print(String(format: "%d findings in %d files, %.1f ms", found.count, project.projectUnits, milliseconds(since: start)))

case "files":
  for unit in project.units.prefix(project.projectUnits) {
    print(unit.path.hasPrefix(project.root + "/") ? String(unit.path.dropFirst(project.root.count + 1)) : unit.path, terminator: "  ")
    print(unit.decls.count, "declarations")
  }

case "decls":
  // A file's declarations as its parser read them: kind, name, line, parent.
  guard let at = option("--at"), let index = project.unitByPath[rootPath(at)] else { exit(2) }
  let unit = project.units[Int(index)]
  for (position, decl) in unit.decls.enumerated() {
    let name = decl.nameToken >= 0 && Int(decl.nameToken) < unit.tokens.count ? unit.string(Int(decl.nameToken)) : "?"
    let line = decl.nameToken >= 0 && Int(decl.nameToken) < unit.tokens.count ? unit.source.lines.line(of: unit.tokens[Int(decl.nameToken)].start) + 1 : 0
    print(position, decl.kind, name, "line", line, "parent", decl.parent, decl.bodyOpen >= 0 ? "body" : "", decl.paramCount > 0 ? "params \(decl.paramCount)" : "")
  }
  for item in unit.imports { print("import", item.moduleName) }

case "complete":
  guard let at = option("--at") else { exit(2) }
  let parts = at.split(separator: ":").map(String.init)
  if let edited = option("--text"), let text = try? String(contentsOfFile: edited, encoding: .utf8) { project.update(path: rootPath(parts[0]), text: text) }
  let start = DispatchTime.now()
  let list = model.complete(path: rootPath(parts[0]), line: Int(parts[1]) ?? 0, character: Int(parts[2]) ?? 0, limit: Int(option("--limit") ?? "") ?? 40)
  print(String(format: "%@ %@ prefix [%@] %d items%@ in %.1f ms", list.context.rawValue, list.state.rawValue, list.prefix, list.items.count, list.isIncomplete ? "+" : "", milliseconds(since: start)))
  for item in list.items { print("  \(item.label)\(item.detail.isEmpty ? "" : " -> " + item.detail)  [\(item.module)]\(item.needsUnwrap ? " ?." : "")") }

case "complete-bench":
  guard let cases = option("--cases"), let out = option("--out"), let data = FileManager.default.contents(atPath: cases),
    let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
  else {
    print("needs --cases and --out")
    exit(2)
  }
  let limit = Int(option("--limit") ?? "") ?? 200
  var answers: [String: Any] = [:]
  var originals: [String: String] = [:]
  var times: [Double] = []
  for item in list {
    guard let key = item["key"] as? String, let path = item["path"] as? String, let text = item["text"] as? String, let line = item["line"] as? Int, let character = item["character"] as? Int else { continue }
    let full = rootPath(path)
    if originals[full] == nil { originals[full] = try? String(contentsOfFile: full, encoding: .utf8) }
    let start = DispatchTime.now()
    project.update(path: full, text: text)
    let updated = milliseconds(since: start)
    let found = model.complete(path: full, line: line, character: character, limit: limit)
    times.append(milliseconds(since: start))
    var answer: [String: Any] = ["context": found.context.rawValue, "state": found.state.rawValue, "names": found.items.map(\.name), "incomplete": found.isIncomplete,
      "updateMs": updated, "ms": milliseconds(since: start)]
    if CommandLine.arguments.contains("--full") {
      answer["items"] = found.items.map { "\($0.label) | \($0.detail) | \($0.module) | \($0.kind.rawValue) | \($0.insertText) | \($0.isSnippet) \($0.isDeprecated) \($0.needsUnwrap)" }
      answer["prefix"] = found.prefix
      answer["replaceStart"] = found.replaceStart
    }
    answers[key] = answer
    if let original = originals[full] { project.update(path: full, text: original) }
  }
  let output = try JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys])
  FileManager.default.createFile(atPath: out, contents: output)
  print(String(format: "%d cases, median %.2f ms, p95 %.2f ms; peak RSS %.1f MB", list.count, percentile(times, 0.5), percentile(times, 0.95), peakRSS()))

case "bench":
  guard let at = option("--at") else {
    print("needs --at <relative path>:<line>:<character>")
    exit(2)
  }
  let parts = at.split(separator: ":").map(String.init)
  let path = rootPath(parts[0])
  let line = Int(parts[1]) ?? 0
  let character = Int(parts[2]) ?? 0
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { exit(2) }
  func ask(_ label: String) {
    let start = DispatchTime.now()
    let found = model.answer(path: path, line: line, character: character)
    print(String(format: "%@: %.2f ms (%@)", label, milliseconds(since: start), found.state.rawValue))
  }
  ask("first question, loading what it needs")
  print(String(format: "first answer at %.1f ms; %d files, %.1f MB of source", milliseconds(since: begin), project.units.count, Double(project.loadedBytes) / 1_048_576))
  ask("the same again")
  func edit(_ new: String, _ label: String) {
    let start = DispatchTime.now()
    let held = project.update(path: path, text: new)
    print(String(format: "%@: %.2f ms, shape %@", label, milliseconds(since: start), held ? "held" : "changed"))
    ask("  answering again")
  }
  var lines = text.components(separatedBy: "\n")
  lines.insert("_ = 1 + 1", at: line + 1)
  edit(lines.joined(separator: "\n"), "body edit")
  let added =
    language.name == "Go" ? "\nfunc addedByBench(value int) int { return value }\n"
    : language.name == "C" ? "\nint addedByBench(int value) { return value; }\n"
    : language.name == "Rust" ? "\nfn added_by_bench(value: i32) -> i32 { value }\n"
    : language.name == "Java" ? "\nclass AddedByBench { static int addedByBench(int value) { return value; } }\n"
    : language.name == "Dart" ? "\nint addedByBench(int value) => value;\n" : language.name == "PHP" ? "\nfunction addedByBench(int $value): int { return $value; }\n" : "\nfunc addedByBench(_ value: Int) -> Int { value }\n"
  edit(text + added, "signature edit")
  print(String(format: "peak RSS %.1f MB", peakRSS()))

default:
  print("unknown command")
  exit(2)
}
