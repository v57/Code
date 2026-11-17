import CodeDartModel
import CodeModel
import Foundation
import Testing

/// A Dart project in a temporary folder, from file text with `@@` before the word a question is about. `dart:`
/// libraries are Code's stub.
private final class Project {
  let root: String
  let model: DartModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String]) throws {
    let base = NSTemporaryDirectory() + "dartmodel-" + UUID().uuidString
    root = base + "/project"
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "@@") {
          let character = rest.utf16.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].drop { $0 == "@" || $0 == "$" }.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
          var key = word
          var n = 2
          while marks[key] != nil {
            key = word + String(n)
            n += 1
          }
          marks[key] = (name.hasPrefix("../") ? base + "/" + name.dropFirst(3) : root + "/" + name, number, character)
          rest.removeSubrange(mark)
        }
        body += rest + "\n"
      }
      let path = name.hasPrefix("../") ? base + "/" + name.dropFirst(3) : root + "/" + name
      let url = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try body.replacingOccurrences(of: "$BASE", with: base).write(to: url, atomically: true, encoding: .utf8)
    }
    model = DartModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the root, `dart:<library>/<name>:1` in the
  /// stub, `package:<name>/<path>:line` in a package outside the root.
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

  func details(_ key: String) -> SymbolDetails? {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    guard let site = found.sites.first else { return nil }
    return model.details(of: site)
  }
}

private let pubspec = "name: demo\nenvironment:\n  sdk: ^3.5.0\n"

@Suite struct Names {
  @Test func localsParametersFieldsAndShadowing() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        class A {
          int count = 0;
          int f(int count) {
            var total = @@count + this.@@count;
            for (var i = 0; i < 3; i++) { total += @@i; }
            for (final item in [1, 2]) { total += @@item; }
            return total * @@total;
          }
        }
        """,
    ])
    #expect(p.exact("count") == "lib/a.dart:3")
    #expect(p.exact("count2") == "lib/a.dart:2")
    #expect(p.exact("i") == "lib/a.dart:5")
    #expect(p.exact("item") == "lib/a.dart:6")
    #expect(p.exact("total") == "lib/a.dart:4")
  }

  @Test func constructorsFieldFormalsAndNamedArguments() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        class Point {
          final int x;
          final int y;
          Point(this.@@x, {required this.y});
          Point.origin() : this(0, y: 0);
          factory Point.parse(String s) => Point(int.parse(s), y: 0);
        }
        void f() {
          final a = @@Point(1, @@y: 2);
          final b = Point.@@origin();
          final c = @@Point.parse('1');
          a.@@x + b.y + c.x;
        }
        """,
    ])
    #expect(p.exact("x") == "lib/a.dart:2")
    #expect(p.exact("Point") == "lib/a.dart:4")
    #expect(p.exact("y") == "lib/a.dart:4")
    #expect(p.exact("origin") == "lib/a.dart:5")
    #expect(p.exact("Point2") == "lib/a.dart:1")
    #expect(p.exact("x2") == "lib/a.dart:2")
  }

  @Test func inheritanceMixinsGettersAndSetters() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        abstract class Shape { double area(); }
        mixin Named { String get name => 'shape'; }
        class Square extends Shape with Named {
          double side = 1;
          set size(double value) => side = value;
          double get size => side;
          @override
          double area() => side * side;
        }
        void f(Shape s, Square q) {
          s.@@area();
          q.@@name;
          q.@@size = 2;
          print(q.@@size);
        }
        """,
    ])
    #expect(p.exact("area") == "lib/a.dart:1")
    #expect(p.exact("name") == "lib/a.dart:2")
    #expect(p.exact("size") == "lib/a.dart:5")
    #expect(p.exact("size2") == "lib/a.dart:6")
  }

  @Test func extensionsAndExtensionTypes() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        extension Twice on String {
          String get twice => this + this;
        }
        extension Firsts<T> on List<T> {
          T get head => first;
        }
        extension type Meters(int value) {
          Meters operator +(Meters other) => Meters(value + other.value);
        }
        class Box { final String label = ''; }
        void f(List<Box> boxes) {
          'a'.@@twice;
          boxes.@@head.@@label;
          final m = Meters(1);
          m.@@value;
        }
        """,
    ])
    #expect(p.exact("twice") == "lib/a.dart:2")
    #expect(p.exact("head") == "lib/a.dart:5")
    #expect(p.exact("label") == "lib/a.dart:10")
    #expect(p.exact("value") == "lib/a.dart:7")
  }

  @Test func enumsWithMembers() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        enum Color {
          red(0xff0000),
          green(0x00ff00);
          const Color(this.hex);
          final int hex;
          bool get isRed => this == Color.red;
        }
        void f() {
          Color.@@red.@@hex;
          Color.green.@@isRed;
          Color.@@values.length;
          Color.red.@@name;
        }
        """,
    ])
    #expect(p.exact("red") == "lib/a.dart:2")
    #expect(p.exact("hex") == "lib/a.dart:5")
    #expect(p.exact("isRed") == "lib/a.dart:6")
    // `values` is the language's, `name` dart:core's `EnumName`.
    #expect(p.exact("name") == "dart:core/EnumName.name:1")
  }

  @Test func wildcardsAndFunctionTypeParameters() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        typedef Handler = void Function(String @@topic);
        void f(Handler h) {
          try { h('a'); } catch (@@_) {}
          final g = (Map<String, Object?> @@body) => @@body;
        }
        """,
    ])
    #expect(p.exact("topic") == "lib/a.dart:1")
    #expect(p.answer("_").state == .unknown)
    #expect(p.exact("body") == "lib/a.dart:4")
    #expect(p.exact("body2") == "lib/a.dart:4")
  }
}

