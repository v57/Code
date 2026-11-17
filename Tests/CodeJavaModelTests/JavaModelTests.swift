import CodeJavaModel
import CodeModel
import Foundation
import Testing

/// A Java project in a temporary folder, from file text with `@@` before the word a question is about. The platform
/// is the built-in stub, so the tests don't depend on a JDK or Android SDK being installed.
private final class Project {
  let root: String
  let model: JavaModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String], root folder: String = "project") throws {
    let base = NSTemporaryDirectory() + "javamodel-" + UUID().uuidString
    root = base + "/" + folder
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
          marks[key] = (base + "/" + name, number, character)
          rest.removeSubrange(mark)
        }
        body += rest + "\n"
      }
      let url = URL(fileURLWithPath: base + "/" + name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try body.write(to: url, atomically: true, encoding: .utf8)
    }
    model = JavaModel(root: root, findsPlatform: false)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the root, `jdk:<name>` in the stub.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
  }

  func exact(_ key: String) -> String? {
    let found = answer(key)
    return found.state == .exact ? found.places.first : nil
  }

  /// The lines a name's references are on, as `path:line`.
  func references(_ key: String) -> [String] {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return model.references(of: found).map { "\($0.path):\($0.line)" }.sorted()
  }

  /// What completes at a mark with `typed` characters of its word typed (the mark's word is the file's text there).
  func complete(_ key: String, typed: Int = 0) -> (context: ModelCompletionContext, names: [String]) {
    let mark = marks[key]!
    let list = model.complete(path: mark.path, line: mark.line, character: mark.character + typed, limit: 300)
    return (list.context, list.items.map(\.name))
  }
}

@Suite struct Names {
  @Test func localsParametersFieldsAndShadowing() throws {
    let p = try Project([
      "project/src/main/java/a/A.java": """
        package a;
        public class A {
          int count;
          int f(int count) {
            int total = @@count + this.@@count;
            for (int i = 0; i < 3; i++) { total += @@i; }
            for (var item : java.util.List.of(1, 2)) { total += @@item; }
            return @@total;
          }
          int g() { return @@count; }
        }
        """
    ])
    #expect(p.exact("count") == "src/main/java/a/A.java:4")
    #expect(p.exact("count2") == "src/main/java/a/A.java:3")
    #expect(p.exact("i") == "src/main/java/a/A.java:6")
    #expect(p.exact("item") == "src/main/java/a/A.java:7")
    #expect(p.exact("total") == "src/main/java/a/A.java:5")
    #expect(p.exact("count3") == "src/main/java/a/A.java:3")
  }

  @Test func importsPackagesAndJavaLang() throws {
    let p = try Project([
      "project/src/main/java/a/b/Util.java": """
        package a.b;
        public class Util {
          public static final int LIMIT = 3;
          public static int twice(int x) { return x * 2; }
          public static class Inner {}
        }
        """,
      "project/src/main/java/a/b/Other.java": """
        package a.b;
        class Other {}
        """,
      "project/src/main/java/c/Main.java": """
        package c;
        import @@a.@@b.@@Util;
        import a.b.*;
        import static a.b.Util.twice;
        import static a.b.Util.*;
        class Main {
          @@Util.@@Inner inner;
          @@String name;
          int run() { return @@twice(@@LIMIT); }
          @@Other other;
          java.util.@@List<String> names;
        }
        """,
    ])
    #expect(p.exact("a") == "package:a:0")
    #expect(p.exact("b") == "package:a.b:0")
    #expect(p.exact("Util") == "src/main/java/a/b/Util.java:2")
    #expect(p.exact("Util2") == "src/main/java/a/b/Util.java:2")
    #expect(p.exact("Inner") == "src/main/java/a/b/Util.java:5")
    #expect(p.exact("String") == "jdk:java.lang.String:1")
    #expect(p.exact("twice") == "src/main/java/a/b/Util.java:4")
    #expect(p.exact("LIMIT") == "src/main/java/a/b/Util.java:3")
    #expect(p.exact("Other") == "src/main/java/a/b/Other.java:2")
    #expect(p.exact("List") == "jdk:java.util.List:1")
  }

