import Foundation

/// A member found through a type's hierarchy: the declaration, and how the declaring type's parameters read in terms
/// of the type the table is for.
package struct MemberEntry {
  package var ref: DeclRef
  package var substitution: [Name: Ty]

  package init(ref: DeclRef, substitution: [Name: Ty]) {
    self.ref = ref
    self.substitution = substitution
  }
}

/// What the class-based front ends (Java, Kotlin, C#) share about types that are declarations with parameters: a
/// declaration's parameters bound to arguments, substitution, the supertype a type has of a given declaration, and
/// binding a generic method's parameters from what's passed. The front end says what a declaration's supertypes are
/// and what a type's members are looked up in (a type parameter's bound).
package protocol NominalTypes: AnyObject {
  var project: Project { get }
  /// A declaration's direct supertypes, in terms of its own parameters.
  func supertypes(of ref: DeclRef) -> [Ty]
  /// What a type's members are looked up in: itself, or a type parameter's bound.
  func memberBase(_ ty: Ty, depth: Int) -> Ty
  /// The supertype of `ty` declared by `target`, with arguments, if `ty` is or extends it. `nominalSupertype` unless the
  /// language's other types have supertypes (C#'s arrays).
  func asSupertype(_ ty: Ty, _ target: DeclRef, depth: Int) -> Ty?
}

extension NominalTypes {
  @inlinable package func asSupertype(_ ty: Ty, _ target: DeclRef, depth: Int = 0) -> Ty? { nominalSupertype(ty, target, depth: depth) }

  /// Through the declared hierarchy alone.
  @inlinable package func nominalSupertype(_ ty: Ty, _ target: DeclRef, depth: Int = 0) -> Ty? {
    guard depth < 16, case .nominal(let ref, let args) = memberBase(ty, depth: 0) else { return nil }
    if ref == target { return .nominal(ref, args) }
    let map = parameterMap(ref, args)
    for parent in supertypes(of: ref) {
      if let found = asSupertype(substitute(parent, map), target, depth: depth + 1) { return found }
    }
    return nil
  }

  /// A declaration's parameters to the arguments given (none for a raw type).
  @inlinable package func parameterMap(_ ref: DeclRef, _ args: [Ty]) -> [Name: Ty] {
    guard !args.isEmpty else { return [:] }
    let holder = project.units[Int(ref.unit)]
    let item = holder.decls[Int(ref.decl)]
    var map: [Name: Ty] = [:]
    for g in 0..<min(Int(item.genericCount), args.count) { map[holder.generics[Int(item.genericStart) + g].name] = args[g] }
    return map
  }

  /// A type with parameters replaced by what `map` binds them to.
  @inlinable package func substitute(_ ty: Ty, _ map: [Name: Ty]) -> Ty {
    guard !map.isEmpty else { return ty }
    switch ty {
    case .param(let word, _): return map[word] ?? ty
    case .nominal(let ref, let args): return args.isEmpty ? ty : .nominal(ref, args.map { substitute($0, map) })
    case .constructed(let kind, let args): return args.isEmpty ? ty : .constructed(kind, args.map { substitute($0, map) })
    case .function(let params, let result): return .function(params.map { substitute($0, map) }, substitute(result, map))
    case .meta(let inner): return .meta(substitute(inner, map))
    case .optional(let inner): return .optional(substitute(inner, map))
    case .tuple(let elements, let labels): return .tuple(elements.map { substitute($0, map) }, labels)
    default: return ty
    }
  }

  /// Every declaration a type is or extends, nearest first, each with how far up it is.
  @inlinable package func hierarchy(of ty: Ty) -> [(DeclRef, Int)] {
    guard case .nominal(let start, _) = memberBase(ty, depth: 0) else { return [] }
    var result: [(DeclRef, Int)] = [(start, 0)]
    var seen: Set<DeclRef> = [start]
    var index = 0
    while index < result.count, result.count < 200 {
      let (ref, distance) = result[index]
      index += 1
      for parent in supertypes(of: ref) {
        guard case .nominal(let next, _) = parent, seen.insert(next).inserted else { continue }
        result.append((next, distance + 1))
      }
    }
    return result
  }

  /// Binds the `own` parameters in `pattern` from `actual`: a declaration's arguments through `actual`'s supertype of
  /// it, a constructed type's (an array's element) and a function's parameters and result element by element.
  @inlinable package func unify(_ pattern: Ty, _ actual: Ty, _ own: Set<Name>, _ bindings: inout [Name: Ty], depth: Int = 0) {
    guard depth < 8, actual != .unknown else { return }
    switch pattern {
    case .param(let word, _):
      if own.contains(word), bindings[word] == nil { bindings[word] = actual }
    case .nominal(let ref, let args):
      guard !args.isEmpty, case .nominal(_, let actualArgs)? = asSupertype(actual, ref, depth: 0) else { return }
      for (a, b) in zip(args, actualArgs) { unify(a, b, own, &bindings, depth: depth + 1) }
    case .constructed(let kind, let args):
      if case .constructed(let other, let actualArgs) = actual, other == kind {
        for (a, b) in zip(args, actualArgs) { unify(a, b, own, &bindings, depth: depth + 1) }
      }
    case .function(let params, let result):
      if case .function(let actualParams, let actualResult) = actual {
        for (a, b) in zip(params, actualParams) { unify(a, b, own, &bindings, depth: depth + 1) }
        unify(result, actualResult, own, &bindings, depth: depth + 1)
      }
    default:
      break
    }
  }
}
