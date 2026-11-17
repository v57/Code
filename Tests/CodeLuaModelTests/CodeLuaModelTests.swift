import CodeModel
import CodeLuaModel
import Foundation
import Testing

/// A Lua project in a temporary folder, from file text with `^^` before the word a question is about. Lua's own
/// library is Code's stub.
private final class Project {
  let root: String
  let model: LuaModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String]) throws {
    let base = NSTemporaryDirectory() + "luamodel-" + UUID().uuidString
    root = base + "/project"
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "^^") {
          let character = rest.utf16.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
          var key = word
          var n = 2
          while marks[key] != nil {
            key = word + String(n)
            n += 1
          }
          marks[key] = (root + "/" + name, number, character)
          rest.removeSubrange(mark)
        }
        body += rest + "\n"
      }
      let url = URL(fileURLWithPath: root + "/" + name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try body.write(to: url, atomically: true, encoding: .utf8)
    }
    model = LuaModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), `std:<name>` for the stub's.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { $0.path.hasPrefix("std:") ? $0.path : "\($0.path):\($0.line)" } })
  }

  /// One place, exactly.
  func exact(_ key: String) -> String? {
    let found = answer(key)
    return found.state == .exact && found.places.count == 1 ? found.places[0] : nil
  }

  /// Every place, exactly, sorted.
  func all(_ key: String) -> [String]? {
    let found = answer(key)
    return found.state == .exact ? found.places.sorted() : nil
  }

  func references(_ key: String) -> [String] {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return model.references(of: found).map { "\($0.path):\($0.line)" }.sorted()
  }

  func complete(_ key: String, typed: Int = 0) -> (context: ModelCompletionContext, state: AnswerState, names: [String]) {
    let mark = marks[key]!
    let list = model.complete(path: mark.path, line: mark.line, character: mark.character + typed, limit: 400)
    return (list.context, list.state, list.items.map(\.name))
  }

  func details(_ key: String) -> SymbolDetails? {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    guard let site = found.sites.first else { return nil }
    return model.details(of: site)
  }
}

@Suite struct CodeLuaModelTests {
  @Test func localsFollowLuasScoping() throws {
    let project = try Project([
      "main.lua": """
      local x = 1
      local x = ^^x + 1
      local function fact(n)
        return n * ^^fact(n - 1)
      end
      local inc = function(n) return ^^inc end
      local y = 10
      do
        local y = ^^y * 2
      end
      repeat
        local done = true
      until ^^done
      for y = 1, ^^y do print(^^y) end
      local a = 1
      local function shadow(a)
        return function() return ^^a end
      end
      print(^^x)
      """
    ])
    #expect(project.exact("x") == "main.lua:1")
    #expect(project.exact("fact") == "main.lua:3")
    // A local function value doesn't see its own name: a global nobody assigns.
    #expect(project.answer("inc").state == .unknown)
    #expect(project.exact("y") == "main.lua:7")
    #expect(project.exact("done") == "main.lua:12")
    #expect(project.exact("y2") == "main.lua:7")
    #expect(project.exact("y3") == "main.lua:14")
    #expect(project.exact("a") == "main.lua:16")
    #expect(project.exact("x2") == "main.lua:2")
    #expect(project.references("x2") == ["main.lua:19", "main.lua:2"])
  }

  @Test func globalsAreTheProgramsAndTheStandardLibrarys() throws {
    let project = try Project([
      "a.lua": """
      counter = 0
      function report() return counter end
      """,
      "b.lua": """
      counter = ^^counter + 1
      ^^report()
      ^^print(^^string.^^format("%d", 1))
      local s = "x"
      s:^^upper();
      ("%d"):^^rep(2)
      ^^game.^^players[1].^^name = "x"
      """,
    ])
    #expect(project.all("counter") == ["a.lua:1", "b.lua:1"])
    #expect(project.exact("report") == "a.lua:2")
    #expect(project.exact("print") == "std:print")
    #expect(project.exact("string") == "std:string")
    #expect(project.exact("format") == "std:string.format")
    #expect(project.exact("upper") == "std:string.upper")
    #expect(project.exact("rep") == "std:string.rep")
    // A host's global (Factorio's `game`): unknown, never a guess.
    #expect(project.answer("game").state == .unknown)
    #expect(project.answer("players").state == .unknown)
    // A field assigned on what can't be told: the fields of that name, as candidates.
    #expect(project.answer("name").state != .exact)
    #expect(project.references("report") == ["a.lua:2", "b.lua:2"])
  }

