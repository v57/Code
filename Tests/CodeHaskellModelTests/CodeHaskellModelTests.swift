import CodeHaskellModel
import CodeModel
import Foundation
import Testing

/// A Haskell project in a temporary folder, from file text with `^^` before the name a question is about (a word or an
/// operator). Base's modules are Code's stub.
private final class Project {
  let root: String
  let model: HaskellModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]
  static let symbols = Set("!#$%&*+./<=>?@\\^|-~:")

  init(_ files: [String: String]) throws {
    let base = NSTemporaryDirectory() + "hsmodel-" + UUID().uuidString
    root = base + "/project"
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "^^") {
          let character = rest.utf16.distance(from: rest.startIndex, to: mark.lowerBound)
          let after = rest[mark.upperBound...]
          var word = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "'" })
          if word.isEmpty { word = String(after.prefix { Self.symbols.contains($0) }) }
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
    model = HaskellModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), `std:<Module>` for the stub's.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { $0.path.hasPrefix("std:") ? $0.path : "\($0.path):\($0.line)" } })
  }

  /// One place, exactly.
  func exact(_ key: String) -> String? {
    let found = answer(key)
    return found.state == .exact && found.places.count == 1 ? found.places[0] : nil
  }

  func completions(_ key: String) -> [String] {
    let mark = marks[key]!
    return model.complete(path: mark.path, line: mark.line, character: mark.character, limit: 400).items.map(\.name)
  }
}

@Suite struct HaskellModelTests {
  @Test func localsFollowHaskellsScoping() throws {
    let project = try Project([
      "Main.hs": """
        module Main where

        area :: Double -> Double
        area r = factor * r * r
          where
            factor = pi
        total xs = sum [ y * 2 | y <- xs, y > 0 ]
        go n = do
          x <- pure n
          let y = x + 1
          case y of
            Just z -> ^^z
            Nothing -> ^^x
        main = print (^^area 2, total [1], \\k -> ^^k)
        twice ^^f = f . f
        user = ^^factor
        """
    ])
    #expect(project.exact("z") == "Main.hs:12")
    #expect(project.exact("x") == "Main.hs:9")
    #expect(project.exact("area") == "Main.hs:4")
    #expect(project.exact("k") == "Main.hs:14")
    #expect(project.exact("f") == "Main.hs:15")
    // `factor` is `area`'s, out of scope here.
    #expect(project.answer("factor").state == .unknown)
  }

  @Test func whereBindingsAndGuards() throws {
    let project = try Project([
      "A.hs": """
        module A (classify) where

        classify :: Int -> String
        classify n
          | n < ^^limit = "small"
          | Just m <- lookup n table = ^^m
          | otherwise = big
          where
            limit = 10
            big = "big"
            table = []
        """
    ])
    #expect(project.exact("limit") == "A.hs:9")
    #expect(project.exact("m") == "A.hs:6")
  }

  @Test func importsQualifiedHidingAndExports() throws {
    let project = try Project([
      "src/Geometry/Shape.hs": """
        module Geometry.Shape (Shape(..), area, module Geometry.Util) where

        import Geometry.Util

        data Shape = Circle { radius :: Double } | Rect Double Double

        area :: Shape -> Double
        area (Circle r) = pi * r * r
        area (Rect w h) = w * h

        hidden = 1
        """,
      "src/Geometry/Util.hs": """
        module Geometry.Util where

        clamp :: Double -> Double
        clamp = max 0
        """,
      "app/Main.hs": """
        module Main (main) where

        import qualified Geometry.Shape as S
        import Geometry.Shape (Shape(Circle), ^^clamp)
        import qualified Data.Map as Map
        import Data.List (sortBy)

        main :: IO ()
        main = do
          let shapes = [^^Circle 1, S.^^Rect 2 3]
              m = Map.^^fromList [(1, "a")]
          print (map S.^^area shapes, ^^clamp (S.^^radius (head shapes)))
          print (^^sortBy compare [3, 1], S.^^hidden, ^^Rect)
          ^^putStrLn "done"
        """,
    ])
    #expect(project.exact("Circle") == "src/Geometry/Shape.hs:5")
    #expect(project.exact("Rect") == "src/Geometry/Shape.hs:5")
    #expect(project.exact("area") == "src/Geometry/Shape.hs:8")
    #expect(project.exact("radius") == "src/Geometry/Shape.hs:5")
    #expect(project.exact("clamp") == "src/Geometry/Util.hs:4")
    #expect(project.exact("clamp2") == "src/Geometry/Util.hs:4")
    #expect(project.exact("fromList") == "std:Data.Map")
    #expect(project.exact("sortBy") == "std:Data.List")
    #expect(project.exact("putStrLn") == "std:Prelude")
    // Not exported, and `Rect` not imported unqualified.
    #expect(project.answer("hidden").state == .unknown)
    #expect(project.answer("Rect2").state == .unknown)
  }

