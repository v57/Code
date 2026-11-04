import CodeLSP
import CodePretty
import CodeScan
import Foundation

/// The language server: reads messages, answers on the same thread, so a query never sees a half-applied edit. All
/// answers take less than a frame, except the first scan, which runs before the first request is read.
public final class LanguageServerLoop {
  private let input: Int32
  private let output: Int32
  private var buffer = [UInt8]()
  private var index = WorkspaceIndex(roots: [])
  private var utf8Positions = false
  private var hierarchicalSymbols = false
  private var watchesFiles = false
  private var running = true
  private var shutdownRequested = false
  private var versions: [String: Int] = [:]

  public init(input: Int32, output: Int32) {
    self.input = input
    self.output = output
  }

  /// Serves on standard input and output until the client says `exit` or goes away.
  public static func runOnStandardStreams() -> Never {
    let loop = LanguageServerLoop(input: 0, output: 1)
    loop.run()
    exit(loop.shutdownRequested ? 0 : 1)
  }

  public func run() {
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    var start = 0
    while running {
      // Messages already here first.
      if let (bodyStart, length) = frame(at: start) {
        if buffer.count >= bodyStart + length {
          let message = buffer.withUnsafeBufferPointer { FastJSON.parse(UnsafeBufferPointer(rebasing: $0[bodyStart..<(bodyStart + length)])) }
          start = bodyStart + length
          if start * 2 > buffer.count {
            buffer.removeFirst(start)
            start = 0
          }
          if let message { handle(message) }
          continue
        }
      }
      #if os(Windows)
        let count = Int(chunk.withUnsafeMutableBytes { _read(input, $0.baseAddress, UInt32($0.count)) })
      #else
        let count = chunk.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
      #endif
      if count <= 0 { return }
      buffer.append(contentsOf: chunk[0..<count])
    }
  }

  /// A header's `Content-Length`, and where the body starts.
  private func frame(at start: Int) -> (Int, Int)? {
    guard buffer.count > start else { return nil }
    return buffer.withUnsafeBufferPointer { bytes -> (Int, Int)? in
      var i = start
      var length = -1
      while i < bytes.count {
        // A line of the header.
        var end = i
        while end < bytes.count, bytes[end] != 0x0A { end += 1 }
        guard end < bytes.count else { return nil }
        var lineEnd = end
        if lineEnd > i, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
        // A header without a usable length has no body to wait for: an empty one, which the caller skips.
        if lineEnd == i { return (end + 1, max(length, 0)) }
        // "Content-Length: 123", any case. Up to 1 TB, so that the sum can't overflow.
        if lineEnd - i > 15, bytes[i] | 0x20 == 0x63, bytes[i + 8] | 0x20 == 0x6C {
          var j = i + 15
          var value = 0
          while j < lineEnd, value >= 0 {
            if bytes[j] >= 0x30, bytes[j] <= 0x39, value < 1 << 40 {
              value = value * 10 + Int(bytes[j] - 0x30)
            } else if bytes[j] != 0x20 {
              value = -1
            }
            j += 1
          }
          length = value
        }
        i = end + 1
      }
      return nil
    }
  }

  private func send(_ write: (inout JSONWriter) -> Void) {
    var body = JSONWriter()
    write(&body)
    let header = Array("Content-Length: \(body.bytes.count)\r\n\r\n".utf8)
    writeAll(header)
    writeAll(body.bytes)
  }

