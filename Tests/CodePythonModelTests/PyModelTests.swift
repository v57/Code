import CodePythonModel
import Foundation
import Testing

/// A Python project in a temporary folder, from file text with `@@` before the word a question is about.
private final class Project {
  let root: String
  let model: PyModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String]) throws {
    root = NSTemporaryDirectory() + "pymodel-" + UUID().uuidString + "/project"
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "@@") {
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
    model = PyModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the project.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
  }

  /// What completes the word after a mark, typed up to its end.
  func complete(_ key: String, typed: Int? = nil) -> [String] {
    let mark = marks[key]!
    let word = key.prefix { !$0.isNumber }
    return model.complete(path: mark.path, line: mark.line, character: mark.character + (typed ?? word.count), limit: 200).items.map(\.name)
  }
}

@Suite struct Scopes {
  @Test func functionsClassesAndGlobals() throws {
    let p = try Project([
      "a.py": """
        x = 1
        x = 2

        class A:
            x = 3
            def f(self):
                return @@x

        def g():
            global x
            x = 4

        def outer():
            y = 1
            def inner():
                nonlocal y
                y = 2
                return @@y
            return inner

        z = [@@w for w in range(3)]
        print(@@len(z))
        """
    ])
    // A class body isn't an enclosing scope: the module's x, every binding (global x = 4 too).
    #expect(p.answer("x").places == ["a.py:1", "a.py:2", "a.py:11"])
    #expect(p.answer("y").places == ["a.py:14", "a.py:17"])
    #expect(p.answer("w").places == ["a.py:21"])
    #expect(p.answer("len").places.first?.hasPrefix("stub:builtins.pyi:") == true)
  }

  @Test func parametersAndKeywordArguments() throws {
    let p = try Project([
      "a.py": """
        def f(@@a, b=2):
            return @@a + b

        f(1, @@b=3)
        """
    ])
    #expect(p.answer("a").places == ["a.py:1"])
    #expect(p.answer("a2").places == ["a.py:1"])
    #expect(p.answer("b").places == ["a.py:1"])
  }
}

@Suite struct Imports {
  @Test func packagesRelativeAndStar() throws {
    let p = try Project([
      "pkg/__init__.py": """
        from .core import Engine
        __all__ = ["Engine", "helper"]
        def helper(): pass
        def _hidden(): pass
        """,
      "pkg/core.py": """
        class Engine:
            def start(self) -> "Engine":
                return self
        """,
      "pkg/sub/mod.py": """
        from .. import @@core
        from ..core import @@Engine as E
        """,
      "main.py": """
        import pkg.@@core
        from pkg import *
        import pkg.core as pc
        @@Engine().@@start().@@start
        @@helper()
        @@pc.Engine
        @@pkg.core
        """,
    ])
    #expect(p.answer("core").places == ["pkg/core.py:1"])
    #expect(p.answer("Engine").places == ["pkg/core.py:1"])
    #expect(p.answer("core2").places == ["pkg/core.py:1"])
    #expect(p.answer("Engine2").places == ["pkg/core.py:1"])
    #expect(p.answer("start").places == ["pkg/core.py:2"])
    #expect(p.answer("start2").places == ["pkg/core.py:2"])
    #expect(p.answer("helper").places == ["pkg/__init__.py:3"])
    #expect(p.answer("pc").places == ["pkg/core.py:1"])
    #expect(p.answer("pkg").places == ["pkg/__init__.py:1"])
  }

  @Test func stubBesideModule() throws {
    let p = try Project([
      "lib.py": "def f(x):\n    return x\n",
      "lib.pyi": "def f(x: int) -> int: ...\n",
      "main.py": "from lib import @@f\n",
    ])
    #expect(p.answer("f").places == ["lib.pyi:1"])
  }

  @Test func srcLayout() throws {
    let p = try Project([
      "pyproject.toml": "[project]\nname = \"tool\"\n",
      "src/tool/__init__.py": "VERSION = 1\n",
      "tests/test_a.py": "import tool\nprint(tool.@@VERSION)\n",
    ])
    #expect(p.answer("VERSION").places == ["src/tool/__init__.py:1"])
  }

  /// A module's uses under its own name and the names it's imported as; an import that isn't found is a definition
  /// other files' imports of it share.
  @Test func moduleAndMissingImportReferences() throws {
    let p = try Project([
      "a.py": "import @@sys\nimport json as j\nfrom ffi import Thing as @@Frame\nsys.exit(0)\n",
      "b.py": "from a import Frame\nimport sys\nsys.argv\nf: Frame\n",
    ])
    func lines(_ key: String) -> [String] {
      let mark = p.marks[key]!
      let found = p.model.answer(path: mark.path, line: mark.line, character: mark.character)
      return p.model.references(of: found).map { "\(($0.path as NSString).lastPathComponent):\($0.line)" }.sorted()
    }
    #expect(lines("sys") == ["a.py:1", "a.py:4", "b.py:2", "b.py:3"])
    #expect(lines("Frame") == ["a.py:3", "b.py:1", "b.py:4"])
  }
}

