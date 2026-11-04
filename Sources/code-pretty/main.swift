import CodePretty
import CodeScan
import Foundation

// code-pretty: formats files in every language the scanner knows.
//
//   code-pretty [--write | --check | --report] <file or folder>...
//   code-pretty --stdin-filepath <path>          # Reads standard input, writes the result to standard output.

let usage = """
  code-pretty [--write | --check | --report] <file or folder>...
  code-pretty --stdin-filepath <path>
  """

final class Totals: @unchecked Sendable {
  let lock = NSLock()
  var files = 0
  var bytes = 0
  var changed: [String] = []
  var refused: [String] = []
  var unstable: [String] = []
  var linesTotal = 0
  var linesKept = 0
  var byLanguage: [String: (files: Int, lines: Int, kept: Int, refused: Int, unstable: Int)] = [:]
}

func formatted(_ source: SourceFile, path: String) -> Pretty.Output {
  Pretty.format(source, path: path, options: PrettyOptions.resolve(path: path, source: source))
}

func printError(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") {
  print(usage)
  exit(arguments.isEmpty ? 2 : 0)
}

if let flag = arguments.firstIndex(of: "--stdin-filepath") {
  guard flag + 1 < arguments.count else {
    printError(usage)
    exit(2)
  }
  let path = arguments[flag + 1]
  let input = FileHandle.standardInput.readDataToEndOfFile()
  guard let profile = LexProfile.profile(forPath: path) else {
    FileHandle.standardOutput.write(input)
    exit(0)
  }
  let output = formatted(SourceFile(bytes: Array(input), profile: profile), path: path)
  FileHandle.standardOutput.write(Data(output.text))
  if output.refused {
    printError("\(path):\((output.refusedLine ?? 0) + 1): left as it is: formatting wasn't provably safe here")
    exit(1)
  }
  exit(0)
}

let write = arguments.contains("--write")
let check = arguments.contains("--check")
let report = arguments.contains("--report")
let paths = arguments.filter { !$0.hasPrefix("--") }
let start = Date()
let totals = Totals()

@Sendable func handle(path: String, bytes: UnsafeBufferPointer<UInt8>) {
  guard let profile = LexProfile.profile(forPath: path) else { return }
  let source = SourceFile(bytes: bytes, profile: profile)
  let output = formatted(source, path: path)
  let isChanged = !output.text.elementsEqual(source.bytes)
  var kept = 0
  var total = 0
  var unstable = false
  if report {
    let edits = output.text.withUnsafeBufferPointer { Pretty.edits(from: source.bytes, to: $0) }
    total = source.lines.starts.count
    kept = total - edits.reduce(0) { $0 + ($1.endLine - $1.startLine) }
    // Formatting the result must not change it again.
    let second = formatted(SourceFile(bytes: output.text, profile: profile), path: path)
    unstable = second.text != output.text
  }
  totals.lock.lock()
  totals.files += 1
  totals.bytes += bytes.count
  if isChanged { totals.changed.append(path) }
  if output.refused { totals.refused.append("\(path):\((output.refusedLine ?? 0) + 1)") }
  if unstable { totals.unstable.append(path) }
  totals.linesTotal += total
  totals.linesKept += kept
  var row = totals.byLanguage[profile.spec.name] ?? (0, 0, 0, 0, 0)
  row.files += 1
  row.lines += total
  row.kept += kept
  if output.refused { row.refused += 1 }
  if unstable { row.unstable += 1 }
  totals.byLanguage[profile.spec.name] = row
  totals.lock.unlock()
  if write, isChanged, !output.refused {
    try? Data(output.text).write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

var roots: [String] = []
for path in paths {
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
    printError("\(path): not found")
    continue
  }
  if isDirectory.boolValue {
    roots.append(path.hasSuffix("/") ? String(path.dropLast()) : path)
  } else if let bytes = FileWalk.read(path) {
    bytes.withUnsafeBufferPointer { handle(path: path, bytes: $0) }
  }
}
FileWalk.walk(
  roots: roots,
  wants: { name in
    let text = String(decoding: name, as: UTF8.self)
    return LexProfile.profile(forPath: "/" + text) != nil
  },
  visit: { path, text, count, _, _ in
    handle(path: path, bytes: UnsafeBufferPointer(start: text, count: count))
  })

let seconds = Date().timeIntervalSince(start)
if report {
  print("language        files    lines   unchanged  refused  unstable")
  for (name, row) in totals.byLanguage.sorted(by: { $0.value.lines > $1.value.lines }) {
    print(
      name.padding(toLength: 14, withPad: " ", startingAt: 0),
      String(format: "%7d %8d %10.1f%% %7d %8d", row.files, row.lines, row.lines > 0 ? Double(row.kept) * 100 / Double(row.lines) : 0, row.refused, row.unstable))
  }
  for path in totals.refused.prefix(20) { print("refused: \(path)") }
  for path in totals.unstable.prefix(20) { print("unstable: \(path)") }
}
for path in totals.changed.sorted().prefix(check ? 200 : 0) { print(path) }
printError(
  String(
    format: "%d files, %.1f MB, %d %@, %d refused, in %.0f ms", totals.files, Double(totals.bytes) / 1e6, totals.changed.count,
    write ? "written" : "would change", totals.refused.count, seconds * 1000))
exit(check && !totals.changed.isEmpty ? 1 : 0)