  private func writeAll(_ bytes: [UInt8]) {
    bytes.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        #if os(Windows)
          let done = Int(_write(output, raw.baseAddress! + offset, UInt32(raw.count - offset)))
        #else
          let done = write(output, raw.baseAddress! + offset, raw.count - offset)
        #endif
        if done <= 0 { running = false; return }
        offset += done
      }
    }
  }

  private func respond(_ id: JSONValue, _ result: (inout JSONWriter) -> Void) {
    send { json in
      json.raw("{\"jsonrpc\":\"2.0\",\"id\":")
      json.value(id)
      json.raw(",\"result\":")
      result(&json)
      json.raw("}")
    }
  }

  private func respondNull(_ id: JSONValue) { respond(id) { $0.raw("null") } }

  private func fail(_ id: JSONValue, code: Int, _ message: String) {
    send { json in
      json.raw("{\"jsonrpc\":\"2.0\",\"id\":")
      json.value(id)
      json.raw(",\"error\":{\"code\":\(code),\"message\":")
      json.string(message)
      json.raw("}}")
    }
  }

  private func notify(_ method: String, _ params: (inout JSONWriter) -> Void) {
    send { json in
      json.raw("{\"jsonrpc\":\"2.0\",\"method\":")
      json.string(method)
      json.raw(",\"params\":")
      params(&json)
      json.raw("}")
    }
  }

  // MARK: - Dispatch

  private func handle(_ message: JSONValue) {
    guard let method = message["method"].string else { return }  // A response to a request of ours: none need one.
    let id = message["id"]
    let params = message["params"]
    if shutdownRequested, method != "exit" {
      if !id.isNull { fail(id, code: -32600, "Shutting down") }
      return
    }
    switch method {
    case "initialize": initialize(id, params)
    case "initialized": scanWorkspace()
    case "shutdown":
      shutdownRequested = true
      respondNull(id)
    case "exit": running = false
    case "textDocument/didOpen": didOpen(params)
    case "textDocument/didChange": didChange(params)
    case "textDocument/didClose":
      if let path = path(params["textDocument"]) {
        index.closeDocument(path: path)
        versions[path] = nil
        notify("textDocument/publishDiagnostics") { $0.raw("{\"uri\":"); $0.string(uri(path)); $0.raw(",\"diagnostics\":[]}") }
      }
    case "textDocument/didSave":
      break  // The editor's text is already the truth.
    case "workspace/didChangeWatchedFiles":
      for change in params["changes"].array ?? [] {
        if let uri = change["uri"].string, let path = decodePath(uri) { index.fileChanged(path: path) }
      }
      index.clearCache()
    case "workspace/didChangeWorkspaceFolders": changeFolders(params["event"])
    case "workspace/didChangeConfiguration", "$/setTrace", "$/cancelRequest", "window/workDoneProgress/cancel": break
    case "textDocument/documentSymbol": documentSymbols(id, params)
    case "textDocument/definition", "textDocument/declaration", "textDocument/implementation", "textDocument/typeDefinition":
      definition(id, params)
    case "textDocument/references": references(id, params)
    case "textDocument/documentHighlight": highlights(id, params)
    case "textDocument/hover": hover(id, params)
    case "textDocument/completion": completion(id, params)
    case "textDocument/signatureHelp": signatureHelp(id, params)
    case "workspace/symbol": workspaceSymbols(id, params)
    case "textDocument/semanticTokens/full": semanticTokens(id, params)
    case "textDocument/foldingRange": foldingRanges(id, params)
    case "textDocument/selectionRange": selectionRanges(id, params)
    case "textDocument/formatting": formatting(id, params, range: nil)
    case "textDocument/rangeFormatting": formatting(id, params, range: params["range"])
    case "textDocument/prepareRename": prepareRename(id, params)
    case "textDocument/rename": rename(id, params)
    default:
      if !id.isNull { fail(id, code: -32601, "Not handled: \(method)") }
    }
  }

  // MARK: - Lifecycle

  private func initialize(_ id: JSONValue, _ params: JSONValue) {
    var roots: [String] = []
    for folder in params["workspaceFolders"].array ?? [] {
      if let uri = folder["uri"].string, let path = decodePath(uri) { roots.append(path) }
    }
    if roots.isEmpty, let uri = params["rootUri"].string, let path = decodePath(uri) { roots = [path] }
    if roots.isEmpty, let path = params["rootPath"].string { roots = [path] }
    index = WorkspaceIndex(roots: roots)
    let capabilities = params["capabilities"]
    utf8Positions = capabilities["general"]["positionEncodings"].array?.contains(.string("utf-8")) == true
    index.encoding = utf8Positions ? .utf8 : .utf16
    hierarchicalSymbols = capabilities["textDocument"]["documentSymbol"]["hierarchicalDocumentSymbolSupport"].bool == true
    watchesFiles = capabilities["workspace"]["didChangeWatchedFiles"]["dynamicRegistration"].bool == true

    let tokenTypes = SemanticTokenType.legend.map { "\"\($0)\"" }.joined(separator: ",")
    respond(id) { json in
      json.raw(
        """
        {"capabilities":{"positionEncoding":"\(utf8Positions ? "utf-8" : "utf-16")","textDocumentSync":{"openClose":true,"change":2,"save":false},\
        "documentSymbolProvider":true,"definitionProvider":true,"declarationProvider":true,"implementationProvider":true,\
        "typeDefinitionProvider":true,"referencesProvider":true,"documentHighlightProvider":true,"hoverProvider":true,\
        "workspaceSymbolProvider":true,"foldingRangeProvider":true,"selectionRangeProvider":true,\
        "documentFormattingProvider":true,"documentRangeFormattingProvider":true,\
        "renameProvider":{"prepareProvider":true},\
        "completionProvider":{"triggerCharacters":["."],"resolveProvider":false},\
        "signatureHelpProvider":{"triggerCharacters":["(",","]},\
        "semanticTokensProvider":{"legend":{"tokenTypes":[\(tokenTypes)],"tokenModifiers":[]},"full":true},\
        "workspace":{"workspaceFolders":{"supported":true,"changeNotifications":true}}},\
        "serverInfo":{"name":"code-lsp","version":"1"}}
        """)
    }
  }

  private func scanWorkspace() {
    index.refresh()
  }

  private func changeFolders(_ event: JSONValue) {
    var roots = Set(index.roots)
    for folder in event["added"].array ?? [] {
      if let uri = folder["uri"].string, let path = decodePath(uri) { roots.insert(path) }
    }
    for folder in event["removed"].array ?? [] {
      if let uri = folder["uri"].string, let path = decodePath(uri) { roots.remove(path) }
    }
    let documents = index.documents
    let encoding = index.encoding
    index = WorkspaceIndex(roots: Array(roots))
    index.encoding = encoding
    index.refresh()
    for (path, source) in documents { index.setDocument(source, path: path) }
  }

  // MARK: - Documents

  private func path(_ document: JSONValue) -> String? { document["uri"].string.flatMap(decodePath) }

  private func didOpen(_ params: JSONValue) {
    let document = params["textDocument"]
    guard let path = path(document), let text = document["text"].string else { return }
    let profile = profile(path: path, language: document["languageId"].string, firstLine: text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init))
    let source = SourceFile(text, profile: profile)
    index.setDocument(source, path: path)
    versions[path] = document["version"].int
    publishProblems(path: path, source: source)
  }

  private func profile(path: String, language: String?, firstLine: String?) -> LexProfile {
    if let found = LexProfile.profile(forPath: path, firstLine: firstLine) { return found }
    if let language, let found = LexProfile.profile(forLanguage: language) { return found }
    return .plainText
  }

  private func didChange(_ params: JSONValue) {
    let document = params["textDocument"]
    guard let path = path(document), let current = index.documents[path] else { return }
    var bytes = Array(current.bytes)
    var map = current.lines
    for change in params["contentChanges"].array ?? [] {
      guard let text = change["text"].string else { continue }
      let range = change["range"]
      if range.isNull {
        bytes = Array(text.utf8)
      } else {
        let (start, end) = bytes.withUnsafeBufferPointer { buffer -> (Int, Int) in
          // Positions read the buffer as far as the end of a line, which has padding in the file, not here: stop short.
          let base = buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!
          let encoding = index.encoding
          let s = map.offset(line: range["start"]["line"].int ?? 0, character: range["start"]["character"].int ?? 0, in: base, encoding: encoding)
          let e = map.offset(line: range["end"]["line"].int ?? 0, character: range["end"]["character"].int ?? 0, in: base, encoding: encoding)
          return (min(s, buffer.count), min(max(s, e), buffer.count))
        }
        bytes.replaceSubrange(start..<end, with: Array(text.utf8))
      }
      // A further change in this message counts on the lines after this one.
      map = bytes.withUnsafeBufferPointer { LineMap($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, $0.count) }
    }
    let source = SourceFile(bytes: bytes, profile: current.profile)
    index.setDocument(source, path: path)
    versions[path] = document["version"].int
    publishProblems(path: path, source: source)
  }

  private func publishProblems(path: String, source: SourceFile) {
    let problems = source.symbols.problems
    let version = versions[path]
    notify("textDocument/publishDiagnostics") { json in
      json.raw("{\"uri\":")
      json.string(uri(path))
      if let version { json.raw(",\"version\":\(version)") }
      json.raw(",\"diagnostics\":[")
      for (position, problem) in problems.enumerated() {
        if position > 0 { json.raw(",") }
        json.raw("{\"range\":")
        writeRange(&json, index.range(in: source, start: Int(problem.offset), end: Int(problem.offset) + Int(problem.length)))
        json.raw(",\"severity\":2,\"source\":\"code-lsp\",\"message\":")
        json.string(problem.message)
        json.raw("}")
      }
      json.raw("]}")
    }
  }

  /// The document's text, the file's if it isn't open, and what the request's position means in it.
  private func place(_ params: JSONValue) -> (path: String, source: SourceFile, offset: Int)? {
    guard let path = path(params["textDocument"]), let source = index.source(path: path) else { return nil }
    let position = params["position"]
    let offset = source.lines.offset(line: position["line"].int ?? 0, character: position["character"].int ?? 0, in: source.text, encoding: index.encoding)
    return (path, source, offset)
  }

  /// Keeps the workspace current for clients that don't report file changes.
  private func refreshForWorkspaceQuery() {
    guard !watchesFiles else { return }
    index.refreshIfStale()
    index.clearCache()
  }

  // MARK: - Features

  private func documentSymbols(_ id: JSONValue, _ params: JSONValue) {
    guard let path = path(params["textDocument"]), let source = index.source(path: path) else { return respondNull(id) }
    let symbols = source.symbols
    let visible = symbols.symbols.indices.filter { !symbols.symbols[$0].isLocal }
    if hierarchicalSymbols {
      var children = [Int: [Int]]()
      var roots: [Int] = []
      for position in visible {
        let parent = Int(symbols.symbols[position].parent)
        if parent >= 0, !symbols.symbols[parent].isLocal { children[parent, default: []].append(position) } else { roots.append(position) }
      }
      func write(_ position: Int, _ json: inout JSONWriter) {
        let symbol = symbols.symbols[position]
        let start = Int(symbol.offset)
        let name = index.range(in: source, start: start, end: start + Int(symbol.nameLength))
        let whole = index.range(in: source, start: min(Int(symbol.start), start), end: max(Int(symbol.end), start + Int(symbol.nameLength)))
        json.raw("{\"name\":")
        json.string(symbols.name(symbol))
        json.raw(",\"kind\":\(symbol.kind.wire),\"range\":")
        writeRange(&json, whole)
        json.raw(",\"selectionRange\":")
        writeRange(&json, name)
        if let list = children[position] {
          json.raw(",\"children\":[")
          for (i, child) in list.enumerated() {
            if i > 0 { json.raw(",") }
            write(child, &json)
          }
          json.raw("]")
        }
        json.raw("}")
      }
      respond(id) { json in
        json.raw("[")
        for (i, root) in roots.enumerated() {
          if i > 0 { json.raw(",") }
          write(root, &json)
        }
        json.raw("]")
      }
    } else {
      respond(id) { json in
        json.raw("[")
        for (i, position) in visible.enumerated() {
          if i > 0 { json.raw(",") }
          let symbol = symbols.symbols[position]
          let start = Int(symbol.offset)
          json.raw("{\"name\":")
          json.string(symbols.name(symbol))
          json.raw(",\"kind\":\(symbol.kind.wire),\"location\":{\"uri\":")
          json.string(uri(path))
          json.raw(",\"range\":")
          writeRange(&json, index.range(in: source, start: start, end: start + Int(symbol.nameLength)))
          json.raw("}}")
        }
        json.raw("]")
      }
    }
  }

  private func definition(_ id: JSONValue, _ params: JSONValue) {
    guard let place = place(params) else { return respondNull(id) }
    refreshForWorkspaceQuery()
    let answers = index.resolve(path: place.path, source: place.source, offset: place.offset)
    respond(id) { json in
      json.raw("[")
      var count = 0
      for answer in answers {
        guard let target = answer.path == place.path ? place.source : index.source(path: answer.path) else { continue }
        if count > 0 { json.raw(",") }
        count += 1
        let start = Int(answer.symbol.offset)
        json.raw("{\"uri\":")
        json.string(uri(answer.path))
        json.raw(",\"range\":")
        writeRange(&json, index.range(in: target, start: start, end: start + Int(answer.symbol.nameLength)))
        json.raw("}")
      }
      json.raw("]")
    }
  }

  private func writeLocations(_ id: JSONValue, _ locations: [SourceLocation]) {
    respond(id) { json in
      json.raw("[")
      for (i, location) in locations.enumerated() {
        if i > 0 { json.raw(",") }
        json.raw("{\"uri\":")
        json.string(uri(location.path))
        json.raw(",\"range\":")
        writeRange(&json, location.range)
        json.raw("}")
      }
      json.raw("]")
    }
  }

  private func references(_ id: JSONValue, _ params: JSONValue) {
    guard let place = place(params) else { return respondNull(id) }
    refreshForWorkspaceQuery()
    let includeDeclaration = params["context"]["includeDeclaration"].bool ?? true
    writeLocations(id, index.references(path: place.path, source: place.source, offset: place.offset, includeDeclaration: includeDeclaration))
  }

  private func highlights(_ id: JSONValue, _ params: JSONValue) {
    guard let place = place(params) else { return respondNull(id) }
    let found = index.references(path: place.path, source: place.source, offset: place.offset, scope: .file)
    respond(id) { json in
      json.raw("[")
      for (i, location) in found.enumerated() {
        if i > 0 { json.raw(",") }
        json.raw("{\"range\":")
        writeRange(&json, location.range)
        json.raw("}")
      }
      json.raw("]")
    }
  }

  private func hover(_ id: JSONValue, _ params: JSONValue) {
    guard let place = place(params), let top = index.resolve(path: place.path, source: place.source, offset: place.offset).first,
      let text = index.describe(top)
    else { return respondNull(id) }
    respond(id) { json in
      json.raw("{\"contents\":{\"kind\":\"markdown\",\"value\":")
      json.string(text)
      json.raw("}}")
    }
  }

  private func completion(_ id: JSONValue, _ params: JSONValue) {
    guard let place = place(params) else { return respondNull(id) }
    let items = index.completions(path: place.path, source: place.source, offset: place.offset)
    respond(id) { json in
      json.raw("{\"isIncomplete\":\(items.count >= 150),\"items\":[")
      for (i, item) in items.enumerated() {
        if i > 0 { json.raw(",") }
        json.raw("{\"label\":")
        json.string(item.label)
        json.raw(",\"kind\":\(completionKind(item.kind))")
        json.raw(",\"sortText\":\"\(String(format: "%05d", 99999 - min(item.score, 99999)))\"}")
      }
      json.raw("]}")
    }
  }

  private func completionKind(_ kind: SymbolKind?) -> Int {
    guard let kind else { return 14 }  // Keyword.
    switch kind {
    case .class: return 7
    case .struct: return 22
    case .enum: return 13
    case .enumMember: return 20
    case .interface: return 8
    case .method: return 2
    case .function: return 3
    case .constructor: return 4
    case .field: return 5
    case .property: return 10
    case .constant: return 21
    case .module, .namespace, .extension: return 9
    case .typeAlias: return 7
    case .variable, .key: return 6
    }
  }

  private func signatureHelp(_ id: JSONValue, _ params: JSONValue) {
    guard let place = place(params), let found = index.signature(path: place.path, source: place.source, offset: place.offset) else {
      return respondNull(id)
    }
    respond(id) { json in
      json.raw("{\"signatures\":[")
      for (i, label) in found.labels.enumerated() {
        if i > 0 { json.raw(",") }
        json.raw("{\"label\":")
        json.string(label)
        json.raw("}")
      }
      json.raw("],\"activeSignature\":0,\"activeParameter\":\(found.parameter)}")
    }
  }

  private func workspaceSymbols(_ id: JSONValue, _ params: JSONValue) {
    refreshForWorkspaceQuery()
    let found = index.workspaceSymbols(query: params["query"].string ?? "")
    respond(id) { json in
      json.raw("[")
      var count = 0
      for item in found {
        guard let source = index.source(path: item.path) else { continue }
        if count > 0 { json.raw(",") }
        count += 1
        json.raw("{\"name\":")
        json.string(item.name)
        json.raw(",\"kind\":\(item.kind.wire)")
        if let container = item.container {
          json.raw(",\"containerName\":")
          json.string(container)
        }
        json.raw(",\"location\":{\"uri\":")
        json.string(uri(item.path))
        json.raw(",\"range\":")
        writeRange(&json, index.range(in: source, start: item.offset, end: item.offset + item.name.utf8.count))
        json.raw("}}")
      }
      json.raw("]")
    }
  }

  private func semanticTokens(_ id: JSONValue, _ params: JSONValue) {
    guard let path = path(params["textDocument"]), let source = index.source(path: path) else { return respondNull(id) }
    respond(id) { json in
      json.raw("{\"data\":[")
      var previousLine = 0
      var previousCharacter = 0
      var first = true
      let symbols = source.symbols
      // Declared names get their kind's color; sorted by offset for one walk with the tokens.
      let declared = symbols.symbols.sorted { $0.offset < $1.offset }
      var nextDeclared = 0
      for token in source.tokens {
        var type = SemanticTokenType.type(of: token.kind)
        while nextDeclared < declared.count, Int(declared[nextDeclared].offset) < token.start { nextDeclared += 1 }
        if nextDeclared < declared.count, Int(declared[nextDeclared].offset) == token.start {
          type = SemanticTokenType.type(of: declared[nextDeclared].kind)
        }
        guard let type else { continue }
        // A token over several lines is one per line.
        var start = token.start
        repeat {
          let position = source.lines.position(of: start, in: source.text, encoding: index.encoding)
          let lineEnd = position.line + 1 < source.lines.starts.count ? Int(source.lines.starts[position.line + 1]) - 1 : source.count
          let end = min(token.end, lineEnd)
          let endPosition = source.lines.position(of: end, in: source.text, encoding: index.encoding)
          let length = endPosition.character - position.character
          if length > 0 {
            let deltaLine = position.line - previousLine
            let deltaCharacter = deltaLine == 0 ? position.character - previousCharacter : position.character
            if !first { json.raw(",") }
            first = false
            json.integer(deltaLine)
            json.raw(",")
            json.integer(deltaCharacter)
            json.raw(",")
            json.integer(length)
            json.raw(",")
            json.integer(type)
            json.raw(",0")
            previousLine = position.line
            previousCharacter = position.character
          }
          start = end + 1
        } while start < token.end
      }
      json.raw("]}")
    }
  }

  private func foldingRanges(_ id: JSONValue, _ params: JSONValue) {
    guard let path = path(params["textDocument"]), let source = index.source(path: path) else { return respondNull(id) }
    respond(id) { json in
      json.raw("[")
      var count = 0
      func add(_ start: Int, _ end: Int, kind: String?, _ json: inout JSONWriter) {
        guard end > start else { return }
        if count > 0 { json.raw(",") }
        count += 1
        json.raw("{\"startLine\":\(start),\"endLine\":\(end)")
        if let kind { json.raw(",\"kind\":\"\(kind)\"") }
        json.raw("}")
      }
      for block in source.symbols.blocks {
        // Up to the line before the closer, which stays visible.
        let start = source.lines.line(of: Int(block.start))
        let end = source.lines.line(of: Int(block.end))
        add(start, end > start + 1 ? end - 1 : end, kind: nil, &json)
      }
      // Multi-line comments, and runs of line comments.
      var run = -1
      var runEnd = -1
      for token in source.tokens {
        guard token.kind == .comment || token.kind == .docComment else {
          if run >= 0 { add(run, runEnd, kind: "comment", &json) }
          run = -1
          continue
        }
        let line = source.lines.line(of: token.start)
        let last = source.lines.line(of: token.end)
        if run >= 0, line > runEnd + 1 {
          add(run, runEnd, kind: "comment", &json)
          run = -1
        }
        if run < 0 { run = line }
        runEnd = last
      }
      if run >= 0 { add(run, runEnd, kind: "comment", &json) }
      json.raw("]")
    }
  }

  private func selectionRanges(_ id: JSONValue, _ params: JSONValue) {
    guard let path = path(params["textDocument"]), let source = index.source(path: path) else { return respondNull(id) }
    let positions = params["positions"].array ?? []
    respond(id) { json in
      json.raw("[")
      for (i, position) in positions.enumerated() {
        if i > 0 { json.raw(",") }
        let offset = source.lines.offset(line: position["line"].int ?? 0, character: position["character"].int ?? 0, in: source.text, encoding: index.encoding)
        var spans: [(Int, Int)] = []
        let at = source.tokenIndex(at: offset)
        if at < source.tokens.count, source.tokens[at].start <= offset {
          spans.append((source.tokens[at].start, source.tokens[at].end))
        }
        // The brackets around it, inside and with their delimiters, then the file.
        var depth = 0
        var scan = min(at, source.tokens.count) - 1
        var closing = at
        while scan >= 0 {
          let token = source.tokens[scan]
          if token.kind == .close { depth += 1 } else if token.kind == .open {
            if depth == 0 {
              var d = 0
              while closing < source.tokens.count {
                let c = source.tokens[closing]
                if c.kind == .open { d += 1 } else if c.kind == .close {
                  if d == 0 { break }
                  d -= 1
                }
                closing += 1
              }
              let end = closing < source.tokens.count ? source.tokens[closing].start : source.count
              spans.append((token.end, end))
              spans.append((token.start, min(end + 1, source.count)))
              closing += 1
            } else {
              depth -= 1
            }
          }
          scan -= 1
        }
        spans.append((0, source.count))
        // Innermost out; each contains the one before.
        var written = 0
        for span in spans {
          json.raw(written == 0 ? "{\"range\":" : ",\"parent\":{\"range\":")
          writeRange(&json, index.range(in: source, start: span.0, end: span.1))
          written += 1
        }
        for _ in 0..<written { json.raw("}") }
      }
      json.raw("]")
    }
  }

  private func formatting(_ id: JSONValue, _ params: JSONValue, range: JSONValue?) {
    guard let path = path(params["textDocument"]), let source = index.source(path: path) else { return respondNull(id) }
    var options = PrettyOptions.resolve(path: path, source: source)
    // The editor's say wins over what the text looks like, unless a project's file said otherwise, which it can't tell.
    let requested = params["options"]
    if requested["tabSize"].int != nil, !hasProjectFormatConfig(path: path) {
      if requested["insertSpaces"].bool == false {
        options.useTabs = true
        options.indentWidth = 1
      } else if let tabSize = requested["tabSize"].int, requested["insertSpaces"].bool == true {
        options.useTabs = false
        options.indentWidth = tabSize
      }
    }
    let output = Pretty.format(source, path: path, options: options)
    if output.refused {
      notify("window/logMessage") { $0.raw("{\"type\":2,\"message\":"); $0.string("\(path): not formatted: the result would change its tokens"); $0.raw("}") }
    }
    var edits = output.text.withUnsafeBufferPointer { Pretty.edits(from: source.bytes, to: $0) }
    if let range {
      let first = range["start"]["line"].int ?? 0
      let last = range["end"]["line"].int ?? 0
      edits = edits.filter { $0.startLine <= last && $0.endLine >= first }
    }
    respond(id) { json in
      json.raw("[")
      for (i, edit) in edits.enumerated() {
        if i > 0 { json.raw(",") }
        json.raw("{\"range\":{\"start\":{\"line\":\(edit.startLine),\"character\":0},\"end\":{\"line\":\(edit.endLine),\"character\":0}},\"newText\":")
        json.quoted(edit.text)
        json.raw("}")
      }
      json.raw("]")
    }
  }

  private func hasProjectFormatConfig(path: String) -> Bool {
    var folder = (path as NSString).deletingLastPathComponent
    let names = [".editorconfig", ".prettierrc", ".prettierrc.json", ".swift-format", "rustfmt.toml", ".rustfmt.toml", ".clang-format"]
    while folder.count > 1 {
      for name in names where FileManager.default.fileExists(atPath: folder + "/" + name) { return true }
      if FileManager.default.fileExists(atPath: folder + "/.git") { return false }
      folder = (folder as NSString).deletingLastPathComponent
    }
    return false
  }

  private func prepareRename(_ id: JSONValue, _ params: JSONValue) {
    guard let place = place(params), let tokenIndex = place.source.nameToken(at: place.offset) else {
      return fail(id, code: -32602, "Nothing to rename here")
    }
    refreshForWorkspaceQuery()
    guard index.renameLocations(path: place.path, source: place.source, offset: place.offset) != nil else {
      return fail(id, code: -32602, "Declared more than once: renaming needs a compiler")
    }
    let token = place.source.tokens[tokenIndex]
    respond(id) { json in writeRange(&json, index.range(in: place.source, start: token.start, end: token.end)) }
  }

  private func rename(_ id: JSONValue, _ params: JSONValue) {
    guard let place = place(params), let name = params["newName"].string else { return respondNull(id) }
    refreshForWorkspaceQuery()
    guard let locations = index.renameLocations(path: place.path, source: place.source, offset: place.offset) else {
      return fail(id, code: -32602, "Declared more than once: renaming needs a compiler")
    }
    var byFile: [String: [CodeScan.TextRange]] = [:]
    for location in locations { byFile[location.path, default: []].append(location.range) }
    respond(id) { json in
      json.raw("{\"changes\":{")
      for (i, (path, ranges)) in byFile.enumerated() {
        if i > 0 { json.raw(",") }
        json.string(uri(path))
        json.raw(":[")
        for (j, range) in ranges.enumerated() {
          if j > 0 { json.raw(",") }
          json.raw("{\"range\":")
          writeRange(&json, range)
          json.raw(",\"newText\":")
          json.string(name)
          json.raw("}")
        }
        json.raw("]")
      }
      json.raw("}}")
    }
  }
}

