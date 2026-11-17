import CodeScan
import Foundation

/// A module: its files and its top-level declarations by name.
package final class Module {
  package let name: Name
  package let displayName: String
  package let isSDK: Bool
  package var units: [Int32] = []
  package var top: [Name: [DeclRef]] = [:]
  /// The name it's published as (`-export-as`): SwiftUICore's declarations are SwiftUI's to anyone reading them.
  package var publishedName: String

  package init(name: Name, displayName: String, isSDK: Bool) {
    self.name = name
    self.displayName = displayName
    self.isSDK = isSDK
    publishedName = displayName
  }
}

/// Layer 2: which files make which module, what each file can see, and everything else only when an import asks. The
/// language's `ProjectLayout` says where files and modules are; this keeps them and their indexes.
public final class Project {
  public let root: String
  package let layout: any ProjectLayout
  public package(set) var units: [Unit] = []
  package var modules: [Name: Module] = [:]
  package var unitByPath: [String: Int32] = [:]
  /// Extensions by the last name of what they extend, whichever module they're in.
  package var extensions: [Name: [DeclRef]] = [:]
  public package(set) var projectUnits = 0
  public package(set) var loadedBytes = 0
  package var visibleCache: [Int32: [Name]] = [:]
  private var missing: Set<Name> = []
  private var focused: Int32?
  /// The project's members by name (declared inside another declaration, not local, not extensions), for an answer
  /// by name when a receiver's type couldn't be told. Built when first asked, dropped when a file's shape changes.
  private var membersByName: [Name: [DeclRef]]?
  package var cachedProjectCounts: [Name: Int32]?
  /// Called when any declaration changed: a table built from them is stale.
  package var onShapeChange: () -> Void = {}

  /// Reads the project's files under `root` (standardized), as `layout` finds and groups them.
  package init(root: String, layout: any ProjectLayout) {
    self.root = root
    self.layout = layout
    loadProject()
  }

  package var syntax: any LanguageSyntax { layout.syntax }

  @inlinable package func unit(_ ref: DeclRef) -> Unit { units[Int(ref.unit)] }
  @inlinable package func decl(_ ref: DeclRef) -> Decl { units[Int(ref.unit)].decls[Int(ref.decl)] }

  /// Reads files in parallel.
  package func parse(_ paths: [String], isInterface: Bool) -> [Unit] {
    var parsed = [Unit?](repeating: nil, count: paths.count)
    let syntax = syntax
    parsed.withUnsafeMutableBufferPointer { buffer in
      nonisolated(unsafe) let slots = buffer
      DispatchQueue.concurrentPerform(iterations: paths.count) { index in
        guard let data = FileManager.default.contents(atPath: paths[index]) else { return }
        slots[index] = Unit(path: paths[index], source: SourceFile(bytes: data, profile: syntax.profile), syntax: syntax, isInterface: isInterface)
      }
    }
    return parsed.compactMap { $0 }
  }

  private func loadProject() {
    let paths = layout.sourceFiles(in: root)
    let prefix = root + "/"
    var groups: [String: [Unit]] = [:]
    for unit in parse(paths, isInterface: false) {
      let relative = unit.path.hasPrefix(prefix) ? String(unit.path.dropFirst(prefix.count)) : unit.path
      groups[layout.moduleName(ofRelative: relative), default: []].append(unit)
    }
    for (moduleName, members) in groups.sorted(by: { $0.key < $1.key }) {
      register(moduleName, members, isSDK: false)
    }
    projectUnits = units.count
  }

  @discardableResult
  package func register(_ displayName: String, _ members: [Unit], isSDK: Bool) -> Module {
    let module = Module(name: name(displayName), displayName: displayName, isSDK: isSDK)
    modules[module.name] = module
    for unit in members {
      let index = Int32(units.count)
      unit.moduleName = module.name
      units.append(unit)
      unitByPath[unit.path] = index
      module.units.append(index)
      loadedBytes += unit.source.count
      addToIndex(unit, index, into: module)
    }
    return module
  }

  /// Adds a unit generated for a module after it was registered (Clang headers read as Swift): ahead of the module's
  /// own files, which extend it.
  package func prepend(_ unit: Unit, to module: Module) {
    unit.moduleName = module.name
    let index = Int32(units.count)
    units.append(unit)
    unitByPath[unit.path] = index
    module.units.insert(index, at: 0)
    loadedBytes += unit.source.count
    var top: [Name: [DeclRef]] = [:]
    var extended: [Name: [DeclRef]] = [:]
    for (position, decl) in unit.decls.enumerated() where decl.parent < 0 && !decl.isLocal {
      let ref = DeclRef(unit: index, decl: Int32(position))
      if decl.kind == .extensionDecl { extended[decl.name, default: []].append(ref) } else { top[decl.name, default: []].append(ref) }
    }
    for (declName, list) in top { module.top[declName] = list + (module.top[declName] ?? []) }
    for (declName, list) in extended { extensions[declName] = list + (extensions[declName] ?? []) }
  }