  /// A required module is the whole file: it opens at its first line, not at its first token below a comment header.
  @Test func requireOpensTheWholeFile() throws {
    let project = try Project([
      "doc.lua": "-- A header.\n-- More of it.\n\nlocal D = {}\nreturn D\n",
      "main.lua": "local doc = require(^^\"doc\")\n",
    ])
    #expect(project.exact("") == "doc.lua:1")
    let mark = project.marks[""]!
    let site = try #require(project.model.answer(path: mark.path, line: mark.line, character: mark.character).sites.first)
    #expect(site.fileUnit != nil)
    let at = try #require(project.model.location(of: site))
    #expect(at.path.hasSuffix("/doc.lua") && at.line == 0 && at.character == 0 && at.preview == "-- A header.")
    #expect(project.model.details(of: site)?.symbol.line == 0)
  }

  @Test func requireFindsTheModulesReturnedTable() throws {
    let project = try Project([
      ".luarc.json": #"{ "runtime.path": ["src/?.lua", "src/?/init.lua"] }"#,
      "src/shapes/init.lua": """
      local M = {}
      M.circle = require("shapes.circle")
      return M
      """,
      "src/shapes/circle.lua": """
      local Circle = {}
      --- The area of a circle.
      function Circle.area(r) return 3.14 * r * r end
      Circle.unit = { radius = 1 }
      return Circle
      """,
      "main.lua": """
      local shapes = require(^^"shapes")
      local circle = require "shapes.circle"
      print(circle.^^area(2), shapes.^^circle.^^area(1), circle.^^unit.^^radius)
      local missing = require("nowhere")
      print(missing.^^thing)
      """,
    ])
    // The required file.
    #expect(project.exact("") == "src/shapes/init.lua:1")
    #expect(project.exact("area") == "src/shapes/circle.lua:3")
    #expect(project.exact("circle") == "src/shapes/init.lua:2")
    #expect(project.exact("area2") == "src/shapes/circle.lua:3")
    #expect(project.exact("unit") == "src/shapes/circle.lua:4")
    #expect(project.exact("radius") == "src/shapes/circle.lua:4")
    // A module not on disk: its fields by name only.
    #expect(project.answer("thing").state != .exact)
    #expect(project.details("area")?.documentation == "The area of a circle.")
    #expect(project.references("area") == ["main.lua:3", "src/shapes/circle.lua:3"])
  }

  @Test func metatablesMakeClasses() throws {
    let project = try Project([
      "animal.lua": """
      local Animal = {}
      Animal.__index = Animal
      function Animal.new(name)
        local self = setmetatable({}, Animal)
        self.name = name
        return self
      end
      function Animal:speak() return ^^self.^^name end
      return Animal
      """,
      "dog.lua": """
      local Animal = require("animal")
      local Dog = setmetatable({}, { __index = Animal })
      Dog.__index = Dog
      function Dog.new(name)
        local o = Animal.new(name)
        return setmetatable(o, Dog)
      end
      function Dog:fetch() return self:^^speak() end
      return Dog
      """,
      "main.lua": """
      local Dog = require("dog")
      local rex = Dog.new("rex")
      rex:^^fetch()
      rex:^^speak()
      print(rex.^^name)
      local plain = {}
      setmetatable(plain, { __index = string })
      plain.^^len("x")
      """,
    ])
    #expect(project.exact("self") == "animal.lua:1")
    #expect(project.exact("name") == "animal.lua:5")
    #expect(project.exact("speak") == "animal.lua:8")
    #expect(project.exact("fetch") == "dog.lua:8")
    #expect(project.exact("speak2") == "animal.lua:8")
    #expect(project.exact("name2") == "animal.lua:5")
    #expect(project.exact("len") == "std:string.len")
    #expect(project.references("speak") == ["animal.lua:8", "dog.lua:8", "main.lua:4"])
  }