@Suite struct Libraries {
  @Test func prefixesShowHideAndExports() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/src/b.dart": """
        class B { void run() {} }
        class Hidden {}
        int _private = 0;
        """,
        "lib/c.dart": "export 'src/b.dart' show B;\n",
      "lib/a.dart": """
        import 'src/b.dart' as @@p;
        import 'c.dart' show @@B;
        import 'src/b.dart' hide Hidden;
        void f() {
          @@p.@@B().run();
          @@B().@@run();
          @@_private;
        }
        """,
    ])
    #expect(p.exact("p") == "lib/a.dart:1")
    #expect(p.exact("B") == "lib/src/b.dart:1")
    #expect(p.exact("p2") == "lib/a.dart:1")
    #expect(p.exact("B2") == "lib/src/b.dart:1")
    #expect(p.exact("B3") == "lib/src/b.dart:1")
    #expect(p.exact("run") == "lib/src/b.dart:1")
    // Private to its library.
    #expect(p.exact("_private") == nil)
  }

  @Test func partsShareALibrary() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        part 'a_part.dart';
        int _secret() => 1;
        void f() => @@_helper();
        """,
      "lib/a_part.dart": """
        part of 'a.dart';
        int _helper() => @@_secret();
        """,
    ])
    #expect(p.exact("_helper") == "lib/a_part.dart:2")
    #expect(p.exact("_secret") == "lib/a.dart:2")
  }

  @Test func packagesFromPackageConfig() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      ".dart_tool/package_config.json": """
        {"configVersion": 2, "packages": [
          {"name": "demo", "rootUri": "../", "packageUri": "lib/"},
          {"name": "util", "rootUri": "file://$BASE/util", "packageUri": "lib/"}
        ]}
        """,
      "../util/lib/util.dart": "String shout(String s) => s.toUpperCase();\n",
      "lib/src/own.dart": "int own() => 1;\n",
      "lib/a.dart": """
        import 'package:util/util.dart';
        import 'package:demo/src/own.dart';
        void f() {
          @@shout('a');
          @@own();
        }
        """,
    ])
    #expect(p.exact("shout") == "package:util/util.dart:1")
    #expect(p.exact("own") == "lib/src/own.dart:1")
  }
}

