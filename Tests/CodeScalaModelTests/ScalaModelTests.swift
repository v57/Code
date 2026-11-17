import CodeModel
import CodeScalaModel
import Foundation
import Testing

/// A Scala project in a temporary folder, from file text with `@@` before the word a question is about. The platform is
/// Java's built-in stub and the standard library Scala's hand-written one, so nothing installed is needed.
private final class Project {
  let root: String
  let model: ScalaModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String], root folder: String = "project") throws {
    let base = NSTemporaryDirectory() + "scalamodel-" + UUID().uuidString
    root = base + "/" + folder
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "@@") {
          let character = rest.utf16.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].drop { $0 == "`" }.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
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
    model = ScalaModel(root: root, findsPlatform: false)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the root; the stub's as `sdk:<file>:<line>`.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
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

  func detail(_ key: String) -> String? {
    let mark = marks[key]!
    return model.details(path: mark.path, line: mark.line, character: mark.character).details.first?.declaration
  }
}

private let main = "project/src/main/scala/"

@Suite struct ScalaNames {
  @Test func localsParametersAndShadowing() throws {
    let p = try Project([
      main + "a/A.scala": """
        package a

        class A(val count: Int, label: String) {
          def f(count: Int): Int = {
            val total = @@count + this.@@count
            val count2 = { val count = 3; @@count }
            total + count2 + @@label.length
          }
        }
        """
    ])
    #expect(p.exact("count") == "src/main/scala/a/A.scala:4")
    #expect(p.exact("count2") == "src/main/scala/a/A.scala:3")
    #expect(p.exact("count3") == "src/main/scala/a/A.scala:6")
    #expect(p.exact("label") == "src/main/scala/a/A.scala:3")
  }

  @Test func classCompanionApplyAndNamedArguments() throws {
    let p = try Project([
      main + "a/Item.scala": """
        package a

        case class Sku(value: String)

        case class Item(sku: Sku, name: String, price: Int = 0) {
          def renamed(n: String): Item = copy(@@name = n)
        }

        object Item {
          def apply(sku: Sku): Item = new Item(sku, "", 0)
        }

        object Use {
          val one = @@Item(@@Sku("a"))
          val three = @@Item(Sku("b"), "x", 3)
          val field = one.@@sku.@@value
          val typed: @@Item = one
          val made = @@Item.apply(Sku("c"))
          def check(i: Item) = i match {
            case @@Item(s, _, _) => s.@@value
          }
        }
        """
    ])
    #expect(p.exact("name") == "src/main/scala/a/Item.scala:5")
    #expect(p.exact("Item") == "src/main/scala/a/Item.scala:10")
    #expect(p.exact("Sku") == "src/main/scala/a/Item.scala:3")
    #expect(p.exact("Item2") == "src/main/scala/a/Item.scala:5")
    #expect(p.exact("sku") == "src/main/scala/a/Item.scala:5")
    #expect(p.exact("value") == "src/main/scala/a/Item.scala:3")
    #expect(p.exact("Item3") == "src/main/scala/a/Item.scala:5")
    #expect(p.exact("Item4") == "src/main/scala/a/Item.scala:9")
    #expect(p.exact("Item5") == "src/main/scala/a/Item.scala:5")
    #expect(p.exact("value2") == "src/main/scala/a/Item.scala:3")
  }

  @Test func packagesImportsAndPackageObjects() throws {
    let p = try Project([
      main + "org/acme/core/Money.scala": """
        package org.acme
        package core

        final case class Money(cents: Long)
        object Money { val zero: Money = Money(0) }
        """,
      main + "org/acme/package.scala": """
        package org

        package object acme {
          type Cents = Long
          def round(m: core.Money): core.Money = m
        }
        """,
      main + "org/acme/app/Main.scala": """
        package org.acme.app

        import org.acme.core.{Money => Cash, *}
        import org.acme.@@core.Money.zero

        object Main {
          import scala.collection.mutable
          val a: @@Cash = @@zero
          val b: org.acme.@@Cents = 1L
          val c = org.acme.@@round(Money.zero)
          val buffer = mutable.@@ListBuffer.empty[Int]
        }
        """,
      main + "org/acme/Other.scala": """
        package org.acme

        object Other {
          val r = @@round(core.Money.zero)
        }
        """,
    ])
    #expect(p.exact("core") == "package:org.acme.core:1")
    #expect(p.exact("Cash") == "src/main/scala/org/acme/core/Money.scala:4")
    #expect(p.exact("zero") == "src/main/scala/org/acme/core/Money.scala:5")
    #expect(p.exact("Cents") == "src/main/scala/org/acme/package.scala:4")
    #expect(p.exact("round") == "src/main/scala/org/acme/package.scala:5")
    #expect(p.exact("round2") == "src/main/scala/org/acme/package.scala:5")
    #expect(p.exact("ListBuffer")?.hasPrefix("sdk:") == true)
  }

