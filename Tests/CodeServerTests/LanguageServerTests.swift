import CodeLSP
import Foundation
import Testing

@testable import CodeServer

/// The server on a pair of pipes, driven as an editor would, with its own read loop on another thread.
private final class Client: @unchecked Sendable {
  private let toServer = Pipe()
  private let fromServer = Pipe()
  private let thread: Thread
  private var buffer = Data()
  private var nextID = 1
  private(set) var notifications: [JSONValue] = []

  init() {
    let loop = LanguageServerLoop(input: toServer.fileHandleForReading.fileDescriptor, output: fromServer.fileHandleForWriting.fileDescriptor)
    thread = Thread { loop.run() }
    thread.start()
  }

  func notify(_ method: String, _ params: String) {
    write("{\"jsonrpc\":\"2.0\",\"method\":\"\(method)\",\"params\":\(params)}")
  }

  func request(_ method: String, _ params: String) -> JSONValue {
    let id = nextID
    nextID += 1
    write("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}")
    while true {
      let message = readMessage()
      if message["id"].int == id { return message }
      notifications.append(message)
    }
  }

  private func write(_ body: String) {
    sendRaw("Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
  }

  func sendRaw(_ text: String) {
    toServer.fileHandleForWriting.write(Data(text.utf8))
  }

  func readMessage() -> JSONValue {
    while true {
      if let split = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let header = String(decoding: buffer[buffer.startIndex..<split.lowerBound], as: UTF8.self)
        let length = Int(header.split(separator: " ").last ?? "0") ?? 0
        if buffer.distance(from: split.upperBound, to: buffer.endIndex) >= length {
          let end = buffer.index(split.upperBound, offsetBy: length)
          let body = Array(buffer[split.upperBound..<end])
          buffer = Data(buffer[end...])
          return body.withUnsafeBufferPointer { FastJSON.parse($0) } ?? .null
        }
      }
      let chunk = fromServer.fileHandleForReading.availableData
      if chunk.isEmpty { return .null }
      buffer.append(chunk)
    }
  }

  /// As an editor that quits without saying so.
  func closeInput() {
    try? toServer.fileHandleForWriting.close()
  }

  func close() {
    _ = request("shutdown", "null")
    notify("exit", "null")
  }
}

