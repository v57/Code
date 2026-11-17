import CodeModel
import CodeScan
import Foundation

enum PyTy {
  /// `None`'s type.
  static let none = Ty.constructed(name("None"), [])
  /// `super()` in a method of a class: lookups start after the class in its MRO.
  static let superKind = name("super()")
  static let selfKey = name("Self")
}

/// typing's special forms and generic aliases, by their name.
private let typingForms: [String: (module: String, name: String)] = {
  var table: [String: (module: String, name: String)] = [
    "List": ("builtins", "list"), "Dict": ("builtins", "dict"), "Set": ("builtins", "set"), "FrozenSet": ("builtins", "frozenset"),
    "Text": ("builtins", "str"), "ByteString": ("builtins", "bytes"), "Deque": ("_collections", "deque"),
    "DefaultDict": ("_collections", "defaultdict"), "OrderedDict": ("collections", "OrderedDict"), "Counter": ("collections", "Counter"),
    "ChainMap": ("collections", "ChainMap"), "Pattern": ("_sre", "Pattern"), "Match": ("_sre", "Match"), "AbstractSet": ("_collections_abc", "Set"),
    "ContextManager": ("contextlib", "AbstractContextManager"), "AsyncContextManager": ("contextlib", "AbstractAsyncContextManager"),
  ]
  for abc in [
    "Iterable", "Iterator", "Generator", "AsyncIterable", "AsyncIterator", "AsyncGenerator", "Awaitable", "Coroutine", "Collection", "Container",
    "Sequence", "MutableSequence", "Mapping", "MutableMapping", "MutableSet", "KeysView", "ValuesView", "ItemsView", "Hashable", "Sized", "Reversible",
  ] {
    table[abc] = ("_collections_abc", abc)
  }
  return table
}()

/// Forms whose first argument is the type: `Annotated[T, …]`, `ClassVar[T]`, `Final[T]`.
private let passThrough: Set<String> = ["Annotated", "ClassVar", "Final", "Required", "NotRequired", "ReadOnly", "InitVar"]
private let unknownForms: Set<String> = ["Any", "Callable", "Literal", "NoReturn", "Never", "TypeAlias", "Generic", "Protocol", "Concatenate", "ParamSpec", "Unpack"]

/// The types of expressions and annotations, and members along a class's MRO.
extension PyModel {
  func isUnknown(_ ty: Ty) -> Bool {
    switch ty {
    case .unknown, .param: return true
    case .constructed(let kind, let parts) where kind == Ty.union: return parts.allSatisfy(isUnknown)
    default: return false
    }
  }

  /// Parts flattened and without repeats; one part is itself.
  func union(_ parts: [Ty]) -> Ty {
    var flat: [Ty] = []
    for part in parts {
      if case .constructed(let kind, let inner) = part, kind == Ty.union {
        for item in inner where !flat.contains(item) { flat.append(item) }
      } else if !flat.contains(part) {
        flat.append(part)
      }
    }
    if flat.isEmpty { return .unknown }
    return flat.count == 1 ? flat[0] : .constructed(Ty.union, flat)
  }

  /// The instance a class value makes: `.meta(C)` is C.
  func instance(_ ty: Ty) -> Ty {
    if case .meta(let inner) = ty { return inner }
    return .unknown
  }

  // MARK: Expressions

  /// The type of the operand chain that ends right before `end` (a `.`, a call's `(`): `a.b(c)[d]`.
  func operandType(_ unitIndex: Int32, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard let start = chainStart(unit, end: end) else { return .unknown }
    return chainType(unitIndex, start, end)
  }

  /// Where a primary and its trailers start, walking back from `end`.
  func chainStart(_ unit: Unit, end: Int) -> Int? {
    var k = end - 1
    var budget = 256
    while k >= 0, budget > 0 {
      budget -= 1
      let token = unit.tokens[k]
      switch token.kind {
      case .close:
        guard let open = unit.matchingOpen(k) else { return nil }
        if open > 0, !unit.isByte(open, 0x7B), case let before = unit.tokens[open - 1].kind,
          before == .identifier || before == .close || before == .string || before == .keyword && isValueKeyword(unit, open - 1),
          !(before == .keyword && !isValueKeyword(unit, open - 1))
        {
          k = open - 1
          continue
        }
        return open
      case .identifier, .string, .number:
        if k >= 2, unit.isByte(k - 1, 0x2E) { k -= 2; continue }
        return k
      case .keyword:
        guard isValueKeyword(unit, k) else { return nil }
        if k >= 2, unit.isByte(k - 1, 0x2E) { k -= 2; continue }
        return k
      default:
        return nil
      }
    }
    return nil
  }

  private func isValueKeyword(_ unit: Unit, _ k: Int) -> Bool {
    unit.isToken(k, "None") || unit.isToken(k, "True") || unit.isToken(k, "False")
  }

