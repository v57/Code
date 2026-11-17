import CodeCSharpModel
import CodeModel
import Foundation
import Testing

/// A C# project in a temporary folder, from file text with `@@` before the word a question is about. The .NET library
/// is the generated stub.
private final class Project {
  let root: String
  let model: CSharpModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String]) throws {
    let base = NSTemporaryDirectory() + "csharpmodel-" + UUID().uuidString
    root = base + "/project"
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "@@") {
          let character = rest.utf16.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].drop { $0 == "@" }.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
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
    model = CSharpModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the root, `net:<name>` in the stub.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
  }

  func exact(_ key: String) -> String? {
    let found = answer(key)
    return found.state == .exact ? found.places.first : nil
  }

  func references(_ key: String) -> [String] {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return model.references(of: found).map { "\($0.path):\($0.line)" }.sorted()
  }

  func complete(_ key: String, typed: Int = 0) -> (context: ModelCompletionContext, names: [String]) {
    let mark = marks[key]!
    let list = model.complete(path: mark.path, line: mark.line, character: mark.character + typed, limit: 300)
    return (list.context, list.items.map(\.name))
  }
}

private let csproj = """
  <Project Sdk="Microsoft.NET.Sdk">
    <PropertyGroup><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
  </Project>
  """

@Suite struct Names {
  @Test func localsParametersFieldsAndShadowing() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        public class A
        {
            int count;
            int F(int count)
            {
                var total = @@count + this.@@count;
                for (var i = 0; i < 3; i++) { total += @@i; }
                foreach (var item in new[] { 1, 2 }) { total += @@item; }
                var product = total * @@total;
                return product;
            }
        }
        """,
    ])
    #expect(p.exact("count") == "App/A.cs:5")
    #expect(p.exact("count2") == "App/A.cs:4")
    #expect(p.exact("i") == "App/A.cs:8")
    #expect(p.exact("item") == "App/A.cs:9")
    // `total * total` multiplies; it declares nothing.
    #expect(p.exact("total") == "App/A.cs:7")
  }

  @Test func namespacesUsingsAliasesAndImplicitUsings() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/Model/Shape.cs": """
        namespace Demo.Geometry
        {
            public class Shape { public static int Count; }
        }
        """,
      "App/Program.cs": """
        using Demo.@@Geometry;
        using static System.@@Math;
        using Table = System.Collections.Generic.Dictionary<string, int>;
        using Pairs = Dictionary<string, Demo.Geometry.Shape>;

        namespace Demo;