  @Test func annotationsGiveTypes() throws {
    let project = try Project([
      "types.lua": """
      ---@class Point
      ---@field x number
      ---@field y number
      local Point = {}
      Point.__index = Point
      function Point:length() return 0 end

      ---@class Shape
      ---@field kind string
      ---@field origin Point

      ---@param p Point
      ---@return Shape
      local function make(p)
        return p:^^length()
      end
      ---@type Shape
      local shape = get_shape()
      local o = shape.^^origin
      print(shape.origin:^^length(), make(nil).^^kind)
      """
    ])
    #expect(project.exact("length") == "types.lua:6")
    #expect(project.exact("length2") == "types.lua:6")
    // `---@field`s without a table to assign them: their types reach on, their own place is unknown.
    #expect(project.answer("origin").state == .unknown)
    #expect(project.answer("kind").state == .unknown)
    let members = project.complete("origin", typed: 0)
    #expect(members.context == .member && members.names.contains("kind") && members.names.contains("origin"))
  }

  @Test func labelsAndLexing() throws {
    let project = try Project([
      "main.lua": """
      local s = [==[
      local hidden = 1 ]] still in the string
      ]==]
      --[[ local comment = 2
      ]]
      --[==[ ]] local nope = 3 ]==]
      for i = 1, 3 do
        if i == 2 then goto ^^continue end
        print(#s // 2, s ~= nil, s .. "x", i)
        ::continue::
      end
      local t = { [ [[key]] ] = 1, plain = 2 }
      print(t.^^plain, hidden, comment, nope)
      """
    ])
    #expect(project.exact("continue") == "main.lua:10")
    #expect(project.exact("plain") == "main.lua:12")
    let names = project.model.project.units[0].tokens.indices.filter { project.model.project.units[0].tokens[$0].kind == .identifier }
      .map { project.model.project.units[0].string($0) }
    #expect(!names.contains("still") && names.filter { $0 == "hidden" }.count == 1)
  }

  @Test func completion() throws {
    let project = try Project([
      "lib.lua": """
      local M = {}
      function M.open(path, mode) end
      M.version = "1"
      return M
      """,
      "main.lua": """
      local lib = require("lib")
      local count = 1
      lib.^^
      -- a comment ^^here
      local ^^fresh
      print(^^co)
      local s = "x"
      s:^^
      unknown_value.^^
      """,
    ])
    let members = project.complete("")
    #expect(members.context == .member && members.state == .exact)
    #expect(Set(members.names) == ["open", "version"])
    #expect(project.complete("here").names.isEmpty)
    #expect(project.complete("fresh", typed: 2).names.isEmpty)
    let scope = project.complete("co", typed: 2)
    #expect(scope.names.first == "count")
    #expect(scope.names.contains("coroutine"))
    #expect(project.complete("2").names.contains("upper"))
    #expect(project.complete("3").state == .unknown)
  }

  @Test func editsKeepAnswersRight() throws {
    let project = try Project([
      "main.lua": """
      local value = 1
      print(^^value)
      """
    ])
    #expect(project.exact("value") == "main.lua:1")
    let path = project.root + "/main.lua"
    // A body edit: the shape holds, the tokens move.
    project.model.project.update(path: path, text: "-- moved\n\nlocal value = 1\nprint(value)\n")
    let found = project.model.answer(path: path, line: 3, character: 6)
    #expect(found.sites.compactMap { project.model.place(of: $0) }.map { "\($0.path):\($0.line)" } == ["main.lua:3"])
  }

  @Test func editsPutAFilesDeclarationsBackInOrder() throws {
    let project = try Project([
      "a.lua": """
      shared = 1
      ---@class Box
      Box = {}
      function Box.open() end
      """,
      "b.lua": """
      shared = 2
      ---@class Box
      Other = {}
      """,
      "c.lua": """
      print(^^shared, Box.^^open)
      ---@type Box
      local box = make()
      box.^^open()
      """,
    ])
    #expect(project.all("shared") == ["a.lua:1", "b.lua:1"])
    #expect(project.exact("open") == "a.lua:4")
    let path = project.root + "/a.lua"
    // a.lua's global and class go, and come back: b.lua's take their place meanwhile, then follow them again.
    project.model.project.update(path: path, text: "local shared = 1\n")
    #expect(project.all("shared") == ["b.lua:1"])
    #expect(project.answer("open2").state != .exact)
    project.model.project.update(path: path, text: "\nshared = 1\n---@class Box\nBox = {}\nfunction Box.open() end\n")
    #expect(project.all("shared") == ["a.lua:2", "b.lua:1"])
    #expect(project.exact("open") == "a.lua:5")
    #expect(project.exact("open2") == "a.lua:5")
  }
}
