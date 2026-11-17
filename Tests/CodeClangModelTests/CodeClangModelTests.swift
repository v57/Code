import CodeClangModel
import Foundation
import Testing

/// A C-family project in a temporary folder, from file text with `@@` before the word a question is about.
private final class Project {
  let root: String
  let model: CModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String]) throws {
    root = NSTemporaryDirectory() + "cmodel-" + UUID().uuidString + "/project"
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "@@") {
          let character = rest.utf8.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
          // The same word twice: the second is `word2`.
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
    model = CModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the project.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
  }

  func references(_ key: String) -> [String] {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return model.references(of: found).map { "\($0.path):\($0.line)" }.sorted()
  }

  func complete(_ key: String) -> [String] {
    let mark = marks[key]!
    return model.complete(path: mark.path, line: mark.line, character: mark.character, limit: 200).items.map(\.name)
  }
}

@Suite struct Definitions {
  @Test func definitionsAcrossFilesAndTheToggle() throws {
    let p = try Project([
      "list.h": """
        #ifndef LIST_H
        #define LIST_H
        struct node { int value; struct node *next; };
        typedef struct node node_t;
        int list_length(node_t *head);
        #endif
        """,
      "list.c": """
        #include "list.h"
        int @@list_length(node_t *head) {
          int count = 0;
          for (node_t *n = head; n; n = n->@@next) count += n->@@value;
          return @@count;
        }
        """,
      "main.c": """
        #include "list.h"
        int main(void) {
          @@node_t first = {1, 0};
          return @@list_length(&first);
        }
        """,
    ])
    // A use goes to the definition in another file; the definition to the header's declaration.
    #expect(p.answer("list_length2").places == ["list.c:2"])
    #expect(p.answer("list_length").places == ["list.h:5"])
    #expect(p.answer("next").places == ["list.h:3"])
    #expect(p.answer("value").places == ["list.h:3"])
    #expect(p.answer("count").places == ["list.c:3"])
    #expect(p.answer("node_t").places == ["list.h:4"])
    #expect(p.references("list_length2") == ["list.c:2", "list.h:5", "main.c:4"])
  }

  @Test func macrosAndConditions() throws {
    let p = try Project([
      "config.h": """
        #define USE_FAST 1
        """,
      "a.c": """
        #include "config.h"
        #define SQUARE(x) ((@@x) * (x))
        #if USE_FAST
        static int fast(int v) { return v; }
        #else
        static int slow(int v) { return v; }
        #endif
        int g(int v) { return @@SQUARE(v) + @@fast(v); }
        #ifdef @@USE_FAST
        #endif
        """,
    ])
    #expect(p.answer("SQUARE").places == ["a.c:2"])
    #expect(p.answer("x").places == ["a.c:2"])
    #expect(p.answer("fast").places == ["a.c:4"])
    #expect(p.answer("USE_FAST").places == ["config.h:1"])
  }

  @Test func staticFunctionsStayInTheirFile() throws {
    let p = try Project([
      "a.c": "static int helper(void) { return 1; }\nint a(void) { return @@helper(); }\n",
      "b.c": "static int helper(void) { return 2; }\nint b(void) { return @@helper(); }\n",
    ])
    #expect(p.answer("helper").places == ["a.c:1"])
    #expect(p.answer("helper2").places == ["b.c:1"])
  }

  @Test func cppClassesNamespacesAndOutOfLineDefinitions() throws {
    let p = try Project([
      "shape.hpp": """
        namespace geo {
        class Shape {
         public:
          virtual double area() const;
          int sides = 0;
        };
        }
        """,
      "shape.cpp": """
        #include "shape.hpp"
        namespace geo {
        double Shape::@@area() const { return @@sides * 1.0; }
        }
        double total(geo::@@Shape &s, geo::Shape *p) { return s.@@area() + p->@@sides; }
        """,
    ])
    #expect(p.answer("area").places == ["shape.hpp:4"])
    #expect(p.answer("sides").places == ["shape.hpp:5"])
    #expect(p.answer("Shape").places == ["shape.hpp:2"])
    #expect(p.answer("area2").places == ["shape.cpp:3"])
    #expect(p.answer("sides2").places == ["shape.hpp:5"])
  }