@Suite struct Expressions {
  @Test func inferenceCascadesAndNullSafety() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        class Node {
          Node? next;
          final List<Node> children = [];
          int value = 0;
          Node add(Node n) { children.add(n); return this; }
        }
        Future<Node> load() async => Node();
        void f(Node? maybe, Object o) async {
          final n = Node()..@@add(Node())..@@value = 2;
          n.next?.@@next!.@@value;
          maybe!.@@children.first.@@value;
          if (o is Node) o.@@next;
          (await load()).@@value;
          final all = n.children.map((c) => c.@@value).toList();
          print('$@@n ${n.@@value} $all');
        }
        """,
    ])
    #expect(p.exact("add") == "lib/a.dart:5")
    #expect(p.exact("value") == "lib/a.dart:4")
    #expect(p.exact("next") == "lib/a.dart:2")
    #expect(p.exact("value2") == "lib/a.dart:4")
    #expect(p.exact("children") == "lib/a.dart:3")
    #expect(p.exact("value3") == "lib/a.dart:4")
    #expect(p.exact("next2") == "lib/a.dart:2")
    #expect(p.exact("value4") == "lib/a.dart:4")
    #expect(p.exact("value5") == "lib/a.dart:4")
    #expect(p.exact("n") == "lib/a.dart:9")
    #expect(p.exact("value6") == "lib/a.dart:4")
  }

  @Test func typeArgumentsBeforeADotAndCollectionLiterals() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        class Box<T> { T? item; }
        void f() {
          final boxes = <Box<Map<String, Object?>>>[];
          boxes.@@add(Box());
          final m = Map<String, Object?>.@@from({});
          Future<void>.@@delayed(Duration(@@seconds: 1));
          Box<Map<String, int>>().@@item;
        }
        """,
    ])
    #expect(p.exact("add") == "dart:core/List.add:1")
    #expect(p.exact("from") == "dart:core/Map.from:1")
    #expect(p.exact("delayed") == "dart:async/Future.delayed:1")
    #expect(p.exact("seconds") == "dart:core/Duration.new.seconds:1")
    #expect(p.exact("item") == "lib/a.dart:1")
  }

  @Test func switchExpressionsAndPatterns() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        String f(Object address) {
          final (a, b) = (1, 'x');
          return switch (address) {
            int port => 'ws://$@@port $@@a',
            String value when value.@@isEmpty => @@value,
            _ => '$b',
          };
        }
        """,
    ])
    #expect(p.exact("port") == "lib/a.dart:4")
    #expect(p.exact("a") == "lib/a.dart:2")
    #expect(p.exact("isEmpty") == "dart:core/String.isEmpty:1")
    #expect(p.exact("value") == "lib/a.dart:5")
  }

  @Test func promotionAndBoundedGenerics() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        class Holder<T extends Function> { T? callback; }
        class After {}
        bool blank(Object? value) => value is! String || value.@@trim().isEmpty;
        void f(Holder<void Function()> h) => h.@@callback;
        After @@make() => After();
        """,
    ])
    #expect(p.exact("trim") == "dart:core/String.trim:1")
    #expect(p.exact("callback") == "lib/a.dart:1")
    // A bound of `Function` once swallowed the rest of the file.
    #expect(p.exact("make") == "lib/a.dart:5")
  }

  @Test func extensionsByTypeArgumentsAndNullAwareIndexes() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        import 'dart:ffi';
        class Sub { String topic() => ''; }
        Pointer<Uint8> alloc(int size) => nullptr.cast();
        void f(Map<String, Sub>? subs, String key) {
          final bytes = alloc(4);
          bytes.@@asTypedList(4);
          bytes.cast<Uint64>().@@value = 0;
          bytes.cast<Int>().@@value;
          final sub = subs?[key];
          sub?.@@topic();
        }
        """,
    ])
    #expect(p.exact("asTypedList") == "dart:ffi/Uint8Pointer.asTypedList:1")
    #expect(p.exact("value") == "dart:ffi/Uint64Pointer.value=:1")
    #expect(p.exact("value2") == "dart:ffi/AbiSpecificIntegerPointer.value:1")
    #expect(p.exact("topic") == "lib/a.dart:2")
  }

  @Test func unknownBeatsAGuess() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        import 'package:missing/missing.dart';
        void f(dynamic d) {
          @@Missing().go();
          d.@@anything;
        }
        """,
    ])
    #expect(p.answer("Missing").state == .unknown)
    #expect(p.answer("anything").state != .exact)
  }
}

@Suite struct ReferencesCompletionAndDetails {
  @Test func referencesAcrossFiles() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": "class A {\n  void @@go() {}\n}\n",
      "lib/b.dart": "import 'a.dart';\nvoid f(A a) {\n  a.go();\n  A()..go();\n}\n",
    ])
    #expect(p.references("go") == ["lib/a.dart:2", "lib/b.dart:3", "lib/b.dart:4"])
  }

  @Test func membersScopeAndNamedParameters() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        extension Loud on String { String get loud => toUpperCase(); }
        class Options { Options({int retries = 0, bool verbose = false}); }
        void f(String s) {
          final localValue = 1;
          @@
          Options(@@);
          s.@@
        }
        """,
    ])
    let scope = p.complete("")
    #expect(scope.names.contains("localValue"))
    #expect(scope.names.contains("Options"))
    let members = p.complete("3")
    #expect(members.names.contains("length"))
    #expect(members.names.contains("loud"))
    let named = p.complete("2")
    #expect(Array(named.names.prefix(2)).sorted() == ["retries", "verbose"])
  }

  @Test func declarationLine() throws {
    let p = try Project([
      "pubspec.yaml": pubspec,
      "lib/a.dart": """
        /// Reads a file.
        Future<String> read(String path, {bool cached = true}) async => '';
        void f() { @@read('a'); }
        """,
    ])
    let details = p.details("read")
    #expect(details?.declaration == "Future<String> read(String path, {bool cached = true}) async")
    #expect(details?.documentation?.contains("Reads a file.") == true)
  }
}
