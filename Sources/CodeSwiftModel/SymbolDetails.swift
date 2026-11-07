import CodeScan
import Foundation

/// What a symbol is, for a menu about it (Code's ⌘-hover): its kind and name, where it's declared, its declaration and
/// summary, what it's inside (out to its module) and, for a value, its type.

/// A symbol, or one of the declarations around it.
public struct SymbolPart: Hashable {
  public enum Kind: String {
    case module, structure, classType, actor, enumeration, protocolType, extensionDecl
    case function, initializer, deinitializer, subscriptDecl, property, variable, local, parameter, enumCase
    case typeAlias, associatedType, macro, generic
  }

  public var kind: Kind
  /// What it's called where it's used: `Trip`, `init(name:start:days:)`, `save()`, `trip`.
  public var name: String
  /// The word that declares it: `struct`, `func`, `let`; empty for a module or a parameter.
  public var keyword: String
  /// The file it's declared in (a `.swiftinterface` or a header for the SDK's), nil for a module without a manifest.
  public var path: String?
  /// From 0; the character in UTF-16 units.
  public var line: Int
  public var character: Int
  /// The module it's in, as written in an import.
  public var module: String
  /// Declared in the SDK, not the project.
  public var isSDK: Bool
}

public struct SymbolDetails: Hashable {
  public var symbol: SymbolPart
  /// Its declaration as one line, without attributes or body: `private func save() throws`, `let trip: Trip`.
  public var declaration: String
  /// The first paragraph of its doc comment.
  public var documentation: String?
  /// What it's inside, nearest first, ending with its module.
  public var parents: [SymbolPart]
  /// A value's type, when that's a declared type.
  public var type: SymbolPart?
}

extension Model {
  /// The details of the symbol at a position: of every site its answer names (one for an exact answer).
  public func details(path: String, line: Int, character: Int) -> (answer: Answer, details: [SymbolDetails]) {
    let found = answer(path: path, line: line, character: character)
    guard found.state != .unknown else { return (found, []) }
    return (found, found.sites.prefix(30).compactMap(details(of:)))
  }

