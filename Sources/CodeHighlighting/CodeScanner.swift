import Foundation

/// A lexical token: a UTF-16 range (relative to the scanned code string) and its
/// Xcode-style syntax kind.
public struct CodeToken: Equatable, Sendable {
  public let range: NSRange
  public let kind: SyntaxKind

  public init(range: NSRange, kind: SyntaxKind) {
    self.range = range
    self.kind = kind
  }
}

/// The scanner state carried from the end of one line to the start of the next:
/// whether the line ends inside a block comment or a multiline string.
///
/// An editor stores the state each line starts in. After an edit it rescans
/// from the edited line until a line ends in the state the next line already
/// starts in; past that point the old tokens are still valid.
public enum LineState: Equatable, Sendable {
  case normal
  case blockComment(open: String, close: String, doc: Bool, depth: Int)
  case multilineString(close: String, escape: Character?)
}

/// Shared regex-scanning engine behind every language in LanguageCatalog.
///
/// Line-based with cross-line state for block comments (nesting, doc comments →
/// prose) and multiline strings. Tolerant of incomplete input — the user is
/// typing: unterminated constructs color to end of line and resume cleanly.
/// All ranges are UTF-16 (NSString coordinates), so emoji and other
/// surrogate-pair characters never split.
public struct CodeScanner: Sendable {
  /// Precompiled anchored patterns and pre-sorted markers for one language.
  /// Built once per language and shared (see `patterns(for:)`).
  public final class Patterns: @unchecked Sendable {
    let declPattern: NSRegularExpression?
    let numberPattern: NSRegularExpression
    let identifierPattern: NSRegularExpression
    let memberPattern: NSRegularExpression
    let shellVarPattern: NSRegularExpression
    let urlPattern: NSRegularExpression
    let hashWordPattern: NSRegularExpression?
    let atWordPattern: NSRegularExpression?
    let rustAttrPattern: NSRegularExpression?
    let directivePattern: NSRegularExpression?
    /// Longest marker first, so "///" wins over "//" and `"""` over `"`.
    let lineComments: [String]
    let strings: [StringDelim]
    let lineRules: [(rule: SyntaxRule, regex: NSRegularExpression)]
    let inlineRules: [(rule: SyntaxRule, regex: NSRegularExpression)]

    init(spec: LanguageSpec) {
      func re(_ p: String) -> NSRegularExpression? { RegexCache.regex(p) }
      let ident = "[A-Za-z_$][A-Za-z0-9_$]*"
      if !spec.declKeywords.isEmpty {
        let alt = spec.declKeywords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        declPattern = re("\\b(" + alt + ")\\s+(" + ident + ")")
      } else {
        declPattern = nil
      }
      numberPattern = re(
        "(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\\.[0-9_]+)?(?:[eE][+-]?[0-9]+)?)[uUlLfF]*"
      )!
      identifierPattern = re(spec.identifierPattern ?? ident)!
      memberPattern = re("\\." + ident)!
      shellVarPattern = re("(?:\\$" + ident + "|\\$\\{" + ident + "\\})")!
      urlPattern = re("(?:https?|ftp)://[^\\s<>\"'()]+")!
      hashWordPattern = (spec.hashDirectives && !spec.hashDirectivesAnchored) ? re("#" + ident) : nil
      atWordPattern = spec.atWords ? re("@" + ident) : nil
      rustAttrPattern = spec.rustAttributes ? re("#!?\\[[^\\]]*\\]") : nil
      directivePattern =
        (spec.hashDirectives && spec.hashDirectivesAnchored)
        ? re("[ \\t]*#[ \\t]*([A-Za-z_][A-Za-z0-9_]*)") : nil
      lineComments = spec.lineComments.sorted { ($0 as NSString).length > ($1 as NSString).length }
      strings = spec.strings.sorted {
        ($0.open as NSString).length > ($1.open as NSString).length
      }
      lineRules = spec.lineRules.compactMap { r in re(r.pattern).map { (r, $0) } }
      inlineRules = spec.inlineRules.compactMap { r in re(r.pattern).map { (r, $0) } }
    }
  }

  private static let patternCache = PatternCache()

