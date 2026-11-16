import CodeTypeScriptModel
import Foundation
import Testing

/// A TypeScript project in a temporary folder, from file text with `@@` before the word a question is about.
private final class Project {
  let root: String
  let model: TSModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  /// A small stand-in for TypeScript's lib files, so no test needs TypeScript installed.
  static let lib = """
    interface Object { toString(): string }
    interface Function { call(thisArg: any, ...args: any[]): any }
    interface String { readonly length: number; split(separator: string): string[] }
    interface Number { toFixed(digits?: number): string }
    interface Boolean {}
    interface RegExp {}
    interface IArguments {}
    interface Array<T> {
      readonly length: number
      map<U>(callbackfn: (value: T, index: number) => U): U[]
      filter<S extends T>(predicate: (value: T) => value is S): S[]
      filter(predicate: (value: T) => unknown): T[]
    }
    interface Promise<T> { then<R>(onfulfilled: (value: T) => R): Promise<R> }
    """

  init(_ files: [String: String]) throws {
    root = NSTemporaryDirectory() + "tsmodel-" + UUID().uuidString + "/project"
    var files = files
    files["node_modules/typescript/lib/lib.es5.d.ts"] = Self.lib
    if files["tsconfig.json"] == nil { files["tsconfig.json"] = #"{ "compilerOptions": { "lib": ["es5"] } }"# }
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "@@") {
          let character = rest.utf16.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })
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
    model = TSModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the project.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
  }

  func complete(_ key: String) -> [String] {
    let mark = marks[key]!
    return model.complete(path: mark.path, line: mark.line, character: mark.character, limit: 200).items.map(\.name)
  }
}

@Suite struct Definitions {
  @Test func importsAndMembers() throws {
    let p = try Project([
      "a.ts": """
        export class Box<T> {
          value: T
          constructor(value: T) { this.value = value }
          get(): T { return this.value }
        }
        export interface Item { name: string; count: number }
        """,
      "b.ts": """
        import { Box, type Item as Thing } from "./a"

        const box = new @@Box<Thing>({ name: "x", count: 1 })
        box.@@get().@@name
        const items: Thing[] = []
        items.map(i => i.@@count)
        """,
    ])
    #expect(p.answer("Box").places == ["a.ts:1"])
    #expect(p.answer("get").places == ["a.ts:4"])
    #expect(p.answer("name").places == ["a.ts:6"])
    #expect(p.answer("count").places == ["a.ts:6"])
  }

  @Test func defaultAndCommonJS() throws {
    let p = try Project([
      "lib.js": """
        function helper() { return 1 }
        module.exports.helper = helper
        module.exports.@@other = () => 2
        """,
      "store.ts": """
        export default class Store { load(): void {} }
        """,
      "main.js": """
        const { helper } = require("./lib")
        const lib = require("./lib")
        @@helper()
        lib.@@other()
        """,
      "main.ts": """
        import Store from "./store"
        new Store().@@load()
        """,
    ])
    #expect(p.answer("helper").places == ["lib.js:2"])
    #expect(p.answer("other").places == ["lib.js:3"])
    #expect(p.answer("other2").places == ["lib.js:3"])
    #expect(p.answer("load").places == ["store.ts:1"])
  }

  @Test func tsconfigPathsAndNamespaces() throws {
    let p = try Project([
      "tsconfig.json": """
        { "compilerOptions": { "lib": ["es5"], "baseUrl": ".", "paths": { "@app/*": ["src/*"] } } }
        """,
      "src/geometry.ts": """
        export namespace Shapes {
          export interface Point { x: number }
        }
        export namespace Shapes {
          export function origin(): Point { return { @@x: 0 } }
        }
        """,
      "src/use.ts": """
        import { Shapes } from "@app/geometry"
        const p: Shapes.@@Point = Shapes.@@origin()
        p.@@x
        """,
    ])
    #expect(p.answer("Point").places == ["src/geometry.ts:2"])
    #expect(p.answer("origin").places == ["src/geometry.ts:5"])
    #expect(p.answer("x").places == ["src/geometry.ts:2"])
    #expect(p.answer("x2").places == ["src/geometry.ts:2"])
  }

  @Test func contextualKeysAndOverloads() throws {
    let p = try Project([
      "a.ts": """
        interface Options { verbose: boolean; depth?: number }
        function run(options: Options): void {}
        run({ @@verbose: true })
        const saved: Options = { @@depth: 2 }
        function pick(value: string): string
        function pick(value: number, extra: number): number
        function pick(value: any, extra?: any): any { return value }
        @@pick(1, 2)
        class Counter {
          #count = 0
          bump() { this.#@@count += 1 }
        }
        """,
    ])
    #expect(p.answer("verbose").places == ["a.ts:1"])
    #expect(p.answer("depth").places == ["a.ts:1"])
    #expect(p.answer("pick") == (.exact, ["a.ts:6"]))
    #expect(p.answer("count").places == ["a.ts:10"])
  }

  @Test func javaScriptGlobals() throws {
    let p = try Project([
      "setup.js": """
        globalThis.db = (name) => ({ name })
        """,
      "use.js": """
        @@db("users")
        """,
    ])
    #expect(p.answer("db").places == ["setup.js:1"])
  }

  @Test func unknownStaysUnsure() throws {
    let p = try Project([
      "a.ts": """
        export class A { size(): number { return 1 } }
        export class B { size(): number { return 2 } }
        """,
      "b.ts": """
        declare const thing: any
        thing.@@size()
        """,
    ])
    let found = p.answer("size")
    #expect(found.state != .exact)
  }

  @Test func references() throws {
    let p = try Project([
      "a.ts": """
        export function @@greet(name: string) { return name }
        """,
      "b.ts": """
        import { greet as hello } from "./a"
        hello("x")
        """,
    ])
    let mark = p.marks["greet"]!
    let answer = p.model.answer(path: mark.path, line: mark.line, character: mark.character)
    let lines = p.model.references(of: answer).map { URL(fileURLWithPath: $0.path).lastPathComponent + ":" + String($0.line) }
    #expect(Set(lines) == ["a.ts:1", "b.ts:1", "b.ts:2"])
  }
}

@Suite struct Completion {
  @Test func membersAndScope() throws {
    let p = try Project([
      "a.ts": """
        export interface User { name: string; email: string; save(): void }
        """,
      "b.ts": """
        import type { User } from "./a"
        function show(user: User, limit: number) {
          li@@
          user.@@
        }
        """,
    ])
    #expect(p.complete("").contains("limit"))
    #expect(Set(p.complete("2")).isSuperset(of: ["name", "email", "save"]))
  }
}
