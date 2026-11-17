import CodeHighlighting
import Foundation
import Testing

@testable import CodeScan

private func tokens(_ text: String, _ language: String) -> [(String, TokenKind)] {
  let source = SourceFile(text, profile: LexProfile.profile(forLanguage: language)!)
  return source.tokens.map { (source.string($0), $0.kind) }
}

/// Name, kind and parent's name of every declaration that isn't a local.
private func declarations(_ text: String, _ language: String) -> [(String, SymbolKind, String?)] {
  let symbols = SourceFile(text, profile: LexProfile.profile(forLanguage: language)!).symbols
  return symbols.symbols.filter { !$0.isLocal }.map { symbol in
    (symbols.name(symbol), symbol.kind, symbol.parent >= 0 ? symbols.name(symbols.symbols[Int(symbol.parent)]) : nil)
  }
}

@Suite struct ZigTests {
  @Test func languageFromItsFiles() {
    for name in ["main.zig", "build.zig.zon"] {
      #expect(Language.detect(url: URL(fileURLWithPath: "/p/" + name))?.name == "Zig", "\(name)")
    }
    #expect(LexProfile.profile(forLanguage: "zig")?.spec.name == "Zig")
  }

  @Test func lineStringsBuiltinsAndCharacters() {
    let text = """
      const s =
          \\\\a "b" // c
          \\\\d
      ;
      const q = @"x y";
      const c = '\\'';
      const n = @intCast(0x1F + 1_000);
      /// Docs.
      // Plain.
      """
    let found = tokens(text, "zig")
    // A `\\` line is a string to its line's end, without the line break, whatever it holds.
    #expect(found.contains { $0 == (#"\\a "b" // c"#, .string) } && found.contains { $0 == (#"\\d"#, .string) })
    #expect(found.contains { $0 == (";", .punctuation) } && !found.contains { $0.0 == "// c" })
    #expect(found.contains { $0 == ("\"x y\"", .string) } && found.contains { $0 == ("'\\''", .string) })
    #expect(found.contains { $0 == ("@intCast", .attribute) } && found.contains { $0 == ("0x1F", .number) } && found.contains { $0 == ("1_000", .number) })
    #expect(found.contains { $0 == ("/// Docs.", .docComment) } && found.contains { $0 == ("// Plain.", .comment) })
  }

  @Test func typesFunctionsAndFields() {
    let text = """
      const std = @import("std");
      pub const Point = extern struct {
          x: i32 = 0,
          y: i32,
          pub fn init(x: i32, y: i32) Point {
              const local = x;
              return .{ .x = local, .y = y };
          }
          const Inner = union(enum) { a: u8, b: void };
      };
      const Color = enum { red, green };
      const Failure = error{ Bad, Worse };
      fn fail() Failure!void {
          return error.Bad;
      }
      var counter: usize = 0;
      """
    let found = declarations(text, "zig")
    #expect(found.contains { $0.0 == "std" && $0.1 == .constant })
    #expect(found.contains { $0.0 == "Point" && $0.1 == .struct })
    #expect(found.contains { $0.0 == "x" && $0.1 == .property && $0.2 == "Point" })
    #expect(found.contains { $0.0 == "init" && $0.1 == .method && $0.2 == "Point" })
    #expect(found.contains { $0.0 == "Inner" && $0.1 == .struct && $0.2 == "Point" })
    #expect(found.contains { $0.0 == "Color" && $0.1 == .enum } && found.contains { $0.0 == "Failure" && $0.1 == .enum })
    #expect(found.contains { $0.0 == "fail" && $0.1 == .function && $0.2 == nil })
    #expect(found.contains { $0.0 == "counter" && $0.1 == .variable })
    #expect(!found.contains { $0.0 == "local" })
    // `error.Bad` is a value, not a set.
    let value = declarations("const e = error.Bad;\n", "zig")
    #expect(value.count == 1 && value[0].1 == .constant)
  }
}

@Suite struct ElixirTests {
  @Test func languageFromItsFiles() {
    for name in ["lib/a.ex", "test/a_test.exs", "mix.lock"] {
      #expect(Language.detect(url: URL(fileURLWithPath: "/p/" + name))?.name == "Elixir", "\(name)")
    }
    #expect(Language.detect(shebang: "#!/usr/bin/env elixir")?.name == "Elixir")
    #expect(LexProfile.profile(forLanguage: "elixir")?.spec.name == "Elixir")
  }