        class Program
        {
            static void Main()
            {
                var s = new @@Shape();
                var list = new @@List<int>();
                @@Table t = new();
                @@Pairs pairs = new();
                var root = @@Sqrt(2.0);
                @@Shape.@@Count = 1;
            }
        }
        """,
    ])
    #expect(p.exact("Geometry") == "namespace:Demo.Geometry:0")
    #expect(p.exact("Math") == "net:System.Math:1")
    #expect(p.exact("Shape") == "App/Model/Shape.cs:3")
    #expect(p.exact("List") == "net:System.Collections.Generic.List`1:1")
    #expect(p.exact("Table") == "net:System.Collections.Generic.Dictionary`2:1")
    // A non-global alias's target sees the global (implicit) usings.
    #expect(p.exact("Pairs") == "net:System.Collections.Generic.Dictionary`2:1")
    #expect(p.answer("Sqrt").places.first == "net:System.Math.Sqrt(1):1")
    #expect(p.exact("Count") == "App/Model/Shape.cs:3")
  }

  @Test func partialTypesAndRecords() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        public partial class Shape { public int Sides; }
        public record Point(int X, int Y);
        """,
      "App/B.cs": """
        namespace Demo;
        public partial class Shape
        {
            public int Twice() => @@Sides * 2;
            public Point Origin() => new(0, 0);
        }
        class Use
        {
            void F(@@Shape s, Point p) { var x = p.@@X; var o = s.Origin().@@Y; }
        }
        """,
    ])
    #expect(p.exact("Sides") == "App/A.cs:2")
    // Every part of a partial type.
    #expect(Set(p.answer("Shape").places) == ["App/A.cs:2", "App/B.cs:2"])
    #expect(p.exact("X") == "App/A.cs:3")
    #expect(p.exact("Y") == "App/A.cs:3")
  }

  @Test func tupleElementsAnonymousMembersAndDiscards() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        class A
        {
            (int @@Count, string Name) pair;
            void F(Func<int, int> f)
            {
                var anon = new { @@a = 1 };
                F(@@_ => 1);
            }
        }
        """,
    ])
    #expect(p.exact("Count") == "App/A.cs:4")
    #expect(p.exact("a") == "App/A.cs:7")
    // A lambda's `_` is a parameter declared there.
    #expect(p.exact("_") == "App/A.cs:8")
  }

  @Test func conditionalRegionsFollowTheProjectsSymbols() throws {
    let p = try Project([
      "App/App.csproj": """
        <Project Sdk="Microsoft.NET.Sdk">
          <PropertyGroup><TargetFramework>net10.0</TargetFramework><DefineConstants>$(DefineConstants);FAST</DefineConstants></PropertyGroup>
        </Project>
        """,
      "App/A.cs": """
        namespace Demo;
        class A
        {
        #if FAST
            static int Speed() => 1;
        #else
            static int Speed() => 2;
        #endif
        #if !NET10_0_OR_GREATER
            static int Old() => 3;
        #endif
            int F() => @@Speed();
        }
        """,
    ])
    #expect(p.exact("Speed") == "App/A.cs:5")
  }

  @Test func topLevelStatements() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/Program.cs": """
        var greeting = "hi";
        Console.@@WriteLine(@@greeting.@@Length);
        @@Helper();
        static void Helper() { }
        """,
    ])
    #expect(p.exact("greeting") == "App/Program.cs:1")
    #expect(p.exact("Length") == "net:System.String.Length:1")
    #expect(p.exact("Helper") == "App/Program.cs:4")
    #expect(p.answer("WriteLine").places.allSatisfy { $0.hasPrefix("net:System.Console.WriteLine(1)") })
  }
}

@Suite struct Calls {
  @Test func overloadsOptionalNamedAndParams() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        class A
        {
            static int F(int a) => a;
            static int F(string s, int scale = 1) => scale;
            static int G(params int[] values) => values.Length;
            void Use()
            {
                @@F(3);
                @@F("x");
                F("x", @@scale: 2);
                @@G(1, 2, 3);
            }
        }
        """,
    ])
    #expect(p.exact("F") == "App/A.cs:4")
    #expect(p.exact("F2") == "App/A.cs:5")
    #expect(p.exact("scale") == "App/A.cs:5")
    #expect(p.exact("G") == "App/A.cs:6")
  }

  @Test func extensionMethodsGenericsAndLinq() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        public class Item { public string Name { get; set; } = ""; public int Size; }
        public static class Ext
        {
            public static int Twice(this Item item) => item.Size * 2;
            public static T First2<T>(this IEnumerable<T> items) where T : class => items.First();
        }
        class Use
        {
            void F(List<Item> items)
            {
                var n = items[0].@@Twice();
                var names = items.@@Where(x => x.@@Size > 0).@@Select(x => x.Name).ToList();
                var first = items.@@First2().@@Name;
                var count = names.@@Count;
            }
        }
        """,
    ])
    #expect(p.exact("Twice") == "App/A.cs:5")
    #expect(p.exact("Where").map { $0.hasPrefix("net:System.Linq.Enumerable.Where(2)") } == true)
    #expect(p.exact("Size") == "App/A.cs:2")
    #expect(p.exact("Select").map { $0.hasPrefix("net:System.Linq.Enumerable.Select(2)") } == true)
    #expect(p.exact("First2") == "App/A.cs:6")
    #expect(p.exact("Name") == "App/A.cs:2")
    #expect(p.exact("Count") == "net:System.Collections.Generic.List`1.Count:1")
  }

  @Test func conversionsChooseTheOverload() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        class A
        {
            byte[] buffer = new byte[4];
            void F(byte[] payload, string text)
            {
                buffer.AsSpan(0, 2).@@CopyTo(payload);
                var span = text.AsSpan();
                span.@@IndexOf('x');
            }
        }
        """,
    ])
    // `byte[]` takes `AsSpan<T>(this T[])`, a `Span<byte>`; `string` the `ReadOnlySpan<char>` one.
    #expect(p.exact("CopyTo") == "net:System.Span`1.CopyTo(1):1")
    #expect(p.answer("IndexOf").places.first.map { $0.contains("MemoryExtensions.IndexOf") || $0.contains("ReadOnlySpan") } == true)
  }

  @Test func patternsNarrowAndNullableOperators() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        class Animal { }
        class Dog : Animal { public void Bark() { } public string? Owner; }
        class A
        {
            void F(Animal a, Dog? maybe)
            {
                if (a is Dog d) d.@@Bark();
                var length = maybe?.@@Owner?.@@Length ?? 0;
                switch (a) { case Dog x: x.@@Bark(); break; }
            }
        }
        """,
    ])
    #expect(p.exact("Bark") == "App/A.cs:3")
    #expect(p.exact("Owner") == "App/A.cs:3")
    #expect(p.exact("Length") == "net:System.String.Length:1")
    #expect(p.exact("Bark2") == "App/A.cs:3")
  }

  @Test func unknownBeatsAWrongAnswer() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        class A
        {
            void F(object o, dynamic d)
            {
                d.@@Anything();
                var x = Missing.@@Thing;
            }
        }
        """,
    ])
    #expect(p.answer("Anything").state != .exact)
    #expect(p.answer("Thing").state != .exact)
  }
}