  @Test func classesInstancesAndOperators() throws {
    let project = try Project([
      "Pretty.hs": """
        module Pretty where

        infixr 5 <+>

        class Pretty a where
          pretty :: a -> String
          prettyList :: [a] -> String
          prettyList = concatMap ^^pretty

        data Doc = Doc String

        (<+>) :: Doc -> Doc -> Doc
        Doc a <+> Doc b = Doc (a ++ b)

        instance Pretty Doc where
          ^^pretty (Doc s) = s

        instance Show Doc where
          ^^show (Doc s) = s

        both = Doc "a" ^^<+> Doc "b"
        shown = ^^show (Doc "x") ^^== "x"
        """
    ])
    #expect(project.exact("pretty") == "Pretty.hs:6")
    #expect(project.exact("pretty2") == "Pretty.hs:6")
    #expect(project.exact("show") == "std:Prelude")
    #expect(project.exact("show2") == "std:Prelude")
    #expect(project.exact("<+>") == "Pretty.hs:13")
    #expect(project.exact("==") == "std:Prelude")
    let references = project.model.references(of: project.model.answer(path: project.marks["<+>"]!.path, line: project.marks["<+>"]!.line, character: project.marks["<+>"]!.character))
    #expect(Set(references.map { "\($0.path):\($0.line)" }) == ["Pretty.hs:3", "Pretty.hs:12", "Pretty.hs:13", "Pretty.hs:21"])
  }

  @Test func recordsWildcardsAndTypeVariables() throws {
    let project = try Project([
      "Config.hs": """
        {-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}
        module Config where

        data Config = Config { host :: String, port :: Int }

        describe :: Config -> String
        describe Config{..} = ^^host ++ ":" ++ show ^^port

        bump :: Config -> Config
        bump c = c { ^^port = port c + 1 }

        pair :: forall ^^a b. a -> b -> (^^a, b)
        pair x y = (x :: ^^a, y)
        """
    ])
    #expect(project.exact("host") == "Config.hs:4")
    #expect(project.exact("port") == "Config.hs:4")
    #expect(project.exact("port2") == "Config.hs:4")
    #expect(project.exact("a2") == "Config.hs:12")
    #expect(project.exact("a3") == "Config.hs:12")
  }

  @Test func layoutKeepsLetInAndIfThenElse() throws {
    let project = try Project([
      "M.hs": """
        module M where
        f n = let a = 1; b = 2 in if n > a then ^^b else let c = a in ^^c
        g = [ (i, j) | i <- [1..3], let j = i * 2, ^^j > 2 ]
        h = \\case
          Left e -> ^^e
          Right v -> v
        """
    ])
    #expect(project.exact("b") == "M.hs:2")
    #expect(project.exact("c") == "M.hs:2")
    #expect(project.exact("j") == "M.hs:3")
    #expect(project.exact("e") == "M.hs:5")
  }

  @Test func completionListsScopeQualifiedAndModules() throws {
    let project = try Project([
      "Main.hs": """
        module Main where
        import qualified Data.Map as M
        import Data.Ch^^

        helper :: Int -> Int
        helper = id

        main = do
          let total = 3
          print (M.^^ , ^^)
        """
    ])
    // Marks in file order: the import's, `M.`'s, then the scope's.
    #expect(project.completions("").contains("Char"))
    #expect(project.completions("2").contains("lookup"))
    #expect(project.completions("3").contains("total"))
    #expect(project.completions("3").contains("helper"))
    #expect(project.completions("3").contains("putStrLn"))
  }

  @Test func detailsShowSignatureAndHaddock() throws {
    let project = try Project([
      "Lib.hs": """
        module Lib where

        -- | Adds one to a number.
        inc :: Int -> Int
        inc = (+ 1)

        use = ^^inc 2
        """
    ])
    let mark = project.marks["inc"]!
    let found = project.model.details(path: mark.path, line: mark.line, character: mark.character)
    #expect(found.details.first?.declaration == "inc :: Int -> Int")
    #expect(found.details.first?.documentation == "Adds one to a number.")
  }
}