  @Test func objectiveCMessagesAndProperties() throws {
    let p = try Project([
      "Counter.h": """
        @interface Counter
        @property int count;
        - (void)addValue:(int)value times:(int)times;
        + (instancetype)counter;
        @end
        """,
      "Counter.m": """
        #import "Counter.h"
        @implementation Counter
        - (void)addValue:(int)value times:(int)times { self.@@count += value * times; }
        + (instancetype)counter { return 0; }
        @end
        void use(void) {
          Counter *c = [Counter @@counter];
          [c @@addValue:1 @@times:2];
        }
        """,
    ])
    #expect(p.answer("count").places == ["Counter.h:2"])
    #expect(p.answer("counter").places == ["Counter.m:4"])
    #expect(p.answer("addValue").places == ["Counter.m:3"])
    #expect(p.answer("times").places == ["Counter.m:3"])
  }
}

@Suite struct Preprocessing {
  @Test func typedefForwardDeclarationsLabelsAndInactiveDefines() throws {
    let p = try Project([
      "a.c": """
        typedef struct box box_t;
        struct box { int size; };
        #ifndef __has_attribute
        #define OLD 1
        #else
        #define NEW 1
        #endif
        int f(box_t *b) {
          if (!b) goto @@done;
          return b->@@size + @@NEW;
        done:
          return 0;
        }
        int g(int (*callback)(int code, void *context)) { return @@callback(1, 0); }
        """
    ])
    #expect(p.answer("done").places == ["a.c:11"])
    #expect(p.answer("size").places == ["a.c:2"])
    // `__has_attribute` counts as defined, so the `#else` is taken.
    #expect(p.answer("NEW").places == ["a.c:6"])
    #expect(p.answer("callback").places == ["a.c:14"])
  }

  @Test func macroWrittenFunctionsAndCapitalTags() throws {
    let p = try Project([
      "a.h": """
        typedef struct _SESSION SESSION;
        #define ALLOC_FUNC(name) void *name(unsigned long count)
        """,
      "a.c": """
        #include "a.h"
        static ALLOC_FUNC(default_alloc) { return 0; }
        static int after(@@SESSION *s) { return 0; }
        void *use(void) { return @@default_alloc(1); }
        """,
    ])
    // `typedef struct _SESSION SESSION` is a tag and a name, not an export macro before one.
    #expect(p.answer("SESSION").places == ["a.h:1"])
    // A macro that writes a function's head names it by its argument, and what follows is still read.
    #expect(p.answer("default_alloc").places == ["a.c:2"])
  }

  @Test func macroBodiesUseTheNearestWordInCode() throws {
    let p = try Project([
      "a.c": """
        struct buffer { int length; };
        #define LENGTH(b) ((b)->@@length)
        int size(struct buffer *b) { return LENGTH(b); }
        """
    ])
    // clangd reads a macro's body as text: the nearest same word in code, here the field.
    #expect(p.answer("length").places == ["a.c:1"])
  }
}

@Suite struct Classes {
  @Test func constructorsDestructorsAndTheClassNameInside() throws {
    let p = try Project([
      "a.hpp": """
        namespace ns {
        template <typename T> class Holder {
         public:
          Holder(T value);
          ~Holder();
          T value_;
        };
        }
        """,
      "a.cpp": """
        #include "a.hpp"
        namespace ns {
        template <typename T> Holder<T>::@@Holder(T value) : value_(value) {}
        template <typename T> Holder<T>::~Holder() {}
        int after(int x) { return x; }
        }
        int use() { return ns::@@after(1); }
        """,
    ])
    // A constructor's definition goes to its declaration, and what follows it is still read.
    #expect(p.answer("Holder").places == ["a.hpp:4"])
    #expect(p.answer("after").places == ["a.cpp:5"])
  }

  @Test func objectiveCGenericsAndAvailability() throws {
    let p = try Project([
      "Box.h": """
        @interface Box<ObjectType> : NSObject
        - (ObjectType)first API_AVAILABLE(macos(10.15));
        - (void)put:(ObjectType)item;
        @end
        """,
      "Box.m": """
        #import "Box.h"
        void use(Box<id> *box) {
          [box @@first];
          [box @@put:0];
        }
        """,
    ])
    #expect(p.answer("first").places == ["Box.h:2"])
    #expect(p.answer("put").places == ["Box.h:3"])
  }
}

@Suite struct Completion {
  @Test func membersAndScope() throws {
    let p = try Project([
      "a.c": """
        struct point { int x; int y; };
        static int scale = 2;
        int f(struct point *p) {
          int local = p->@@x;
          return @@lo;
        }
        """
    ])
    #expect(Set(p.complete("x")).isSuperset(of: ["x", "y"]))
    #expect(p.complete("lo").contains("local"))
  }
}
