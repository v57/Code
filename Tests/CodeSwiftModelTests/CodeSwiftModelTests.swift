import CodeScan
import Foundation
import Testing

@testable import CodeSwiftModel

/// A package in a temporary folder, from file text with `@@` where the question is.
private final class Package {
  let root: String
  let model: Model
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String], useSDK: Bool = false) throws {
    // In a folder of its own: siblings of the root are where imports get looked for.
    root = NSTemporaryDirectory() + "swiftmodel-" + UUID().uuidString + "/package"
    for (name, text) in files {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "@@") {
          let character = rest.distance(from: rest.startIndex, to: mark.lowerBound)
          let after = rest[mark.upperBound...]
          let word = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
          marks[word] = (root + "/" + name, number, character)
          rest.removeSubrange(mark)
        }
        body += rest + "\n"
      }
      let url = URL(fileURLWithPath: root + "/" + name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try body.write(to: url, atomically: true, encoding: .utf8)
    }
    model = Model(project: Project(root: root, useSDK: useSDK))
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  func answer(_ word: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[word]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
  }
}

private func unit(_ text: String) -> CodeSwiftModel.Unit {
  CodeSwiftModel.Unit(path: "x.swift", source: SourceFile(text, profile: LexProfile.profile(forLanguage: "swift")!))
}

@Suite struct Declarations {
  @Test func access() {
    let file = unit("public struct A { private(set) var a = 1; fileprivate func b() {}; public var c: Int }\nextension A { func d() {} }\npublic extension A { func e() {} }")
    func decl(_ text: String) -> Decl { file.decls.first { $0.name == hashName(text) && $0.kind != .extensionDecl }! }
    #expect(decl("A").access == .isPublic)
    // `private(set)` says nothing about reading.
    #expect(decl("a").access == .inherited)
    #expect(decl("b").access == .filePrivate)
    #expect(decl("c").access == .isPublic)
    #expect(decl("d").access == .inherited)
    #expect(decl("e").access == .isPublic)
  }

  @Test func protocolAndEnumMembersTakeTheirAccess() {
    let file = unit("public protocol P { func a() }\npublic enum E { case b }")
    #expect(file.decls.first { $0.name == hashName("a") }!.access == .isPublic)
    #expect(file.decls.first { $0.name == hashName("b") }!.access == .isPublic)
  }

  @Test func genericClosersInOneToken() {
    let file = unit("var a: Array<Array<Int>>? = nil\nfunc b(x: [Int: Array<Int>]) -> Array<Array<Int>>? { nil }\nvar c = 1")
    #expect(file.decls.map(\.name) == ["a", "b", "c"].map(hashName))
    #expect(file.decls[1].paramCount == 1)
    #expect(file.decls[1].bodyOpen > 0)
  }

  @Test func branchesNotTakenAreSkipped() {
    let file = unit("#if os(iOS)\nfunc a() {}\n#elseif os(macOS)\nfunc b() {}\n#else\nfunc c() {}\n#endif\nfunc d() {}")
    #expect(file.decls.map(\.name) == ["b", "d"].map(hashName))
  }

  @Test func bracesSplitAcrossBranchesCountOnce() {
    let file = unit("struct S {\n#if os(macOS)\nfunc a() {\n#else\nfunc a(x: Int) {\n#endif\n}\nfunc b() {}\n}\nfunc c() {}")
    #expect(file.decls.filter { $0.parent < 0 }.map(\.name) == ["S", "c"].map(hashName))
  }

  @Test func shapeHoldsThroughABodyEdit() {
    let a = unit("func f(x: Int) -> Int { x }\nvar g: Int { 1 }")
    let b = unit("func f(x: Int) -> Int { x + 1 + 2 }\nvar g: Int { 2 }")
    let c = unit("func f(x: String) -> Int { 1 }\nvar g: Int { 1 }")
    let d = unit("func f(x: Int) -> Int { x }\nvar g: Int { 1 }\nfunc h() {}")
    #expect(a.shape == b.shape)
    #expect(a.shape != c.shape)
    #expect(a.shape != d.shape)
  }

  @Test func anInferredInitializerIsPartOfTheShape() {
    #expect(unit("var a = 1").shape != unit("var a = \"x\"").shape)
    #expect(unit("var a: Int = 1").shape == unit("var a: Int = 2").shape)
  }
}

@Suite struct Binding {
  @Test func privateAndInternalInDifferentFiles() throws {
    let package = try Package([
      "Sources/App/A.swift": "private func shared() -> Int { 1 }\nfunc a() { let x: Int = @@shared(); _ = x }",
      "Sources/App/B.swift": "func shared() -> String { \"\" }\nfunc b() { let y: String = @@sharedB(); _ = y }\nfunc sharedB() -> Int { 1 }",
    ])
    #expect(package.answer("shared").places.first?.hasPrefix("Sources/App/A.swift:1") == true)
  }

  @Test func dynamicMemberLookupReachesTheRoot() throws {
    let package = try Package([
      "Sources/App/A.swift": """
        struct Inner { var deep = 1; func method() {} }
        @dynamicMemberLookup struct Wrap<Value> { var own = 0
          subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> Wrap<T> { fatalError() }
        }
        func a(w: Wrap<Inner>) { _ = w.@@deep.@@own }
        """,
    ])
    #expect(package.answer("deep").places == ["Sources/App/A.swift:1"])
    #expect(package.answer("own").places == ["Sources/App/A.swift:2"])
  }

  @Test func aProjectedValueOfALocalOrAPropertyWrapper() throws {
    let package = try Package([
      "Sources/App/A.swift": """
        struct Model { var open = false }
        struct Ref<T> { var bound = 0 }
        @propertyWrapper @dynamicMemberLookup struct Box<Value> {
          var wrappedValue: Value
          var projectedValue: Box<Value> { self }
          subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> Ref<T> { fatalError() }
        }
        struct V {
          @Box var stored: Model
          func body(model: Model) {
            @Box var local = model
            _ = $local.@@open.@@bound
            _ = $stored.@@wrappedValue
          }
        }
        """,
    ])
    #expect(package.answer("open").places == ["Sources/App/A.swift:1"])
    #expect(package.answer("bound").places == ["Sources/App/A.swift:2"])
    #expect(package.answer("wrappedValue").places == ["Sources/App/A.swift:4"])
  }

  @Test func aPrivateFromAnotherFileIsNotSeen() throws {
    let package = try Package([
      "Sources/App/A.swift": "private func only() {}",
      "Sources/App/B.swift": "func b() { @@only() }",
    ])
    #expect(package.answer("only").state == .unknown)
  }

  @Test func ownModuleShadowsAnImportAndQualifiedGoesToIt() throws {
    let package = try Package([
      "Sources/Lib/L.swift": "public func clash() {}",
      "Sources/App/A.swift": "import Lib\nfunc clash() {}\nfunc a() { @@clash()\n  Lib.@@clashTwo() }",
      "Sources/Lib/M.swift": "public func clashTwo() {}",
    ])
    #expect(package.answer("clash").places == ["Sources/App/A.swift:2"])
    #expect(package.answer("clashTwo").places == ["Sources/Lib/M.swift:1"])
  }

