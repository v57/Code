import CodeModel
import CodeRubyModel
import Foundation
import Testing

/// A Ruby project in a temporary folder, from file text with `^^` before the word a question is about (`^^@name` for
/// an instance variable; Ruby's own `@@` is a class variable). Ruby's own classes are Code's stub.
private final class Project {
  let root: String
  let model: RubyModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String]) throws {
    let base = NSTemporaryDirectory() + "rubymodel-" + UUID().uuidString
    root = base + "/project"
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "^^") {
          let character = rest.utf16.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "@" || $0 == "$" || $0 == "?" || $0 == "!" })
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
    model = RubyModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), `ruby:core.rb:<line>` in the stub.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
  }

  func exact(_ key: String) -> String? {
    let found = answer(key)
    return found.state == .exact ? found.places.first : nil
  }

  /// The stub's line for an exact answer there, as its text: `def join(*args); end`.
  func stubLine(_ key: String) -> String? {
    guard let place = exact(key), place.hasPrefix("ruby:core.rb:"), let line = Int(place.dropFirst("ruby:core.rb:".count)) else { return nil }
    let text = try? String(contentsOfFile: NSTemporaryDirectory() + "code-ruby-std/core.rb", encoding: .utf8)
    let lines = text?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
    return line - 1 < lines.count ? lines[line - 1].trimmingCharacters(in: .whitespaces) : nil
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

@Suite struct Names {
  @Test func localsParametersAndBlocks() throws {
    let project = try Project([
      "a.rb": """
        def walk(head, limit: 3)
          node = head
          count = 0
          while node
            node = ^^node.next
            count += 1
          end
          [1, 2].each do |item|
            total = item + ^^count + ^^limit
          end
          ^^total = 0
          x = ^^x
          a, b = 1, 2
          ^^a + ^^b + ^^head
        end
        """
    ])
    // `x = x.next` reads the first binding, not the line it's on.
    #expect(project.exact("node") == "a.rb:2")
    #expect(project.exact("count") == "a.rb:3")
    #expect(project.exact("limit") == "a.rb:1")
    // A block's own local isn't seen after it: this is a new one.
    #expect(project.exact("total") == "a.rb:11")
    // `x = x`: the assignment makes the local first (nil on the right).
    #expect(project.exact("x") == "a.rb:12")
    #expect(project.exact("a") == "a.rb:13")
    #expect(project.exact("b") == "a.rb:13")
    #expect(project.exact("head") == "a.rb:1")
  }

  @Test func keywordsAfterDotsAreMethods() throws {
    let project = try Project([
      "a.rb": """
        class Range2
          def initialize(a) = @a = a
          def end = @a
          def self.begin = new(0)
        end
        r = Range2::^^new(1)
        r.^^end
        Range2.^^begin.^^class
        r.^^then { |v| v }
        """
    ])
    #expect(project.exact("new") == "a.rb:2")
    #expect(project.exact("end") == "a.rb:3")
    #expect(project.exact("begin") == "a.rb:4")
    #expect(project.stubLine("class") == "def class; end")
    #expect(project.stubLine("then")?.hasPrefix("def then") == true)
  }

  @Test func referencesKeepNamesOnOneLineApart() throws {
    let project = try Project([
      "a.rb": """
        class Person
          attr_reader :^^name, :age
          def initialize(name, age)
            @name, @age = name, age
          end
          def label = "#{name} (#{age})"
        end
        """
    ])
    // `name` and `age` share lines: the references of one hold its own uses only, its reader where it's declared.
    let found = project.references("name")
    #expect(found == ["a.rb:2", "a.rb:6"])
  }

  @Test func commandCallsOverLocals() throws {
    let project = try Project([
      "a.rb": """
        def file(name) = name
        [[1, "a"]].each do |need, file|
          ^^file "x"
          ^^file
        end
        """
    ])
    // `file "x"` calls the method even with a local of that name in scope.
    #expect(project.exact("file") == "a.rb:1")
    #expect(project.exact("file2") == "a.rb:2")
  }
}

@Suite struct Constants {
  @Test func lexicalScopeThenAncestorsThenTopLevel() throws {
    let project = try Project([
      "lib/shop.rb": """
        LIMIT = 1
        module Shop
          LIMIT = 2
          class Base
            RATE = 3
          end
          class Basket < Base
            def total = ^^LIMIT + ^^RATE + ::^^LIMIT
          end
        end
        class Shop::Basket
          def again = ^^LIMIT
        end
        Shop::^^Basket.new
        """
    ])
    #expect(project.exact("LIMIT") == "lib/shop.rb:3")
    #expect(project.exact("RATE") == "lib/shop.rb:5")
    #expect(project.exact("LIMIT2") == "lib/shop.rb:1")
    // `class Shop::Basket` opens only Basket: `Shop`'s constants aren't in its lexical scope.
    #expect(project.exact("LIMIT3") == "lib/shop.rb:1")
    #expect(project.answer("Basket").places.contains("lib/shop.rb:7"))
  }

  @Test func requiresReachOtherFilesAndRubysOwn() throws {
    let project = try Project([
      "lib/a.rb": """
        require_relative ^^"b"
        require ^^"json"
        B.new
        ^^JSON.^^generate({})
        ^^File.^^join("a", "b")
        """,
      "lib/b.rb": "class B; end\n",
    ])
    // A required file's path answers the file.
    #expect(project.exact("") == "lib/b.rb:1")
    #expect(project.exact("2")?.contains("json.rb:") == true)
    #expect(project.answer("JSON").state == .exact)
    #expect(project.stubLine("File")?.hasPrefix("class File") == true)
    #expect(project.stubLine("join")?.hasPrefix("def join") == true)
  }
}

@Suite struct Members {
  @Test func mixinsAttributesSingletonsAndAliases() throws {
    let project = try Project([
      "a.rb": """
        module Greeting
          def greet = "hi"
        end
        module Loud
          def shout = "HI"
        end
        class Speaker
          include Greeting
          extend Loud
          attr_accessor :volume
          Point = Struct.new(:x, :y)
          def self.make = new
          class << self
            def build = make
          end
          def say = greet
          alias_method :speak, :say
          alias talk say
        end
        s = Speaker.^^make
        Speaker.^^build
        Speaker.^^shout
        s.^^greet
        s.^^volume = 2
        s.^^speak
        s.^^talk
        Speaker::Point.new(1, 2).^^x
        """
    ])
    #expect(project.exact("make") == "a.rb:12")
    #expect(project.exact("build") == "a.rb:14")
    #expect(project.exact("shout") == "a.rb:5")
    #expect(project.exact("greet") == "a.rb:2")
    #expect(project.exact("volume") == "a.rb:10")
    #expect(project.exact("speak") == "a.rb:17")
    #expect(project.exact("talk") == "a.rb:18")
    #expect(project.exact("x") == "a.rb:11")
  }

  @Test func instanceVariablesBelongToTheirClass() throws {
    let project = try Project([
      "a.rb": """
        class A
          @count = 0
          def initialize
            @name = "a"
          end
          def name = ^^@name
          def self.count = ^^@count
        end
        class B
          def name = ^^@name
        end
        """
    ])
    #expect(project.exact("@name") == "a.rb:4")
    // `@count` in the class body is the class object's.
    #expect(project.exact("@count") == "a.rb:2")
    // B's own, never assigned: not A's.
    #expect(project.exact("@name2") == nil)
  }

  @Test func runtimeMethodsAnswerUnknown() throws {
    let project = try Project([
      "a.rb": """
        class Ghost
          def method_missing(name, *args) = name
          def respond_to_missing?(*) = true
          define_method(:boo) { 1 }
        end
        g = Ghost.new
        g.^^boo
        g.^^anything
        """
    ])
    // `define_method` with a literal name declares it; anything else may be made at run time.
    #expect(project.exact("boo") == "a.rb:4")
    #expect(project.answer("anything").state != .exact)
  }

  @Test func keywordArgumentsNameTheirParameters() throws {
    let project = try Project([
      "a.rb": """
        def connect(host, port: 80) = host
        connect("a", ^^port: 8080)
        """
    ])
    #expect(project.exact("port") == "a.rb:1")
  }
}

@Suite struct Types {
  @Test func yardAndSorbetTypesAndTheirDescriptions() throws {
    let project = try Project([
      "a.rb": """
        class User
          def name = "u"
        end
        class Repo
          # Finds one.
          # @param id [Integer] the User's number
          # @return [User] the User found
          def find(id) = User.new
          extend T::Sig
          sig { returns(User) }
          def first = User.new
        end
        Repo.new.find(1).^^name
        Repo.new.first.^^name
        """
    ])
    #expect(project.exact("name") == "a.rb:2")
    #expect(project.exact("name2") == "a.rb:2")
  }

  @Test func multilineCallsAndOrAssign() throws {
    let project = try Project([
      "a.rb": """
        class Box
          def open = 1
        end
        def make = Box.new
        box = make(
        )
        box.^^open
        cache ||= Box.new
        cache.^^open
        """
    ])
    #expect(project.exact("open") == "a.rb:2")
    #expect(project.exact("open2") == "a.rb:2")
  }

  @Test func blocksYieldTheirElementTypes() throws {
    let project = try Project([
      "a.rb": """
        class Words
          # @return [Hash{String => Integer}]
          def counts = {}
          # @return [Array<String>]
          def list = []
        end
        w = Words.new
        w.counts.each { |key, value| key.^^upcase }
        w.list.each_with_index { |word, i| word.^^upcase; i.^^succ }
        """
    ])
    #expect(project.stubLine("upcase")?.hasPrefix("def upcase") == true)
    #expect(project.stubLine("upcase2")?.hasPrefix("def upcase") == true)
    #expect(project.stubLine("succ")?.hasPrefix("def succ") == true)
  }

  @Test func singletonMethodsOnOtherObjectsStayTheirs() throws {
    let project = try Project([
      "a.rb": """
        class Stream
          def each = 1
        end
        def wrap(sender)
          def sender.each = 2
          sender
        end
        Stream.new.^^each
        """
    ])
    #expect(project.exact("each") == "a.rb:2")
  }
}

@Suite struct Completion {
  @Test func membersConstantsVariablesAndScope() throws {
    let project = try Project([
      "a.rb": """
        module Shop
          class Basket
            LIMIT = 10
            attr_reader :items
            def initialize = @items = []
            def add(item, count: 1) = self
            def total
              sum = 0
              ^^
              ^^@
              self.^^
            end
            def self.build = new
          end
        end
        b = Shop::Basket.new
        b.^^
        Shop::Basket.^^
        Shop::^^
        """
    ])
    let member = project.complete("")
    #expect(member.context == .scope && member.names.contains("sum") && member.names.contains("add") && member.names.contains("LIMIT"))
    #expect(project.complete("@", typed: 1).names == ["@items"])
    #expect(project.complete("2").names.contains("total"))
    let instance = project.complete("3")
    #expect(instance.context == .member && instance.names.contains("add") && instance.names.contains("items") && !instance.names.contains("build"))
    #expect(instance.names.contains("frozen?") && !instance.names.contains("puts"))
    let klass = project.complete("4")
    #expect(klass.names.contains("build") && klass.names.contains("new") && !klass.names.contains("add"))
    #expect(project.complete("5").names == ["Basket"])
  }

  @Test func unknownReceiversGiveNothing() throws {
    let project = try Project(["a.rb": "def f(x) = x.^^\n"])
    let list = project.complete("")
    #expect(list.state == .unknown && list.names.isEmpty)
  }
}

@Suite struct Details {
  @Test func declarationDocumentationAndType() throws {
    let project = try Project([
      "a.rb": """
        module Shop
          # A basket of items.
          # @see Shop
          class Basket
            # Adds one.
            # @return [Basket]
            def add(item) = self
          end
        end
        Shop::Basket.new.^^add(1)
        """
    ])
    let found = try #require(project.details("add"))
    #expect(found.declaration == "def add(item) = self")
    #expect(found.documentation == "Adds one.")
    #expect(found.parents.first?.name == "Shop::Basket")
    #expect(found.type?.name == "Shop::Basket")
  }
}