@Suite(.serialized) struct LanguageServerTests {
  private func start(_ files: [String: String], _ body: (Client, String) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codeserver-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: folder) }
    for (name, text) in files {
      let url = folder.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let client = Client()
    let initialized = client.request(
      "initialize",
      "{\"rootUri\":\"file://\(folder.path)\",\"capabilities\":{\"textDocument\":{\"documentSymbol\":{\"hierarchicalDocumentSymbolSupport\":true}}}}")
    #expect(initialized["result"]["capabilities"]["definitionProvider"].bool == true)
    #expect(initialized["result"]["capabilities"]["positionEncoding"].string == "utf-16")
    client.notify("initialized", "{}")
    try body(client, folder.path)
    client.close()
  }

  private func open(_ client: Client, _ path: String, _ text: String, language: String = "swift") {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    client.notify("textDocument/didOpen", "{\"textDocument\":{\"uri\":\"file://\(path)\",\"languageId\":\"\(language)\",\"version\":1,\"text\":\"\(escaped)\"}}")
  }

  private func at(_ path: String, _ line: Int, _ character: Int) -> String {
    "{\"textDocument\":{\"uri\":\"file://\(path)\"},\"position\":{\"line\":\(line),\"character\":\(character)}}"
  }

  @Test func definitionHoverAndSymbols() throws {
    let a = "/// Holds things.\nstruct Thing {\n  func run(fast: Bool) {}\n}\n"
    let b = "func use() {\n  let t = Thing()\n  t.run(fast: true)\n}\n"
    try start(["A.swift": a, "B.swift": b]) { client, root in
      let definition = client.request("textDocument/definition", at(root + "/B.swift", 1, 10))
      #expect(definition["result"].array?.first?["uri"].string == "file://\(root)/A.swift")
      #expect(definition["result"].array?.first?["range"]["start"]["line"].int == 1)

      let hover = client.request("textDocument/hover", at(root + "/B.swift", 1, 10))
      #expect(hover["result"]["contents"]["value"].string?.contains("Holds things.") == true)

      let symbols = client.request("textDocument/documentSymbol", "{\"textDocument\":{\"uri\":\"file://\(root)/A.swift\"}}")
      let thing = symbols["result"].array?.first
      #expect(thing?["name"].string == "Thing")
      #expect(thing?["children"].array?.first?["name"].string == "run")

      let found = client.request("workspace/symbol", "{\"query\":\"Thin\"}")
      #expect(found["result"].array?.first?["name"].string == "Thing")
    }
  }

  @Test func incrementalEditsAreApplied() throws {
    try start(["A.swift": "\n"]) { client, root in
      let path = root + "/A.swift"
      open(client, path, "let 😀 = 1\nstruct Old {}\n")
      // On the second line, and on the first after a character of two UTF-16 units.
      client.notify(
        "textDocument/didChange",
        """
        {"textDocument":{"uri":"file://\(path)","version":2},"contentChanges":[
        {"range":{"start":{"line":1,"character":7},"end":{"line":1,"character":10}},"text":"New"},
        {"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":7}},"text":" "}]}
        """)
      let symbols = client.request("textDocument/documentSymbol", "{\"textDocument\":{\"uri\":\"file://\(path)\"}}")
      #expect(symbols["result"].array?.map { $0["name"].string ?? "" }.contains("New") == true)
      let tokens = client.request("textDocument/semanticTokens/full", "{\"textDocument\":{\"uri\":\"file://\(path)\"}}")
      #expect((tokens["result"]["data"].array?.count ?? 0) % 5 == 0)
      #expect((tokens["result"]["data"].array?.count ?? 0) > 0)
    }
  }

  @Test func diagnosticsFollowTheBrackets() throws {
    try start(["A.swift": "\n"]) { client, root in
      let path = root + "/A.swift"
      open(client, path, "func a() {\n")
      _ = client.request("workspace/symbol", "{\"query\":\"x\"}")
      let problems = client.notifications.last { $0["method"].string == "textDocument/publishDiagnostics" }
      #expect(problems?["params"]["diagnostics"].array?.count == 1)
      client.notify(
        "textDocument/didChange",
        "{\"textDocument\":{\"uri\":\"file://\(path)\",\"version\":2},\"contentChanges\":[{\"text\":\"func a() {}\\n\"}]}")
      _ = client.request("workspace/symbol", "{\"query\":\"x\"}")
      let clean = client.notifications.last { $0["method"].string == "textDocument/publishDiagnostics" }
      #expect(clean?["params"]["diagnostics"].array?.isEmpty == true)
    }
  }

  @Test func formattingAnswersWithEdits() throws {
    try start(["A.swift": "\n"]) { client, root in
      let path = root + "/A.swift"
      open(client, path, "func a() {\nb( c )\n}\n")
      let edits = client.request(
        "textDocument/formatting", "{\"textDocument\":{\"uri\":\"file://\(path)\"},\"options\":{\"tabSize\":2,\"insertSpaces\":true}}")
      let first = edits["result"].array?.first
      #expect(first?["newText"].string == "  b(c)\n")
      #expect(first?["range"]["start"]["line"].int == 1)
      #expect(first?["range"]["end"]["line"].int == 2)
    }
  }

  @Test func renameRefusesWhatItCantProve() throws {
    try start(["A.swift": "func once() {}\nfunc two() {}\nstruct S { func two() {} }\nfunc f() { once(); two() }\n"]) { client, root in
      let path = root + "/A.swift"
      let good = client.request("textDocument/rename", String(at(path, 0, 6).dropLast()) + ",\"newName\":\"one\"}")
      #expect(good["result"]["changes"]["file://\(path)"].array?.count == 2)
      let bad = client.request("textDocument/rename", String(at(path, 1, 6).dropLast()) + ",\"newName\":\"one\"}")
      #expect(bad["error"]["code"].int == -32602)
    }
  }

  @Test func foldingAndSelection() throws {
    try start(["A.swift": "\n"]) { client, root in
      let path = root + "/A.swift"
      open(client, path, "func a() {\n  b(c)\n  d()\n}\n")
      let folds = client.request("textDocument/foldingRange", "{\"textDocument\":{\"uri\":\"file://\(path)\"}}")
      #expect(folds["result"].array?.contains { $0["startLine"].int == 0 && $0["endLine"].int == 2 } == true)
      let selection = client.request(
        "textDocument/selectionRange", "{\"textDocument\":{\"uri\":\"file://\(path)\"},\"positions\":[{\"line\":1,\"character\":4}]}")
      let innermost = selection["result"].array?.first
      #expect(innermost?["range"]["start"]["character"].int == 4)
      #expect(innermost?["parent"]["parent"]["range"]["start"]["line"].int != nil)
    }
  }

  @Test func brokenFramesAreSkipped() throws {
    try start(["A.swift": "struct Thing {}\n"]) { client, _ in
      let long = String(repeating: "9", count: 40)
      for header in ["Nonsense\r\n\r\n", "Content-Length: abc\r\n\r\n", "Content-Length: -1\r\n\r\n", "Content-Length: 2\r\n\r\n{]", "Content-Type: a\r\n\r\n"] {
        client.sendRaw(header)
        let found = client.request("workspace/symbol", "{\"query\":\"Thin\"}")
        #expect(found["result"].array?.first?["name"].string == "Thing", "\(header)")
      }
      // Only overflow to rule out: a length this big waits for its body, so it comes last, from a client of its own.
      let overflowing = Client()
      overflowing.sendRaw("Content-Length: \(long)\r\n\r\n")
      overflowing.closeInput()
    }
  }

  @Test func wildPositionsAndWidthsGetAnAnswer() throws {
    try start(["A.swift": "func a() {\nb( c )\n}\n"]) { client, root in
      let path = root + "/A.swift"
      for (line, character) in [(-1, -1), (1 << 40, 1 << 40), (0, 1 << 31), (3, 0), (99, 0)] {
        for method in ["definition", "hover", "completion", "references", "documentHighlight"] {
          #expect(client.request("textDocument/\(method)", at(path, line, character))["error"]["code"].int != -32603)
        }
        client.notify(
          "textDocument/didChange",
          "{\"textDocument\":{\"uri\":\"file://\(path)\",\"version\":2},\"contentChanges\":[{\"range\":{\"start\":{\"line\":\(line),\"character\":\(character)},\"end\":{\"line\":0,\"character\":0}},\"text\":\"\"}]}")
      }
      for tabSize in [-1, 0, 1_000_000] {
        let edits = client.request(
          "textDocument/formatting", "{\"textDocument\":{\"uri\":\"file://\(path)\"},\"options\":{\"tabSize\":\(tabSize),\"insertSpaces\":true}}")
        #expect(edits["result"].array != nil)
      }
    }
  }

  @Test func unknownMethodsGetAnErrorAndNoCrash() throws {
    try start(["A.swift": "\n"]) { client, _ in
      #expect(client.request("nonsense/method", "{}")["error"]["code"].int == -32601)
      #expect(client.request("textDocument/definition", at("/not/there.swift", 0, 0))["result"].isNull)
    }
  }
}