  @Test func modulesComeFromTheManifestsTargetFolders() throws {
    let package = try Package([
      "Package.swift": """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "P", targets: [
          .target(name: "Lib", path: "Core/Lib"),
          .target(name: "Net", path: "Core/Network/Channel"),
          .target(name: "App", dependencies: ["Lib", "Net"], path: "App"),
        ])
        """,
      "Core/Lib/L.swift": "public func clash() {}\npublic func clashOne() {}",
      "Core/Network/Channel/C.swift": "public func clashTwo() {}",
      "App/A.swift": "import Lib\nimport Net\nfunc clash() {}\nfunc a() { @@clash()\n  Lib.@@clashOne()\n  Net.@@clashTwo() }",
    ])
    let project = package.model.project
    let names = Set(project.units.prefix(project.projectUnits).compactMap { project.modules[$0.moduleName]?.displayName }.filter { !$0.hasPrefix("<") })
    #expect(names == ["Lib", "Net", "App"])
    #expect(package.answer("clash").places == ["App/A.swift:3"])
    #expect(package.answer("clashOne").places == ["Core/Lib/L.swift:2"])
    #expect(package.answer("clashTwo").places == ["Core/Network/Channel/C.swift:1"])
  }

  @Test func overloadsByLabelAndByLiteral() throws {
    let package = try Package([
      "Sources/App/A.swift": "func a(x: Int) {}\nfunc a(y: Int) {}\nfunc t() { @@a(y: 1) }"
    ])
    #expect(package.answer("a").places == ["Sources/App/A.swift:2"])
    #expect(package.answer("a").state == .exact)
  }

  @Test func aReturnTypePicksByTheNextMember() throws {
    let package = try Package([
      "Sources/App/A.swift":
        "struct P { func only() {} }\nstruct Q { func other() {} }\nfunc make() -> P { P() }\nfunc make(_ v: Int = 0) -> Q { Q() }\nfunc t() { @@make().only() }"
    ])
    #expect(package.answer("make").places == ["Sources/App/A.swift:3"])
    #expect(package.answer("make").state == .exact)
  }

  @Test func aLocalReadsTheOuterInItsOwnInitializer() throws {
    let package = try Package([
      "Sources/App/A.swift": "func t(url: Int) {\n  let url = @@url\n  _ = @@later(url)\n}\nfunc later(_ v: Int) {}"
    ])
    #expect(package.answer("url").places == ["Sources/App/A.swift:1"])
  }

  @Test func guardLetOnOneLineUnwraps() throws {
    let package = try Package([
      "Sources/App/A.swift": "struct S { func m() {} }\nfunc f() -> S? { nil }\nfunc t() {\n  guard let a = f() else { return }\n  a.@@m()\n}"
    ])
    #expect(package.answer("m").places == ["Sources/App/A.swift:1"])
    #expect(package.answer("m").state == .exact)
  }

  @Test func aKeywordAsAnArgumentLabelDoesntEndTheScan() throws {
    let package = try Package([
      "Sources/App/A.swift": "func style(for v: Int) -> Int { v }\nfunc t() {\n  let a = style(for: 1)\n  let later = a\n  _ = @@later\n}"
    ])
    #expect(package.answer("later").places == ["Sources/App/A.swift:4"])
  }

  @Test func chainThroughUnknownStaysUnknown() throws {
    let package = try Package(["Sources/App/A.swift": "func t() { missing().@@member() }"])
    let found = package.answer("member")
    #expect(found.state == .unknown)
    #expect(found.places.isEmpty)
  }

  @Test func aCycleIsUnknownNotAHang() throws {
    let package = try Package(["Sources/App/A.swift": "var a = b\nvar b = a\nfunc t() { a.@@x }"])
    #expect(package.answer("x").state == .unknown)
  }

  @Test func extensionMembersConformancesAndWitnesses() throws {
    let package = try Package([
      "Sources/App/A.swift":
        "protocol P { func m() }\nextension P { func d() {} }\nstruct S: P { func m() {} }\nextension S { func e() {} }\nfunc t(s: S) { s.@@m(); s.@@d(); s.@@e() }"
    ])
    #expect(package.answer("m").places == ["Sources/App/A.swift:3"])
    #expect(package.answer("d").places == ["Sources/App/A.swift:2"])
    #expect(package.answer("e").places == ["Sources/App/A.swift:4"])
  }

  @Test func ifLetUnwrapsAndGuardLeaksToTheBlock() throws {
    let package = try Package([
      "Sources/App/A.swift":
        "struct S { func m() {} }\nfunc t(a: S?) {\n  if let a { a.@@m() }\n  guard let b = a else { return }\n  b.@@mTwo()\n}\nextension S { func mTwo() {} }"
    ])
    #expect(package.answer("m").places == ["Sources/App/A.swift:1"])
    #expect(package.answer("mTwo").places == ["Sources/App/A.swift:7"])
  }

  @Test func implicitMembersFromContext() throws {
    let package = try Package([
      "Sources/App/A.swift":
        "enum E { case a, b }\nfunc f(_ e: E) {}\nfunc t(x: E) -> E {\n  f(.@@a)\n  switch x { case .@@b: break; default: break }\n  return .@@a2\n}\nextension E { static var a2: E { .a } }"
    ])
    #expect(package.answer("a").places == ["Sources/App/A.swift:1"])
    #expect(package.answer("b").places == ["Sources/App/A.swift:1"])
    #expect(package.answer("a2").places == ["Sources/App/A.swift:8"])
  }
}

@Suite struct Findings {
  @Test func aMemberAClosedTypeDoesntHave() throws {
    let package = try Package(["Sources/App/A.swift": "struct S { func m() {} }\nfunc t(s: S) { s.m(); s.nope() }"])
    let found = package.model.allFindings()
    #expect(found.map(\.message) == ["no member 'nope'"])
    #expect(found.first?.line == 2)
  }

  @Test func aPrivateMemberFromAnotherFile() throws {
    let package = try Package([
      "Sources/App/A.swift": "struct S { private func hidden() {} }",
      "Sources/App/B.swift": "func t(s: S) { s.hidden() }",
    ])
    #expect(package.model.allFindings().map(\.message) == ["'hidden' is inaccessible from here"])
  }

  @Test func nothingIsSaidOfAnOpenType() throws {
    let package = try Package(["Sources/App/A.swift": "class C: Missing {}\nfunc t(c: C) { c.anything() }\n@dynamicMemberLookup struct D {}\nfunc u(d: D) { d.anything }"])
    #expect(package.model.allFindings().isEmpty)
  }
}

