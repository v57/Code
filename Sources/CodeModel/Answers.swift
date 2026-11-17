import CodeScan
import Foundation

public enum AnswerState: String { case exact, candidates, unknown }

public struct Answer {
  public var state: AnswerState
  public var sites: [Site]
  /// Candidates only because they have the right name, as the receiver's type couldn't be told.
  public var byNameOnly = false

  package init(state: AnswerState, sites: [Site], byNameOnly: Bool = false) {
    self.state = state
    self.sites = sites
    self.byNameOnly = byNameOnly
  }
}

/// Something the model is sure is an error.
public struct Finding {
  public var path: String
  public var line: Int
  public var word: String
  public var message: String

  package init(path: String, line: Int, word: String, message: String) {
    self.path = path
    self.line = line
    self.word = word
    self.message = message
  }
}

extension Project {
  /// A declaration's place: `path` relative to the root, or `sdk:<module><interface extension>`.
  public func place(of site: Site) -> (path: String, line: Int)? {
    switch site {
    case .decl(let ref):
      return placeOf(unit(ref), token: Int(decl(ref).nameToken))
    case .local(let unit, let token), .generic(let unit, let token):
      return placeOf(units[Int(unit)], token: Int(token))
    case .module(let moduleName):
      return ("sdk:" + (modules[moduleName]?.publishedName ?? "?") + layout.interfaceExtension, 1)
    }
  }

  /// Where a site is on disk, for an editor to open: a file in the project, an interface in the SDK, or the header a
  /// generated declaration was read from. Line and character from 0, the character in UTF-16 units; `name` is what's
  /// declared there. Nil for a module.
  public func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)? {
    let holder: Unit
    let token: Int
    switch site {
    case .decl(let ref):
      holder = unit(ref)
      token = Int(decl(ref).nameToken)
    case .local(let unitIndex, let index), .generic(let unitIndex, let index):
      holder = units[Int(unitIndex)]
      token = Int(index)
    case .module:
      return nil
    }
    guard token >= 0, token < holder.tokens.count else { return nil }
    let start = holder.tokens[token].start
    let end = holder.tokens[token].end
    let bytes = holder.source.bytes
    let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
    let line = holder.source.lines.line(of: start)
    let lineStart = holder.source.lines.offset(line: line, character: 0, in: holder.source.text)
    var lineEnd = lineStart
    while lineEnd < bytes.count, bytes[lineEnd] != 10 { lineEnd += 1 }
    // The declaration's line as the generated code reads it, also for a header's (it reads better than the C).
    let preview = String(
      String(decoding: UnsafeBufferPointer(rebasing: bytes[lineStart..<lineEnd]), as: UTF8.self)
        .trimmingCharacters(in: .whitespaces).prefix(160))
    if !holder.headerLines.isEmpty {
      guard line < holder.headerLines.count else { return nil }
      let entry = holder.headerLines[line]
      return (holder.headerFiles[Int(entry.header)], max(0, Int(entry.line) - 1), 0, name, preview)
    }
    let character = String(decoding: UnsafeBufferPointer(rebasing: bytes[lineStart..<start]), as: UTF8.self).utf16.count
    return (holder.path, line, character, name, preview)
  }

  package func placeOf(_ unit: Unit, token: Int) -> (path: String, line: Int)? {
    guard token >= 0, token < unit.tokens.count else { return nil }
    let line = unit.source.lines.line(of: unit.tokens[token].start) + 1
    if !unit.headerLines.isEmpty, line - 1 < unit.headerLines.count {
      // The real header's line, named with its module first as the scorer reads it.
      let entry = unit.headerLines[line - 1]
      let moduleName = modules[unit.moduleName]?.publishedName ?? "?"
      let file = URL(fileURLWithPath: unit.headerFiles[Int(entry.header)]).lastPathComponent
      return ("sdk:" + moduleName + "." + file, Int(entry.line))
    }
    if unit.isInterface {
      let moduleName = modules[unit.moduleName]?.publishedName ?? "?"
      return ("sdk:" + moduleName + layout.interfaceExtension, line)
    }
    if unit.path.hasPrefix(root + "/") { return (String(unit.path.dropFirst(root.count + 1)), line) }
    // Outside the root, as the reference writes it.
    return ("sdk:" + URL(fileURLWithPath: unit.path).lastPathComponent, line)
  }

  /// A path as the references write it: relative to the root, with `..` for each folder above it.
  package func rootRelative(_ path: String) -> String {
    let root = self.root.split(separator: "/")
    let parts = path.split(separator: "/")
    var common = 0
    while common < root.count, common < parts.count, root[common] == parts[common] { common += 1 }
    return (Array(repeating: "..", count: root.count - common) + parts[common...].map(String.init)).joined(separator: "/")
  }

  /// A name filter over the project's files (or one of them), then each hit resolved by `answer`: a reference is only
  /// what lands on one of `targets`.
  package func references(named names: Set<Name>, in restrict: Int32?, landingOn targets: Set<Site>, answer: (_ unitIndex: Int32, _ token: Int) -> Answer)
    -> [(path: String, line: Int)]
  {
    var seen = Set<String>()
    var result: [(String, Int)] = []
    for u in 0..<projectUnits {
      if let restrict, restrict != Int32(u) { continue }
      let unit = units[u]
      for (index, token) in unit.tokens.enumerated() {
        switch token.kind {
        case .identifier, .keyword, .declarationKeyword:
          guard names.contains(hashName(unit.source.text + token.start, token.length)) else { continue }
        case .attribute, .directive:
          // `@Test`, `#expect`: the name past its sign.
          guard token.length > 1, names.contains(hashName(unit.source.text + token.start + 1, token.length - 1)) else { continue }
        default:
          continue
        }
        let found = answer(Int32(u), index)
        guard found.state != .unknown, !found.byNameOnly, found.sites.contains(where: targets.contains) else { continue }
        guard let place = placeOf(unit, token: index) else { continue }
        if seen.insert("\(place.path):\(place.line)").inserted { result.append((place.path, place.line)) }
      }
    }
    return result
  }
}
