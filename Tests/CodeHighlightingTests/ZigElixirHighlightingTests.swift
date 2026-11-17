import Foundation
import Testing

@testable import CodeHighlighting

/// The kind of the innermost token covering `word`'s first character (its `occurrence`th one, from 0).
private func kind(of word: String, in code: String, _ language: String, occurrence: Int = 0) -> SyntaxKind? {
  let text = code as NSString
  var range = text.range(of: word)
  for _ in 0..<occurrence { range = text.range(of: word, range: NSRange(location: NSMaxRange(range), length: text.length - NSMaxRange(range))) }
  return CodeHighlighter.tokens(in: code, language: language).last { NSLocationInRange(range.location, $0.range) }?.kind
}

@Suite struct ZigElixirHighlightingTests {
  @Test func zig() {
    let code = """
      const std = @import("std");
      pub const Point = extern struct { x: i32 };
      fn area(p: Point) u32 {
          const s =
              \\\\raw // text
          ;
          return 'a';
      }
      """
    #expect(kind(of: "const", in: code, "zig") == .keyword && kind(of: "@import", in: code, "zig") == .attribute)
    #expect(kind(of: "Point", in: code, "zig") == .typeDeclaration && kind(of: "area", in: code, "zig") == .memberDeclaration)
    #expect(kind(of: "Point", in: code, "zig", occurrence: 1) == .otherType)
    #expect(kind(of: "raw", in: code, "zig") == .string && kind(of: "text", in: code, "zig") == .string)
    #expect(kind(of: ";", in: code, "zig", occurrence: 2) != .string)
    #expect(kind(of: "'a'", in: code, "zig") == .string)
  }

  @Test func elixir() {
    let code = """
      defmodule Shop.Cart do
        @moduledoc "Cart."
        def empty?(items), do: items == []
        def tag(x), do: {:ok, ~r/a#b/i, ?#, :"a b", x}
      end
      """
    #expect(kind(of: "defmodule", in: code, "elixir") == .keyword && kind(of: "Shop", in: code, "elixir") == .typeDeclaration)
    #expect(kind(of: "@moduledoc", in: code, "elixir") == .attribute)
    #expect(kind(of: "empty?", in: code, "elixir") == .memberDeclaration)
    #expect(kind(of: "(items)", in: code, "elixir") != .string)
    #expect(kind(of: "do:", in: code, "elixir") == .string && kind(of: ":ok", in: code, "elixir") == .string)
    #expect(kind(of: "~r/a#b/i", in: code, "elixir") == .string && kind(of: "b/i", in: code, "elixir") == .string)
    #expect(kind(of: "?#", in: code, "elixir") == .string && kind(of: ":\"a b\"", in: code, "elixir") == .string)
    #expect(kind(of: "end", in: code, "elixir") == .keyword)
  }
}