  @Test func enumsEndMarkersAndIndentation() throws {
    let p = try Project([
      main + "a/Status.scala": """
        package a

        enum Status:
          case Todo
          case Done(note: String)

          def isDone: Boolean = this match
            case @@Done(_) => true
            case _ => false
        end @@Status

        object Status:
          def parse(s: String): Status = if s == "todo" then Status.@@Todo else @@Done(s)

        def use(s: Status) = s match
          case Status.Done(n) => n.@@length
          case other => other.@@isDone.toString
        """
    ])
    #expect(p.exact("Done") == "src/main/scala/a/Status.scala:5")
    #expect(p.exact("Status") == "src/main/scala/a/Status.scala:3")
    #expect(p.exact("Todo") == "src/main/scala/a/Status.scala:4")
    #expect(p.exact("Done2") == "src/main/scala/a/Status.scala:5")
    #expect(p.exact("length") != nil)
    #expect(p.exact("isDone") == "src/main/scala/a/Status.scala:7")
  }

  @Test func traitsLinearizationAndSuper() throws {
    let p = try Project([
      main + "a/T.scala": """
        package a

        trait Named { def name: String = "named"; def tag: String = "n" }
        trait Labelled extends Named { override def name: String = "labelled" }
        class Thing extends Named with Labelled {
          def both = super.@@tag + @@name
        }
        object Use { def f(t: Thing) = t.@@name }
        """
    ])
    #expect(p.exact("tag") == "src/main/scala/a/T.scala:3")
    #expect(p.exact("name") == "src/main/scala/a/T.scala:4")
    #expect(p.exact("name2") == "src/main/scala/a/T.scala:4")
  }
}

@Suite struct ScalaTypes {
  @Test func inferenceThroughChainsLambdasAndStub() throws {
    let p = try Project([
      main + "a/A.scala": """
        package a

        case class Point(x: Int, y: Int) { def norm: Int = x * x + y * y }

        object Use {
          val points = List(Point(1, 2), Point(3, 4))
          val first = points.head.@@norm
          val xs = points.map(_.@@x)
          val ys = points.map(p => p.@@y)
          val maybe: Option[Point] = points.headOption
          val n = maybe.map(_.norm).getOrElse(0)
          val pairs = points.zipWithIndex.map { case (pt, i) => pt.@@x + i }
          val grouped = points.groupBy(_.x).values.map(_.head.@@y)
          for {
            pt <- points
            if pt.@@x > 0
          } yield pt.@@norm
          println(@@n)
        }
        """
    ])
    #expect(p.exact("norm") == "src/main/scala/a/A.scala:3")
    #expect(p.exact("x") == "src/main/scala/a/A.scala:3")
    #expect(p.exact("y") == "src/main/scala/a/A.scala:3")
    #expect(p.exact("x2") == "src/main/scala/a/A.scala:3")
    #expect(p.exact("y2") == "src/main/scala/a/A.scala:3")
    #expect(p.exact("x3") == "src/main/scala/a/A.scala:3")
    #expect(p.exact("norm2") == "src/main/scala/a/A.scala:3")
    #expect(p.exact("n") == "src/main/scala/a/A.scala:11")
  }

  @Test func extensionsAndImplicitClasses() throws {
    let p = try Project([
      main + "a/Ext.scala": """
        package a

        case class Box[A](value: A)

        extension [A](box: Box[A])
          def get: A = box.value
          def twice: List[A] = List(box.value, box.value)

        object Syntax {
          implicit class RichString(s: String) {
            def shout: String = s.toUpperCase + "!"
          }
        }
        """,
      main + "b/Use.scala": """
        package b

        import a.*
        import a.Syntax.*

        case class P(name: String)

        object Use {
          val b = Box(P("x"))
          val name = b.@@get.@@name
          val loud = "hi".@@shout
          val all = b.@@twice.head.name
        }
        """,
      main + "c/NoImport.scala": """
        package c

        object NoImport { val s = "hi".@@shout }
        """,
    ])
    #expect(p.exact("get") == "src/main/scala/a/Ext.scala:6")
    #expect(p.exact("name") == "src/main/scala/b/Use.scala:6")
    #expect(p.exact("shout") == "src/main/scala/a/Ext.scala:11")
    #expect(p.exact("twice") == "src/main/scala/a/Ext.scala:7")
    // Not imported there: not an answer.
    #expect(p.answer("shout2").state == .unknown)
  }

  @Test func implicitConversionsStayUnknown() throws {
    let p = try Project([
      main + "a/A.scala": """
        package a

        import scala.language.implicitConversions

        class Rich(val n: Int) { def doubled: Int = n * 2 }
        class Plain(val n: Int)

        object Conversions {
          implicit def toRich(p: Plain): Rich = new Rich(p.n)
          def use(p: Plain) = p.@@doubled
        }
        """
    ])
    #expect(p.answer("doubled").state == .unknown)
  }