@Suite struct Edits {
  @Test func aBodyEditKeepsTablesAndASignatureEditRebuilds() throws {
    let package = try Package(["Sources/App/A.swift": "struct S { func m() {} }\nfunc t(s: S) { s.@@m() }"])
    let path = package.marks["m"]!.path
    #expect(package.answer("m").places == ["Sources/App/A.swift:1"])
    let tables = package.model.tables.count
    #expect(tables > 0)
    #expect(package.model.project.update(path: path, text: "struct S { func m() {} }\nfunc t(s: S) { s.m(); s.m() }\n"))
    #expect(package.model.tables.count == tables)
    #expect(package.answer("m").places == ["Sources/App/A.swift:1"])
    // Lines moved but nothing else: the shape holds, and places still come out right.
    #expect(package.model.project.update(path: path, text: "\nstruct S { func m() {} }\nfunc t(s: S) { s.m() }\n"))
    #expect(package.model.place(of: package.model.answer(path: path, line: 2, character: 17).sites[0])?.line == 2)
    // A new signature goes through the tables again.
    #expect(!package.model.project.update(path: path, text: "struct S { func n() {} }\nfunc t(s: S) { s.n() }\n"))
    #expect(package.model.tables.isEmpty)
    #expect(package.model.place(of: package.model.answer(path: path, line: 1, character: 17).sites[0])?.line == 1)
  }
}

/// The benchmark's folder beside this repository (`../Demos/CodeModelBench`), where it's checked out.
private let bench = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Demos/CodeModelBench")