  /// How many places use what an answer names (the declaration counts), nil when the answer is a guess.
  public func referenceCount(of answer: Answer) -> Int? {
    guard answer.state != .unknown, !answer.byNameOnly else { return nil }
    let found = references(of: answer)
    return found.isEmpty ? nil : found.count
  }

  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      guard let symbol = part(ref) else { return nil }
      let item = decl(ref)
      var parents: [SymbolPart] = []
      var seen = Set<DeclRef>()
      for index in self.parents(of: ref).reversed() {
        if let parent = containerPart(DeclRef(unit: ref.unit, decl: index)), seen.insert(parent.ref).inserted {
          parents.append(parent.part)
        }
      }
      parents.append(modulePart(of: unit(ref)))
      var type: SymbolPart?
      var typeText: String?
      if item.kind == .variable {
        let ty = variableType(ref)
        type = typePart(ty)
        typeText = swiftType(ty)
      }
      return SymbolDetails(
        symbol: symbol, declaration: declaration(ref, inferred: typeText), documentation: documentation(ref),
        parents: parents, type: type)
    case .local(let unitIndex, let token):
      return localDetails(unitIndex: unitIndex, token: token)
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: holder.string(Int(token)), keyword: "", path: at.path, line: at.line, character: at.character,
        module: moduleName(of: holder), isSDK: isSDK(holder))
      var parents: [SymbolPart] = []
      for index in chain(at: token, unitIndex: unitIndex).reversed() {
        if let parent = containerPart(DeclRef(unit: unitIndex, decl: index)) { parents.append(parent.part) }
      }
      parents.append(modulePart(of: holder))
      return SymbolDetails(symbol: symbol, declaration: symbol.name, documentation: nil, parents: parents, type: nil)
    case .module(let name):
      guard let module = project.modules[name] else { return nil }
      let part = modulePart(module)
      return SymbolDetails(symbol: part, declaration: "import " + part.name, documentation: nil, parents: [], type: nil)
    }
  }

  // MARK: Parts

  /// A declaration as a part, at its name.
  func part(_ ref: DeclRef) -> SymbolPart? {
    guard let at = location(of: .decl(ref)) else { return nil }
    let item = decl(ref)
    let holder = unit(ref)
    let kind: SymbolPart.Kind
    switch item.kind {
    case .structure: kind = .structure
    case .classType: kind = .classType
    case .actor: kind = .actor
    case .enumeration: kind = .enumeration
    case .protocolType: kind = .protocolType
    case .extensionDecl: kind = .extensionDecl
    case .function: kind = .function
    case .initializer: kind = .initializer
    case .deinitializer: kind = .deinitializer
    case .subscriptDecl: kind = .subscriptDecl
    case .variable: kind = item.parent >= 0 && holder.decls[Int(item.parent)].kind.hasMembers ? .property : .variable
    case .enumCase: kind = .enumCase
    case .typeAlias: kind = .typeAlias
    case .associatedType: kind = .associatedType
    case .macro: kind = .macro
    }
    return SymbolPart(
      kind: kind, name: displayName(ref), keyword: keyword(ref), path: at.path, line: at.line, character: at.character,
      module: moduleName(of: holder), isSDK: isSDK(holder))
  }

  /// A parent as shown: an extension stands for the type it extends.
  private func containerPart(_ ref: DeclRef) -> (ref: DeclRef, part: SymbolPart)? {
    var target = ref
    if decl(ref).kind == .extensionDecl, let nominal = nominal(forMembersOf: ref), decl(nominal).kind != .extensionDecl {
      target = nominal
    }
    return part(target).map { (target, $0) }
  }

  private func modulePart(of holder: Unit) -> SymbolPart {
    if let module = project.modules[holder.moduleName] { return modulePart(module) }
    return SymbolPart(kind: .module, name: moduleName(of: holder), keyword: "", path: nil, line: 0, character: 0, module: moduleName(of: holder), isSDK: isSDK(holder))
  }

  private func modulePart(_ module: Module) -> SymbolPart {
    let name = module.publishedName
    let target = module.isSDK ? nil : project.manifestLine(ofTarget: module.displayName)
    return SymbolPart(
      kind: .module, name: name, keyword: "", path: target.map { _ in project.root + "/Package.swift" }, line: target ?? 0,
      character: 0, module: name, isSDK: module.isSDK || (target == nil && isSDKModule(module)))
  }

  private func isSDKModule(_ module: Module) -> Bool {
    module.units.first.map { isSDK(project.units[Int($0)]) } ?? module.isSDK
  }

  private func moduleName(of holder: Unit) -> String {
    project.modules[holder.moduleName]?.publishedName ?? ""
  }

  private func isSDK(_ holder: Unit) -> Bool {
    holder.isInterface || !holder.headerLines.isEmpty || project.modules[holder.moduleName]?.isSDK == true
  }

  /// A local or a parameter.
  private func localDetails(unitIndex: Int32, token: Int32) -> SymbolDetails? {
    let holder = project.units[Int(unitIndex)]
    guard let at = location(of: .local(unit: unitIndex, token: token)) else { return nil }
    let owners = chain(at: token, unitIndex: unitIndex)
    // A parameter of the declaration it's in, or one of its body's names.
    var isParameter = false
    if let owner = owners.last {
      let item = holder.decls[Int(owner)]
      for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].nameToken == token { isParameter = true }
    }
    var ty = Ty.unknown
    var hasInitializer = false
    for scan in scans(unitIndex: unitIndex, token: token) {
      guard let index = scan.byToken[token] else { continue }
      ty = localType(scan: scan, index: index, unitIndex: unitIndex)
      if case .initializer = scan.locals[Int(index)].kind { hasInitializer = true }
      break
    }
    let before = Int(token) - 1
    var keyword = ""
    if holder.isToken(before, "let") || holder.isToken(before, "var") {
      keyword = holder.string(before)
    } else if !isParameter {
      keyword = "let"
    }
    let name = holder.string(Int(token))
    let symbol = SymbolPart(
      kind: isParameter ? .parameter : .local, name: name, keyword: keyword, path: at.path, line: at.line,
      character: at.character, module: moduleName(of: holder), isSDK: isSDK(holder))
    var declaration = (keyword.isEmpty ? "" : keyword + " ") + name
    if let text = swiftType(ty) {
      declaration += ": " + text
    } else if hasInitializer {
      declaration = at.preview
    }
    var parents: [SymbolPart] = []
    var seen = Set<DeclRef>()
    for index in owners.reversed() {
      if let parent = containerPart(DeclRef(unit: unitIndex, decl: index)), seen.insert(parent.ref).inserted {
        parents.append(parent.part)
      }
    }
    parents.append(modulePart(of: holder))
    return SymbolDetails(symbol: symbol, declaration: declaration, documentation: nil, parents: parents, type: typePart(ty))
  }

  /// The declaration a value's type names, unwrapping an optional.
  private func typePart(_ ty: Ty) -> SymbolPart? {
    switch ty {
    case .optional(let wrapped): return typePart(wrapped)
    case .nominal(let ref, _):
      guard decl(ref).kind.isType else { return nil }
      return part(ref)
    default: return nil
    }
  }

  // MARK: Text

  /// `init(name:start:days:)`, `save()`, `subscript(_:)`; other declarations by their name.
  func displayName(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    let name = holder.string(Int(item.nameToken))
    guard item.kind.isCallable, item.kind != .macro else { return name }
    var labels: [String] = []
    for p in 0..<Int(item.paramCount) {
      let param = holder.params[Int(item.paramStart) + p]
      let named = Int(param.nameToken)
      let before = named - 1
      // `label name: T` and `_ name: T`: the word before is the label.
      if param.typeStart > param.nameToken, before > Int(item.nameToken),
        holder.tokens[before].kind == .identifier || holder.tokens[before].kind == .keyword || holder.isToken(before, "_"),
        !holder.isByte(before, 0x3A)
      {
        labels.append(holder.string(before))
      } else {
        labels.append(item.kind == .subscriptDecl ? "_" : holder.string(named))
      }
    }
    return name + "(" + labels.map { $0 + ":" }.joined() + ")"
  }

  /// The word that declares it.
  private func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    switch item.kind {
    case .structure: return "struct"
    case .classType: return "class"
    case .actor: return "actor"
    case .enumeration: return "enum"
    case .protocolType: return "protocol"
    case .extensionDecl: return "extension"
    case .function: return "func"
    case .initializer: return "init"
    case .deinitializer: return "deinit"
    case .subscriptDecl: return "subscript"
    case .enumCase: return "case"
    case .typeAlias: return "typealias"
    case .associatedType: return "associatedtype"
    case .macro: return "macro"
    case .variable:
      let holder = unit(ref)
      var i = Int(item.nameToken) - 1
      while i >= Int(item.first) {
        if holder.isToken(i, "let") || holder.isToken(i, "var") { return holder.string(i) }
        i -= 1
      }
      return "var"
    }
  }

  /// The declaration from its first modifier to its body (a property's to its type), attributes left out, on one line.
  /// A property without a written type takes `inferred`.
  private func declaration(_ ref: DeclRef, inferred: String?) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    var start = Int(item.first)
    while start < Int(item.nameToken), holder.tokens[start].kind == .attribute { start = holder.skipAttribute(start) }
    var end = Int(item.end)
    if item.bodyOpen >= 0 { end = min(end, Int(item.bodyOpen)) }
    var suffix = ""
    if item.kind == .variable {
      if item.typeStart >= 0 {
        end = min(end, Int(item.typeEnd))
      } else {
        end = Int(item.nameToken) + 1
        if let inferred { suffix = ": " + inferred }
      }
    }
    guard start < end, end <= holder.tokens.count else { return displayName(ref) }
    let bytes = holder.source.bytes
    let from = holder.tokens[start].start
    let to = holder.tokens[end - 1].end
    guard from < to, to <= bytes.count else { return displayName(ref) }
    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[from..<to]), as: UTF8.self)
    return String((Self.interfaceSpelling(Self.oneLine(text)) + suffix).prefix(400))
  }

  /// A generated interface's spelling as code writes it: `__shared Foundation::URL` → `URL`.
  static func interfaceSpelling(_ text: String) -> String {
    guard text.contains("::") || text.contains("__") else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return Self.interfaceNoise.stringByReplacingMatches(in: text, range: range, withTemplate: "")
  }

  private static let interfaceNoise = try! NSRegularExpression(
    pattern: #"\b__(shared|owned) |\b[A-Za-z_][A-Za-z0-9_]*::"#)

  /// Whitespace runs with a line break in them become one space.
  static func oneLine(_ text: String) -> String {
    var result = ""
    var pendingSpace = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      if pendingSpace, let last = result.last, last != "(", last != "[", !trimmed.hasPrefix(")"), !trimmed.hasPrefix("]") {
        result += " "
      }
      result += result.isEmpty ? trimmed : String(trimmed)
      pendingSpace = true
    }
    return result
  }

  /// The doc comment's first paragraph above a declaration (`///` lines or a `/** */` block).
  func documentation(_ ref: DeclRef) -> String? {
    let item = decl(ref)
    let holder = unit(ref)
    guard holder.headerLines.isEmpty, item.first >= 0, Int(item.first) < holder.tokens.count else { return nil }
    let source = holder.source
    var line = source.lines.line(of: holder.tokens[Int(item.first)].start) - 1
    var lines: [String] = []
    func text(of line: Int) -> String {
      let start = source.lines.offset(line: line, character: 0, in: source.text)
      var end = start
      let bytes = source.bytes
      while end < bytes.count, bytes[end] != 10 { end += 1 }
      return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        .trimmingCharacters(in: .whitespaces)
    }
    if line >= 0, text(of: line).hasSuffix("*/") {
      while line >= 0 {
        var current = text(of: line)
        let opens = current.hasPrefix("/**")
        if current.hasSuffix("*/") { current.removeLast(2) }
        if opens { current.removeFirst(3) } else if current.hasPrefix("*") { current.removeFirst() }
        lines.insert(current.trimmingCharacters(in: .whitespaces), at: 0)
        if opens { break }
        line -= 1
      }
    } else {
      while line >= 0 {
        let current = text(of: line)
        guard current.hasPrefix("///") else { break }
        lines.insert(String(current.dropFirst(3)).trimmingCharacters(in: .whitespaces), at: 0)
        line -= 1
      }
    }
    var paragraph: [String] = []
    for line in lines {
      if line.isEmpty || line.hasPrefix("- ") {
        if paragraph.isEmpty { continue }
        break
      }
      paragraph.append(line)
    }
    return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
  }

  /// A type as Swift writes it; nil when part of it isn't known.
  func swiftType(_ ty: Ty) -> String? {
    switch ty {
    case .unknown, .module, .dependent: return nil
    case .nominal(let ref, let args):
      let item = decl(ref)
      let name = unit(ref).string(Int(item.nameToken))
      let parts = args.map(swiftType)
      if parts.contains(where: { $0 == nil }) { return parts.isEmpty ? name : nil }
      let written = parts.compactMap { $0 }
      if written.isEmpty { return name }
      if item.name == Word.array, written.count == 1 { return "[" + written[0] + "]" }
      if item.name == Word.dictionary, written.count == 2 { return "[" + written[0] + ": " + written[1] + "]" }
      if item.name == Word.optional, written.count == 1 { return written[0] + "?" }
      return name + "<" + written.joined(separator: ", ") + ">"
    case .meta(let inner): return swiftType(inner).map { $0 + ".Type" }
    case .tuple(let items, _):
      let parts = items.map(swiftType)
      guard !parts.contains(where: { $0 == nil }) else { return nil }
      return "(" + parts.compactMap { $0 }.joined(separator: ", ") + ")"
    case .function(let params, let result):
      let parts = params.map(swiftType)
      guard !parts.contains(where: { $0 == nil }), let result = swiftType(result) else { return nil }
      return "(" + parts.compactMap { $0 }.joined(separator: ", ") + ") -> " + result
    case .optional(let inner):
      guard let text = swiftType(inner) else { return nil }
      if case .function = inner { return "(" + text + ")?" }
      return text + "?"
    case .param(let name, let ref):
      // A generic parameter: its name, read from where it's declared.
      guard let ref else { return nil }
      let holder = unit(ref)
      let item = decl(ref)
      for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == name {
        return holder.string(Int(holder.generics[Int(item.genericStart) + g].token))
      }
      return nil
    case .selfType: return "Self"
    case .existential(let items):
      let parts = items.map(swiftType)
      guard !parts.contains(where: { $0 == nil }) else { return nil }
      return "any " + parts.compactMap { $0 }.joined(separator: " & ")
    }
  }
}

extension Project {
  /// The line (from 0) of the root's `Package.swift` that declares a target: `.target(name: "Atlas"`, else the first
  /// line naming it.
  func manifestLine(ofTarget target: String) -> Int? {
    guard let text = try? String(contentsOfFile: root + "/Package.swift", encoding: .utf8) else { return nil }
    let quoted = "\"" + target + "\""
    var first: Int?
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      guard line.contains(quoted), line.contains("name:") else { continue }
      if line.contains("arget(") || line.contains(".macro(") || line.contains(".plugin(") { return index }
      if first == nil { first = index }
    }
    return first
  }
}