  private func addToIndex(_ unit: Unit, _ index: Int32, into module: Module) {
    for (position, decl) in unit.decls.enumerated() where decl.parent < 0 && !decl.isLocal {
      let ref = DeclRef(unit: index, decl: Int32(position))
      if decl.kind == .extensionDecl {
        extensions[decl.name, default: []].append(ref)
      } else {
        module.top[decl.name, default: []].append(ref)
      }
    }
  }

  /// Finds a module an import names: the project's, or what the layout loads, then what it re-exports.
  @discardableResult
  package func ensureModule(_ moduleName: Name, display: String) -> Module? {
    if let module = modules[moduleName] { return module }
    if missing.contains(moduleName) { return nil }
    guard let loaded = layout.loadModule(moduleName, display: display, into: self) else {
      missing.insert(moduleName)
      return nil
    }
    for unitIndex in loaded.units {
      for item in units[Int(unitIndex)].imports where item.isExported { ensureModule(item.module, display: item.moduleName) }
    }
    return loaded
  }

  /// A file's modules in the order names resolve: its own, then its imports with what they re-export, then the implicit ones.
  package func visibleModules(of unitIndex: Int32) -> [Name] {
    if let cached = visibleCache[unitIndex] { return cached }
    let unit = units[Int(unitIndex)]
    var order: [Name] = [unit.moduleName]
    var seen: Set<Name> = [unit.moduleName]
    func visit(_ moduleName: Name, _ display: String) {
      guard seen.insert(moduleName).inserted, let module = ensureModule(moduleName, display: display) else { return }
      order.append(moduleName)
      for member in module.units {
        for item in units[Int(member)].imports where item.isExported { visit(item.module, item.moduleName) }
      }
    }
    for item in unit.imports { visit(item.module, item.moduleName) }
    // `@_exported import` in one file of a module reaches every file of that module.
    if let own = modules[unit.moduleName] {
      for member in own.units {
        for item in units[Int(member)].imports where item.isExported { visit(item.module, item.moduleName) }
      }
    }
    for implicit in layout.implicitModules { visit(name(implicit), implicit) }
    visibleCache[unitIndex] = order
    return order
  }

  package func membersNamed(_ member: Name) -> [DeclRef] {
    if membersByName == nil {
      var map: [Name: [DeclRef]] = [:]
      for u in 0..<projectUnits {
        let unit = units[u]
        for (index, decl) in unit.decls.enumerated() where decl.parent >= 0 && !decl.isLocal && decl.kind != .extensionDecl {
          map[decl.name, default: []].append(DeclRef(unit: Int32(u), decl: Int32(index)))
        }
      }
      membersByName = map
    }
    return membersByName?[member] ?? []
  }

  package func isTestable(_ moduleName: Name, from unit: Unit) -> Bool {
    unit.imports.contains { $0.isTestable && $0.module == moduleName }
  }

  /// Takes a file's new text. Returns whether what others see held, so that only its own body answers go.
  @discardableResult
  public func update(path: String, text: String) -> Bool {
    guard let index = unitByPath[path] else { return false }
    let old = units[Int(index)]
    return install(Unit(path: path, source: SourceFile(text, profile: syntax.profile), syntax: syntax, focusOffset: old.focusOffset), at: index, replacing: old)
  }

  /// A question inside code `#if` leaves out reads that branch; one outside what's being worked on goes back.
  package func focus(unitIndex: Int32, offset: Int) {
    let old = units[Int(unitIndex)]
    guard !old.isInterface else { return }
    // One file at a time: another's left-out branch shouldn't answer for this question.
    if let earlier = focused, earlier != unitIndex {
      focused = nil
      let other = units[Int(earlier)]
      install(Unit(path: other.path, source: other.source, syntax: other.syntax), at: earlier, replacing: other)
    }
    if old.focusOffset == nil, !old.isLeftOut(offset: offset) { return }
    if old.focusOffset != nil, old.focusedRanges.contains(where: { $0.start <= offset && offset < $0.end }), !old.isLeftOut(offset: offset) { return }
    // Without a focus, is this in what's left out?
    let plain = old.focusOffset == nil ? old : Unit(path: old.path, source: old.source, syntax: old.syntax)
    let wanted = plain.isLeftOut(offset: offset) ? offset : nil
    if wanted == old.focusOffset { return }
    // Two offsets in the same branch read the same: the check on shape below keeps what's built.
    focused = wanted == nil ? nil : unitIndex
    install(Unit(path: old.path, source: old.source, syntax: old.syntax, focusOffset: wanted, focusKey: wanted == nil ? 0 : plain.leftOutKey(offset: offset)), at: unitIndex, replacing: old)
  }

  @discardableResult
  private func install(_ new: Unit, at index: Int32, replacing old: Unit) -> Bool {
    new.moduleName = old.moduleName
    units[Int(index)] = new
    if new.shape == old.shape { return true }
    visibleCache.removeAll()
    membersByName = nil
    if let module = modules[old.moduleName] {
      module.top = module.top.mapValues { $0.filter { $0.unit != index } }.filter { !$0.value.isEmpty }
      extensions = extensions.mapValues { $0.filter { $0.unit != index } }.filter { !$0.value.isEmpty }
      addToIndex(new, index, into: module)
    }
    for unit in units { unit.dropBodyAnswers() }
    onShapeChange()
    return false
  }
}
