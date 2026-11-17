import CodeModel
import CodeScan
import Foundation

final class PowerShellSyntax: LanguageSyntax {
  let profile = LexProfile.profile(forLanguage: "powershell")!
  let parametersHaveLabels = false
  let parses = ScriptCounter()
  func parse(_ unit: CodeModel.Unit) -> UInt64 {
    parses.increment()
    unit.scans[ScriptFile.key] = ScriptFile()
    return 0
  }
  func codeTokens(_ source: SourceFile) -> [Token] { ScriptTokens.read(source, dialect: .powerShell) }
  func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool { true }
  func conditional(_ unit: CodeModel.Unit, _ i: Int) -> ConditionalDirective { .none }
}

enum PowerShellStd { static let source = "" }

enum ScriptType: Hashable { case unknown }

extension ScriptModel {
  func resolveModule(_ source: ScriptSource, of unitIndex: Int32) -> Int32? { nil }
  func moduleFunctions(_ key: Name, in unitIndex: Int32) -> [DeclRef] { [] }
  func parameterAnswer(_ key: Name, command: Int, in unitIndex: Int32) -> Answer { Self.unknown }
  func memberAnswer(_ key: Name, receiver: Int32, in unitIndex: Int32) -> Answer { Self.unknown }
  func staticMemberAnswer(_ key: Name, type: Int, in unitIndex: Int32) -> Answer { Self.unknown }
  func typeAnswer(first: Int, last: Int, in unitIndex: Int32) -> Answer { Self.unknown }
}
