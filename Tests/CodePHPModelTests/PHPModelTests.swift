import CodeModel
import CodePHPModel
import Foundation
import Testing

/// A PHP project in a temporary folder, from file text with `@@` before the word a question is about (`$@@name` for
/// a variable). PHP's own declarations are Code's stub.
private final class Project {
  let root: String
  let model: PHPModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String]) throws {
    let base = NSTemporaryDirectory() + "phpmodel-" + UUID().uuidString
    root = base + "/project"
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
    model = PHPModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), `php:<name>:1` in the stub.
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

@Suite struct Names {
  @Test func variablesParametersAndClosures() throws {
    let project = try Project([
      "a.php": """
        <?php
        function total(array $items, int $tax = 0): int {
          $sum = 0;
          foreach ($items as $key => $item) {
            $sum += $item;
          }
          $add = function ($x) use ($sum) { return $x + $@@sum; };
          $twice = fn ($y) => $y + $@@tax;
          static $calls = 0;
          [$first, $second] = $items;
          return $@@sum + $@@key + $@@first + $@@calls + $@@items + $@@y;
        }
        """
    ])
    #expect(project.exact("sum") == "a.php:7")
    #expect(project.exact("tax") == "a.php:2")
    #expect(project.exact("sum2") == "a.php:3")
    #expect(project.exact("key") == "a.php:4")
    #expect(project.exact("first") == "a.php:10")
    #expect(project.exact("calls") == "a.php:9")
    #expect(project.exact("items") == "a.php:2")
    // Bound only in the arrow function: here it is its own first use.
    #expect(project.exact("y") == "a.php:11")
  }

  @Test func namespacesImportsAndGlobalFallback() throws {
    let project = try Project([
      "src/Model/User.php": """
        <?php
        namespace App\\Model;

        class User {
          public function __construct(public string $name, private ?Address $address = null) {}
          public function address(): ?Address { return $this->address; }
          public static function make(string $name): static { return new static($name); }
        }
        function helper(): int { return 1; }
        const LIMIT = 10;
        """,
      "src/Model/Address.php": """
        <?php
        namespace App\\Model;
        class Address { public string $city = ''; }
        """,
      "src/main.php": """
        <?php
        namespace App;

        use App\\Model\\@@User;
        use App\\Model\\User as Person;
        use function App\\Model\\helper;
        use const App\\Model\\LIMIT;

        $u = new @@User('a');
        $p = @@Person::@@make('b');
        $p->@@address()->@@city;
        $n = @@helper() + @@LIMIT + @@strlen('x');
        $u->@@name;
        """,
    ])
    #expect(project.exact("User") == "src/Model/User.php:4")
    #expect(project.exact("User2") == "src/Model/User.php:4")
    #expect(project.exact("Person") == "src/Model/User.php:4")
    #expect(project.exact("make") == "src/Model/User.php:7")
    #expect(project.exact("address") == "src/Model/User.php:6")
    #expect(project.exact("city") == "src/Model/Address.php:3")
    #expect(project.exact("helper") == "src/Model/User.php:9")
    #expect(project.exact("LIMIT") == "src/Model/User.php:10")
    #expect(project.exact("strlen") == "php:strlen:1")
    #expect(project.exact("name") == "src/Model/User.php:5")
  }

  @Test func composerAutoloadingFindsVendorClasses() throws {
    let project = try Project([
      "composer.json": #"{"autoload": {"psr-4": {"App\\": "src/"}}}"#,
      "vendor/composer/autoload_psr4.php": """
        <?php
        $vendorDir = dirname(__DIR__);
        $baseDir = dirname($vendorDir);
        return array(
            'Acme\\\\Log\\\\' => array($vendorDir . '/acme/log/src'),
            'App\\\\' => array($baseDir . '/src'),
        );
        """,
      "vendor/acme/log/src/Logger.php": """
        <?php
        namespace Acme\\Log;
        class Logger { public function info(string $message): void {} }
        """,
      "src/Service.php": """
        <?php
        namespace App;
        use Acme\\Log\\Logger;
        class Service {
          public function __construct(private Logger $logger) {}
          public function run(): void { $this->@@logger->@@info('x'); }
        }
        """,
    ])
    #expect(project.exact("logger") == "src/Service.php:5")
    #expect(project.exact("info") == "vendor/acme/log/src/Logger.php:3")
  }

  @Test func inheritanceTraitsEnumsAndStatics() throws {
    let project = try Project([
      "a.php": """
        <?php
        interface Shape { public function area(): float; }
        trait Named {
          public function name(): string { return static::class; }
          public function hello(): string { return 'hi'; }
        }
        trait Greets { public function hello(): string { return 'hey'; } }
        abstract class Base implements Shape {
          const SIDES = 0;
          protected static int $count = 0;
          public function describe(): string { return 'base'; }
        }
        final class Square extends Base {
          use Named, Greets { Greets::hello insteadof Named; Named::hello as namedHello; }
          const SIDES = 4;
          public function __construct(private float $side) { self::$@@count++; }
          public function area(): float { return $this->side ** 2; }
          public function describe(): string { return parent::@@describe() . static::@@SIDES . $this->@@hello() . $this->@@namedHello(); }
        }
        enum Suit: string {
          case Hearts = 'H';
          case Spades = 'S';
          public function color(): string { return 'red'; }
        }
        $s = new Square(2);
        $s->@@name();
        $s->@@area();
        Suit::@@Hearts->@@color();
        Suit::@@from('H');
        """
    ])
    #expect(project.exact("count") == "a.php:10")
    #expect(project.exact("describe") == "a.php:11")
    #expect(project.exact("SIDES") == "a.php:15")
    #expect(project.exact("hello") == "a.php:7")
    #expect(project.exact("namedHello") == "a.php:5")
    #expect(project.exact("name") == "a.php:4")
    #expect(project.exact("area") == "a.php:17")
    #expect(project.exact("Hearts") == "a.php:21")
    #expect(project.exact("color") == "a.php:23")
    #expect(project.exact("from") == "php:BackedEnum::from:1")
  }