  @Test func nestedInnerAndLocalClasses() throws {
    let p = try Project([
      "project/src/Outer.java": """
        class Outer {
          int field;
          class Inner {
            int read() { return @@field; }
          }
          static class Nested { static int value; }
          int f() {
            class Local { int x; }
            @@Local local = new @@Local();
            return local.@@x + @@Nested.@@value + new Outer.@@Nested().hashCode();
          }
        }
        """
    ])
    #expect(p.exact("field") == "src/Outer.java:2")
    #expect(p.exact("Local") == "src/Outer.java:8")
    #expect(p.exact("Local2") == "src/Outer.java:8")
    #expect(p.exact("x") == "src/Outer.java:8")
    #expect(p.exact("Nested") == "src/Outer.java:6")
    #expect(p.exact("value") == "src/Outer.java:6")
    #expect(p.exact("Nested2") == "src/Outer.java:6")
  }
}

@Suite struct Types {
  @Test func inheritanceInterfacesAndDefaultMethods() throws {
    let p = try Project([
      "project/src/Shapes.java": """
        interface Shape {
          double area();
          default String describe() { return "shape"; }
        }
        abstract class Base implements Shape {
          protected String name;
          void rename(String to) { name = to; }
        }
        class Square extends Base {
          double side;
          public double area() { return side * side; }
          void use(Square other, Shape any) {
            other.@@rename("x");
            other.@@describe();
            any.@@area();
            other.@@area();
            this.@@name.@@length();
            super.@@rename("y");
          }
        }
        """
    ])
    #expect(p.exact("rename") == "src/Shapes.java:7")
    #expect(p.exact("describe") == "src/Shapes.java:3")
    #expect(p.exact("area") == "src/Shapes.java:2")
    #expect(p.exact("area2") == "src/Shapes.java:11")
    #expect(p.exact("name") == "src/Shapes.java:6")
    #expect(p.exact("length") == "jdk:java.lang.String.length(0):1")
    #expect(p.exact("rename2") == "src/Shapes.java:7")
  }

  @Test func overloadsByCountAndArgumentTypes() throws {
    let p = try Project([
      "project/src/O.java": """
        class O {
          void put(int x) {}
          void put(String s) {}
          void put(int x, int y) {}
          void put(Object o) {}
          void run(long n, StringBuilder sb) {
            @@put(1);
            @@put("a");
            @@put(1, 2);
            @@put(sb);
            @@put(sb.toString());
            sb.@@append(n);
            sb.@@append("x").@@append(1.5);
          }
        }
        """
    ])
    #expect(p.exact("put") == "src/O.java:2")
    #expect(p.exact("put2") == "src/O.java:3")
    #expect(p.exact("put3") == "src/O.java:4")
    #expect(p.exact("put4") == "src/O.java:5")
    #expect(p.exact("put5") == "src/O.java:3")
    #expect(p.exact("append") == "jdk:java.lang.StringBuilder.append(1):1")
    #expect(p.answer("append3").places.first == "jdk:java.lang.StringBuilder.append(1):1")
  }

  @Test func genericsBoundsAndInference() throws {
    let p = try Project([
      "project/src/G.java": """
        import java.util.*;
        class Box<T extends CharSequence> {
          T value;
          T get() { return value; }
          int size() { return value.@@length(); }
        }
        class G {
          void f(Box<String> box, Map<String, List<Integer>> map) {
            box.get().@@isEmpty();
            map.get("a").get(0).@@intValue();
            for (Map.Entry<String, List<Integer>> e : map.entrySet()) { e.getValue().@@size(); }
            var copy = new ArrayList<>(map.keySet());
            copy.get(0).@@trim();
            Optional.of("x").map(s -> s.@@length()).orElse(0).@@compareTo(1);
          }
        }
        """
    ])
    #expect(p.exact("length") == "jdk:java.lang.CharSequence.length(0):1")
    #expect(p.exact("isEmpty") == "jdk:java.lang.String.isEmpty(0):1")
    #expect(p.exact("intValue") == "jdk:java.lang.Integer.intValue(0):1")
    #expect(p.exact("size") == "jdk:java.util.Collection.size(0):1")
    #expect(p.exact("trim") == "jdk:java.lang.String.trim(0):1")
    #expect(p.exact("length2") == "jdk:java.lang.String.length(0):1")
    #expect(p.exact("compareTo") == "jdk:java.lang.Integer.compareTo(1):1")
  }