  /// The shared patterns for `spec`, keyed by its name.
  public static func patterns(for spec: LanguageSpec) -> Patterns {
    patternCache.patterns(for: spec)
  }

  public let spec: LanguageSpec
  private let patterns: Patterns
  private let code: String?

  /// A scanner for line-at-a-time use with `scanLine(_:at:state:)`.
  public init(spec: LanguageSpec) {
    self.spec = spec
    patterns = Self.patterns(for: spec)
    code = nil
  }

  /// A scanner for a whole code string, read with `scan()`.
  public init(code: String, spec: LanguageSpec) {
    self.spec = spec
    patterns = Self.patterns(for: spec)
    self.code = code
  }

  /// Scans the whole code string passed to `init(code:spec:)`.
  public mutating func scan() -> [CodeToken] {
    guard let code else { return [] }
    let source = code as NSString
    let lines = LineIndex(source)
    var tokens: [CodeToken] = []
    var state = LineState.normal
    for line in 0..<lines.count {
      let range = lines.contentRange(ofLine: line, in: source)
      let result = scanLine(source.substring(with: range) as NSString, at: range.location, state: state)
      tokens += result.tokens
      state = result.end
    }
    return tokens
  }

  /// Scans one line (without its line terminator) that starts at UTF-16 offset
  /// `offset` of the document, beginning in `state`. Token ranges are document
  /// offsets; `end` is the state the next line starts in.
  public func scanLine(_ line: NSString, at offset: Int, state: LineState) -> (
    tokens: [CodeToken], end: LineState
  ) {
    var run = LineRun(text: line, base: offset, state: state)
    scan(&run)
    return (run.tokens, run.state)
  }

  // MARK: - Line scanning

  /// Tokens and state for the line being scanned. Ranges inside are line-local
  /// until `emit` shifts them by `base`.
  private struct LineRun {
    let text: NSString
    let base: Int
    var state: LineState
    var tokens: [CodeToken] = []

    init(text: NSString, base: Int, state: LineState) {
      self.text = text
      self.base = base
      self.state = state
    }

    mutating func emit(_ kind: SyntaxKind, _ location: Int, _ length: Int) {
      guard length > 0 else { return }
      tokens.append(CodeToken(range: NSRange(location: base + location, length: length), kind: kind))
    }
  }