  @Test func javaInTheSameProject() throws {
    let p = try Project([
      "project/src/main/java/a/Barcode.java": """
        package a;

        public final class Barcode {
          private final String digits;
          public Barcode(String digits) { this.digits = digits; }
          public String getDigits() { return digits; }
          public static Barcode of(String digits) { return new Barcode(digits); }
        }
        """,
      main + "a/Use.scala": """
        package a

        object Use {
          val code = @@Barcode.@@of("123")
          val digits = code.@@getDigits.@@length
        }
        """,
    ])
    #expect(p.exact("Barcode") == "src/main/java/a/Barcode.java:3")
    #expect(p.exact("of") == "src/main/java/a/Barcode.java:7")
    #expect(p.exact("getDigits") == "src/main/java/a/Barcode.java:6")
    #expect(p.exact("length") != nil)
  }
}

@Suite struct ScalaEditing {
  @Test func referencesThroughRenamesAndInterpolation() throws {
    let p = try Project([
      main + "a/A.scala": """
        package a

        class @@Warehouse(val name: String) {
          override def toString: String = s"warehouse $@@name"
        }
        """,
      main + "b/B.scala": """
        package b

        import a.{Warehouse => Site}

        object B {
          def make(): Site = new Site("main")
          def label(w: a.Warehouse): String = s"${w.name}"
        }
        """,
    ])
    #expect(p.references("Warehouse") == ["src/main/scala/a/A.scala:3", "src/main/scala/b/B.scala:3", "src/main/scala/b/B.scala:6", "src/main/scala/b/B.scala:7"])
    #expect(p.references("name") == ["src/main/scala/a/A.scala:3", "src/main/scala/a/A.scala:4", "src/main/scala/b/B.scala:7"])
  }

  @Test func completion() throws {
    let p = try Project([
      main + "a/A.scala": """
        package a

        case class Point(x: Int, y: Int) { def norm: Int = x * x + y * y }

        object Use {
          val point = Point(1, 2)
          val shown = point.@@no
          val longName = 3
          def f = lon@@
          val xs = List(point).@@he
        }
        """
    ])
    #expect(p.complete("no", typed: 2).contains("norm"))
    #expect(p.complete("no").contains("x"))
    #expect(p.complete("").contains("longName"))
    #expect(p.complete("he", typed: 2).contains("head"))
    #expect(p.complete("he", typed: 2).contains("headOption"))
  }

  @Test func completionInStringsSelectorsEnumsAndCopy() throws {
    let p = try Project([
      main + "a/util/Ext.scala": "package a.util\n\nextension (s: String) def shout: String = s.toUpperCase\n",
      main + "a/B.scala": """
        package a

        import a.util.{@@sh}

        enum Color:
          case Red, Green

        object Color:
          def parse(s: String): Color = Red

        case class Box(width: Int, height: Int)

        object Use:
          val name = "box"
          val text = s"a $@@na"
          val c = Color.@@Gr
          val b = Box(1, 2).copy(@@he = 3)
          def scale(factor: Int): Int =
            @@
          val after = 1
        """,
    ])
    #expect(p.complete("sh", typed: 2).contains("shout"))
    #expect(p.complete("na", typed: 2).contains("name"))
    #expect(p.complete("Gr", typed: 2).contains("Green"))
    #expect(p.complete("he", typed: 2).contains("height"))
    #expect(p.complete("").contains("factor"))
  }

  @Test func details() throws {
    let p = try Project([
      main + "a/A.scala": """
        package a

        /** A point on a plane. */
        case class Point(x: Int, y: Int)

        object Use {
          val @@origin = Point(0, 0)
          def @@norm(p: Point): Int = p.x * p.x
        }
        """
    ])
    #expect(p.detail("origin") == "val origin: Point")
    #expect(p.detail("norm") == "def norm(p: Point): Int")
  }
}

@Suite struct ScalaLayouts {
  @Test func sbtProjectsAndCrossBuiltFolders() throws {
    let p = try Project(
      [
        "build/build.sbt": """
          lazy val core = project.in(file("core"))
          lazy val app = (project in file("app")).dependsOn(core)
          """,
        "build/core/src/main/scala/c/Core.scala": "package c\n\nobject Core { def answer: Int = 42 }\n",
        "build/core/src/main/scala-2.13/c/Compat.scala": "package c\n\nobject Compat { def old: Int = 1 }\n",
        "build/app/src/main/scala/app/Main.scala": """
          package app

          import c.{Core, Compat}

          object Main { val n = Core.@@answer + Compat.@@old }
          """,
      ], root: "build/app")
    #expect(p.exact("answer") == "sdk:Core.scala:3")
    #expect(p.exact("old") == "sdk:Compat.scala:3")
  }

  @Test func millModules() throws {
    let p = try Project(
      [
        "mill/build.sc": """
          import mill._, scalalib._

          object domain extends ScalaModule {
            def scalaVersion = "3.3.1"
          }
          object app extends ScalaModule {
            def moduleDeps = Seq(domain)
            object test extends ScalaTests
          }
          """,
        "mill/domain/src/d/Task.scala": "package d\n\ncase class Task(title: String)\n",
        "mill/app/src/app/Main.scala": "package app\n\nobject Main { val t = d.Task(\"x\").@@title }\n",
      ], root: "mill/app")
    #expect(p.exact("title") == "sdk:Task.scala:3")
  }
}