  /// An expression's type: conditional and boolean operators give a union, comparisons a `bool`, arithmetic on
  /// builtins its left side's type, a top-level comma a tuple.
  func expressionType(_ unitIndex: Int32, _ start: Int, _ end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard start >= 0, start < end, end <= unit.tokens.count else { return .unknown }
    guard depth < 48 else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    // Splits at the loosest operator outside brackets.
    var commas: [Int] = []
    var ifToken = -1
    var elseToken = -1
    var boolean: [Int] = []
    var comparison = -1
    var notToken = -1
    var arithmetic = -1
    var bracket = 0
    var k = start
    var lambdaAt = -1
    while k < end {
      let token = unit.tokens[k]
      switch token.kind {
      case .open, .interpolationOpen: bracket += 1
      case .close, .interpolationClose: bracket -= 1
      case .keyword where bracket == 0:
        if unit.isToken(k, "lambda") {
          if lambdaAt < 0 { lambdaAt = k }
        } else if lambdaAt >= 0 {
          break
        } else if unit.isToken(k, "if") {
          if ifToken < 0 { ifToken = k }
        } else if unit.isToken(k, "else") {
          if elseToken < 0 { elseToken = k }
        } else if unit.isToken(k, "or") || unit.isToken(k, "and") {
          boolean.append(k)
        } else if unit.isToken(k, "in") || unit.isToken(k, "is") {
          if comparison < 0 { comparison = k }
        } else if unit.isToken(k, "not"), k == start || !unit.isToken(k - 1, "is") {
          if notToken < 0 { notToken = k }
        }
      case .punctuation where bracket == 0 && lambdaAt < 0:
        if unit.isByte(k, 0x2C) {
          commas.append(k)
        } else if isComparison(unit, k) {
          if comparison < 0 { comparison = k }
        } else if arithmetic < 0, k > start, isBinaryOperator(unit, k) {
          arithmetic = k
        }
      default: break
      }
      k += 1
    }
    if lambdaAt == start { return .unknown }
    if !commas.isEmpty {
      var items: [Ty] = []
      var from = start
      for comma in commas + [end] where from < comma {
        items.append(expressionType(unitIndex, from, comma))
        from = comma + 1
      }
      return .tuple(items, [])
    }
    if ifToken > start, elseToken > ifToken {
      return union([expressionType(unitIndex, start, ifToken), expressionType(unitIndex, elseToken + 1, end)])
    }
    if !boolean.isEmpty {
      var parts: [Ty] = []
      var from = start
      for op in boolean + [end] {
        parts.append(expressionType(unitIndex, from, op))
        from = op + 1
      }
      if parts.contains(where: isUnknown) { return .unknown }
      return union(parts.filter { $0 != PyTy.none })
    }
    if notToken == start || comparison >= 0 { return builtinClass(name("bool")) }
    if unit.isToken(start, "await") { return expressionType(unitIndex, start + 1, end) }
    if arithmetic > start {
      let left = expressionType(unitIndex, start, arithmetic)
      guard case .nominal(let ref, _) = left, isBuiltinsUnit(self.unit(ref)) else { return .unknown }
      let text = self.unit(ref).string(Int(decl(ref).nameToken))
      if ["str", "bytes", "list", "tuple", "set", "frozenset", "float", "dict"].contains(text) { return left }
      if text == "int" || text == "bool" {
        if unit.isToken(arithmetic, "/") { return builtinClass(name("float")) }
        let right = expressionType(unitIndex, arithmetic + 1, end)
        if case .nominal(let other, _) = right, isBuiltinsUnit(self.unit(other)), self.unit(other).string(Int(decl(other).nameToken)) == "float" { return right }
        return builtinClass(name("int"))
      }
      return .unknown
    }
    // Unary signs.
    if unit.tokens[start].kind == .punctuation, unit.isByte(start, 0x2D) || unit.isByte(start, 0x2B) || unit.isByte(start, 0x7E) {
      return expressionType(unitIndex, start + 1, end)
    }
    return chainType(unitIndex, start, end)
  }

  private func isComparison(_ unit: Unit, _ k: Int) -> Bool {
    unit.isToken(k, "==") || unit.isToken(k, "!=") || unit.isToken(k, "<") || unit.isToken(k, ">") || unit.isToken(k, "<=") || unit.isToken(k, ">=")
  }

  /// An operator between two operands (not a unary sign, `*args`, `**kw`, `:` or `=`).
  private func isBinaryOperator(_ unit: Unit, _ k: Int) -> Bool {
    let before = unit.tokens[k - 1].kind
    guard before == .identifier || before == .close || before == .string || before == .number || before == .keyword && isValueKeyword(unit, k - 1) else { return false }
    if unit.isByte(k, 0x2E) || unit.isByte(k, 0x3A) || unit.isByte(k, 0x3D) || unit.isToken(k, "->") || unit.isByte(k, 0x3B) { return false }
    if unit.isWalrus(k) || unit.startsWithAssign(k) || unit.isAugmented(k) { return false }
    return true
  }

  /// A primary and its trailers: `name`, literals, displays, then `.attr`, `(args)`, `[index]`.
  func chainType(_ unitIndex: Int32, _ start: Int, _ end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard start < end else { return .unknown }
    var k = start
    var ty: Ty
    var calledName: Name = 0
    let token = unit.tokens[k]
    switch token.kind {
    case .identifier:
      if k + 1 < end, unit.tokens[k + 1].kind == .string, unit.tokens[k + 1].start == token.end {
        // A prefixed string.
        ty = builtinClass(name(unit.string(k).lowercased().contains("b") ? "bytes" : "str"))
        k += 2
        while k < end, unit.tokens[k].kind == .string { k += 1 }
      } else {
        ty = nameType(unitIndex, k)
        calledName = unit.hash(k)
        k += 1
      }
    case .string:
      ty = builtinClass(name("str"))
      k += 1
      while k < end, unit.tokens[k].kind == .string || unit.tokens[k].kind == .interpolationOpen || unit.tokens[k].kind == .interpolationClose || unit.tokens[k].kind == .identifier && false { k += 1 }
      // An f-string's code runs to its closing quote.
      if k < end, unit.tokens[k - 1].kind == .interpolationOpen { return ty }
    case .number:
      let text = unit.string(k).lowercased()
      if text.hasSuffix("j") {
        ty = builtinClass(name("complex"))
      } else if !text.hasPrefix("0x"), text.contains(".") || text.contains("e") {
        ty = builtinClass(name("float"))
      } else {
        ty = builtinClass(name("int"))
      }
      k += 1
    case .keyword:
      if unit.isToken(k, "None") {
        ty = PyTy.none
      } else if unit.isToken(k, "True") || unit.isToken(k, "False") {
        ty = builtinClass(name("bool"))
      } else {
        return .unknown
      }
      k += 1
    case .open:
      let close = unit.skipBalanced(k)
      ty = displayType(unitIndex, open: k, close: close - 1)
      k = close
    default:
      return .unknown
    }
    while k < end {
      if unit.isByte(k, 0x2E), k + 1 < end, unit.tokens[k + 1].kind == .identifier || unit.tokens[k + 1].kind == .keyword {
        ty = memberType(ty, unit.hash(k + 1), from: unitIndex)
        calledName = 0
        k += 2
      } else if unit.isByte(k, 0x28) {
        let close = unit.skipBalanced(k)
        ty = callResult(ty, unitIndex, open: k, close: close - 1, calledName: calledName)
        calledName = 0
        k = close
      } else if unit.isByte(k, 0x5B) {
        let close = unit.skipBalanced(k)
        ty = subscriptResult(ty, unitIndex, open: k, close: close - 1)
        calledName = 0
        k = close
      } else {
        return .unknown
      }
      if case .unknown = ty { return .unknown }
    }
    return ty
  }