  private func scan(_ run: inout LineRun) {
    let text = run.text
    var pos = 0

    // Cross-line state first: the rest of the line belongs to a comment or
    // string unless it closes here.
    switch run.state {
    case .normal:
      break
    case .blockComment(let open, let close, let doc, let depth):
      if let closeIdx = findBlockClose(in: text, from: 0, open: open, close: close, depth: depth) {
        emitContent(&run, 0, closeIdx, doc: doc)
        run.emit(.comment, closeIdx, (close as NSString).length)
        run.state = .normal
        pos = closeIdx + (close as NSString).length
      } else {
        emitContent(&run, 0, text.length, doc: doc)
        return
      }
    case .multilineString(let close, let escape):
      if let closeIdx = findStringClose(in: text, from: 0, close: close, escape: escape) {
        run.emit(.string, 0, closeIdx + (close as NSString).length)
        run.state = .normal
        pos = closeIdx + (close as NSString).length
      } else {
        run.emit(.string, 0, text.length)
        return
      }
    }

    // Anchored preprocessor directive must start the line (C family).
    if let d = patterns.directivePattern, pos == 0, let m = matchAnchor(text, at: 0, pattern: d) {
      run.emit(.preprocessor, 0, m.range.length)
      pos = m.range.length
      // #include <header.h>: the header name is a string (GitHub colors it
      // so); consumes up to the '>' (or the line end while typing).
      if spec.headerStrings, m.groups.count > 1, m.groups[1].length > 0 {
        let word = text.substring(with: m.groups[1]).lowercased()
        if ["include", "import", "include_next"].contains(word) {
          var i = pos
          while i < text.length && (text.character(at: i) == 0x20 || text.character(at: i) == 0x09)
          { i += 1 }
          if i < text.length && text.character(at: i) == 0x3C {  // '<'
            i += 1
            let contentStart = i
            while i < text.length && text.character(at: i) != 0x3E { i += 1 }  // '>'
            run.emit(.string, contentStart, i - contentStart)
            pos = i < text.length ? i + 1 : text.length
          }
        }
      }
    }

    // Line-start rules (Markdown headings, YAML keys, Makefile targets, ...).
    if pos == 0, let (rule, m) = firstRule(patterns.lineRules, text, at: 0) {
      let group = m.groups.count > 1 && m.groups[1].location != NSNotFound ? m.groups[1] : m.range
      run.emit(rule.kind, group.location, group.length)
      if rule.consumesLine { return }
      pos = NSMaxRange(m.range)
    }

    while pos < text.length {
      // 1. Block comment open (before line comments: Lua --[[ ]])
      if let bc = spec.blockComments.first(where: { prefix(text, $0.open, at: pos) }) {
        let openLen = (bc.open as NSString).length
        // Doc comment: "/*" whose third char is '*' but fourth is not '/'
        // ("/**/  */" ambiguity: "/**/" is an empty non-doc comment).
        let isDoc =
          bc.open == "/*" && pos + 2 < text.length && text.character(at: pos + 2) == 0x2A
          && (pos + 3 >= text.length || text.character(at: pos + 3) != 0x2F)
        let markerLen = (isDoc ? 3 : openLen)
        run.emit(.comment, pos, markerLen)
        let contentStart = pos + markerLen
        if let closeIdx = findBlockClose(
          in: text, from: contentStart, open: bc.open, close: bc.close, depth: 1)
        {
          emitContent(&run, contentStart, closeIdx - contentStart, doc: isDoc)
          run.emit(.comment, closeIdx, (bc.close as NSString).length)
          pos = closeIdx + (bc.close as NSString).length
        } else {
          emitContent(&run, contentStart, text.length - contentStart, doc: isDoc)
          run.state = .blockComment(open: bc.open, close: bc.close, doc: isDoc, depth: 1)
          return
        }
        continue
      }

      // 2. Line comment (longest marker first) — consumes the rest of the line.
      if let marker = patterns.lineComments.first(where: { prefix(text, $0, at: pos) }),
        !spec.lineCommentsAtLineStartOnly || isBlank(text, upTo: pos)
      {
        let markerLen = (marker as NSString).length
        // Doc line comment: "///" or "//!" (Swift/Rust/Kotlin conventions).
        let isDoc =
          marker == "//" && pos + markerLen < text.length
          && (text.character(at: pos + markerLen) == 0x2F
            || text.character(at: pos + markerLen) == 0x21)
        let docLen = isDoc ? markerLen + 1 : markerLen
        if isDoc {
          run.emit(.comment, pos, docLen)
          emitContent(&run, pos + docLen, text.length - pos - docLen, doc: true)
        } else {
          emitContent(&run, pos, text.length - pos, doc: false)
        }
        return
      }

      // 3. Strings (longest open first: """ before ", @" before ").
      if let delim = patterns.strings.first(where: { prefix(text, $0.open, at: pos) }) {
        let openLen = (delim.open as NSString).length
        let closeLen = (delim.close as NSString).length
        if let closeIdx = findStringClose(
          in: text, from: pos + openLen, close: delim.close, escape: delim.escape)
        {
          run.emit(.string, pos, closeIdx + closeLen - pos)
          pos = closeIdx + closeLen
        } else if delim.multiline {
          run.emit(.string, pos, text.length - pos)
          run.state = .multilineString(close: delim.close, escape: delim.escape)
          return
        } else {
          run.emit(.string, pos, text.length - pos)
          return
        }
        continue
      }

      // 4. Character literals (C family): 'x', '\n', '\'' — but NOT Rust lifetimes
      // or Scala symbol literals ('a, 'foo): those are `'` + identifier +
      // non-quote, colored plain. A `'x'` char literal closes after exactly
      // one character; escapes ('\n') scan to their closing quote.
      if let ch = spec.charLiteral, text.character(at: pos) == charUTF16(ch) {
        let next: unichar? = pos + 1 < text.length ? text.character(at: pos + 1) : nil
        let nextIsIdent =
          next.map {
            ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39)
              || $0 == 0x5F
          } ?? false
        let closesShortly = pos + 2 < text.length && text.character(at: pos + 2) == 0x27  // 'x'
        if nextIsIdent && !closesShortly {
          pos += 1  // lifetime / symbol literal: plain
        } else if let closeIdx = findStringClose(in: text, from: pos + 1, close: "'", escape: "\\")
        {
          run.emit(.string, pos, closeIdx + 1 - pos)
          pos = closeIdx + 1
        } else {
          pos += 1
        }
        continue
      }

      // 5. Attributes (Rust #[...], @-words) and Swift hash words (preprocessor).
      if let r = patterns.rustAttrPattern, let m = matchAnchor(text, at: pos, pattern: r) {
        run.emit(.attribute, pos, m.range.length)
        pos = NSMaxRange(m.range)
        continue
      }
      if let h = patterns.hashWordPattern, let m = matchAnchor(text, at: pos, pattern: h) {
        run.emit(.preprocessor, pos, m.range.length)
        pos = NSMaxRange(m.range)
        continue
      }
      if let a = patterns.atWordPattern, let m = matchAnchor(text, at: pos, pattern: a) {
        run.emit(.attribute, pos, m.range.length)
        pos = NSMaxRange(m.range)
        continue
      }

      // 6. URLs → links (also extracted inside comments by emitContent).
      if let m = matchAnchor(text, at: pos, pattern: patterns.urlPattern) {
        run.emit(.link, pos, m.range.length)
        pos = NSMaxRange(m.range)
        continue
      }

      // 7. Inline rules (Markdown emphasis, CSS selectors, HTML tags, ...).
      if let (rule, m) = firstRule(patterns.inlineRules, text, at: pos) {
        let group = m.groups.count > 1 && m.groups[1].location != NSNotFound ? m.groups[1] : m.range
        run.emit(rule.kind, group.location, group.length)
        pos = NSMaxRange(m.range)
        continue
      }

      // 8. Numbers.
      if spec.highlightsNumbers, let m = matchAnchor(text, at: pos, pattern: patterns.numberPattern)
      {
        run.emit(.number, pos, m.range.length)
        pos = NSMaxRange(m.range)
        continue
      }

      // 9. Declarations: "class Foo" / "func bar" → keyword + declared name.
      if let d = patterns.declPattern, let m = matchAnchor(text, at: pos, pattern: d) {
        let kwRange = m.groups[1]
        let nameRange = m.groups[2]
        run.emit(.keyword, kwRange.location, kwRange.length)
        if nameRange.length > 0 {
          let kw = text.substring(with: kwRange)
          let kind = spec.declKeywords[kw] ?? .plainText
          if kind != .plainText {
            run.emit(kind, nameRange.location, nameRange.length)
          }
        }
        pos = NSMaxRange(m.range)
        continue
      }

      // 10. Member accesses: obj.name → otherMember.
      if spec.memberAccess, let m = matchAnchor(text, at: pos, pattern: patterns.memberPattern) {
        run.emit(.otherMember, pos, m.range.length)
        pos = NSMaxRange(m.range)
        continue
      }

      // 11. Shell variables: $name / ${name} → otherMember.
      if spec.shellVars, let m = matchAnchor(text, at: pos, pattern: patterns.shellVarPattern) {
        run.emit(.otherMember, pos, m.range.length)
        pos = NSMaxRange(m.range)
        continue
      }

      // 12. Identifiers → keyword, capitalized type reference, or plain.
      if let m = matchAnchor(text, at: pos, pattern: patterns.identifierPattern) {
        let word = text.substring(with: m.range)
        let key = spec.keywordsCaseInsensitive ? word.uppercased() : word
        if spec.keywords.contains(key) {
          run.emit(.keyword, pos, m.range.length)
        } else if spec.capitalizedIsType, let first = word.unicodeScalars.first,
          CharacterSet.uppercaseLetters.contains(first)
        {
          run.emit(.otherType, pos, m.range.length)
        }
        pos = NSMaxRange(m.range)
        continue
      }

      // 13. Anything else: plain character.
      pos += 1
    }
  }

  // MARK: - Helpers

  private func prefix(_ text: NSString, _ s: String, at pos: Int) -> Bool {
    let len = (s as NSString).length
    guard pos >= 0, pos + len <= text.length else { return false }
    return text.compare(s, options: .literal, range: NSRange(location: pos, length: len))
      == .orderedSame
  }

  private func isBlank(_ text: NSString, upTo pos: Int) -> Bool {
    for i in 0..<pos where text.character(at: i) != 0x20 && text.character(at: i) != 0x09 {
      return false
    }
    return true
  }

  private func firstRule(
    _ rules: [(rule: SyntaxRule, regex: NSRegularExpression)], _ text: NSString, at pos: Int
  ) -> (SyntaxRule, (range: NSRange, groups: [NSRange]))? {
    for (rule, regex) in rules {
      if let m = matchAnchor(text, at: pos, pattern: regex), m.range.length > 0 {
        return (rule, m)
      }
    }
    return nil
  }

  /// Anchored regex match at `pos`. Returns the match range plus group ranges.
  private func matchAnchor(_ text: NSString, at pos: Int, pattern: NSRegularExpression) -> (
    range: NSRange, groups: [NSRange]
  )? {
    guard pos < text.length else { return nil }
    let full = NSRange(location: pos, length: text.length - pos)
    guard let m = pattern.firstMatch(in: text as String, options: .anchored, range: full) else {
      return nil
    }
    let groups = (0..<m.numberOfRanges).map { m.range(at: $0) }
    return (m.range, groups)
  }

  /// Index of the close marker's first character, or nil when the block stays
  /// open past this line. Honors nesting when the spec nests (Swift).
  private func findBlockClose(
    in text: NSString, from start: Int, open: String, close: String, depth startingDepth: Int
  ) -> Int? {
    let openLen = (open as NSString).length
    let closeLen = (close as NSString).length
    var depth = startingDepth
    var i = start
    while i < text.length {
      if spec.nestedBlockComments, prefix(text, open, at: i) {
        depth += 1
        i += openLen
        continue
      }
      if prefix(text, close, at: i) {
        if depth > 1 {
          depth -= 1
          i += closeLen
          continue
        }
        return i
      }
      i += 1
    }
    return nil
  }

  /// Index of the close marker's first character, or nil. `escape` (e.g. "\")
  /// skips the following character (nil = raw string, no escapes).
  private func findStringClose(
    in text: NSString, from start: Int, close: String, escape: Character?
  ) -> Int? {
    let esc = escape.map { charUTF16($0) }
    var i = start
    while i < text.length {
      if let e = esc, text.character(at: i) == e {
        i += 2
        continue
      }
      if prefix(text, close, at: i) { return i }
      i += 1
    }
    return nil
  }

  /// Emits the comment token over a line-local range (prose for doc comments),
  /// then link tokens for URLs inside it. Later tokens win when applied in
  /// order, so the link subranges override the comment/prose color.
  private func emitContent(_ run: inout LineRun, _ location: Int, _ length: Int, doc: Bool) {
    guard length > 0 else { return }
    run.emit(doc ? .prose : .comment, location, length)
    var links: [NSRange] = []
    patterns.urlPattern.enumerateMatches(
      in: run.text as String, options: [], range: NSRange(location: location, length: length)
    ) { m, _, _ in
      if let m, m.range.length > 0 { links.append(m.range) }
    }
    for link in links { run.emit(.link, link.location, link.length) }
  }

  private func charUTF16(_ c: Character) -> unichar { Array(String(c).utf16)[0] }
}

/// Lock-protected cache of compiled patterns, keyed by language name.
private final class PatternCache: @unchecked Sendable {
  private let lock = NSLock()
  private var byName: [String: CodeScanner.Patterns] = [:]

  func patterns(for spec: LanguageSpec) -> CodeScanner.Patterns {
    lock.lock()
    defer { lock.unlock() }
    if let cached = byName[spec.name] { return cached }
    let made = CodeScanner.Patterns(spec: spec)
    byName[spec.name] = made
    return made
  }
}
