import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its signature (`name :: type`, else its line), its Haddock comment (`-- |`
/// or `{-| -}` above it), what it's inside (a type for a constructor or field, a class for a method) and its module.
extension HaskellModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      let holder = unit(ref)
      let item = decl(ref)
      guard let at = project.location(of: site), let kind = info(ref)?.kind else { return nil }
      let text = holder.string(Int(item.nameToken))
      let isOperator = holder.tokens[Int(item.nameToken)].kind == .punctuation
      let shown = isOperator ? "(" + text + ")" : text
      let module = moduleText(ref.unit)
      let symbol = SymbolPart(
        kind: partKind(kind), name: shown, keyword: keyword(kind), path: at.path, line: at.line, character: at.character, module: module,
        isSDK: holder.isInterface)
      let type = typeText(ref)
      var declaration: String
      switch kind {
      case .function, .variable, .method, .field, .foreign:
        declaration = type.isEmpty ? holder.lineText(at.line) : shown + " :: " + type
      case .constructor:
        // A GADT's constructor has a signature; a plain one its fields' types after its name.
        let isGADT = Int(item.nameToken) + 1 < holder.tokens.count && (holder.isToken(Int(item.nameToken) + 1, "::") || holder.isToken(Int(item.nameToken) + 1, ","))
        declaration = isGADT ? shown + " :: " + type : (shown + " " + type).trimmingCharacters(in: .whitespaces)
      default:
        declaration = holder.lineText(at.line)
      }
      var parents: [SymbolPart] = []
      if item.parent >= 0 {
        let parentRef = DeclRef(unit: ref.unit, decl: item.parent)
        if let parentKind = info(parentRef)?.kind, let place = project.location(of: .decl(parentRef)) {
          parents.append(
            SymbolPart(
              kind: partKind(parentKind), name: holder.string(Int(decl(parentRef).nameToken)), keyword: keyword(parentKind), path: place.path,
              line: place.line, character: place.character, module: module, isSDK: holder.isInterface))
        }
      }
      parents.append(modulePart(ref.unit))
      let statement = info(ref)?.statement ?? item.first
      return SymbolDetails(
        symbol: symbol, declaration: String(declaration.prefix(400)), documentation: haddock(holder, Int(statement)), parents: parents, type: nil)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = project.location(of: site), let file = hsFile(unitIndex) else { return nil }
      guard let local = file.locals[token] else {
        // A module's name.
        let name = moduleText(unitIndex)
        let symbol = SymbolPart(kind: .module, name: name, keyword: "module", path: at.path, line: at.line, character: at.character, module: name, isSDK: holder.isInterface)
        return SymbolDetails(symbol: symbol, declaration: "module " + name, documentation: haddock(holder, Int(token) - 1), parents: [], type: nil)
      }
      let text = holder.string(Int(token))
      let kind: SymbolPart.Kind = local.kind == .parameter ? .parameter : local.kind == .typeVariable ? .generic : .local
      let symbol = SymbolPart(kind: kind, name: text, keyword: "", path: at.path, line: at.line, character: at.character, module: moduleText(unitIndex), isSDK: false)
      var declaration = text
      if let signature = file.localSignatures[token], signature.1 > signature.0 {
        declaration += " :: " + holder.text(from: Int(signature.0), to: Int(signature.1))
      }
      return SymbolDetails(symbol: symbol, declaration: declaration, documentation: nil, parents: [modulePart(unitIndex)], type: nil)
    case .generic, .module:
      return nil
    }
  }

  private func modulePart(_ unitIndex: Int32) -> SymbolPart {
    let holder = project.units[Int(unitIndex)]
    return SymbolPart(kind: .module, name: moduleText(unitIndex), keyword: "module", path: holder.path, line: 0, character: 0, module: moduleText(unitIndex), isSDK: holder.isInterface)
  }

  private func partKind(_ kind: HsDeclInfo.Kind) -> SymbolPart.Kind {
    switch kind {
    case .function, .foreign, .method: return .function
    case .variable: return .variable
    case .data, .newtype, .dataFamily: return .structure
    case .typeSynonym, .typeFamily: return .typeAlias
    case .associatedType: return .associatedType
    case .classDecl: return .protocolType
    case .constructor, .patternSynonym: return .enumCase
    case .field: return .property
    }
  }

  private func keyword(_ kind: HsDeclInfo.Kind) -> String {
    switch kind {
    case .data, .dataFamily: return "data"
    case .newtype: return "newtype"
    case .typeSynonym, .typeFamily, .associatedType: return "type"
    case .classDecl: return "class"
    case .patternSynonym: return "pattern"
    case .foreign: return "foreign import"
    default: return ""
    }
  }

  /// The Haddock comment right above a token's line: `-- |` and the `--` lines after it, or `{-| … -}`.
  func haddock(_ holder: Unit, _ token: Int) -> String? {
    guard token >= 0, token < holder.tokens.count else { return nil }
    var line = holder.source.lines.line(of: holder.tokens[token].start) - 1
    var lines: [String] = []
    if line >= 0, holder.lineText(line).hasSuffix("-}") {
      while line >= 0 {
        var current = holder.lineText(line)
        let opens = current.hasPrefix("{-")
        if current.hasSuffix("-}") { current.removeLast(2) }
        if opens {
          guard current.hasPrefix("{-|") else { return nil }
          current.removeFirst(3)
        }
        lines.insert(current.trimmingCharacters(in: .whitespaces), at: 0)
        if opens { break }
        line -= 1
      }
      if line < 0 { return nil }
    } else {
      var found = false
      while line >= 0 {
        let current = holder.lineText(line)
        guard current.hasPrefix("--") else { break }
        var body = current.drop { $0 == "-" }
        body = body.drop { $0 == " " }
        if body.hasPrefix("|") {
          lines.insert(String(body.dropFirst()).trimmingCharacters(in: .whitespaces), at: 0)
          found = true
          break
        }
        lines.insert(String(body), at: 0)
        line -= 1
      }
      guard found else { return nil }
    }
    var paragraph: [String] = []
    for text in lines {
      if text.isEmpty {
        if paragraph.isEmpty { continue }
        break
      }
      paragraph.append(text)
    }
    return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
  }
}
