#if os(macOS) || os(Windows) || os(Linux)
  import CodeFolders
  import CodeScan
  import CodeSwiftModel
  import Foundation

  /// The two fast tiers of one workspace, in this process: Code's scanner for every language, and the Swift model for
  /// Swift. Each works on its own serial queue, built on first use, and answers with the editor's current text.
  final class CodeTiers: @unchecked Sendable {
    let root: URL
    private let scanner: ScannerTier
    private var swift: SwiftModelTier?
    private let lock = NSLock()

    init(root: URL) {
      self.root = root.standardizedFileURL
      scanner = ScannerTier(root: self.root)
    }

    /// The Swift model, made (and its project loaded, in the background) on first use.
    private var swiftModel: SwiftModelTier {
      lock.lock()
      defer { lock.unlock() }
      if let swift { return swift }
      let made = SwiftModelTier(root: root)
      swift = made
      return made
    }

    /// Starts loading the Swift model, so that the first question doesn't wait for all of it.
    func prepareSwiftModel() { _ = swiftModel }

    /// Drops the Swift model and its memory (turned off in settings).
    func dropSwiftModel() {
      lock.lock()
      swift = nil
      lock.unlock()
    }

    var hasSwiftModel: Bool {
      lock.lock()
      defer { lock.unlock() }
      return swift != nil
    }

    /// Reads the whole project again (the folder became trusted: its manifest may now be evaluated).
    func reloadSwiftModel() {
      lock.lock()
      let swift = swift
      lock.unlock()
      swift?.filesChanged([], reload: true)
    }

    /// Files changed on disk: the Swift model reads them again, or the whole project when files came or went or a
    /// manifest changed. The scanner checks its files itself when asked.
    func filesChanged(_ urls: [URL], structural: Bool) {
      lock.lock()
      let swift = swift
      lock.unlock()
      guard let swift else { return }
      let paths = urls.map(\.standardizedFileURL.path)
      let reload = paths.contains { $0.hasSuffix("/Package.swift") } || (structural && paths.contains { $0.hasSuffix(".swift") })
      swift.filesChanged(paths.filter { $0.hasSuffix(".swift") }, reload: reload)
    }

    func scannerDefinitions(url: URL, text: String, line: Int, column: Int) async -> DefinitionAnswer? {
      await scanner.definitions(path: url.standardizedFileURL.path, text: text, line: line, column: column)
    }

    func modelDefinitions(url: URL, text: String, line: Int, column: Int) async -> DefinitionAnswer? {
      await swiftModel.definitions(path: url.standardizedFileURL.path, text: text, line: line, column: column)
    }

    func modelCompletions(url: URL, text: String, line: Int, column: Int) async -> SwiftCompletionList? {
      await swiftModel.completions(path: url.standardizedFileURL.path, text: text, line: line, column: column)
    }

    /// What the scanner knows of the symbol at a position, for the symbol menu.
    func scannerSymbols(url: URL, text: String, line: Int, column: Int) async -> SymbolAnswer? {
      await scanner.symbols(path: url.standardizedFileURL.path, text: text, line: line, column: column)
    }

    /// What the Swift model knows of the symbol at a position, and how many places use it (counted only when asked:
    /// it reads every file that has the name).
    func modelSymbols(url: URL, text: String, line: Int, column: Int, countReferences: Bool) async
      -> (answer: SymbolAnswer?, references: Int?)
    {
      await swiftModel.symbols(
        path: url.standardizedFileURL.path, text: text, line: line, column: column, countReferences: countReferences)
    }

    /// The declaration at a place (a language server's answer), described by the Swift model, else the scanner.
    func describe(_ place: DefinitionPlace, useModel: Bool, useScanner: Bool) async -> SymbolDescription? {
      if useModel, Self.isSwift(place.url), let found = await swiftModel.describe(place) { return found }
      guard useScanner else { return nil }
      return await scanner.describe(place)
    }

    func scannerCompletions(url: URL, text: String, line: Int, column: Int) async -> [WorkspaceIndex.Completion] {
      await scanner.completions(path: url.standardizedFileURL.path, text: text, line: line, column: column)
    }

    func scannerSymbols(matching query: String, limit: Int) async -> [ProjectSymbol] {
      await scanner.symbols(matching: query, limit: limit)
    }

    /// Whether a file is one the Swift model reads.
    static func isSwift(_ url: URL) -> Bool { url.pathExtension.lowercased() == "swift" }
  }

  /// The line's text at `line` (from 0), trimmed, for the definitions menu.
  func previewLine(_ bytes: UnsafeBufferPointer<UInt8>, lineStart: Int) -> String {
    var end = lineStart
    while end < bytes.count, bytes[end] != 10 { end += 1 }
    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[lineStart..<end]), as: UTF8.self)
    return String(text.trimmingCharacters(in: .whitespaces).prefix(160))
  }

  /// Code's scanner over the workspace: lexical, with no types, every language. About 8 MB for a few hundred files.
  private final class ScannerTier: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodeKit.scanner", qos: .userInitiated)
    private let index: WorkspaceIndex
    private var indexed = false

    init(root: URL) {
      index = WorkspaceIndex(roots: FolderScope.isBroad(root) ? [] : [root.path])
    }

    /// The file as the editor has it, and its offset at a position.
    private func prepare(path: String, text: String, line: Int, column: Int) -> (SourceFile, Int)? {
      if !indexed {
        index.refresh()
        indexed = true
      } else {
        index.refreshIfStale()
      }
      guard let profile = LexProfile.profile(forPath: path) else { return nil }
      let source: SourceFile
      if let current = index.source(path: path), current.bytes.elementsEqual(text.utf8) {
        source = current
      } else {
        source = SourceFile(text, profile: profile)
        index.setDocument(source, path: path)
      }
      index.clearCache()
      return (source, source.lines.offset(line: line, character: column, in: source.text))
    }

    func definitions(path: String, text: String, line: Int, column: Int) async -> DefinitionAnswer? {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let (source, offset) = prepare(path: path, text: text, line: line, column: column) else {
            return continuation.resume(returning: nil)
          }
          var places: [DefinitionPlace] = []
          for answer in index.resolve(path: path, source: source, offset: offset).prefix(30) {
            guard let target = answer.path == path ? source : index.source(path: answer.path) else { continue }
            let start = Int(answer.symbol.offset)
            let range = index.range(in: target, start: start, end: start + Int(answer.symbol.nameLength))
            let lineStart = target.lines.offset(line: range.start.line, character: 0, in: target.text)
            places.append(
              DefinitionPlace(
                url: URL(fileURLWithPath: answer.path), line: range.start.line, column: range.start.character,
                name: answer.name, preview: previewLine(target.bytes, lineStart: lineStart)))
          }
          continuation.resume(returning: DefinitionAnswer(tier: .scanner, isSure: false, places: places))
        }
      }
    }

    func completions(path: String, text: String, line: Int, column: Int) async -> [WorkspaceIndex.Completion] {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let (source, offset) = prepare(path: path, text: text, line: line, column: column) else {
            return continuation.resume(returning: [])
          }
          continuation.resume(returning: index.completions(path: path, source: source, offset: offset))
        }
      }
    }

    func symbols(path: String, text: String, line: Int, column: Int) async -> SymbolAnswer? {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let (source, offset) = prepare(path: path, text: text, line: line, column: column) else {
            return continuation.resume(returning: nil)
          }
          let found = index.resolve(path: path, source: source, offset: offset).prefix(30).compactMap { describe($0, from: path, source: source) }
          continuation.resume(returning: SymbolAnswer(tier: .scanner, isSure: false, symbols: found))
        }
      }
    }

    func describe(_ place: DefinitionPlace) async -> SymbolDescription? {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          let path = place.url.path
          guard let source = index.source(path: path) else { return continuation.resume(returning: nil) }
          let offset = source.lines.offset(line: place.line, character: place.column, in: source.text)
          let found = index.resolve(path: path, source: source, offset: offset).first.flatMap { describe($0, from: path, source: source) }
          continuation.resume(returning: found)
        }
      }
    }

    /// Declarations for Open Quickly (`WorkspaceIndex.searchSymbols`), with their lines.
    func symbols(matching query: String, limit: Int) async -> [ProjectSymbol] {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          if !indexed {
            index.refresh()
            indexed = true
          } else {
            index.refreshIfStale()
          }
          let found = index.searchSymbols(query, limit: limit).compactMap { match -> ProjectSymbol? in
            guard let source = index.source(path: match.path) else { return nil }
            let range = index.range(in: source, start: match.offset, end: match.offset + match.name.utf8.count)
            return ProjectSymbol(
              name: match.name, kind: ProjectSymbol.Kind(match.kind), containers: match.containers,
              url: URL(fileURLWithPath: match.path), line: range.start.line, column: range.start.character,
              nameQuery: match.nameQuery)
          }
          continuation.resume(returning: found)
        }
      }
    }

    /// A resolved name as the menu describes it: the scanner knows kinds, signatures and parents, not modules or types.
    private func describe(_ resolved: WorkspaceIndex.Resolved, from path: String, source: SourceFile) -> SymbolDescription? {
      guard let target = resolved.path == path ? source : index.source(path: resolved.path) else { return nil }
      let details = index.details(resolved)
      let isSwift = resolved.path.hasSuffix(".swift")
      func place(_ offset: Int, _ length: Int, name: String) -> DefinitionPlace {
        let range = index.range(in: target, start: offset, end: offset + length)
        let lineStart = target.lines.offset(line: range.start.line, character: 0, in: target.text)
        return DefinitionPlace(
          url: URL(fileURLWithPath: resolved.path), line: range.start.line, column: range.start.character, name: name,
          preview: previewLine(target.bytes, lineStart: lineStart))
      }
      let symbol = SymbolInfo(
        kind: Self.kind(resolved.symbol.kind, isLocal: resolved.symbol.isLocal), name: resolved.name,
        keyword: Self.keyword(resolved.symbol.kind, swift: isSwift),
        place: place(Int(resolved.symbol.offset), Int(resolved.symbol.nameLength), name: resolved.name))
      let parents = (details?.parents ?? []).map { parent in
        SymbolInfo(
          kind: Self.kind(parent.kind, isLocal: false), name: parent.name, keyword: Self.keyword(parent.kind, swift: isSwift),
          place: place(parent.offset, parent.name.utf8.count, name: parent.name))
      }
      return SymbolDescription(
        symbol: symbol, declaration: details?.signature, documentation: details?.documentation, parents: parents)
    }

    static func kind(_ kind: CodeScan.SymbolKind, isLocal: Bool) -> SymbolInfo.Kind {
      switch kind {
      case .module, .namespace: return .module
      case .class: return .classType
      case .struct: return .structure
      case .enum: return .enumeration
      case .interface: return .protocolType
      case .extension: return .extensionDecl
      case .method: return .method
      case .function: return .function
      case .constructor: return .initializer
      case .property, .field, .key: return .property
      case .variable, .constant: return isLocal ? .local : .variable
      case .enumMember: return .enumCase
      case .typeAlias: return .typeAlias
      }
    }

    /// The word for a kind: Swift's in a Swift file, plain words elsewhere.
    static func keyword(_ kind: CodeScan.SymbolKind, swift: Bool) -> String {
      switch kind {
      case .module: return "module"
      case .namespace: return "namespace"
      case .class: return "class"
      case .struct: return "struct"
      case .enum: return "enum"
      case .interface: return swift ? "protocol" : "interface"
      case .extension: return "extension"
      case .method: return swift ? "func" : "method"
      case .function: return swift ? "func" : "function"
      case .constructor: return swift ? "init" : "constructor"
      case .property, .field: return swift ? "var" : "property"
      case .key: return "key"
      case .variable: return swift ? "var" : "variable"
      case .constant: return swift ? "let" : "constant"
      case .enumMember: return "case"
      case .typeAlias: return swift ? "typealias" : "type"
      }
    }
  }

  /// The Swift model of the workspace (CodeSwiftModel): declarations from every Swift file, the SDK's interfaces and
  /// headers read when a question needs them. 150 to 200 MB for a large app; the first question waits for the project
  /// to load (under a second).
  private final class SwiftModelTier: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodeKit.swiftModel", qos: .userInitiated)
    private var model: Model?
    /// The text each file was last given as, by path, so that an unchanged file isn't read again.
    private var given: [String: Int] = [:]

    private let root: String
    private let isBroad: Bool

    init(root: URL) {
      self.root = root.path
      isBroad = FolderScope.isBroad(root)
      queue.async { [self] in load() }
    }

    private func load() {
      guard !isBroad else { return }
      // A manifest is code: evaluated only in a trusted folder (FolderTrust).
      model = Model(project: Project(root: root, runsManifest: FolderTrust.isTrusted(URL(fileURLWithPath: root))))
      given = [:]
    }

    /// A reload is waiting: changes come in bursts (a checkout, a build).
    private var reloadPending = false

    func filesChanged(_ paths: [String], reload: Bool) {
      if reload {
        queue.async { [self] in
          guard !reloadPending else { return }
          reloadPending = true
          queue.asyncAfter(deadline: .now() + 1) { [self] in
            reloadPending = false
            load()
          }
        }
        return
      }
      queue.async { [self] in
        guard let model else { return }
        for path in paths {
          guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
          var hasher = Hasher()
          hasher.combine(text)
          let hash = hasher.finalize()
          guard given[path] != hash else { continue }
          given[path] = hash
          model.project.update(path: path, text: text)
        }
      }
    }

    /// The model, with `path` as the editor has it.
    private func prepare(path: String, text: String) -> Model? {
      guard let model else { return nil }
      var hasher = Hasher()
      hasher.combine(text)
      let hash = hasher.finalize()
      if given[path] != hash {
        given[path] = hash
        model.project.update(path: path, text: text)
      }
      return model
    }

    func definitions(path: String, text: String, line: Int, column: Int) async -> DefinitionAnswer? {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let model = prepare(path: path, text: text) else { return continuation.resume(returning: nil) }
          let answer = model.answer(path: path, line: line, character: column)
          guard answer.state != .unknown else { return continuation.resume(returning: nil) }
          var places: [DefinitionPlace] = []
          for site in answer.sites.prefix(30) {
            guard let found = model.location(of: site) else { continue }
            places.append(
              DefinitionPlace(
                url: URL(fileURLWithPath: found.path), line: found.line, column: found.character, name: found.name,
                preview: found.preview))
          }
          // An answer found by name only is a guess, like the scanner's.
          let sure = answer.state == .exact && !answer.byNameOnly
          continuation.resume(returning: DefinitionAnswer(tier: .model, isSure: sure, places: places))
        }
      }
    }

    func completions(path: String, text: String, line: Int, column: Int) async -> SwiftCompletionList? {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let model = prepare(path: path, text: text) else { return continuation.resume(returning: nil) }
          continuation.resume(returning: model.complete(path: path, line: line, character: column, limit: 300))
        }
      }
    }

    func symbols(path: String, text: String, line: Int, column: Int, countReferences: Bool) async
      -> (answer: SymbolAnswer?, references: Int?)
    {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let model = prepare(path: path, text: text) else { return continuation.resume(returning: (nil, nil)) }
          let found = model.details(path: path, line: line, character: column)
          guard found.answer.state != .unknown else { return continuation.resume(returning: (nil, nil)) }
          let sure = found.answer.state == .exact && !found.answer.byNameOnly
          let answer = SymbolAnswer(tier: .model, isSure: sure, symbols: found.details.map(Self.description))
          continuation.resume(returning: (answer, countReferences ? model.referenceCount(of: found.answer) : nil))
        }
      }
    }

    func describe(_ place: DefinitionPlace) async -> SymbolDescription? {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let model else { return continuation.resume(returning: nil) }
          let found = model.details(path: place.url.path, line: place.line, character: place.column)
          continuation.resume(returning: found.details.first.map(Self.description))
        }
      }
    }

    static func description(_ details: SymbolDetails) -> SymbolDescription {
      SymbolDescription(
        symbol: info(details.symbol), declaration: details.declaration, documentation: details.documentation,
        parents: details.parents.map(info), type: details.type.map(info))
    }

    static func info(_ part: SymbolPart) -> SymbolInfo {
      let kind: SymbolInfo.Kind
      switch part.kind {
      case .module: kind = .module
      case .structure: kind = .structure
      case .classType: kind = .classType
      case .actor: kind = .actor
      case .enumeration: kind = .enumeration
      case .protocolType: kind = .protocolType
      case .extensionDecl: kind = .extensionDecl
      case .function: kind = .function
      case .initializer, .deinitializer: kind = .initializer
      case .subscriptDecl: kind = .subscriptDecl
      case .property: kind = .property
      case .variable: kind = .variable
      case .local: kind = .local
      case .parameter: kind = .parameter
      case .enumCase: kind = .enumCase
      case .typeAlias, .associatedType: kind = .typeAlias
      case .macro: kind = .macro
      case .generic: kind = .generic
      }
      let place = part.path.map {
        DefinitionPlace(url: URL(fileURLWithPath: $0), line: part.line, column: part.character, name: part.name)
      }
      return SymbolInfo(kind: kind, name: part.name, keyword: part.keyword, place: place, module: part.module, isSDK: part.isSDK)
    }
  }
#endif
