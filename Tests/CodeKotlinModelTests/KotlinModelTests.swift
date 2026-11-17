import CodeKotlinModel
import CodeModel
import Foundation
import Testing

/// A Kotlin project in a temporary folder, from file text with `@@` before the word a question is about. The platform
/// is Java's built-in stub and the standard library Kotlin's generated one, so nothing installed is needed.
private final class Project {
  let root: String
  let model: KotlinModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String], root folder: String = "project") throws {
    let base = NSTemporaryDirectory() + "kotlinmodel-" + UUID().uuidString
    root = base + "/" + folder
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "@@") {
          let character = rest.utf16.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].drop { $0 == "@" || $0 == "`" }.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
          var key = word
          var n = 2
          while marks[key] != nil {
            key = word + String(n)
            n += 1
          }
          marks[key] = (base + "/" + name, number, character)
          rest.removeSubrange(mark)
        }
        body += rest + "\n"
      }
      let url = URL(fileURLWithPath: base + "/" + name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try body.write(to: url, atomically: true, encoding: .utf8)
    }
    model = KotlinModel(root: root, findsPlatform: false)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the root; a library's as `kotlin:<name>`
  /// or `jdk:<name>`.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { $0.line == 1 && $0.path.contains(":") ? $0.path : "\($0.path):\($0.line)" } })
  }

  func exact(_ key: String) -> String? {
    let found = answer(key)
    return found.state == .exact && found.places.count == 1 ? found.places.first : nil
  }

  /// The lines a name's references are on, as `path:line`.
  func references(_ key: String) -> [String] {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return model.references(of: found).map { "\($0.path):\($0.line)" }.sorted()
  }

  /// What completes at a mark with `typed` characters of its word typed.
  func complete(_ key: String, typed: Int = 0) -> [String] {
    let mark = marks[key]!
    return model.complete(path: mark.path, line: mark.line, character: mark.character + typed, limit: 400).items.map(\.name)
  }
}

private let main = "project/src/main/kotlin/"

@Suite struct KotlinNames {
  @Test func localsParametersAndShadowing() throws {
    let p = try Project([
      main + "a/A.kt": """
        package a

        class A(val count: Int) {
          fun f(count: Int): Int {
            val total = @@count + this.@@count
            for (i in 0 until 3) { println(@@i) }
            return total
          }
        }

        fun service(): String = "s"

        fun g() {
          val service = @@service()
          println(@@service)
        }
        """,
    ])
    #expect(p.exact("count") == "src/main/kotlin/a/A.kt:4")
    #expect(p.exact("count2") == "src/main/kotlin/a/A.kt:3")
    #expect(p.exact("i") == "src/main/kotlin/a/A.kt:6")
    // Its own initializer doesn't see the local: the function is called.
    #expect(p.exact("service") == "src/main/kotlin/a/A.kt:11")
    #expect(p.exact("service2") == "src/main/kotlin/a/A.kt:14")
  }

  @Test func packagesNeedNotMatchFolders() throws {
    let p = try Project([
      main + "anywhere/Util.kt": """
        package com.example.util

        fun helper(): Int = 1
        val answer = 42
        """,
      main + "other/Use.kt": """
        package com.example.app

        import com.example.util.@@helper
        import com.example.util.answer as theAnswer
        import com.example.util.*

        fun use() = @@helper() + @@theAnswer + @@answer
        """,
    ])
    #expect(p.exact("helper") == "src/main/kotlin/anywhere/Util.kt:3")
    #expect(p.exact("helper2") == "src/main/kotlin/anywhere/Util.kt:3")
    #expect(p.exact("theAnswer") == "src/main/kotlin/anywhere/Util.kt:4")
    #expect(p.exact("answer") == "src/main/kotlin/anywhere/Util.kt:4")
  }

  @Test func backtickNames() throws {
    let p = try Project([
      main + "t/T.kt": """
        package t

        fun `a name with spaces`(): Int = 1

        fun use() = @@`a name with spaces`()
        """,
    ])
    #expect(p.exact("a") == "src/main/kotlin/t/T.kt:3")
  }
}

