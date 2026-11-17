import CodeModel
import CodeRustModel
import Foundation
import Testing

/// A Cargo project in a temporary folder, from file text with `@@` before the word a question is about.
private final class Project {
  let root: String
  let model: RustModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String]) throws {
    root = NSTemporaryDirectory() + "rustmodel-" + UUID().uuidString + "/project"
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
    model = RustModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the project, `std:<item>` in the stub.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
  }

  /// The lines a name's references are on, as `path:line`.
  func references(_ key: String) -> [String] {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return model.references(of: found).map { place in
      let path = place.path.hasPrefix(root + "/") ? String(place.path.dropFirst(root.count + 1)) : place.path
      return "\(path):\(place.line)"
    }.sorted()
  }

  /// What completes at a mark with `typed` characters of its word typed (the mark's word is the file's text there).
  func complete(_ key: String, typed: Int = 0) -> (context: ModelCompletionContext, names: [String]) {
    let mark = marks[key]!
    let list = model.complete(path: mark.path, line: mark.line, character: mark.character + typed, limit: 300)
    return (list.context, list.items.map(\.name))
  }
}

private let manifest = """
  [package]
  name = "app"
  version = "0.1.0"
  edition = "2021"
  """

@Suite struct Names {
  @Test func localsParametersAndShadowing() throws {
    let p = try Project([
      "Cargo.toml": manifest,
      "src/lib.rs": """
        pub fn f(count: usize) -> usize {
            let total = @@count + 1;
            let total = total * 2;
            match Some(total) {
                Some(inner) => @@inner + @@total,
                None => 0,
            }
        }
        """,
    ])
    #expect(p.answer("count").places == ["src/lib.rs:1"])
    #expect(p.answer("inner").places == ["src/lib.rs:5"])
    // The second `let` shadows the first.
    #expect(p.answer("total").places == ["src/lib.rs:3"])
  }

  @Test func modulesFilesAndUseTrees() throws {
    let p = try Project([
      "Cargo.toml": manifest,
      "src/lib.rs": """
        mod net;
        mod util {
            pub fn helper() -> u8 { 1 }
            pub mod deep { pub struct Thing; }
        }
        use util::{@@helper, deep::{self, Thing}};
        use crate::net::Socket as Sock;

        pub fn g() -> u8 {
            let _s: @@Sock = net::@@Socket::open();
            let _t: @@Thing = @@deep::Thing;
            @@helper()
        }
        """,
      "src/net.rs": """
        pub struct Socket;
        impl Socket {
            pub fn open() -> Socket { Socket }
        }
        pub fn up() -> u8 { super::util::@@helper() }
        """,
    ])
    #expect(p.answer("helper").places == ["src/lib.rs:3"])
    #expect(p.answer("Sock").places == ["src/net.rs:1"])
    #expect(p.answer("Socket").places == ["src/net.rs:1"])
    #expect(p.answer("Thing").places == ["src/lib.rs:4"])
    #expect(p.answer("deep").places == ["src/lib.rs:4"])
    #expect(p.answer("helper2").places == ["src/lib.rs:3"])
    #expect(p.answer("helper3").places == ["src/lib.rs:3"])
  }

  @Test func workspacePathDependency() throws {
    let p = try Project([
      "Cargo.toml": """
        [workspace]
        members = ["app", "core"]
        """,
      "app/Cargo.toml": """
        [package]
        name = "app"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        engine = { path = "../core", package = "engine-core" }
        """,
      "app/src/main.rs": """
        use engine::Engine;
        fn main() {
            let e = @@Engine::new();
            e.@@start();
        }
        """,
      "core/Cargo.toml": """
        [package]
        name = "engine-core"
        version = "0.1.0"
        edition = "2021"
        """,
      "core/src/lib.rs": """
        pub struct Engine;
        impl Engine {
            pub fn new() -> Engine { Engine }
            pub fn start(&self) {}
        }
        """,
    ])
    #expect(p.answer("Engine").places == ["core/src/lib.rs:1"])
    #expect(p.answer("start").places == ["core/src/lib.rs:4"])
  }

  @Test func localMacroItems() throws {
    let p = try Project([
      "Cargo.toml": manifest,
      "src/lib.rs": """
        macro_rules! items {
            () => {
                pub struct Made;
            };
        }
        items!();
        pub fn f() -> @@Made { Made }
        """,
    ])
    #expect(p.answer("Made").places == ["src/lib.rs:3"])
  }
}

@Suite struct Types {
  @Test func methodsThroughReferencesAndBoxes() throws {
    let p = try Project([
      "Cargo.toml": manifest,
      "src/lib.rs": """
        pub struct Point { pub x: i32 }
        impl Point {
            pub fn norm(&self) -> i32 { self.@@x }
        }
        pub fn f(p: &Point, b: Box<Point>, list: Vec<Point>) -> i32 {
            p.@@norm() + b.@@norm() + list.iter().map(|q| q.@@x).sum::<i32>()
        }
        """,
    ])
    #expect(p.answer("x").places == ["src/lib.rs:1"])
    #expect(p.answer("norm").places == ["src/lib.rs:3"])
    #expect(p.answer("norm2").places == ["src/lib.rs:3"])
    #expect(p.answer("x2").places == ["src/lib.rs:1"])
  }