@Suite struct Types {
  @Test func classesAndMRO() throws {
    let p = try Project([
      "a.py": """
        class Base:
            def hello(self): pass
            def who(self): pass

        class Left(Base):
            def who(self): pass

        class Right(Base):
            def hello(self): pass

        class Child(Left, Right):
            def __init__(self):
                self.count = 0
                super().@@hello()

            @property
            def size(self) -> int:
                return self.@@count

        c = Child()
        c.@@hello()
        c.@@who()
        c.size.@@bit_length()
        """
    ])
    // Child, Left, Right, Base: Right's hello comes before Base's.
    #expect(p.answer("hello").places == ["a.py:9"])
    #expect(p.answer("count").places == ["a.py:13"])
    #expect(p.answer("hello2").places == ["a.py:9"])
    #expect(p.answer("who").places == ["a.py:6"])
    #expect(p.answer("bit_length").places.first?.hasPrefix("stub:builtins.pyi:") == true)
  }

  @Test func annotationsAndDataclasses() throws {
    let p = try Project([
      "a.py": """
        from dataclasses import dataclass
        from typing import Optional, List

        @dataclass
        class Point:
            x: int
            y: int = 0

            def norm(self) -> float:
                return 0.0

        def make() -> Optional[Point]:
            return None

        def all_points(items: List[Point]):
            for item in items:
                item.@@norm()
            first = items[0]
            first.@@x
            return [p for p in items if p.@@y]

        p = make()
        p.@@norm()
        Point(@@x=1, y=2)
        with open("f") as handle:
            handle.@@read()
        """
    ])
    #expect(p.answer("norm").places == ["a.py:9"])
    #expect(p.answer("x").places == ["a.py:6"])
    #expect(p.answer("y").places == ["a.py:7"])
    #expect(p.answer("norm2").places == ["a.py:9"])
    #expect(p.answer("x2").places == ["a.py:6"])
    #expect(p.answer("read").state == .exact)
  }

  @Test func unknownReceiverIsByName() throws {
    let p = try Project([
      "a.py": """
        class A:
            def run(self): pass

        def f(thing):
            thing.@@run()
        """
    ])
    let found = p.answer("run")
    #expect(found.state == .candidates)
    #expect(found.places == ["a.py:2"])
  }
}

@Suite struct Completion {
  @Test func membersScopeAndModules() throws {
    let p = try Project([
      "a.py": """
        import os
        class A:
            def run(self): pass
            def rest(self): pass
            def _private(self): pass

        value = A()
        value.@@r
        @@val
        os.@@pat
        """,
      "b.py": """
        import @@os
        from a import @@Ax
        """,
    ])
    #expect(Set(p.complete("r").prefix(2)) == ["rest", "run"])
    #expect(p.complete("r").contains("_private"))
    #expect(p.complete("val").contains("value"))
    #expect(p.complete("pat").contains("path"))
    #expect(p.complete("os", typed: 0).contains("a"))
    #expect(p.complete("Ax", typed: 1).contains("A"))
  }
}

@Suite struct Folders {
  @Test func newestVersionFirst() {
    #expect(Toolchains.newestFirst(["3.9", "Current", "3.13", "3.10"]) == ["3.13", "3.10", "3.9", "Current"])
    #expect(Toolchains.newestFirst(["python3", "python3.9", "python3.13"]) == ["python3.13", "python3.9", "python3"])
    #expect(Toolchains.newestFirst(["jdk1.8.0_292.jdk", "temurin-17.jdk", "jdk-21.jdk"]) == ["jdk-21.jdk", "temurin-17.jdk", "jdk1.8.0_292.jdk"])
    #expect(Toolchains.newestFirst(["ruby-3.3.0", "ruby-3.10.0", "default"]) == ["ruby-3.10.0", "ruby-3.3.0", "default"])
    #expect(
      Toolchains.newestPathsFirst(["/m2/g/a/1.9.0/a-1.9.0-sources.jar", "/m2/g/a/1.10.0/a-1.10.0-sources.jar"])
        == ["/m2/g/a/1.10.0/a-1.10.0-sources.jar", "/m2/g/a/1.9.0/a-1.9.0-sources.jar"])
  }
}