  /// `(…)`, `[…]`, `{…}`: a tuple or a parenthesized expression, a list, a dict or a set, comprehensions too.
  private func displayType(_ unitIndex: Int32, open: Int, close: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let empty = close == open + 1
    var depth = 0
    var colon = -1
    var forToken = -1
    var comma = -1
    var k = open + 1
    while k < close {
      switch unit.tokens[k].kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose: depth -= 1
      default:
        if depth == 0 {
          if unit.isByte(k, 0x3A), !unit.isWalrus(k), colon < 0, forToken < 0 { colon = k }
          if unit.isToken(k, "for"), forToken < 0 { forToken = k }
          if unit.isByte(k, 0x2C), comma < 0 { comma = k }
          if unit.isToken(k, "lambda") { colon = -2 }
        }
      }
      k += 1
    }
    let firstEnd = forToken >= 0 ? forToken : comma >= 0 ? comma : close
    if unit.isByte(open, 0x28) {
      if empty { return .tuple([], []) }
      if forToken >= 0 { return .unknown }
      if comma < 0 { return expressionType(unitIndex, open + 1, close) }
      return expressionType(unitIndex, open + 1, close)
    }
    if unit.isByte(open, 0x5B) {
      let element = empty || unit.isByte(open + 1, 0x2A) ? Ty.unknown : expressionType(unitIndex, open + 1, firstEnd)
      return builtinClass(name("list"), [element])
    }
    if empty || colon >= 0 || unit.isToken(open + 1, "**") {
      guard colon > open else { return builtinClass(name("dict"), [.unknown, .unknown]) }
      let valueEnd = forToken >= 0 ? forToken : comma >= 0 ? comma : close
      return builtinClass(name("dict"), [expressionType(unitIndex, open + 1, colon), expressionType(unitIndex, colon + 1, valueEnd)])
    }
    return builtinClass(name("set"), [expressionType(unitIndex, open + 1, firstEnd)])
  }

  /// A name read at a token: what its bindings hold.
  func nameType(_ unitIndex: Int32, _ token: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    let word = unit.hash(token)
    // `self`/`cls` and parameters: the binding at hand.
    let sites = lookup(word, unitIndex: unitIndex, scope: facts.scope(at: token))
    return sitesType(sites)
  }

  /// What a symbol's sites hold: an annotated one's type, else every binding's together.
  func sitesType(_ sites: [Site]) -> Ty {
    guard !sites.isEmpty else { return .unknown }
    if sites.count == 1 { return siteType(sites[0]) }
    for site in sites {
      if let annotated = annotatedType(site) { return annotated }
    }
    var parts: [Ty] = []
    for site in sites.prefix(8) {
      let ty = siteType(site)
      parts.append(ty)
    }
    let known = parts.filter { !isUnknown($0) }
    if known.isEmpty { return .unknown }
    return union(parts.filter { $0 != .unknown })
  }

  private func annotatedType(_ site: Site) -> Ty? {
    guard let (unitIndex, index) = bindingOf(site) else { return nil }
    let binding = file(unitIndex).bindings[Int(index)]
    guard binding.annotationStart >= 0 else { return nil }
    return bindingType(unitIndex, index)
  }

  /// The binding a site is (a declaration's, a local's).
  func bindingOf(_ site: Site) -> (Int32, Int32)? {
    switch site {
    case .decl(let ref):
      guard let index = file(ref.unit).bindingOfDecl[ref.decl] else { return nil }
      return (ref.unit, index)
    case .local(let unitIndex, let token):
      guard let index = file(unitIndex).byToken[token] else { return nil }
      return (unitIndex, index)
    default:
      return nil
    }
  }

  func siteType(_ site: Site) -> Ty {
    switch site {
    case .module(let moduleName): return .module(moduleName)
    case .decl(let ref):
      let item = decl(ref)
      switch item.kind {
      case .classType: return .meta(.nominal(ref, []))
      case .function: return .nominal(ref, [])
      default:
        guard let index = file(ref.unit).bindingOfDecl[ref.decl] else { return .unknown }
        return bindingType(ref.unit, index)
      }
    case .local(let unitIndex, let token):
      guard let index = file(unitIndex).byToken[token] else { return .unknown }
      return bindingType(unitIndex, index)
    case .generic:
      return .unknown
    }
  }

  /// What a binding holds: its annotation, else what's assigned, iterated, entered, caught or imported.
  func bindingType(_ unitIndex: Int32, _ index: Int32) -> Ty {
    let facts = file(unitIndex)
    let key = Int64(index)
    if let known = facts.types[key] { return known }
    guard facts.resolving.insert(key).inserted, depth < 48 else { return .unknown }
    depth += 1
    defer {
      depth -= 1
      facts.resolving.remove(key)
    }
    let ty = computeBindingType(unitIndex, index)
    facts.types[key] = ty
    return ty
  }

  private func computeBindingType(_ unitIndex: Int32, _ index: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    let binding = facts.bindings[Int(index)]
    if binding.annotationStart >= 0 {
      return typeExpression(unitIndex, Int(binding.annotationStart), Int(binding.annotationEnd), env: [:])
    }
    switch binding.kind {
    case .parameter:
      let scope = facts.scopes[Int(binding.scope)]
      if binding.position == 0, scope.selfName != 0, scope.selfName == binding.name, scope.decl >= 0 {
        let method = unit.decls[Int(scope.decl)]
        guard method.parent >= 0 else { return .unknown }
        let owner = Ty.nominal(DeclRef(unit: unitIndex, decl: method.parent), [])
        let flags = facts.decorations[scope.decl] ?? []
        if flags.contains(.classMethod) || method.name == PyWord.new || unit.string(Int(method.nameToken)) == "__init_subclass__" { return .meta(owner) }
        return owner
      }
      if binding.valueStart >= 0 {
        let ty = expressionType(unitIndex, Int(binding.valueStart), Int(binding.valueEnd))
        return ty == PyTy.none ? .unknown : ty
      }
      return .unknown
    case .assign, .walrus:
      let value = expressionType(unitIndex, Int(binding.valueStart), Int(binding.valueEnd))
      return binding.position == 0 ? value : item(value, binding.position)
    case .forTarget, .comprehension:
      let element = elementType(expressionType(unitIndex, Int(binding.valueStart), Int(binding.valueEnd)), unitIndex: unitIndex)
      return binding.position == 0 ? element : item(element, binding.position)
    case .withTarget:
      let context = expressionType(unitIndex, Int(binding.valueStart), Int(binding.valueEnd))
      let isAsync = unit.isToken(Int(binding.valueStart) - 1, "with") && unit.isToken(Int(binding.valueStart) - 2, "async")
      var entered = methodResult(context, isAsync ? PyWord.aenter : PyWord.enter, from: unitIndex)
      // The generated stubs don't say what `__enter__` returns: the C types' return themselves.
      if isUnknown(entered), case .decl(let ref)? = members(of: context, named: isAsync ? PyWord.aenter : PyWord.enter, from: unitIndex).first,
        self.unit(ref).path.hasPrefix(PyModel.stubDirectory)
      {
        entered = context
      }
      return binding.position == 0 ? entered : item(entered, binding.position)
    case .exceptTarget:
      let caught = expressionType(unitIndex, Int(binding.valueStart), Int(binding.valueEnd))
      if case .tuple(let items, _) = caught { return union(items.map(instance)) }
      return instance(caught)
    case .importModule, .importMember:
      return sitesType(follow(unitIndex, Int(binding.importIndex)))
    case .function, .classDecl:
      return binding.decl >= 0 ? siteType(.decl(DeclRef(unit: unitIndex, decl: binding.decl))) : .unknown
    case .annotation, .augmented:
      return .unknown
    }
  }

  /// An unpacked item, from 1.
  func item(_ ty: Ty, _ position: Int32) -> Ty {
    guard position > 0 else { return .unknown }
    switch ty {
    case .tuple(let items, _): return Int(position) <= items.count ? items[Int(position) - 1] : .unknown
    case .nominal(let ref, let args) where isBuiltinsUnit(unit(ref)) && unit(ref).string(Int(decl(ref).nameToken)) == "tuple": return args.first ?? .unknown
    default: return .unknown
    }
  }

  /// A method's result on a receiver: `__enter__`'s, `__next__`'s.
  func methodResult(_ receiver: Ty, _ method: Name, from unitIndex: Int32) -> Ty {
    for site in members(of: receiver, named: method, from: unitIndex) {
      if case .decl(let ref) = site, decl(ref).kind == .function { return returnType(ref, receiver: receiver) }
    }
    return .unknown
  }

  /// What iterating a value gives.
  func elementType(_ ty: Ty, unitIndex: Int32) -> Ty {
    switch ty {
    case .tuple(let items, _): return union(items)
    case .constructed(let kind, let parts) where kind == Ty.union: return union(parts.filter { $0 != PyTy.none }.map { elementType($0, unitIndex: unitIndex) })
    case .nominal(let ref, let args):
      guard decl(ref).kind == .classType else { return .unknown }
      if isBuiltinsUnit(unit(ref)) {
        switch unit(ref).string(Int(decl(ref).nameToken)) {
        case "str": return ty
        case "bytes", "bytearray", "range": return builtinClass(name("int"))
        default: break
        }
      }
      let iterated = methodResult(ty, PyWord.iter, from: unitIndex)
      if case .nominal(let iterator, let iteratorArgs) = iterated {
        if let first = iteratorArgs.first, !isUnknown(first) { return first }
        if iterator != ref {
          let next = methodResult(iterated, PyWord.next, from: unitIndex)
          if !isUnknown(next) { return next }
        }
      }
      return args.first ?? .unknown
    default:
      return .unknown
    }
  }

  /// `x[i]`: a tuple's item, `__getitem__`'s result, a container's element.
  func subscriptResult(_ ty: Ty, _ unitIndex: Int32, open: Int, close: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    switch ty {
    case .tuple(let items, _):
      if close == open + 2, unit.tokens[open + 1].kind == .number, let index = Int(unit.string(open + 1)), index < items.count { return items[index] }
      return .unknown
    case .nominal(let ref, let args) where decl(ref).kind == .classType:
      // A slice is the container itself.
      var depth = 0
      for k in open + 1..<close {
        if unit.tokens[k].kind == .open { depth += 1 } else if unit.tokens[k].kind == .close { depth -= 1 } else if depth == 0, unit.isByte(k, 0x3A) {
          return ty
        }
      }
      let result = methodResult(ty, PyWord.getitem, from: unitIndex)
      if !isUnknown(result) { return result }
      if args.count == 2 { return args[1] }
      return args.first ?? .unknown
    case .meta, .module:
      // `Box[int]`, `list[str]` written as a value: a type.
      return .meta(typeExpression(unitIndex, chainStart(unit, end: open) ?? open, close + 1, env: [:]))
    default:
      return .unknown
    }
  }

  /// A call's result: a class makes an instance, a function returns its return type, `super()`, `type(x)` and the
  /// builtins that pass an element on (`enumerate`, `zip`, `sorted`, `list`…) as Python does.
  func callResult(_ callee: Ty, _ unitIndex: Int32, open: Int, close: Int, calledName: Name) -> Ty {
    let unit = project.units[Int(unitIndex)]
    if case .meta(.nominal(let ref, _)) = callee, isBuiltinsUnit(self.unit(ref)) || calledName != 0 {
      if let special = builtinCall(self.unit(ref).string(Int(decl(ref).nameToken)), unitIndex, open: open, close: close, ref: ref) { return special }
    }
    if case .nominal(let ref, _) = callee, decl(ref).kind == .function {
      let text = self.unit(ref).string(Int(decl(ref).nameToken))
      if isBuiltinsUnit(self.unit(ref)), let special = builtinCall(text, unitIndex, open: open, close: close, ref: ref) { return special }
      if text == "cast", self.unit(ref).path.hasSuffix("/typing.py"), let first = arguments(unit, open, close).first {
        return typeExpression(unitIndex, first.0, first.1, env: [:])
      }
    }
    switch callee {
    case .meta(let inner):
      if case .nominal(let ref, _) = inner, decl(ref).kind == .classType { return .nominal(ref, []) }
      return .unknown
    case .nominal(let ref, let args):
      if decl(ref).kind == .function { return returnType(ref, receiver: args.first) }
      return methodResult(callee, PyWord.call, from: unitIndex)
    case .function(_, let result): return result
    case .constructed(let kind, let parts) where kind == Ty.union:
      return union(parts.map { callResult($0, unitIndex, open: open, close: close, calledName: 0) })
    default: return .unknown
    }
  }

  /// A call's arguments, outside brackets.
  func arguments(_ unit: Unit, _ open: Int, _ close: Int) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    var depth = 0
    var start = open + 1
    var k = open + 1
    while k < close {
      switch unit.tokens[k].kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose: depth -= 1
      default:
        if depth == 0, unit.isByte(k, 0x2C) {
          if start < k { result.append((start, k)) }
          start = k + 1
        }
      }
      k += 1
    }
    if start < close { result.append((start, close)) }
    return result
  }

  private func builtinCall(_ text: String, _ unitIndex: Int32, open: Int, close: Int, ref: DeclRef) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    let args = arguments(unit, open, close)
    func argument(_ index: Int) -> Ty { index < args.count ? expressionType(unitIndex, args[index].0, args[index].1) : .unknown }
    func element(_ index: Int) -> Ty { elementType(argument(index), unitIndex: unitIndex) }
    switch text {
    case "super":
      guard args.isEmpty else { return .unknown }
      let facts = file(unit)
      var scope = facts.scope(at: open)
      while scope > 0, facts.scopes[Int(scope)].kind != .function { scope = facts.scopes[Int(scope)].parent }
      guard scope > 0, case let method = facts.scopes[Int(scope)].decl, method >= 0, unit.decls[Int(method)].parent >= 0,
        unit.decls[Int(unit.decls[Int(method)].parent)].kind == .classType
      else { return .unknown }
      return .constructed(PyTy.superKind, [.nominal(DeclRef(unit: unitIndex, decl: unit.decls[Int(method)].parent), [])])
    case "type":
      return args.count == 1 ? .meta(argument(0)) : nil
    case "enumerate": return builtinClass(name("list"), [.tuple([builtinClass(name("int")), element(0)], [])])
    case "zip": return builtinClass(name("list"), [.tuple(args.indices.map(element), [])])
    case "sorted", "reversed", "iter", "list": return args.isEmpty ? nil : builtinClass(name("list"), [element(0)])
    case "set", "frozenset": return args.isEmpty ? nil : builtinClass(name(text), [element(0)])
    case "tuple": return args.isEmpty ? nil : builtinClass(name("tuple"), [element(0)])
    case "next": return element(0)
    case "min", "max": return args.count == 1 ? element(0) : argument(0)
    default: return nil
    }
  }

  /// What a function returns when called on a receiver: its annotation (with the receiver's type arguments), else what
  /// its `return` statements give when they agree.
  func returnType(_ ref: DeclRef, receiver: Ty?) -> Ty {
    let item = decl(ref)
    let facts = file(ref.unit)
    let env = environment(of: receiver)
    if item.typeStart >= 0 { return typeExpression(ref.unit, Int(item.typeStart), Int(item.typeEnd), env: env) }
    if item.name == PyWord.initName { return PyTy.none }
    let key = Int64(1) << 40 | Int64(ref.decl)
    if let known = facts.types[key] { return known }
    guard facts.resolving.insert(key).inserted, depth < 48 else { return .unknown }
    depth += 1
    defer {
      depth -= 1
      facts.resolving.remove(key)
    }
    var result = Ty.unknown
    if !facts.generators.contains(ref.decl), let returns = facts.returns[ref.decl] {
      var parts: [Ty] = []
      for (start, end) in returns.prefix(12) {
        let ty = expressionType(ref.unit, Int(start), Int(end))
        if isUnknown(ty) {
          parts = []
          break
        }
        parts.append(ty)
      }
      if !parts.isEmpty { result = union(parts) }
    }
    facts.types[key] = result
    return result
  }

  /// A receiver's class's type parameters bound to its arguments, and `Self`.
  func environment(of receiver: Ty?) -> [Name: Ty] {
    guard let receiver else { return [:] }
    var env: [Name: Ty] = [PyTy.selfKey: receiver]
    if case .nominal(let ref, let args) = receiver, !args.isEmpty, decl(ref).kind == .classType {
      for (index, parameter) in typeParameters(ref).enumerated() where index < args.count { env[parameter] = args[index] }
    }
    return env
  }

  // MARK: Annotations

  /// The type an annotation names: classes as instances, typing's forms read (`Optional`, `Union`, `List`…, `X | Y`),
  /// a string annotation's name, type variables from the environment.
  func typeExpression(_ unitIndex: Int32, _ start: Int, _ end: Int, env: [Name: Ty]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard start >= 0, start < end, end <= unit.tokens.count, depth < 48 else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    // `A | B`.
    var bars: [Int] = []
    var bracket = 0
    for k in start..<end {
      switch unit.tokens[k].kind {
      case .open: bracket += 1
      case .close: bracket -= 1
      default: if bracket == 0, unit.isByte(k, 0x7C) { bars.append(k) }
      }
    }
    if !bars.isEmpty {
      var parts: [Ty] = []
      var from = start
      for bar in bars + [end] {
        parts.append(typeExpression(unitIndex, from, bar, env: env))
        from = bar + 1
      }
      return union(parts)
    }
    if end - start == 1, unit.tokens[start].kind == .string { return stringAnnotation(unitIndex, start, env: env) }
    if unit.isToken(start, "None") { return PyTy.none }
    // The base's end: a subscript's `[`.
    var baseEnd = end
    if unit.isByte(end - 1, 0x5D), let open = unit.matchingOpen(end - 1), open > start { baseEnd = open }
    var args: [(Int, Int)] = []
    if baseEnd < end { args = arguments(unit, baseEnd, end - 1) }
    // The base's sites.
    var sites: [Site] = []
    if baseEnd == start + 1, unit.tokens[start].kind == .identifier {
      let word = unit.hash(start)
      if let bound = env[word] { return bound }
      sites = lookup(word, unitIndex: unitIndex, scope: file(unit).scope(at: start))
    } else if baseEnd > start + 2, unit.isByte(baseEnd - 2, 0x2E) {
      sites = members(of: chainType(unitIndex, start, baseEnd - 2), named: unit.hash(baseEnd - 1), from: unitIndex)
    } else {
      return .unknown
    }
    func arg(_ index: Int) -> Ty { index < args.count ? typeExpression(unitIndex, args[index].0, args[index].1, env: env) : .unknown }
    if let form = typingForm(sites) {
      if form == "Optional" { return union([arg(0), PyTy.none]) }
      if form == "Union" { return union(args.indices.map(arg)) }
      if form == "Tuple" || form == "tuple" { return tupleType(unit, unitIndex, args, env: env) }
      if form == "Type" { return .meta(arg(0)) }
      if form == "Self" { return env[PyTy.selfKey] ?? .unknown }
      if form == "LiteralString" || form == "AnyStr" { return builtinClass(name("str")) }
      if form == "TypeGuard" || form == "TypeIs" { return builtinClass(name("bool")) }
      if passThrough.contains(form) { return arg(0) }
      if unknownForms.contains(form) { return .unknown }
      if let target = typingForms[form] {
        let key = target.module == "builtins" || target.module == "_collections" || target.module == "_sre"
          ? PyLayout.stubPrefix + target.module : layout.resolve(target.module, level: 0, from: project.root + "/x.py")
        guard let module = self.module(key) else { return .unknown }
        for case .decl(let ref) in moduleMember(module.name, name(target.name)) where decl(ref).kind == .classType {
          return .nominal(ref, args.indices.map(arg))
        }
        return .unknown
      }
    }
    for site in sites {
      if case .decl(let ref) = site {
        let item = decl(ref)
        if item.kind == .classType {
          if isBuiltinsUnit(self.unit(ref)), self.unit(ref).string(Int(item.nameToken)) == "tuple", !args.isEmpty { return tupleType(unit, unitIndex, args, env: env) }
          if isBuiltinsUnit(self.unit(ref)), self.unit(ref).string(Int(item.nameToken)) == "type", !args.isEmpty { return .meta(arg(0)) }
          return .nominal(ref, args.indices.map(arg))
        }
        if item.kind == .variable, let parameter = typeVariable(ref) { return env[parameter] ?? .param(parameter, ref) }
        // A type alias: what its value names.
        if item.kind == .variable, item.parent < 0, item.initStart >= 0, args.isEmpty, resolvingValues.insert(ref).inserted {
          defer { resolvingValues.remove(ref) }
          let value = typeExpression(ref.unit, Int(item.initStart), Int(item.initEnd), env: [:])
          if !isUnknown(value) { return value }
        }
      }
    }
    return .unknown
  }

  private func tupleType(_ unit: Unit, _ unitIndex: Int32, _ args: [(Int, Int)], env: [Name: Ty]) -> Ty {
    if args.count == 2, unit.isToken(args[1].0, "...") { return builtinClass(name("tuple"), [typeExpression(unitIndex, args[0].0, args[0].1, env: env)]) }
    return .tuple(args.map { typeExpression(unitIndex, $0.0, $0.1, env: env) }, [])
  }

  /// `"Foo"`, `"mod.Foo"`, `"Foo | None"`, `"Optional[Foo]"` written as a string.
  private func stringAnnotation(_ unitIndex: Int32, _ token: Int, env: [Name: Ty]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var text = unit.pyStringValue(token).trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("Optional["), text.hasSuffix("]") { text = String(text.dropFirst(9).dropLast()) }
    let parts = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0 != "None" }
    guard parts.count == 1 else { return .unknown }
    // `"Box[T]"`: the class, its arguments left out.
    var written = parts[0]
    if written.hasSuffix("]"), let open = written.firstIndex(of: "[") { written = String(written[..<open]) }
    let path = written.split(separator: ".").map(String.init)
    guard let first = path.first, path.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !$0.isEmpty }) else { return .unknown }
    if let bound = env[name(first)], path.count == 1 { return bound }
    var ty = sitesType(lookup(name(first), unitIndex: unitIndex, scope: file(unit).scope(at: token)))
    for part in path.dropFirst() { ty = memberType(ty, name(part), from: unitIndex) }
    if case .meta(let inner) = ty { return inner }
    return .unknown
  }

  /// The name of typing's special form or alias the sites are, if they're typing's (or typing_extensions').
  func typingForm(_ sites: [Site]) -> String? {
    for site in sites {
      switch site {
      case .decl(let ref):
        let path = unit(ref).path
        if path.hasSuffix("/typing.py") || path.hasSuffix("/typing.pyi") || path.contains("typing_extensions") {
          return unit(ref).string(Int(decl(ref).nameToken))
        }
        if isBuiltinsUnit(unit(ref)), decl(ref).kind == .classType, unit(ref).string(Int(decl(ref).nameToken)) == "tuple" { return nil }
      case .local(let unitIndex, let token):
        // An import of a module that isn't here (typing_extensions without its package): the member's name.
        let holder = project.units[Int(unitIndex)]
        for item in holder.imports where item.aliasToken == token && item.memberToken >= 0 {
          if item.moduleName.hasSuffix("typing_extensions") || item.moduleName.hasSuffix("typing") { return holder.string(Int(item.memberToken)) }
        }
      default:
        break
      }
    }
    return nil
  }

  /// `T = TypeVar("T")`: the type variable's name.
  func typeVariable(_ ref: DeclRef) -> Name? {
    let item = decl(ref)
    let holder = unit(ref)
    guard item.initStart >= 0, item.initEnd - item.initStart >= 3, holder.isByte(Int(item.initStart) + 1, 0x28) || holder.isByte(Int(item.initStart) + 3, 0x28) else { return nil }
    let word = holder.string(Int(item.initStart) + (holder.isByte(Int(item.initStart) + 1, 0x28) ? 0 : 2))
    guard word == "TypeVar" || word == "ParamSpec" || word == "TypeVarTuple" else { return nil }
    return item.name
  }

  // MARK: Classes

  /// A class's type parameters: `Generic[…]`'s or `Protocol[…]`'s arguments, else the type variables its bases use.
  func typeParameters(_ ref: DeclRef) -> [Name] {
    if let known = typeParamCache[ref] { return known }
    typeParamCache[ref] = []
    let item = decl(ref)
    let holder = unit(ref)
    var found: [Name] = []
    for r in 0..<Int(item.inheritCount) {
      let range = holder.ranges[Int(item.inheritStart) + r]
      guard holder.isByte(Int(range.end) - 1, 0x5D), let open = holder.matchingOpen(Int(range.end) - 1) else { continue }
      let base = holder.hash(open - 1)
      var names: [Name] = []
      for k in open + 1..<Int(range.end) - 1 where holder.tokens[k].kind == .identifier {
        let word = holder.hash(k)
        for case .decl(let variable) in lookup(word, unitIndex: ref.unit, scope: file(holder).scope(at: k)) where typeVariable(variable) != nil {
          if !names.contains(word) { names.append(word) }
        }
      }
      if base == PyWord.generic || base == PyWord.protocolWord {
        found = names
        break
      }
      for word in names where !found.contains(word) { found.append(word) }
    }
    typeParamCache[ref] = found
    return found
  }

  /// A class's bases, nil for one that can't be told; `Generic[…]`, `Protocol` and `object` left out.
  func bases(_ ref: DeclRef) -> [DeclRef?] {
    let item = decl(ref)
    let holder = unit(ref)
    var result: [DeclRef?] = []
    for r in 0..<Int(item.inheritCount) {
      let range = holder.ranges[Int(item.inheritStart) + r]
      var end = Int(range.end)
      if holder.isByte(end - 1, 0x5D), let open = holder.matchingOpen(end - 1), open > Int(range.start) { end = open }
      if end - Int(range.start) == 1, holder.hash(end - 1) == PyWord.generic || holder.hash(end - 1) == PyWord.protocolWord || holder.hash(end - 1) == PyWord.object { continue }
      let ty = chainType(ref.unit, Int(range.start), end)
      if case .meta(.nominal(let base, _)) = ty, decl(base).kind == .classType {
        if base == ref { continue }
        let text = unit(base).string(Int(decl(base).nameToken))
        if (text == "Generic" || text == "Protocol"), unit(base).path.hasSuffix("/typing.py") { continue }
        result.append(base)
      } else {
        if let form = typingFormOfRange(ref.unit, Int(range.start), end), form == "Generic" || form == "Protocol" { continue }
        result.append(nil)
      }
    }
    return result
  }

  private func typingFormOfRange(_ unitIndex: Int32, _ start: Int, _ end: Int) -> String? {
    let unit = project.units[Int(unitIndex)]
    guard end - start == 1, unit.tokens[start].kind == .identifier else { return nil }
    return typingForm(lookup(unit.hash(start), unitIndex: unitIndex, scope: file(unit).scope(at: start)))
  }

  /// The method resolution order (C3), nil standing for a base that can't be told.
  func mro(_ ref: DeclRef) -> [DeclRef?] {
    if let known = mroCache[ref] { return known }
    mroCache[ref] = [ref]
    let direct = bases(ref)
    var sequences: [[DeclRef]] = direct.compactMap { $0 }.map { mro($0).compactMap { $0 } }
    sequences.append(direct.compactMap { $0 })
    var result: [DeclRef] = [ref]
    sequences = sequences.filter { !$0.isEmpty }
    var guardCount = 0
    while !sequences.isEmpty, guardCount < 256 {
      guardCount += 1
      guard let head = sequences.lazy.map({ $0[0] }).first(where: { candidate in !sequences.contains { $0.dropFirst().contains(candidate) } }) else {
        // No consistent order: depth first.
        for sequence in sequences { for item in sequence where !result.contains(item) { result.append(item) } }
        break
      }
      result.append(head)
      sequences = sequences.map { $0.filter { $0 != head } }.filter { !$0.isEmpty }
    }
    var order: [DeclRef?] = result
    let unknownBases = direct.contains { $0 == nil } || direct.compactMap { $0 }.contains { mroCache[$0]?.contains(where: { $0 == nil }) == true }
    if unknownBases { order.append(nil) }
    mroCache[ref] = order
    return order
  }

  /// A class's declarations of a name along its MRO (its own body's, its methods' `self.x`), `object`'s last.
  func classMember(_ ref: DeclRef, named word: Name, skipping: Int = 0) -> [DeclRef] {
    let order = mro(ref)
    for entry in order.dropFirst(skipping) {
      guard let entry else { continue }
      let holder = unit(entry)
      var found: [DeclRef] = []
      for child in holder.children(of: entry.decl) where holder.decls[Int(child)].name == word && !holder.decls[Int(child)].isLocal {
        found.append(DeclRef(unit: entry.unit, decl: child))
      }
      if !found.isEmpty { return found }
    }
    if !order.contains(where: { $0 == nil }), case .nominal(let object, _) = builtinClass(PyWord.object), object != ref {
      let holder = unit(object)
      let found = holder.children(of: object.decl).filter { holder.decls[Int($0)].name == word }.map { DeclRef(unit: object.unit, decl: $0) }
      if !found.isEmpty { return found }
    }
    return []
  }

  /// Whether a type's lookups can miss what an unknown base declares.
  func hasUnknownBase(_ ty: Ty) -> Bool {
    switch ty {
    case .nominal(let ref, _), .meta(.nominal(let ref, _)):
      return decl(ref).kind == .classType && mro(ref).contains { $0 == nil }
    case .constructed(let kind, let parts) where kind == Ty.union: return parts.contains(where: hasUnknownBase)
    default: return false
    }
  }

  /// What a value of a type has of a name.
  func members(of ty: Ty, named word: Name, from unitIndex: Int32) -> [Site] {
    switch ty {
    case .module(let moduleName):
      return moduleMember(moduleName, word)
    case .nominal(let ref, _):
      guard decl(ref).kind == .classType else { return [] }
      return classMember(ref, named: word).map { .decl($0) }
    case .meta(.nominal(let ref, _)):
      guard decl(ref).kind == .classType else { return [] }
      let own = classMember(ref, named: word)
      if !own.isEmpty { return own.map { .decl($0) } }
      if case .nominal(let type, _) = builtinClass(PyWord.type) { return classMember(type, named: word).map { .decl($0) } }
      return []
    case .tuple:
      return members(of: builtinClass(name("tuple")), named: word, from: unitIndex)
    case .constructed(let kind, let parts) where kind == Ty.union:
      var result: [Site] = []
      for part in parts {
        for site in members(of: part, named: word, from: unitIndex) where !result.contains(site) { result.append(site) }
      }
      return result
    case .constructed(let kind, let parts) where kind == PyTy.superKind:
      guard case .nominal(let ref, _)? = parts.first else { return [] }
      return classMember(ref, named: word, skipping: 1).map { .decl($0) }
    default:
      return []
    }
  }

  /// What `x.name` holds: a property's result, a method bound to x, an attribute's value, a nested class, a submodule.
  func memberType(_ ty: Ty, _ word: Name, from unitIndex: Int32) -> Ty {
    let sites = members(of: ty, named: word, from: unitIndex)
    guard !sites.isEmpty else { return .unknown }
    var receiver = ty
    if case .constructed(let kind, let parts) = ty, kind == PyTy.superKind, let first = parts.first { receiver = first }
    var parts: [Ty] = []
    var annotated: Ty?
    for site in sites.prefix(8) {
      guard case .decl(let ref) = site else {
        parts.append(siteType(site))
        continue
      }
      let item = decl(ref)
      let flags = file(ref.unit).decorations[ref.decl] ?? []
      switch item.kind {
      case .function:
        if flags.contains(.property) { return returnType(ref, receiver: receiver) }
        if flags.contains(.setter) { continue }
        return .nominal(ref, flags.contains(.staticMethod) ? [] : [receiver])
      case .classType:
        return .meta(.nominal(ref, []))
      default:
        guard let index = file(ref.unit).bindingOfDecl[ref.decl] else { continue }
        let binding = file(ref.unit).bindings[Int(index)]
        if binding.annotationStart >= 0 {
          if annotated == nil { annotated = typeExpression(ref.unit, Int(binding.annotationStart), Int(binding.annotationEnd), env: environment(of: receiver)) }
          continue
        }
        if binding.kind == .augmented { continue }
        parts.append(bindingType(ref.unit, index))
      }
    }
    if let annotated { return annotated }
    if parts.contains(where: { $0 == .unknown }) || parts.isEmpty { return .unknown }
    return union(parts)
  }
}