@Suite struct KotlinClasses {
  @Test func objectsCompanionsAndEnums() throws {
    let p = try Project([
      main + "c/C.kt": """
        package c

        class Factory private constructor(val name: String) {
          companion object {
            fun create(name: String) = Factory(name)
          }
        }

        object Registry {
          val items = mutableListOf<String>()
        }

        enum class Color { RED, GREEN }

        data class Point(val x: Int, val y: Int)

        fun use() {
          val f = Factory.@@create("a")
          println(f.@@name)
          Registry.@@items.add("x")
          println(Color.@@GREEN)
          val p = Point(1, 2).@@copy(y = 3)
          println(p.@@x)
        }
        """,
    ])
    #expect(p.exact("create") == "src/main/kotlin/c/C.kt:5")
    #expect(p.exact("name") == "src/main/kotlin/c/C.kt:3")
    #expect(p.exact("items") == "src/main/kotlin/c/C.kt:10")
    #expect(p.exact("GREEN") == "src/main/kotlin/c/C.kt:13")
    #expect(p.exact("x") == "src/main/kotlin/c/C.kt:15")
  }

  @Test func sealedClassesWhenAndSmartCasts() throws {
    let p = try Project([
      main + "s/S.kt": """
        package s

        sealed class Shape
        class Circle(val radius: Double) : Shape()
        class Square(val side: Double) : Shape()

        fun area(shape: Shape): Double = when (shape) {
          is Circle -> shape.@@radius * shape.radius
          is Square -> shape.@@side * shape.side
        }

        fun describe(any: Any): String {
          if (any is String) return any.@@length.toString()
          return if (any is Int) any.@@inc().toString() else any.@@toString()
        }
        """,
    ])
    #expect(p.exact("radius") == "src/main/kotlin/s/S.kt:4")
    #expect(p.exact("side") == "src/main/kotlin/s/S.kt:5")
    #expect(p.exact("length") == "kotlin:kotlin.String.length")
    #expect(p.exact("inc") == "kotlin:kotlin.Int.inc(0)")
    // The `else` branch isn't cast.
    #expect(p.exact("toString") == "kotlin:kotlin.Any.toString(0)")
  }

  @Test func elvisSafeCastsAndNegatedChecks() throws {
    let p = try Project([
      main + "n/N.kt": """
        package n

        fun narrow(any: Any?, name: String?): Int {
          val s = any as? String ?: return 0
          val t = name ?: "none"
          if (any !is CharSequence) return 0
          return s.@@length + t.@@length + any.@@length
        }

        fun other(any: Any): Int {
          if (any !is String) { return 1 } else { return any.@@length }
        }
        """,
    ])
    #expect(p.exact("length") == "kotlin:kotlin.String.length")
    #expect(p.exact("length2") == "kotlin:kotlin.String.length")
    // `if (x !is T) return`: x is T after it.
    #expect(p.exact("length3") == "kotlin:kotlin.CharSequence.length")
    #expect(p.exact("length4") == "kotlin:kotlin.String.length")
  }

  @Test func genericsWithVariance() throws {
    let p = try Project([
      main + "g/G.kt": """
        package g

        class Box<out T>(val value: T)

        fun <T> boxOf(value: T): Box<T> = Box(value)

        fun use() = boxOf("text").value.@@length + Box(listOf(1)).value.@@first()
        """,
    ])
    #expect(p.exact("length") == "kotlin:kotlin.String.length")
    #expect(p.exact("first")?.hasPrefix("kotlin:kotlin.collections.") == true)
  }
}