private func writeRange(_ json: inout JSONWriter, _ range: CodeScan.TextRange) {
  json.raw("{\"start\":{\"line\":")
  json.integer(range.start.line)
  json.raw(",\"character\":")
  json.integer(range.start.character)
  json.raw("},\"end\":{\"line\":")
  json.integer(range.end.line)
  json.raw(",\"character\":")
  json.integer(range.end.character)
  json.raw("}}")
}

/// `file:///a%20b` to `/a b`.
func decodePath(_ uri: String) -> String? {
  guard uri.hasPrefix("file://") else { return nil }
  var path = String(uri.dropFirst(7))
  // file://localhost/…
  if !path.hasPrefix("/"), let slash = path.firstIndex(of: "/") { path = String(path[slash...]) }
  return path.removingPercentEncoding ?? path
}

private let uriAllowed: CharacterSet = {
  var allowed = CharacterSet.urlPathAllowed
  allowed.remove(charactersIn: "+&=;,?#@:$")
  return allowed
}()

/// `/a b` to `file:///a%20b`.
func uri(_ path: String) -> String {
  "file://" + (path.addingPercentEncoding(withAllowedCharacters: uriAllowed) ?? path)
}

enum SemanticTokenType {
  static let legend = [
    "comment", "keyword", "string", "number", "operator", "macro", "decorator", "type", "class", "struct", "enum", "interface",
    "function", "method", "property", "variable", "namespace", "enumMember", "parameter",
  ]

  static func type(of kind: TokenKind) -> Int? {
    switch kind {
    case .comment, .docComment: return 0
    case .keyword, .declarationKeyword: return 1
    case .string: return 2
    case .number: return 3
    case .directive: return 5
    case .attribute: return 6
    case .interpolationOpen, .interpolationClose: return 5
    default: return nil
    }
  }

  static func type(of kind: SymbolKind) -> Int {
    switch kind {
    case .class, .typeAlias: return 8
    case .struct: return 9
    case .enum: return 10
    case .interface: return 11
    case .function, .constructor: return 12
    case .method: return 13
    case .property, .field, .key: return 14
    case .variable, .constant: return 15
    case .module, .namespace, .extension: return 16
    case .enumMember: return 17
    }
  }
}