@Suite struct FastJSONTests {
  private func parse(_ text: String) -> JSONValue? { Array(text.utf8).withUnsafeBufferPointer { FastJSON.parse($0) } }

  @Test func values() {
    let value = parse(#"{"a":[1,-2.5,true,false,null,"x\n\"é😀"],"b":{"c":1e3}}"#)
    #expect(value?["a"].array?.count == 6)
    #expect(value?["a"].array?[0].int == 1)
    #expect(value?["a"].array?[5].string == "x\n\"é😀")
    #expect(value?["b"]["c"].int == 1000)
  }

  @Test func whatIsntJSONIsNil() {
    for text in ["", "{", "[1,", "{\"a\"}", "{a:1}", "tru", "\"abc", "[1 2]", "1e999", "-1e999"] {
      #expect(parse(text) == nil, "\(text)")
    }
    let deep = String(repeating: "[", count: 100_000)
    #expect(parse(deep) == nil)
  }

  @Test func numbersPastAnIntDontTrap() {
    #expect(parse("1e30")?.int == nil)
    #expect(parse("-1e30")?.int == nil)
    #expect(parse("-9223372036854775808") != nil)
    #expect(parse("99999999999999999999999999")?.int == nil)
    #expect(parse("123456789012")?.int == 123_456_789_012)
    #expect(parse("-5")?.int == -5)
    #expect(parse("2.9")?.int == 2)
  }

  @Test func writerRoundTrips() {
    var writer = JSONWriter()
    writer.string("a\"\\\n\t\u{1}é😀")
    let value = writer.bytes.withUnsafeBufferPointer { FastJSON.parse($0) }
    #expect(value?.string == "a\"\\\n\t\u{1}é😀")
  }

  @Test func uris() {
    #expect(decodePath("file:///a%20b/c.swift") == "/a b/c.swift")
    #expect(decodePath("file://localhost/a") == "/a")
    #expect(decodePath("untitled:1") == nil)
    #expect(uri("/a b/c#d.swift") == "file:///a%20b/c%23d.swift")
  }
}