  @Test func phpDocTypesAndNarrowing() throws {
    let project = try Project([
      "a.php": """
        <?php
        class Node {
          /** @var Node[] */
          public array $children = [];
          /** @var ?Node */
          public $parent;
          public function label(): string { return ''; }
          /** @return static */
          public function self() { return $this; }
        }
        /** @param Node[] $nodes */
        function walk(array $nodes, $other) {
          foreach ($nodes as $node) {
            $node->@@label();
            $node->@@parent->@@label();
          }
          if ($other instanceof Node) {
            $other->@@children;
          }
          /** @var Node $found */
          $found = find();
          $found->@@self()->@@label();
          $other->@@label();
        }
        """
    ])
    #expect(project.exact("label") == "a.php:7")
    #expect(project.exact("parent") == "a.php:6")
    #expect(project.exact("label2") == "a.php:7")
    #expect(project.exact("children") == "a.php:4")
    #expect(project.exact("self") == "a.php:9")
    #expect(project.exact("label3") == "a.php:7")
    // Outside the check, $other's type isn't known: candidates by name.
    #expect(project.answer("label4").state != .exact)
  }

  @Test func magicAndUnknownReceiversAreNotExact() throws {
    let project = try Project([
      "a.php": """
        <?php
        class Magic {
          public function __get($name) { return 1; }
          public function __call($name, $args) { return 2; }
          public function real(): int { return 3; }
        }
        $m = new Magic();
        $m->@@anything;
        $m->@@whatever();
        $m->@@real();
        $x = make();
        $x->@@real();
        """
    ])
    #expect(project.answer("anything").state == .unknown)
    #expect(project.answer("whatever").state == .unknown)
    #expect(project.exact("real") == "a.php:5")
    #expect(project.answer("real2").state == .candidates)
  }

  @Test func includesAndSuperglobals() throws {
    let project = try Project([
      "lib/config.php": "<?php\nreturn ['a' => 1];\n",
      "index.php": """
        <?php
        $config = require __DIR__ . @@'/lib/config.php';
        $host = $@@_SERVER['HTTP_HOST'];
        ?>
        <p><?= $@@config['a'] ?></p>
        """,
    ])
    #expect(project.exact("") == "lib/config.php:1")
    #expect(project.exact("_SERVER") == "php:$_SERVER:1")
    #expect(project.exact("config") == "index.php:2")
  }

  @Test func anonymousClassesAndDocblockWords() throws {
    let project = try Project([
      "a.php": """
        <?php
        class Scalar { public function value(): int { return 1; } }
        class Visitor { public function enter(): void {} }
        function make(): Visitor {
          $v = new class extends Visitor {
            public int $count = 0;
            public function enter(): void { $this->@@count++; }
          };
          $v->@@enter();
          $s = new @@Scalar();
          return $v;
        }
        """
    ])
    #expect(project.exact("count") == "a.php:6")
    #expect(project.exact("enter") == "a.php:7")
    #expect(project.exact("Scalar") == "a.php:2")
  }

  @Test func referencesOfAMethodAndAVariable() throws {
    let project = try Project([
      "a.php": """
        <?php
        class A { public function @@run(): void {} }
        function go(A $a) {
          $a->run();
          $@@b = $a;
          $b->run();
          return $b;
        }
        """
    ])
    #expect(project.references("run") == ["a.php:2", "a.php:4", "a.php:6"])
    #expect(project.references("b") == ["a.php:5", "a.php:6", "a.php:7"])
  }
}

@Suite struct Completion {
  @Test func membersStaticsAndVariables() throws {
    let project = try Project([
      "a.php": """
        <?php
        class Box {
          const SIZE = 1;
          public int $width = 0;
          public static function make(): static { return new static(); }
          public function open(): void {}
          private function secret(): void {}
        }
        function use_box(Box $box, int $count) {
          $box->@@op;
          Box::@@m;
          $@@co;
        }
        """
    ])
    let members = project.complete("op", typed: 0)
    #expect(members.context == .member)
    #expect(members.names.contains("open") && members.names.contains("width") && !members.names.contains("SIZE"))
    let statics = project.complete("m")
    #expect(statics.names.contains("make") && statics.names.contains("SIZE") && !statics.names.contains("open"))
    let variables = project.complete("co", typed: 2)
    #expect(variables.names.first == "count")
  }

  @Test func detailsOfAMethodAndALocal() throws {
    let project = try Project([
      "a.php": """
        <?php
        namespace App;
        class Repo {
          /** Finds one. */
          public function find(int $id): ?Repo { return null; }
        }
        $r = new Repo();
        $r->@@find(1);
        $@@r;
        """
    ])
    let method = try #require(project.details("find"))
    #expect(method.declaration == "public function find(int $id): ?Repo")
    #expect(method.documentation == "Finds one.")
    #expect(method.parents.map(\.name) == ["Repo", "App"])
    let local = try #require(project.details("r"))
    #expect(local.declaration == "Repo $r")
  }
}
