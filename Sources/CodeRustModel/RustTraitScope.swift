import CodeModel
import CodeScan
import Foundation

/// Which traits are in scope where a method is called: a trait's methods apply only when it is (declared or imported
/// in an enclosing scope, a glob's, the prelude's). Bounds and `dyn` traits always apply.
extension RustModel {
  /// The traits in scope at a token.
  func traitsInScope(unitIndex: Int32, token: Int32) -> Set<DeclRef> {
    let list = scopes(unitIndex: unitIndex, token: token)
    guard let innermost = list.first else { return [] }
    let key = ScopeKey(unit: innermost.0, scope: innermost.1, word: 0, namespace: nil)
    if let known = traitScopeCache[key] { return known }
    var result: Set<DeclRef> = []
    for (u, s) in list { result.formUnion(traits(inScope: s, of: u)) }
    if let prelude = preludeNode { result.formUnion(traits(ofNode: prelude)) }
    traitScopeCache[key] = result
    return result
  }

  /// The traits one scope declares or imports.
  private func traits(inScope scope: Int32, of unitIndex: Int32) -> Set<DeclRef> {
    var result: Set<DeclRef> = []
    let unit = project.units[Int(unitIndex)]
    let facts = facts(unitIndex)
    for (_, list) in facts.items[scope] ?? [:] {
      for index in list where unit.decls[Int(index)].kind == .protocolType { result.insert(DeclRef(unit: unitIndex, decl: index)) }
    }
    for index in facts.importsByScope[scope] ?? [] {
      if unit.imports[index].member == RustWord.glob {
        for base in importBase(unitIndex, index) { if case .node(let node) = base { result.formUnion(traits(ofNode: node)) } }
      } else {
        for found in resolveImport(unitIndex, index, .type) {
          if case .decl(let ref) = found, decl(ref).kind == .protocolType { result.insert(ref) }
        }
      }
    }
    return result
  }

  /// The traits a module has for a glob: its own and those it imports publicly.
  func traits(ofNode node: Int32) -> Set<DeclRef> {
    if let known = nodeTraitCache[node] { return known }
    nodeTraitCache[node] = []
    let holder = nodes[Int(node)]
    let result = traits(inScope: holder.decl, of: holder.unit)
    nodeTraitCache[node] = result
    return result
  }
}