  @Test func recordsEnumsAndSealedTypes() throws {
    let p = try Project([
      "project/src/R.java": """
        sealed interface Shape permits Circle, @@Rect {}
        record Circle(double radius) implements Shape {}
        record Rect(double w, double h) implements Shape {
          double area() { return @@w * h; }
        }
        enum Color {
          RED, GREEN;
          Color next() { return @@GREEN; }
        }
        class R {
          double f(Circle c, Color color) {
            if (c.@@radius() > 1 && color == Color.@@RED) return color.@@ordinal();
            return switch (color) { case @@RED -> 1; case GREEN -> 2; };
          }
        }
        """
    ])
    #expect(p.exact("Rect") == "src/R.java:3")
    #expect(p.exact("w") == "src/R.java:3")
    #expect(p.exact("GREEN") == "src/R.java:7")
    #expect(p.exact("radius") == "src/R.java:2")
    #expect(p.exact("RED") == "src/R.java:7")
    #expect(p.exact("ordinal") == "jdk:java.lang.Enum.ordinal(0):1")
  }

  @Test func lambdasMethodReferencesAndAnonymousClasses() throws {
    let p = try Project([
      "project/src/L.java": """
        import java.util.*;
        import java.util.function.*;
        class L {
          static int parse(String s) { return 0; }
          void f(List<String> names) {
            names.forEach(n -> n.@@trim());
            Function<String, Integer> length = s -> s.@@length();
            BiFunction<String, String, Boolean> same = (a, b) -> a.@@equals(b);
            names.stream().map(L::@@parse).forEach(i -> i.@@byteValue());
            Runnable r = new Runnable() {
              int calls;
              public void run() { @@calls++; }
            };
            r.@@run();
          }
        }
        """
    ])
    #expect(p.exact("trim") == "jdk:java.lang.String.trim(0):1")
    #expect(p.exact("length") == "jdk:java.lang.String.length(0):1")
    #expect(p.exact("equals") == "jdk:java.lang.String.equals(1):1")
    #expect(p.exact("parse") == "src/L.java:4")
    #expect(p.exact("byteValue") == "jdk:java.lang.Number.byteValue(0):1")
    #expect(p.exact("calls") == "src/L.java:11")
    #expect(p.exact("run") == "jdk:java.lang.Runnable.run(0):1")
  }

  @Test func annotations() throws {
    let p = try Project([
      "project/src/N.java": """
        @interface Tag { String value(); int level() default 0; }
        class N {
          @@@Tag(@@level = 2, value = "x") int a;
          @@@Override public String toString() { return ""; }
        }
        """
    ])
    #expect(p.exact("Tag") == "src/N.java:1")
    #expect(p.exact("level") == "src/N.java:1")
    #expect(p.exact("Override") == "jdk:java.lang.Override:1")
  }
}

@Suite struct Builds {
  @Test func gradleModulesAndIncludedBuilds() throws {
    let p = try Project(
      [
        "app/settings.gradle.kts": """
          rootProject.name = "app"
          include("core", "cli")
          includeBuild("../lib")
          """,
        "app/core/src/main/java/app/core/Engine.java": """
          package app.core;
          public class Engine { public void start() {} }
          """,
        "app/cli/src/main/java/app/cli/Main.java": """
          package app.cli;
          import app.core.@@Engine;
          import lib.@@Helper;
          class Main { void f(Engine e) { e.@@start(); Helper.@@help(); } }
          """,
        "lib/settings.gradle": "include 'tools'",
        "lib/tools/src/main/java/lib/Helper.java": """
          package lib;
          public class Helper { public static void help() {} }
          """,
      ], root: "app/cli")
    #expect(p.exact("Engine") == "../core/src/main/java/app/core/Engine.java:2")
    #expect(p.exact("start") == "../core/src/main/java/app/core/Engine.java:2")
    #expect(p.exact("Helper") == "../../lib/tools/src/main/java/lib/Helper.java:2")
    #expect(p.exact("help") == "../../lib/tools/src/main/java/lib/Helper.java:2")
  }