@Suite struct Fixture {
  /// The shared fixture against sourcekit-lsp's answers.
  @Test(.enabled(if: FileManager.default.fileExists(atPath: bench.appendingPathComponent("reference").path)))
  func everyProjectPositionMatchesSourceKit() throws {
    let data = try Data(contentsOf: bench.appendingPathComponent("reference/fixture-sourcekit.json"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let queries = json["queries"] as! [[String: Any]]
    let root = bench.appendingPathComponent("fixture").path
    let model = Model(project: Project(root: root, useSDK: true))
    var wrong: [String] = []
    var projectPositions = 0
    for query in queries {
      let want = (query["definition"] as! [[Any]]).map { "\($0[0]):\($0[1])" }
      guard !want.isEmpty, !want[0].hasPrefix("sdk:") else { continue }
      projectPositions += 1
      let found = model.answer(path: root + "/" + (query["path"] as! String), line: query["line"] as! Int, character: query["character"] as! Int)
      let first = found.sites.first.flatMap { model.place(of: $0) }.map { "\($0.path):\($0.line)" }
      if found.state != .exact || first == nil || !want.contains(first!) { wrong.append("\(query["key"]!) \(found.state) \(first ?? "-") want \(want)") }
    }
    #expect(projectPositions == 25)
    #expect(wrong.isEmpty, "\(wrong)")
  }
}

/// Clang headers as Swift sees them: a made-up framework for the rules, the SDK's Foundation for the whole way through.
@Suite struct Clang {
  private static let header = """
    #import <Foundation/NSObject.h>
    NS_HEADER_AUDIT_BEGIN(nullability, sendability)
    typedef NS_ENUM(NSInteger, FKMode) { FKModeFast, FKModeSlow } API_AVAILABLE(macos(10.0));
    typedef NS_OPTIONS(NSUInteger, FKFlags) { FKFlagsRead = 1 << 0, FKFlagsWrite = 1 << 1 };
    typedef NSString * FKKey NS_TYPED_EXTENSIBLE_ENUM;
    FOUNDATION_EXPORT FKKey const FKKeyName API_AVAILABLE(macos(10.0));
    typedef struct { double x; double y; } FKPoint;
    typedef FKPoint FKPosition;
    typedef const struct CF_BRIDGED_TYPE(NSData) __FKBlob * FKBlobRef;
    FOUNDATION_EXPORT double FKDistance(FKPoint a, FKPoint b);
    typedef unsigned char FKByte;
    typedef unsigned FKWord;
    typedef unsigned long long FKWide;
    typedef long int FKLong;
    NS_SWIFT_SENDABLE
    @interface FKThing : NSObject <NSCopying> {
    @private
        int _hidden;
    }
    @property (class, readonly, strong) FKThing *defaultThing;
    @property (nullable, copy) NSString *title;
    - (BOOL)removeItemAtURL:(NSURL *)URL error:(NSError **)error API_AVAILABLE(macos(10.6));
    - (void)addObject:(id)object;
    - (instancetype)initWithName:(NSString *)name;
    - (nullable instancetype)initWithPath:(NSString *)path;
    - (void)oldThing NS_UNAVAILABLE;
    - (void)renamedThing:(int)a NS_SWIFT_NAME(fresh(value:));
    - (void)notedSelector:(int)a;
    @end
    @interface FKThing (Extras)
    - (NSString *)describe;
    @end
    @protocol FKDelegate <NSObject>
    - (void)thingDidChange:(FKThing *)thing;
    @end
    #if TARGET_OS_IPHONE
    @interface FKPhoneOnly : NSObject
    @end
    #endif
    #ifdef __cplusplus
    namespace fk { int hiddenInNamespace; }
    #else
    FOUNDATION_EXPORT int FKPlainC;
    #endif
    #if defined(__cplusplus) && 1
    class FKCppOnly { };
    #endif
    NS_HEADER_AUDIT_END(nullability, sendability)
    """
  private static let notes = """
    Name: Fake
    Classes:
    - Name: FKThing
      SwiftName: Thing
      Methods:
      - Selector: 'notedSelector:'
        SwiftName: noted(with:)
        MethodKind: Instance
      Properties:
      - Name: title
        SwiftName: heading
    SwiftVersions:
    - Version: 4
      Classes:
      - Name: FKThing
        SwiftName: OldThing
    """

  private func generated() throws -> GeneratedModule {
    let folder = NSTemporaryDirectory() + "swiftmodel-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let headers = folder + "/Fake.framework/Headers"
    try FileManager.default.createDirectory(atPath: headers, withIntermediateDirectories: true)
    try Clang.header.write(toFile: headers + "/Fake.h", atomically: true, encoding: .utf8)
    try Clang.notes.write(toFile: headers + "/Fake.apinotes", atomically: true, encoding: .utf8)
    let importer = ClangImporter(sdk: folder, frameworks: ["Fake": folder + "/Fake.framework", "Foundation": folder + "/None.framework"])
    return try #require(importer.generate("Fake"))
  }

  @Test func classes() throws {
    let text = try generated().text
    #expect(text.contains("public class Thing: NSObject, NSCopying {"))
    #expect(text.contains("public typealias FKThing = Thing"))
    #expect(!text.contains("OldThing"))
    #expect(text.contains("public static var defaultThing: Thing { get }"))
    #expect(text.contains("public static var `default`: Thing { get }"))
    #expect(text.contains("public var heading: String? { get }"))
    #expect(text.contains("public func removeItem(at p0: URL) throws\n"))
    #expect(text.contains("public func add(_ p0: Any)\n"))
    #expect(text.contains("public init(name p0: String)"))
    #expect(!text.contains("oldThing"))
    #expect(text.contains("public func fresh(value p0: Int32)"))
    #expect(text.contains("public func noted(with p0: Int32)"))
    #expect(text.contains("extension Thing {\npublic func describe() -> String"))
    #expect(text.contains("public protocol FKDelegate: NSObjectProtocol {"))
    #expect(text.contains("func thingDidChange(_ p0: Thing)"))
    #expect(!text.contains("FKPhoneOnly"))
    #expect(!text.contains("hiddenInNamespace"))
    #expect(!text.contains("FKCppOnly"))
    #expect(text.contains("public var FKPlainC: Int32 { get }"))
  }

  @Test func valueTypes() throws {
    let text = try generated().text
    #expect(text.contains("public enum FKMode {\ncase fast\ncase slow\n}"))
    #expect(text.contains("public struct FKFlags: OptionSet {"))
    #expect(text.contains("public static var read: FKFlags { get }"))
    #expect(text.contains("public struct FKKey: Hashable, RawRepresentable"))
    #expect(text.contains("extension FKKey { public static var name: FKKey { get } }"))
    #expect(text.contains("public var x: Double"))
    #expect(text.contains("public init(x: Double, y: Double) {}"))
    #expect(text.contains("public typealias FKPosition = FKPoint"))
    #expect(text.contains("FKBlobRef"))
    #expect(text.contains("public init?(path p0: String)"))
    #expect(text.contains("public func FKDistance(_ p0: FKPoint, _ p1: FKPoint) -> Double"))
    // MacTypes' `typedef unsigned char UInt8` is Swift's UInt8, not a CChar.
    #expect(text.contains("public typealias FKByte = UInt8"))
    #expect(text.contains("public typealias FKWord = UInt32"))
    #expect(text.contains("public typealias FKWide = UInt64"))
    #expect(text.contains("public typealias FKLong = Int"))
  }

  @Test func placesAndExports() throws {
    let module = try generated()
    #expect(module.exports == ["Foundation"])
    #expect(module.text.hasPrefix("@_exported import Foundation\n"))
    let lines = module.text.components(separatedBy: "\n")
    let index = try #require(lines.firstIndex { $0.contains("removeItem(at") })
    let headerLine = try #require(Clang.header.components(separatedBy: "\n").firstIndex { $0.contains("removeItemAtURL") })
    #expect(module.lines[index].line == Int32(headerLine + 1))
  }

  private var headerFilesLoaded: (Package) -> Int { { $0.model.project.units.filter { !$0.headerLines.isEmpty }.count } }

  @Test func headersWaitForAMiss() throws {
    let package = try Package(["Sources/App/A.swift": """
      import Foundation
      struct Own { func plain() -> Int { 1 } }
      func f(own: Own, url: URL) {
        _ = own.@@plain()
        _ = url.@@absoluteString
        let lock = @@NSLock()
        _ = lock
      }
      """], useSDK: true)
    // A question about the project, and one the Swift interfaces answer, read no headers.
    #expect(package.answer("plain").state == .exact)
    #expect(package.answer("absoluteString").places.first?.hasPrefix("sdk:Foundation") == true)
    #expect(package.model.clangLoads == 0)
    #expect(headerFilesLoaded(package) == 0)
    #expect(package.answer("NSLock").places.first?.hasPrefix("sdk:Foundation.NSLock.h") == true)
    #expect(package.model.clangLoads == 1)
    #expect(headerFilesLoaded(package) > 0)
  }

  @Test func aMemoizedMissStillLoadsHeaders() throws {
    let package = try Package(["Sources/App/A.swift": """
      import Foundation
      final class Holder {
        var other = NSLock()
        func @@take(_ lock: NSLock) -> Int { 1 }
      }
      func use(_ holder: Holder) {
        _ = holder.@@take(holder.other)
        holder.other.@@lock()
      }
      """], useSDK: true)
    // The first answer is exact, and on the way learns that `other`'s type is unknown. The second must not stop at that.
    #expect(package.answer("take").state == .exact)
    #expect(package.answer("lock").places.first?.hasPrefix("sdk:Foundation.NSLock.h") == true)
  }

  @Test func keyPathsAreNotNamesInScope() throws {
    let package = try Package(["Sources/App/A.swift": """
      func index(_ a: Int) -> Int { a }
      struct Row { let index: Int }
      func f(rows: [Row]) { _ = rows.map(\\.@@index) }
      func helper(_ a: Int) -> Int { a }
      func describe(_ a: Int) -> String { "\\(@@helper(a))" }
      """], useSDK: false)
    #expect(package.answer("index").places.isEmpty)
    // `\\(` opens an interpolation, not a key path.
    #expect(package.answer("helper").state == .exact)
  }

  @Test func foundationEndToEnd() throws {
    let package = try Package(["Sources/App/A.swift": """
      import Foundation
      func f() throws {
        let manager = FileManager.@@default
        try manager.@@removeItem(at: URL(fileURLWithPath: "/"))
        let lock = @@NSLock()
        lock.@@lock()
        let keys: [URLResourceKey] = [.@@isDirectoryKey]
        _ = keys
      }
      """], useSDK: true)
    #expect(package.answer("default").places.first?.hasPrefix("sdk:Foundation.NSFileManager.h") == true)
    #expect(package.answer("removeItem").places.first?.hasPrefix("sdk:Foundation.NSFileManager.h") == true)
    #expect(package.answer("NSLock").places.first?.hasPrefix("sdk:Foundation.NSLock.h") == true)
    #expect(package.answer("lock").places.first?.hasPrefix("sdk:Foundation.NSLock.h") == true)
    #expect(package.answer("isDirectoryKey").places.first?.hasPrefix("sdk:Foundation.NSURL.h") == true)
  }
}

/// What the 2026-11-05 trace of unresolved positions turned up.
@Suite struct Scopes {
  @Test func caseBindingsLastUntilTheNextCase() throws {
    let package = try Package([
      "Sources/App/A.swift": """
      struct S { func foo() {}; func fromIf() {} }
      struct T { func bar() {}; func baz() {} }
      enum E { case a(S), b(T) }
      func t(e: E) {
        let x = T()
        switch e {
        case .a(let x): x.@@foo()
        case .b(let x): x.@@bar()
        default: x.@@baz()
        }
        if case .a(let y) = e { y.@@fromIf() }
      }
      """
    ])
    for word in ["foo", "bar", "baz", "fromIf"] {
      #expect(package.answer(word).state == .exact, "\(word)")
    }
    #expect(package.answer("foo").places.first?.hasSuffix(":1") == true)
    #expect(package.answer("baz").places.first?.hasSuffix(":2") == true)
  }

  @Test func observersAfterAnInitializer() throws {
    let file = unit("struct P { var a = Q() { didSet { } }\nvar b = make { 1 }\nvar c = 1 { willSet { } } }")
    func decl(_ text: String) -> Decl { file.decls.first { $0.name == hashName(text) }! }
    #expect(decl("a").bodyOpen > decl("a").initEnd - 1)
    #expect(decl("b").bodyOpen < 0)
    #expect(decl("c").bodyOpen > 0)

    let package = try Package([
      "Sources/App/A.swift": """
      struct P { var top = 0 }
      struct V {
        var inset = P() {
          didSet { _ = @@oldValue.@@top }
        }
      }
      """
    ])
    #expect(package.answer("oldValue").state == .exact)
    #expect(package.answer("oldValue").places.first?.hasSuffix(":4") == true)
    #expect(package.answer("top").places.first?.hasSuffix(":1") == true)
  }
}

@Suite struct Overloads {
  @Test func failableGenericInitializers() {
    let file = unit("struct D {\ninit?<S: P>(_ x: S) {}\ninit!<S>(y: S) {}\ninit?(z: Int) {}\n}")
    let inits = file.decls.filter { $0.kind == .initializer }
    #expect(inits.map(\.isFailable) == [true, false, true])
    #expect(inits.map(\.paramCount) == [1, 1, 1])
    #expect(inits.map(\.genericCount) == [1, 1, 0])
  }

  @Test func genericConstraintsPickTheOverload() throws {
    let package = try Package(
      [
        "Sources/App/A.swift": """
        protocol Text {}
        protocol Whole {}
        struct Str: Text {}
        struct Num {
          init(_ raw: Builtin::Int64) {}
          init<W>(_ whole: W) where W: Whole {}
          init?<S: Text>(_ text: S) {}
        }
        func t() {
          _ = @@Num(Str()).@@map { $0 }
        }
        """
      ], useSDK: true)
    #expect(package.answer("Num").state == .exact)
    #expect(package.answer("Num").places.contains { $0.hasSuffix("A.swift:7") })
    #expect(package.answer("map").places.first?.hasPrefix("sdk:Swift") == true)
  }

  @Test func anOwnInitializerDoesntHideAnInheritedOverload() throws {
    let package = try Package(
      [
        "Sources/App/A.swift": """
        protocol Parsed {}
        extension Parsed {
          init?(_ text: String) { nil }
          init?<S: StringProtocol>(_ text: S, radix: Int = 10) { nil }
        }
        struct Num: Parsed {
          init(_ small: Int8) {}
        }
        func t(s: String) {
          _ = @@Num(s)
        }
        """
      ], useSDK: true)
    #expect(package.answer("Num").state == .exact)
    #expect(package.answer("Num").places.contains { $0.hasSuffix("A.swift:3") })
  }

  @Test func aLocalFunctionsReturnTypeIsntCalled() throws {
    let package = try Package([
      "Sources/App/A.swift": """
      struct U { init(x: () -> Void) {} }
      func t() {
        func f() -> @@U { U(x: {}) }
        _ = [1].map { _ in f() }
      }
      """
    ])
    #expect(package.answer("U").places == ["Sources/App/A.swift:1"])
  }

  @Test func arrayCalledWithNoElements() throws {
    let package = try Package(
      ["Sources/App/A.swift": "func t() {\n  var bytes = [UInt8]()\n  bytes.@@append(contentsOf: [1])\n}"], useSDK: true)
    #expect(package.answer("append").state != .unknown)
    #expect(package.answer("append").places.first?.hasPrefix("sdk:Swift") == true)
  }

  @Test func aModuleInTheMiddleOfATypePath() throws {
    let package = try Package([
      "Sources/App/A.swift": """
      struct A { struct B { func m() {} } }
      func t(x: A.App::B) { x.@@m() }
      """
    ])
    #expect(package.answer("m").state == .exact)
  }

  @Test func anArgumentTypeThroughAnImplicitInit() throws {
    let package = try Package(
      [
        "Sources/App/A.swift": """
        import Foundation
        let parsed = try? AttributedString(markdown: "", options: .@@init(interpretedSyntax: .@@inlineOnlyPreservingWhitespace))
        """
      ], useSDK: true)
    #expect(package.answer("init").places.first?.hasPrefix("sdk:Foundation") == true)
    #expect(package.answer("inlineOnlyPreservingWhitespace").places.first?.hasPrefix("sdk:Foundation") == true)
  }
}

/// What's offered where a name is being typed: the text is cut at `@@`, as the question's position.
@Suite struct Completion {
  private func names(_ text: String, extra: [String: String] = [:], useSDK: Bool = false) throws -> (list: SwiftCompletionList, names: [String]) {
    var files = extra
    files["Sources/App/A.swift"] = text.replacingOccurrences(of: "@@", with: "@@cursor")
    let package = try Package(files, useSDK: useSDK)
    let mark = package.marks.first { $0.key.hasPrefix("cursor") }!.value
    // The word the marker made isn't in the file: put the text back without it.
    let body = text.replacingOccurrences(of: "@@", with: "")
    package.model.project.update(path: mark.path, text: body)
    let list = package.model.complete(path: mark.path, line: mark.line, character: mark.character)
    return (list, list.items.map(\.name))
  }

  @Test func membersOfAKnownType() throws {
    let found = try names("struct B { var one = 1; func two() -> Int { 2 }; static let three = 3; private var four = 4 }\nstruct C { var b = B() }\nfunc t(c: C) {\n  c.b.@@\n}")
    #expect(found.list.context == .member)
    #expect(found.list.state == .exact)
    #expect(found.names.contains("one"))
    #expect(found.names.contains("two"))
    #expect(!found.names.contains("three"))
    #expect(!found.names.contains("four"))
  }

  @Test func whatComesAfterTheCursorIsntTheChain() throws {
    let found = try names("struct B { var one = 1 }\nstruct D { var other = 1 }\nfunc t(b: B, d: D) {\n  b.@@\n  d.other = 2\n}")
    #expect(found.names.contains("one"))
    #expect(!found.names.contains("other"))
  }

  @Test func aPrefixNarrowsAndRanks() throws {
    let found = try names("struct B { var alpha = 1; var beta = 2; var alphabet = 3 }\nfunc t(b: B) {\n  b.al@@\n}")
    #expect(found.list.prefix == "al")
    #expect(Set(found.names) == ["alpha", "alphabet"])
    #expect(found.names.first == "alpha")
  }

  @Test func staticSide() throws {
    let found = try names("struct B { var one = 1; static let two = 2; init(x: Int) {} }\nfunc t() {\n  B.@@\n}")
    #expect(found.names.contains("two"))
    #expect(found.names.contains("init"))
    #expect(!found.names.contains("one"))
  }

  @Test func implicitMembersFromAnAnnotation() throws {
    let found = try names("enum E { case a, b; static let c = E.a }\nfunc t() {\n  let x: E = .@@\n}")
    #expect(found.list.context == .implicitMember)
    #expect(Set(found.names).isSuperset(of: ["a", "b", "c"]))
  }

  @Test func implicitMembersFromAMissingArgumentsCall() throws {
    let found = try names("enum E { case a, b }\nstruct S {\n  init(name: String, kind: E, more: Int) {}\n}\nfunc t() {\n  S(name: \"x\", kind: .@@)\n}")
    #expect(found.list.state == .exact)
    #expect(Set(found.names).isSuperset(of: ["a", "b"]))
  }

  @Test func implicitMembersFromAMemberwiseInitializer() throws {
    let found = try names("enum E { case a, b }\nstruct S { var name: String; var kind: E }\nfunc t() {\n  S(name: \"x\", kind: .@@)\n}")
    #expect(found.list.state == .exact)
    #expect(Set(found.names).isSuperset(of: ["a", "b"]))
  }

  @Test func labelsNotWrittenYet() throws {
    let found = try names("func f(alpha: Int, beta: Int) {}\nfunc t() {\n  f(alpha: 1, @@)\n}")
    #expect(found.names.first == "beta")
    #expect(!found.names.contains("alpha"))
  }

  @Test func memberwiseLabels() throws {
    let found = try names("struct S { var name: String; let fixed = 1; var kind = 2; var computed: Int { 1 } }\nfunc t() {\n  S(@@)\n}")
    #expect(found.names.prefix(2).contains("name"))
    #expect(found.names.contains("kind"))
    #expect(!found.names.prefix(3).contains("fixed"))
    #expect(!found.names.prefix(3).contains("computed"))
  }

  @Test func scopeOffersLocalsThenMembersInOrder() throws {
    let found = try names("struct B {\n  var member = 1\n  static let shared = 1\n  func m(param: Int) {\n    let before = 1\n    @@\n    let after = 2\n  }\n}\nfunc global() {}")
    #expect(found.list.context == .scope)
    for name in ["before", "param", "member", "global"] { #expect(found.names.contains(name)) }
    #expect(!found.names.contains("after"))
    #expect(!found.names.contains("shared"))
    #expect(found.names.firstIndex(of: "before")! < found.names.firstIndex(of: "global")!)
  }

  @Test func staticContextHasNoInstanceMembers() throws {
    let found = try names("struct B {\n  var member = 1\n  static let shared = 1\n  static func m() {\n    @@\n  }\n}")
    #expect(found.names.contains("shared"))
    #expect(!found.names.contains("member"))
  }

  @Test func typePositions() throws {
    let found = try names("struct Alpha {}\nlet value = 1\nfunc f(a: Alpha, b: @@) {}")
    #expect(found.list.context == .type)
    #expect(found.names.contains("Alpha"))
    #expect(!found.names.contains("value"))
    let annotation = try names("struct Alpha {}\nlet value = 1\nfunc f() {\n  let x: Al@@\n}")
    #expect(annotation.list.context == .type)
    #expect(annotation.names == ["Alpha"])
    // An argument's value isn't a type, in a call that looks like a declaration by its `init`.
    let argument = try names("let value = 1\nclass A { init(x: Int) {} }\nclass B: A { init() { super.init(x: va@@) } }")
    #expect(argument.list.context == .scope)
    #expect(argument.names.contains("value"))
  }

  @Test func nothingWhereANameIsBeingDeclaredOrInText() throws {
    #expect(try names("func na@@").list.context == .none)
    #expect(try names("let a = \"te@@xt\"").list.context == .none)
    #expect(try names("// a.@@").list.context == .none)
    #expect(try names("let a = \"\\(1.@@)\"").list.context != .none)
  }

  @Test func imports() throws {
    let found = try names("import Ot@@", extra: ["Sources/Other/O.swift": "public let o = 1"])
    #expect(found.list.context == .moduleName)
    #expect(found.names.contains("Other"))
  }

  @Test func synthesized() throws {
    let raw = try names("enum E: String { case a }\nfunc t(e: E) {\n  e.@@\n}", useSDK: true)
    #expect(raw.names.contains("rawValue"))
    #expect(!raw.names.contains("count"))
  }

  @Test func anOptionalReceiverOffersWhatItWraps() throws {
    let found = try names("struct B { var one = 1 }\nfunc t(b: B?) {\n  b.@@\n}", useSDK: true)
    let one = found.list.items.first { $0.name == "one" }
    #expect(one?.needsUnwrap == true)
    #expect(found.names.contains("map"))
    let unwrapped = try names("struct B { var one = 1 }\nfunc t(b: B?) {\n  b?.@@\n}", useSDK: true)
    #expect(unwrapped.list.items.first { $0.name == "one" }?.needsUnwrap == false)
    #expect(!unwrapped.names.contains("map"))
  }

  @Test func unknownReceiverIsSaidToBe() throws {
    let found = try names("struct B { var one = 1 }\nfunc t() {\n  nowhere.@@\n}")
    #expect(found.list.state == .unknown)
    #expect(found.names.contains("one"))
  }

  /// Half-typed code leaves brackets open: the rest of the file has to stay where it is.
  @Test func openBracketsDontShiftTheFile() throws {
    let text = "struct B {\n  var one = 1\n  func m() {\n    foo(a: one.@@\n  }\n  var two = 2\n  func n() {\n    let x = 1\n  }\n}\nstruct After { var three = 3 }"
    let found = try names(text, useSDK: true)
    #expect(found.list.state == .exact)
    let package = try Package(["Sources/App/A.swift": text.replacingOccurrences(of: "@@", with: "")])
    let unit = package.model.project.units[0]
    let declared = unit.decls.filter { $0.parent < 0 }
    #expect(declared.count == 2)
    let b = unit.children(of: 0).map { unit.string(Int(unit.decls[Int($0)].nameToken)) }
    #expect(b == ["one", "m", "two", "n"])
  }

  @Test func balancedBracketsStayAsTheyWere() {
    let file = unit("func f() { g(a: [1, 2], b: { x in (x) }) }\nlet y = 1")
    let open = file.tokens.indices.first { file.string($0) == "{" }!
    #expect(file.skipBalanced(open) == file.tokens.indices.first { file.string($0) == "let" })
    let closes = file.tokens.indices.filter { file.string($0) == "}" }
    #expect(file.matchingOpen(closes.last!) == open)
  }

  @Test func capturedNames() throws {
    let found = try names("struct B { var one = 1 }\nfunc t(b: B) {\n  let f = { [kept = b] in\n    kept.@@\n  }\n}")
    #expect(found.list.state == .exact)
    #expect(found.names.contains("one"))
  }

  @Test func severalTrailingClosures() throws {
    let found = try names("struct B { var one = 1 }\nfunc make(a: () -> Void, b: () -> Void) -> B { B() }\nfunc t() {\n  make { } b: { }\n    .@@\n}")
    #expect(found.list.state == .exact)
    #expect(found.names.contains("one"))
  }

  @Test func ternaryAndRange() throws {
    let found = try names("struct B { var one = 1 }\nfunc t(c: Bool, b: B, d: B?) {\n  let x = c ? b : d!\n  x.@@\n}")
    #expect(found.names.contains("one"))
    let range = try names("func t() {\n  let x = 0..<3\n  x.@@\n}", useSDK: true)
    #expect(range.names.contains("lowerBound"))
  }

  @Test func dependentTypesAreTheirParametersNotTheReceivers() throws {
    let found = try names("func t(a: [String], f: (String) -> [Int]) {\n  let x = a.flatMap { f($0) }\n  for y in x {\n    y.@@\n  }\n}", useSDK: true)
    #expect(found.names.contains("byteSwapped"))
    #expect(!found.names.contains("hasPrefix"))
  }

  @Test func aTypesInitializerAsAnArgument() throws {
    let found = try names("func t(a: [Substring]) {\n  for y in a.map(String.init) {\n    y.@@\n  }\n}", useSDK: true)
    #expect(found.list.state == .exact)
    #expect(found.names.contains("hasPrefix"))
  }

  @Test func projectedValuesAreTheWrappers() throws {
    let found = try names("@propertyWrapper struct W<T> { var wrappedValue: T; var projectedValue: P<T> { P() } }\nstruct P<T> { var extra = 1 }\nstruct V {\n  @W var text: String\n  func m() {\n    $text.@@\n  }\n}")
    #expect(found.names.contains("extra"))
  }

  @Test func objectiveCPropertiesLowerTheirInitials() throws {
    let found = try names("import AppKit\nfunc t(c: NSGraphicsContext) {\n  c.cg@@\n}", useSDK: true)
    #expect(found.names.contains("cgContext"))
  }

  @Test func aBranchLeftOutIsReadWhenWorkedIn() throws {
    let text = "struct B { var one = 1 }\n#if os(Windows)\nfunc w(b: B) {\n  let c = b\n  c.@@\n}\n#else\nfunc m(b: B) { }\n#endif"
    let found = try names(text)
    #expect(found.list.state == .exact)
    #expect(found.names.contains("one"))
  }

  @Test func aDefinitionInABranchLeftOut() throws {
    let package = try Package([
      "Sources/App/A.swift": "struct B { var one = 1 }\n#if os(Windows)\nfunc w(b: B) { _ = b.@@one }\n#endif\nfunc m(b: B) { _ = b.@@two }\nextension B { var two: Int { 2 } }"
    ])
    #expect(package.answer("one").state == .exact)
    // Asked back in the active code, the file goes back as well.
    #expect(package.answer("two").state == .exact)
    #expect(package.model.project.units[0].focusOffset == nil)
  }

  @Test func tupleMembers() throws {
    let found = try names("func make() -> (data: String, count: Int)? { nil }\nfunc t() {\n  guard let m = make() else { return }\n  m.@@\n}\nlet data = 1\nlet count = 2\nfunc u(data: Int) {}", useSDK: false)
    #expect(found.list.state == .exact)
    #expect(found.names.contains("0"))
  }

  @Test func keyPaths() throws {
    let list = try names("struct A { var one: Int { 1 } }\nfunc f(p: KeyPath<A, Int>) {}\nfunc t() {\n  f(p: \\.@@)\n}", useSDK: true)
    #expect(list.list.state == .exact)
    #expect(list.names.contains("one"))
    let map = try names("struct A { var one: Int { 1 } }\nfunc t(a: [A]) {\n  _ = a.map(\\.@@)\n}", useSDK: true)
    #expect(map.list.state == .exact)
    #expect(map.names.contains("one"))
  }

  @Test func aWrappersArgumentGivesThePropertysType() throws {
    let source = "import SwiftUI\nfinal class M { var one = 1 }\nextension FocusedValues { @Entry var m: M? }\nstruct V { @Environment(M.self) private var a; @FocusedValue(\\.m) private var b\n  func t() {\n  @@\n  }\n}"
    let direct = try names(source.replacingOccurrences(of: "  @@", with: "  a.@@"), useSDK: true)
    #expect(direct.list.state == .exact)
    #expect(direct.names.contains("one"))
    let keyPath = try names(source.replacingOccurrences(of: "  @@", with: "  b?.@@"), useSDK: true)
    #expect(keyPath.list.state == .exact)
    #expect(keyPath.names.contains("one"))
  }

  @Test func aCastInAPattern() throws {
    let source = "struct B { var one = 1 }\nfunc t(xs: [Any]) {\n  for case let b as B in xs {\n    b.@@\n  }\n}"
    #expect(try names(source).names.contains("one"))
    let inSwitch = "struct B { var one = 1 }\nfunc t(x: Any) {\n  switch x {\n  case let b as B:\n    b.@@\n  default: break\n  }\n}"
    #expect(try names(inSwitch).names.contains("one"))
  }

  @Test func closuresWithAWrittenType() throws {
    let plain = try names("struct B { var one = 1 }\nfunc t() {\n  let f: (B) -> Bool = { b in\n    b.@@\n  }\n}")
    #expect(plain.names.contains("one"))
    let sendable = try names("struct B { var one = 1 }\nfunc t() {\n  let f: @Sendable (B) -> Bool = { b in\n    b.@@\n  }\n}")
    #expect(sendable.names.contains("one"))
  }

  @Test func closureParametersThroughGenerics() throws {
    let source = "struct B { var one = 1 }\nstruct W<Data: Collection, Out> {\n  init(_ data: Data, content: (Data.Element) -> Out) {}\n  init(_ data: Int, content: (Int) -> Out) {}\n}\nfunc t(xs: [B]) {\n  _ = W(xs) { b in\n    b.@@\n  }\n}"
    #expect(try names(source, useSDK: true).names.contains("one"))
  }

  @Test func aGenericWithNothingKnownAsksForNames() throws {
    let found = try names("struct B { var one = 1 }\nfunc g<T>(_ f: (T) -> Void) {}\nfunc t() {\n  g { $0.@@ }\n}")
    #expect(found.list.state == .unknown)
    #expect(found.names.contains("one"))
  }

  @Test func implicitMembersAskedOfEverySurrounding() throws {
    let kinds = "enum K: Comparable { case a, b; static func < (l: K, r: K) -> Bool { true } }\n"
    let cases: [String] = [
      "func t() -> K { return .@@ }",
      "func t() -> K? {\n  if true { return .@@ }\n  return nil\n}",
      "var t: K { get { return .@@ } }",
      "func t(x: K) { _ = x >= .@@ }",
      "func f(k: K) {}\nfunc t(c: Bool) { f(k: c ? .@@) }",
      "func f(k: K) {}\nfunc t(c: Bool) { f(k: c ? .a : .@@) }",
      "func t(c: Bool) { let x: K = c ? .@@ }",
      "func t(d: [K: Int]) { _ = d[.@@] }",
      "func f(d: [K: Int]) {}\nfunc t() { f(d: [.@@]) }",
      "func f(d: [String: K]) {}\nfunc t() { f(d: [\"a\": .@@]) }",
      "func f(d: [K]) {}\nfunc t() { f(d: [.a, .@@]) }",
      "struct S { subscript(k: K) -> Int { 1 } }\nfunc t(s: S) { _ = s[.@@] }",
      "func g(_ f: () -> K) {}\nfunc t() { g { .@@ } }",
      "func g(_ f: () -> K) {}\nfunc t() { g { return .@@ } }",
    ]
    for text in cases {
      let found = try names(kinds + text, useSDK: true)
      #expect(found.list.state == .exact, "\(text)")
      #expect(found.names.contains("a"), "\(text)")
    }
  }

  @Test func anImplicitMemberOfNothingKnownOffersCasesThisTypesFirst() throws {
    let found = try names("enum Other { case far; var plain: Int { 1 } }\nenum K { case near\n  var t: Bool { [.@@].isEmpty }\n}")
    #expect(found.list.state == .unknown)
    #expect(found.names.first == "near")
    #expect(found.names.contains("far"))
    #expect(!found.names.contains("plain"))
  }

  @Test func extensionsWhereClausesFilterMembers() throws {
    let base = """
      protocol P {}
      protocol Q {}
      extension Q { func fromQ() {} }
      struct A: P {}
      struct B {}
      enum E { case one }
      struct Box<T> { var t: T }
      extension Box where T: P { func onlyP() {} }
      extension Box where T == B { func onlyB() {} }
      extension Box where T: AnyObject { func onlyClass() {} }
      extension Box { func fits() where T: P {} }
      extension Box: Q where T: P {}

      """
    let a = try names(base + "func t(b: Box<A>) {\n  b.@@\n}").names
    #expect(a.contains("onlyP") && a.contains("fromQ") && a.contains("fits"))
    #expect(!a.contains("onlyB") && !a.contains("onlyClass"))
    let b = try names(base + "func t(b: Box<B>) {\n  b.@@\n}").names
    #expect(b.contains("t") && b.contains("onlyB"))
    #expect(!b.contains("onlyP") && !b.contains("fromQ") && !b.contains("fits"))
    // What isn't known yet keeps them all.
    let open = try names(base + "extension Box {\n  func t(b: Box<T>) {\n    b.@@\n  }\n}").names
    #expect(open.contains("onlyP") && open.contains("onlyB") && open.contains("fromQ"))
    // An enum is Equatable without saying so.
    let e = try names(base + "extension Box where T: Equatable { func same() {} }\nfunc t(b: Box<E>) {\n  b.@@\n}").names
    #expect(e.contains("same"))
  }

  @Test func dynamicMembersAreTheRootsProperties() throws {
    let base = """
      struct Inner { var deep = 1; func method() {} }
      @dynamicMemberLookup struct Wrap<Value> { var own = 0
        subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> Wrap<T> { fatalError() }
      }

      """
    let found = try names(base + "func t(w: Wrap<Inner>) {\n  w.@@\n}").names
    #expect(found.contains("own") && found.contains("deep") && !found.contains("method"))
    #expect((found.firstIndex(of: "own") ?? 99) < (found.firstIndex(of: "deep") ?? 0))
    let binding = try names("import SwiftUI\nfunc t(b: Binding<String>) {\n  b.@@\n}", useSDK: true).names
    #expect(binding.contains("count") && binding.contains("isEmpty") && binding.contains("wrappedValue"))
    #expect(!binding.contains("uppercased"))
  }

  @Test func aBindableLocalsProjection() throws {
    let found = try names("import SwiftUI\nfinal class M { var on = false }\nfunc t(m: M) {\n  @Bindable var m = m\n  $m.@@\n}", useSDK: true).names
    #expect(found.contains("on") && found.contains("wrappedValue"))
  }

  @Test func standardLibraryWhereClauses() throws {
    let ints = try names("func t(a: [Int]) {\n  a.@@\n}", useSDK: true).names
    #expect(ints.contains("removeLast") && ints.contains("popLast") && ints.contains("sorted") && ints.contains("hash"))
    #expect(!ints.contains("joined") && !ints.contains("popFirst"))
    let strings = try names("func t(a: [String]) {\n  a.@@\n}", useSDK: true).names
    #expect(strings.contains("joined"))
    let bytes = try names("import Foundation\nfunc t(a: UnsafeBufferPointer<UInt8>) {\n  a.@@\n}", useSDK: true).names
    #expect(bytes.contains("regions") && bytes.contains("copyBytes"))
    // Array's DataProtocol members are there only for bytes, and don't hide Collection's `firstRange` from the rest.
    let equatables = try names("import Foundation\nstruct T: Equatable {}\nfunc t(a: [T]) {\n  a.@@\n}", useSDK: true).names
    #expect(equatables.contains("firstRange") && equatables.contains("firstIndex") && !equatables.contains("regions"))
    let pairs = try names("func t(a: [Int: Int]) {\n  a.@@\n}", useSDK: true).names
    #expect(!pairs.contains("joined") && pairs.contains("keys"))
    // `Dictionary<Key, Value>.Swift::Keys`, where `>.` comes as one token.
    let keys = try names("func t(a: [Int: Int]) {\n  a.keys.@@\n}", useSDK: true).names
    #expect(keys.contains("sorted") && keys.contains("contains") && !keys.contains("removeValue"))
  }
}

@Suite struct Reach {
  @Test func exportedImportReachesTheWholeModule() throws {
    let package = try Package([
      "Sources/Base/B.swift": "public struct B { public init() {}; public var one = 1 }",
      "Sources/App/Exports.swift": "@_exported import Base",
      "Sources/App/A.swift": "func t(b: @@B) {}",
    ], useSDK: false)
    let mark = package.marks["B"] ?? package.marks.first!.value
    let answer = package.model.answer(path: mark.path, line: mark.line, character: mark.character)
    #expect(answer.state == .exact)
  }

  @Test func aSpaceSeparatesAnAttributeFromAType() throws {
    let file = unit("func a(f: @Sendable (Int) -> Bool, g: @convention(c) (Int) -> Bool, h: @MainActor @Sendable () -> Void) {}")
    let decl = file.decls.first { $0.kind == .function }!
    #expect(decl.paramCount == 3)
    let parser = DeclParser(unit: file)
    for p in 0..<Int(decl.paramCount) {
      let param = file.params[Int(decl.paramStart) + p]
      // Each type reaches its result or a closing bracket.
      #expect(parser.skipType(Int(param.typeStart)) == Int(param.typeEnd))
      #expect(file.isToken(Int(param.typeEnd) - 1, "Bool") || file.isToken(Int(param.typeEnd) - 1, "Void"))
    }
  }

  @Test func aQualifiedAttributeIsSkippedWhole() throws {
    let file = unit("func a(@SwiftUICore::ViewBuilder content: () -> Int, @M.B other: Int) {}")
    let decl = file.decls.first { $0.kind == .function }!
    let labels = (0..<Int(decl.paramCount)).map { file.params[Int(decl.paramStart) + $0].label }
    #expect(labels == [name("content"), name("other")])
  }
}
