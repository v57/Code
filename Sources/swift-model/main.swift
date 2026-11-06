import Foundation
import CodeSwiftModel

// swift-model query --root <dir> --queries <reference.json> --out <answers.json> [--no-sdk] [--no-references]
// swift-model bench --root <dir> --file <relative path> [--no-sdk]

func option(_ flag: String) -> String? {
  guard let at = CommandLine.arguments.firstIndex(of: flag), at + 1 < CommandLine.arguments.count else { return nil }
  return CommandLine.arguments[at + 1]
}

func milliseconds(since start: DispatchTime) -> Double {
  Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

func peakRSS() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_maxrss) / 1_048_576
}

guard CommandLine.arguments.count > 1, let root = option("--root") else {
  print("swift-model query|bench --root <dir> ...")
  exit(2)
}
let useSDK = !CommandLine.arguments.contains("--no-sdk")
let begin = DispatchTime.now()
let project = Project(root: root, useSDK: useSDK, useClang: !CommandLine.arguments.contains("--no-clang"))
let model = Model(project: project)
print(String(format: "project: %d files in %.1f ms, of which the manifest %.1f ms", project.projectUnits, milliseconds(since: begin), project.manifestMilliseconds))

func rootPath(_ relative: String) -> String { project.root + "/" + relative }

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
  let start = DispatchTime.now()
  var referenceTime = 0.0
  for query in list {
    guard let key = query["key"] as? String, let path = query["path"] as? String, let line = query["line"] as? Int, let character = query["character"] as? Int else { continue }
    let startAnswer = DispatchTime.now()
    let answer = model.answer(path: rootPath(path), line: line, character: character)
    let answerTime = milliseconds(since: startAnswer)
    if first == nil { first = milliseconds(since: begin) }
    var definitions: [[Any]] = []
    for site in answer.sites {
      if let place = model.place(of: site) { definitions.append([place.path, place.line]) }
    }
    var entry: [String: Any] = ["state": answer.state.rawValue, "definitions": definitions, "ms": answerTime]
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
  print(String(format: "first answer %.1f ms; %d positions in %.1f ms, of which references %.1f ms; %d files loaded, %.1f MB of source; headers read %d times; peak RSS %.1f MB", first ?? 0, list.count, milliseconds(since: start), referenceTime, project.units.count, Double(project.loadedBytes) / 1_048_576, model.clangLoads, peakRSS()))

case "check":
  // Everything it can be sure is an error. On code that compiles, each of these is a false report.
  let start = DispatchTime.now()
  let found = model.allFindings()
  for finding in found { print("\(finding.path):\(finding.line): \(finding.message)") }
  print(String(format: "%d findings in %d files, %d member accesses on fully known types checked, %.1f ms", found.count, project.projectUnits, model.checkedAccesses, milliseconds(since: start)))

case "complete":
  // swift-model complete --root <dir> --at <relative path>:<line>:<character> [--text <file with the text being edited>]
  guard let at = option("--at") else { exit(2) }
  let parts = at.split(separator: ":").map(String.init)
  if let edited = option("--text"), let text = try? String(contentsOfFile: edited, encoding: .utf8) { project.update(path: rootPath(parts[0]), text: text) }
  let start = DispatchTime.now()
  let list = model.complete(path: rootPath(parts[0]), line: Int(parts[1]) ?? 0, character: Int(parts[2]) ?? 0, limit: Int(option("--limit") ?? "") ?? 40)
  print(String(format: "%@ %@ prefix [%@] %d items%@ in %.1f ms", list.context.rawValue, list.state.rawValue, list.prefix, list.items.count, list.isIncomplete ? "+" : "", milliseconds(since: start)))
  for item in list.items { print("  \(item.label)\(item.detail.isEmpty ? "" : " -> " + item.detail)  [\(item.module)]\(item.needsUnwrap ? " ?." : "")") }

case "complete-bench":
  // swift-model complete-bench --root <dir> --cases <cases.json> --out <answers.json> [--limit n]
  // Each case: the text as it would be while typing, then the question, then the file put back, as an editor would.
  guard let cases = option("--cases"), let out = option("--out"), let data = FileManager.default.contents(atPath: cases),
    let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
  else {
    print("needs --cases and --out")
    exit(2)
  }
  let limit = Int(option("--limit") ?? "") ?? 200
  var answers: [String: Any] = [:]
  var originals: [String: String] = [:]
  for item in list {
    guard let key = item["key"] as? String, let path = item["path"] as? String, let text = item["text"] as? String, let line = item["line"] as? Int, let character = item["character"] as? Int else { continue }
    let full = rootPath(path)
    if originals[full] == nil { originals[full] = try? String(contentsOfFile: full, encoding: .utf8) }
    let start = DispatchTime.now()
    project.update(path: full, text: text)
    let updated = milliseconds(since: start)
    let found = model.complete(path: full, line: line, character: character, limit: limit)
    answers[key] = ["context": found.context.rawValue, "state": found.state.rawValue, "names": found.items.map(\.name), "incomplete": found.isIncomplete,
      "updateMs": updated, "ms": milliseconds(since: start)]
    if let original = originals[full] { project.update(path: full, text: original) }
  }
  let output = try JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys])
  FileManager.default.createFile(atPath: out, contents: output)
  print(String(format: "%d cases; headers read %d times; peak RSS %.1f MB", list.count, model.clangLoads, peakRSS()))

case "interface":
  // The Swift a Clang module was read into, with where each line came from.
  guard let moduleName = option("--module"), let text = project.generatedInterface(of: moduleName) else {
    print("needs --module, of a Clang module")
    exit(2)
  }
  print(text)

case "explain":
  // swift-model explain --root <dir> --at <relative path>:<line>:<character>, 0-based.
  guard let at = option("--at") else { exit(2) }
  let parts = at.split(separator: ":").map(String.init)
  if let edited = option("--text"), let text = try? String(contentsOfFile: edited, encoding: .utf8) { project.update(path: rootPath(parts[0]), text: text) }
  // Asked first, so that it explains what the answer ended up seeing.
  _ = model.answer(path: rootPath(parts[0]), line: Int(parts[1]) ?? 0, character: Int(parts[2]) ?? 0)
  print(model.explain(path: rootPath(parts[0]), line: Int(parts[1]) ?? 0, character: Int(parts[2]) ?? 0))

case "bench":
  // A first answer, then one edit in a body and one to a signature, each with the time to answer again.
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
  print(String(format: "first answer at %.1f ms; %d files, %.1f MB of source; headers read %d times", milliseconds(since: begin), project.units.count, Double(project.loadedBytes) / 1_048_576, model.clangLoads))
  ask("the same again")
  func edit(_ new: String, _ label: String) {
    let start = DispatchTime.now()
    let held = project.update(path: path, text: new)
    print(String(format: "%@: %.2f ms, shape %@", label, milliseconds(since: start), held ? "held" : "changed"))
    ask("  answering again")
  }
  // A statement just after the question's line, in the same body, so that the question's position holds.
  var lines = text.components(separatedBy: "\n")
  lines.insert("_ = 1 + 1", at: line + 1)
  edit(lines.joined(separator: "\n"), "body edit")
  // A new top-level function at the end of the file: every file might see it.
  edit(text + "\nfunc addedByBench(_ value: Int) -> Int { value }\n", "signature edit")
  print(String(format: "peak RSS %.1f MB", peakRSS()))

default:
  print("unknown command")
  exit(2)
}