@Suite struct KotlinExtensions {
  @Test func extensionFunctionsAndProperties() throws {
    let p = try Project([
      main + "e/Ext.kt": """
        package e

        fun String.shout(): String = uppercase() + "!"
        val String.firstChar: Char get() = this[0]
        fun <T> List<T>.second(): T = this[1]

        class Named(val name: String) {
          fun shout(): String = name
        }

        fun use() {
          println("hi".@@shout())
          println("hi".@@firstChar)
          println(listOf("a", "b").@@second().@@length)
          // A member wins over an extension.
          println(Named("n").@@shout())
        }
        """,
    ])
    #expect(p.exact("shout") == "src/main/kotlin/e/Ext.kt:3")
    #expect(p.exact("firstChar") == "src/main/kotlin/e/Ext.kt:4")
    #expect(p.exact("second") == "src/main/kotlin/e/Ext.kt:5")
    #expect(p.exact("length") == "kotlin:kotlin.String.length")
    #expect(p.exact("shout2") == "src/main/kotlin/e/Ext.kt:8")
  }

  @Test func scopeFunctionsItAndLazy() throws {
    let p = try Project([
      main + "l/L.kt": """
        package l

        class Config {
          var host = "localhost"
          var port = 80
        }

        val config by lazy { Config() }

        fun use() {
          val c = Config().apply { @@port = 8080 }
          c.let { println(@@it.@@host) }
          with(c) { println(@@host) }
          println(config.@@port)
          listOf(1, 2).map { @@it + 1 }
        }
        """,
    ])
    #expect(p.exact("port") == "src/main/kotlin/l/L.kt:5")
    #expect(p.exact("it") == "src/main/kotlin/l/L.kt:12")
    #expect(p.exact("host") == "src/main/kotlin/l/L.kt:4")
    #expect(p.exact("host2") == "src/main/kotlin/l/L.kt:4")
    #expect(p.exact("port2") == "src/main/kotlin/l/L.kt:5")
    #expect(p.exact("it2") == "src/main/kotlin/l/L.kt:15")
  }
}

@Suite struct KotlinMixed {
  @Test func kotlinSeesJavaAndJavaSeesKotlin() throws {
    let p = try Project([
      "project/src/main/java/m/Person.java": """
        package m;

        public class Person {
          private String name;
          public String getName() { return name; }
          public boolean isAdult() { return true; }
          public static Person of(String name) { return new Person(); }
          public int age() { return new Greeter().@@greet().length(); }
        }
        """,
      main + "m/Greeter.kt": """
        package m

        class Greeter {
          fun greet(): String = "hi"
        }

        fun use() {
          val person = Person.@@of("a")
          println(person.@@name.@@length)
          println(person.@@isAdult)
          println(person.@@age())
        }
        """,
    ])
    #expect(p.exact("of") == "src/main/java/m/Person.java:7")
    // A Java getter as a property.
    #expect(p.exact("name") == "src/main/java/m/Person.java:5")
    #expect(p.exact("length") == "kotlin:kotlin.String.length")
    #expect(p.exact("isAdult") == "src/main/java/m/Person.java:6")
    #expect(p.exact("age") == "src/main/java/m/Person.java:8")
    // Java's model answers in `.java` files, and sees Kotlin's classes.
    #expect(p.exact("greet") == "src/main/kotlin/m/Greeter.kt:4")
  }
}

@Suite struct KotlinReferencesAndCompletion {
  @Test func referencesOfAFunction() throws {
    let p = try Project([
      main + "r/R.kt": """
        package r

        fun @@target() = 1

        fun a() = target()
        fun b() = target() + target()
        """,
    ])
    #expect(p.references("target") == ["src/main/kotlin/r/R.kt:3", "src/main/kotlin/r/R.kt:5", "src/main/kotlin/r/R.kt:6"])
  }

  @Test func membersAndExtensionsComplete() throws {
    let p = try Project([
      main + "k/K.kt": """
        package k

        class Account(val owner: String) {
          fun deposit(amount: Int) {}
        }

        fun Account.close() {}

        fun use(account: Account) {
          account.@@d
        }
        """,
    ])
    let all = p.complete("d")
    #expect(all.contains("deposit"))
    #expect(all.contains("owner"))
    #expect(all.contains("close"))
  }
}