  /// Of two traits' methods of one name, the one whose trait is in scope; `io::Write` isn't `fmt::Write`.
  @Test func traitsInScope() throws {
    let p = try Project([
      "Cargo.toml": manifest,
      "src/lib.rs": """
        mod shapes {
            pub trait Area { fn area(&self) -> f64; }
            pub trait Survey { fn area(&self) -> f64; }
            pub struct Square;
            impl Area for Square { fn area(&self) -> f64 { 1.0 } }
            impl Survey for Square { fn area(&self) -> f64 { 2.0 } }
        }
        use std::io::Write;
        pub fn f(s: shapes::Square) -> f64 {
            let _ = std::io::stderr().@@flush();
            use shapes::Survey;
            s.@@area()
        }
        pub fn g(s: shapes::Square) -> f64 {
            use shapes::Area;
            s.@@area()
        }
        """,
    ])
    #expect(p.answer("flush").places == ["std:Write::flush:1"])
    #expect(p.answer("area").places == ["src/lib.rs:3"])
    #expect(p.answer("area2").places == ["src/lib.rs:2"])
  }

  /// `impl<T: Display> ToString for T`: whether it applies is asked inside the question of what applies, in any
  /// order, and the answer mustn't depend on which was asked first.
  @Test func blanketImpls() throws {
    let p = try Project([
      "Cargo.toml": manifest,
      "src/lib.rs": """
        use std::fmt;
        pub trait Show { fn show(&self) -> u8; }
        pub trait Shout { fn shout(&self); }
        impl<T: Show> Shout for T { fn shout(&self) {} }
        pub struct E;
        impl fmt::Display for E {
            fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { Ok(()) }
        }
        impl Show for E { fn show(&self) -> u8 { 0 } }
        pub fn f(e: E, r: Result<u8, E>) {
            e.@@shout();
            let _ = e.@@to_string();
            let _ = r.map_err(|err| err.@@to_string());
        }
        """,
    ])
    #expect(p.answer("shout").places == ["src/lib.rs:3"])
    #expect(p.answer("to_string").places == ["std:ToString::to_string:1"])
    #expect(p.answer("to_string2").places == ["std:ToString::to_string:1"])
  }
}

@Suite struct Conditions {
  /// A question inside an item `#[cfg]` leaves out reads it, with every item of the same conditions.
  @Test func leftOutItemsAnswerInsideTheirBranch() throws {
    let p = try Project([
      "Cargo.toml": manifest,
      "src/lib.rs": """
        #[cfg(feature = "extra")]
        pub struct Extra;
        #[cfg(feature = "extra")]
        pub fn make() -> @@Extra { Extra }
        #[cfg(not(feature = "extra"))]
        pub fn make() -> u8 { 0 }
        pub fn use_it() -> u8 { @@make() }
        """,
    ])
    #expect(p.answer("Extra").places == ["src/lib.rs:2"])
    // Outside the branch, only what's compiled.
    #expect(p.answer("make").places == ["src/lib.rs:6"])
  }
}

@Suite struct References {
  @Test func acrossFiles() throws {
    let p = try Project([
      "Cargo.toml": manifest,
      "src/lib.rs": """
        mod a;
        pub fn @@shared() -> u8 { 1 }
        pub fn twice() -> u8 { shared() + shared() }
        """,
      "src/a.rs": """
        pub fn more() -> u8 { crate::shared() }
        """,
    ])
    #expect(p.references("shared") == ["src/a.rs:1", "src/lib.rs:2", "src/lib.rs:3"])
  }
}

@Suite struct Completion {
  @Test func scopeAndMembers() throws {
    let p = try Project([
      "Cargo.toml": manifest,
      "src/lib.rs": """
        use std::sync::{@@Arc, Mutex};
        pub struct Point { pub x: i32, pub y: i32 }
        impl Point { pub fn len(&self) -> i32 { self.x } }
        pub fn f(p: Point, shared: Arc<u8>) -> Option<u8> {
            let _n = p.@@x;
            let _c = Arc::@@clone(&shared);
            let total = 1;
            for i in 0..2 {
                let _ = i;
            }
            @@
        }
        pub fn g(o: Option<u8>) {
            if let @@Some(v) = o {}
        }
        """,
    ])
    let members = p.complete("x")
    #expect(members.context == .member)
    #expect(members.names.contains("x") && members.names.contains("y") && members.names.contains("len"))
    // A `use` group: the members of the path before the brace.
    let group = p.complete("Arc", typed: 2)
    #expect(group.context == .member)
    #expect(group.names.contains("Arc"))
    // Derived and implemented traits' methods on a type's path.
    #expect(p.complete("clone", typed: 2).names.contains("clone"))
    // Before the body's closing brace: its locals, not the loop's; the prelude's `Option` (`Option::{self, …}`).
    let scope = p.complete("")
    #expect(scope.names.contains("total") && scope.names.contains("p") && !scope.names.contains("i"))
    #expect(scope.names.contains("Option"))
    // `if let` starts a pattern.
    #expect(p.complete("Some", typed: 2).names.contains("Some"))
  }
}