@Suite struct Projects {
  @Test func projectReferencesAndInternalTypes() throws {
    let p = try Project([
      "Lib/Lib.csproj": csproj,
      "Lib/Api.cs": """
        namespace Lib;
        public class Api { public int Call() => 1; }
        internal class Hidden { }
        """,
      "App/App.csproj": """
        <Project Sdk="Microsoft.NET.Sdk">
          <PropertyGroup><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings></PropertyGroup>
          <ItemGroup><ProjectReference Include="../Lib/Lib.csproj" /></ItemGroup>
        </Project>
        """,
      "App/Program.cs": """
        using Lib;
        var api = new @@Api();
        api.@@Call();
        @@Hidden h = null!;
        """,
      "Other/Other.csproj": csproj,
      "Other/O.cs": """
        using Lib;
        class O { @@Api2 a; }
        """,
      "All.sln": "",
    ])
    #expect(p.exact("Api") == "Lib/Api.cs:2")
    #expect(p.exact("Call") == "Lib/Api.cs:2")
    // Another project's internal type isn't seen; a project that doesn't reference Lib doesn't see it.
    #expect(p.exact("Hidden") == nil)
    #expect(p.exact("Api2") == nil)
  }

  @Test func manifestsMatchByPattern() {
    let language = ModelLanguage.cSharp
    #expect(language.isManifest("/a/b/App.csproj"))
    #expect(language.isManifest("/a/All.sln"))
    #expect(language.isManifest("/a/Directory.Build.props"))
    #expect(!language.isManifest("/a/App.cs"))
    #expect(language.handles("/a/App.cs"))
  }
}

@Suite struct References {
  @Test func referencesFindEveryUse() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        class A
        {
            int @@value;
            void F() { value = 1; G(value); }
            void G(int x) { }
        }
        """,
    ])
    #expect(p.references("value") == ["App/A.cs:4", "App/A.cs:5"])
  }
}

@Suite struct Completion {
  @Test func membersExtensionsAndScope() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        public class Item { public string Name { get; set; } = ""; public int Size; public static Item Empty = new(); }
        class A
        {
            void F(Item item, List<int> numbers)
            {
                item.@@x;
                numbers.@@y;
                Item.@@z;
                var total = 0;
                @@t;
            }
        }
        """,
    ])
    let members = p.complete("x")
    #expect(members.context == .member)
    #expect(members.names.contains("Name") && members.names.contains("Size"))
    #expect(!members.names.contains("Empty"))
    let list = p.complete("y")
    #expect(list.names.contains("Add") && list.names.contains("Where"))
    let statics = p.complete("z")
    #expect(statics.names.contains("Empty") && !statics.names.contains("Name"))
    let scope = p.complete("t", typed: 1)
    #expect(scope.names.contains("total"))
  }
}

@Suite struct Details {
  @Test func declarationAndDocumentation() throws {
    let p = try Project([
      "App/App.csproj": csproj,
      "App/A.cs": """
        namespace Demo;
        class A
        {
            /// <summary>Adds two numbers.</summary>
            public static int Add(int a, int b) => a + b;
            int F() => @@Add(1, 2);
        }
        """,
    ])
    let mark = p.marks["Add"]!
    let found = p.model.answer(path: mark.path, line: mark.line, character: mark.character)
    let details = p.model.details(of: found.sites[0])
    #expect(details?.declaration == "public static int Add(int a, int b)")
    #expect(details?.documentation == "Adds two numbers.")
    #expect(details?.parents.map(\.name) == ["A", "Demo"])
  }
}