  @Test func mavenModules() throws {
    let p = try Project(
      [
        "m/pom.xml": """
          <project><modules><module>api</module><module>web</module></modules></project>
          """,
        "m/api/pom.xml": "<project><build><sourceDirectory>src</sourceDirectory></build></project>",
        "m/api/src/m/api/Api.java": """
          package m.api;
          public interface Api { int call(); }
          """,
        "m/web/src/main/java/m/web/Web.java": """
          package m.web;
          class Web { int f(m.api.@@Api api) { return api.@@call(); } }
          """,
      ], root: "m/web")
    #expect(p.exact("Api") == "../api/src/m/api/Api.java:2")
    #expect(p.exact("call") == "../api/src/m/api/Api.java:2")
  }
}

@Suite struct Answers {
  @Test func unknownRatherThanWrong() throws {
    let p = try Project([
      "project/src/U.java": """
        import com.missing.Thing;
        class U {
          void f(Thing t, Object o) {
            t.@@frob();
            ((String) o).@@trim();
            @@nothing();
          }
          void g(int a) {}
          void h() { @@g(1, 2); }
        }
        """
    ])
    #expect(p.answer("frob").state == .unknown)
    #expect(p.exact("trim") == "jdk:java.lang.String.trim(0):1")
    #expect(p.answer("nothing").state == .unknown)
    #expect(p.answer("g").state == .candidates)
  }

  @Test func referencesAcrossFiles() throws {
    let p = try Project([
      "project/src/p/A.java": """
        package p;
        public class A { public void @@go() {} void go(int x) {} }
        """,
      "project/src/p/B.java": """
        package p;
        class B {
          void f(A a) {
            a.go();
            a.go(1);
            new A().go();
          }
        }
        """,
    ])
    #expect(p.references("go") == ["src/p/A.java:2", "src/p/B.java:4", "src/p/B.java:6"])
  }

  @Test func detailsOfAMethod() throws {
    let p = try Project([
      "project/src/D.java": """
        package d;
        class D {
          /** Adds one. */
          static int inc(int x) { return x + 1; }
          int f() { return @@inc(1); }
        }
        """
    ])
    let mark = p.marks["inc"]!
    let found = p.model.details(path: mark.path, line: mark.line, character: mark.character)
    #expect(found.details.first?.declaration == "static int inc(int x)")
    #expect(found.details.first?.documentation == "Adds one.")
    #expect(found.details.first?.parents.map(\.name) == ["D", "d"])
  }
}

@Suite struct Completion {
  @Test func membersScopeTypesAndPackages() throws {
    let p = try Project([
      "project/src/C.java": """
        import java.@@util.List;
        class C {
          int counter;
          void f(String text, List<String> items) {
            text.@@trim();
            items.@@size();
            @@counter++;
            Integer.@@parseInt("1");
            List<@@String> other;
          }
        }
        """
    ])
    #expect(p.complete("trim").names.contains("trim"))
    #expect(p.complete("trim", typed: 2).names.first == "trim")
    #expect(p.complete("size", typed: 1).names.contains("size"))
    #expect(p.complete("counter", typed: 3).names.first == "counter")
    #expect(p.complete("parseInt", typed: 5).names.first == "parseInt")
    #expect(!p.complete("parseInt", typed: 1).names.contains("intValue"))
    #expect(p.complete("String", typed: 3).names.contains("String"))
    #expect(p.complete("util", typed: 1).names.contains("util"))
  }
}
