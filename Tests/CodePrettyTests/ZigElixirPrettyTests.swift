import CodeHighlighting
import CodeScan
import Foundation
import Testing

@testable import CodePretty

/// Formats with the options a file of the language gets: Zig's are zig fmt's four spaces.
private func pretty(_ text: String, _ language: String) -> String {
  let source = SourceFile(text, profile: LexProfile.profile(forLanguage: language)!)
  let output = Pretty.format(source, options: PrettyOptions.resolve(path: nil, source: source))
  return String(decoding: output.text, as: UTF8.self)
}

@Suite struct ZigElixirPrettyTests {
  /// Zig is laid out in full, as zig fmt would: four spaces, `x: T`, `.{ .a = 1 }`, `if (`, `=>` spaced.
  @Test func zigIsLaidOutLikeZigFmt() {
    let text = """
      const Point = struct {
        x: i32=0,
        pub fn init(x:i32) Point {
           return Point{ .x=x };
        }
      };
      fn f(v: u8) void {
          if(v==0) return;
          switch (v) { 1=>{}, else => {} }
          const s =
          \\\\a // b
          ;
      }

      """
    #expect(
      pretty(text, "zig") == """
        const Point = struct {
            x: i32 = 0,
            pub fn init(x: i32) Point {
                return Point{ .x = x };
            }
        };
        fn f(v: u8) void {
            if (v == 0) return;
            switch (v) { 1 => {}, else => {} }
            const s =
                \\\\a // b
            ;
        }

        """)
    // A literal's type and its braces stay together, and a body's brace keeps its space.
    for line in [
      "const a = [_]u8{ 1, 2 };\n", "const p: Point = .{};\n", "const e = error{ A, B };\n", "fn g() !void {}\n",
      "f(.{x}, .{&y}, error{A});\n",
    ] {
      #expect(pretty(line, "zig") == line, "\(line)")
    }
    // A one-element list keeps its braces as written; more elements or a field are spaced.
    #expect(pretty("f(.{ x }, .{a, b}, .{.x = 1});\n", "zig") == "f(.{ x }, .{ a, b }, .{ .x = 1 });\n")
    // A switch's prongs are its content, `else` and `error.A` ones too: no `case` level, no continuation.
    let prongs = """
      const t = read() catch |err| switch (err) {
          error.FileNotFound => 0,
          else => return err,
      };

      """
    #expect(pretty(prongs, "zig") == prongs)
    // A list's columns and the comma after a `\\` string's lines stay where zig fmt puts them.
    let columns = """
      fn g() void {
          print(
              \\\\a
          , .{
              a,   bb, ccc,
              aaa, b,  c,
          });
      }

      """
    #expect(pretty(columns, "zig") == columns)
    // `++` is a concatenation, and `or`, `and`, `orelse` are operators: a line after one goes on.
    #expect(
      pretty("const s =\n\"a\" ++\n\"b\";\nconst t = x orelse\nreturn;\nconst u = a or\nb;\n", "zig")
        == "const s =\n    \"a\" ++\n    \"b\";\nconst t = x orelse\n    return;\nconst u = a or\n    b;\n")
    // A blank line just inside a `{` goes, unless a comment follows it.
    #expect(pretty("fn h() void {\n\n    a();\n}\n", "zig") == "fn h() void {\n    a();\n}\n")
    #expect(pretty("fn h() void {\n\n    // a\n    a();\n}\n", "zig") == "fn h() void {\n\n    // a\n    a();\n}\n")
  }

  /// Elixir only gets spaces within its lines, and keeps every space that is meaning.
  @Test func elixirKeepsSpacesThatMeanSomething() {
    #expect(pretty("def f( a ,b ) do\n  {:ok,a}\nend\n", "elixir") == "def f(a, b) do\n  {:ok, a}\nend\n")
    for text in [
      "foo -1\n", "foo (1)\n", "bar [1]\n", "x = %Point{a: 1}\n", "if(a, do: b)\n", "~w(a  b)a\n", "s = \"a  #{ b }\"\n",
      "x = ?a == ?b\n", "@doc \"\"\"\n  x = \"\"\"  y\n\"\"\"\n", "a |> b\n", "def f(a \\\\ 1), do: a\n",
    ] {
      #expect(pretty(text, "elixir") == text, "\(text)")
    }
  }
}