  @Test func sigilsAtomsCharactersAndHeredocs() {
    let text = #"""
      re = ~r/a#b(c)\/d/iu
      w = ~w(a b)a ++ ~S|x\|y| ++ ~HTML"<p>" ++ ~s{#{f("}")} z}
      h = ~S"""
      not """ the end
      """
      a = [:ok, :empty?, :"a b#{c}", :'d', key: 1, do: 2] ++ ?" ++ ?# ++ ?\n ++ ?é
      t = x :: y
      d = """
      x = """ inside
        """ <> "s#{1 + "}"}" <> 'c#{2}'
      def empty?(list), do: list == []
      """#
    let found = tokens(text, "elixir")
    for sigil in [#"~r/a#b(c)\/d/iu"#, "~w(a b)a", #"~S|x\|y|"#, #"~HTML"<p>""#, #"~s{#{f("}")} z}"#, "~S\"\"\"\nnot \"\"\" the end\n\"\"\""] {
      #expect(found.contains { $0 == (sigil, .string) }, "\(sigil)")
    }
    for atom in [":ok", ":empty?", #":"a b#{c}""#, ":'d'"] { #expect(found.contains { $0 == (atom, .string) }, "\(atom)") }
    // `key:` and `do:` are a name and a colon; `do:` isn't the `do` of a block.
    #expect(found.contains { $0 == ("key", .identifier) } && found.contains { $0 == ("do", .identifier) })
    #expect(found.contains { $0 == ("::", .punctuation) })
    // No setter atoms: `:ok=f()` is a match.
    #expect(tokens(":ok=f()", "elixir").prefix(2).map(\.0) == [":ok", "="])
    // A name's `?` is its own before `=` too: `?=` isn't a character there.
    #expect(tokens("done?=x", "elixir").map(\.0) == ["done?", "=", "x"])
    for character in ["?\"", "?#", "?\\n", "?é"] { #expect(found.contains { $0 == (character, .string) }, "\(character)") }
    #expect(!found.contains { $0.1 == .comment })
    // A heredoc ends at a line that starts with its quotes, and every string interpolates.
    #expect(found.contains { $0 == ("\"\"\"\nx = \"\"\" inside\n  \"\"\"", .string) })
    // A quoted atom and a sigil are one token with their `#{…}`; the two strings' interpolations are code.
    #expect(found.filter { $0.1 == .interpolationOpen }.count == 2)
    #expect(found.contains { $0 == ("empty?", .identifier) } && found.contains { $0 == ("==", .punctuation) })
  }

  @Test func modulesFunctionsTypesAndFields() {
    let text = """
      defmodule MyApp.User do
        @moduledoc "A user."
        defstruct [:name, age: 0, tags: []]
        @type t :: %__MODULE__{name: String.t()}
        @callback load(term) :: t

        def valid?(%__MODULE__{age: age}) when age > 0, do: true
        defp helper(x) do
          y = x + 1
          y
        end
        defmacro m(a), do: a
      end

      defprotocol Size do
        def size(data)
      end

      defimpl Size, for: MyApp.User do
        def size(_), do: 1
      end
      """
    let found = declarations(text, "elixir")
    #expect(found.contains { $0.0 == "User" && $0.1 == .module })
    for field in ["name", "age", "tags"] { #expect(found.contains { $0.0 == field && $0.1 == .field && $0.2 == "User" }, "\(field)") }
    #expect(found.contains { $0.0 == "t" && $0.1 == .typeAlias } && found.contains { $0.0 == "load" })
    for function in ["valid?", "helper", "m"] { #expect(found.contains { $0.0 == function && $0.1 == .method && $0.2 == "User" }, "\(function)") }
    #expect(found.contains { $0.0 == "Size" && $0.1 == .interface } && found.contains { $0.0 == "Size" && $0.1 == .extension })
    #expect(!found.contains { $0.0 == "y" })
    #expect(SourceFile(text, profile: LexProfile.profile(forLanguage: "elixir")!).symbols.problems.isEmpty)
  }
}
