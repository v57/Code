import CodeHighlighting
import CodeScan
import Foundation

/// How a text gets laid out; `resolve` reads it from the project's own configuration.
public struct PrettyOptions: Equatable, Sendable {
  public var indentWidth = 2
  public var useTabs = false
  /// Lines over this break at their outermost list. 0 keeps them: only a project's configuration sets a width, since a
  /// default would rewrite every file of a project that never agreed to one.
  public var printWidth = 0
  public var maxBlankLines = 1
  /// `"` or `'`, for languages that may use either; nil keeps what most of the file uses.
  public var quote: UInt8?
  public var trailingCommas = true

  public init() {}
}

/// A formatter for every language: the scanner's tokens with their whitespace decided again.
///
/// It only moves whitespace, adds a trailing comma where a list breaks and swaps quotes where nothing escapes, and proves
/// it: the result is scanned again and must give the same tokens, or the text comes back unchanged. How much of the
/// layout it decides depends on what whitespace means in the language (`LanguageRules.Layout`).
public enum Pretty {
  public struct Output: Sendable {
    public var text: [UInt8]
    /// The result would have changed tokens, so `text` is the input.
    public var refused = false
    /// The line of the first token it would have changed, from 0; nil when tokens held but a second pass disagreed.
    public var refusedLine: Int?
  }

  public static func format(_ source: SourceFile, path: String? = nil, options: PrettyOptions) -> Output {
    let first = formatOnce(source, path: path, options: options)
    guard !first.refused, !first.text.elementsEqual(source.bytes) else { return first }
    // Formatting a second time must change nothing, or saving would keep moving the code: leave those alone.
    let again = formatOnce(SourceFile(bytes: first.text, profile: source.profile), path: path, options: options)
    guard again.text == first.text else {
      return Output(text: Array(source.bytes), refused: true)
    }
    return first
  }

  private static func formatOnce(_ source: SourceFile, path: String?, options: PrettyOptions) -> Output {
    var layout = source.profile.rules.layout
    // JSX text is content between tags, and tokens can't tell it from code.
    if let path, ["tsx", "jsx", "vue", "svelte", "astro", "mdx"].contains((path as NSString).pathExtension.lowercased()) {
      layout = .lines
    }
    let result: [UInt8]
    switch layout {
    case .lines: result = LineFormatter(source: source, options: options).run()
    case .spacing, .full:
      var formatter = TokenFormatter(source: source, options: options, layout: layout)
      result = formatter.run()
    }
    let formatted = SourceFile(bytes: result, profile: source.profile)
    if let offset = firstDifference(source, formatted) {
      return Output(text: Array(source.bytes), refused: true, refusedLine: source.lines.line(of: offset))
    }
    return Output(text: result)
  }

  public static func format(_ text: String, language: String, path: String? = nil, options: PrettyOptions = PrettyOptions()) -> String? {
    guard let profile = LexProfile.profile(forLanguage: language) else { return nil }
    let output = format(SourceFile(text, profile: profile), path: path, options: options)
    return String(decoding: output.text, as: UTF8.self)
  }

  /// Whether two texts are the same code: every token equal, but for whitespace inside comments, added trailing commas
  /// and a string's quotes.
  public static func sameTokens(_ a: SourceFile, _ b: SourceFile) -> Bool { firstDifference(a, b) == nil }

  /// Where in `a` the two stop being the same code; nil when they are.
  static func firstDifference(_ a: SourceFile, _ b: SourceFile) -> Int? {
    let x = a.tokens
    let y = b.tokens
    var i = 0
    var j = 0
    while i < x.count, j < y.count {
      let p = x[i]
      let q = y[j]
      if !sameToken(p, a.text, q, b.text) {
        // Only a comma before a closing bracket (and comments) can be new.
        if isComma(q, b.text), j + 1 < y.count, nextCode(y, after: j)?.kind == .close || nextCode(y, after: j)?.kind == .interpolationClose, p.kind == .close || p.kind == .comment || p.kind == .docComment {
          j += 1
          continue
        }
        return p.start
      }
      i += 1
      j += 1
    }
    // A comma can be the last before the end only inside a bracket: nothing else may be left.
    if i == x.count, j == y.count { return nil }
    return i < x.count ? x[i].start : a.count
  }

  private static func nextCode(_ tokens: [Token], after index: Int) -> Token? {
    var i = index + 1
    while i < tokens.count {
      if tokens[i].kind != .comment, tokens[i].kind != .docComment { return tokens[i] }
      i += 1
    }
    return nil
  }

  private static func isComma(_ token: Token, _ t: UnsafePointer<UInt8>) -> Bool {
    token.length == 1 && t[token.start] == 0x2C
  }

  private static func sameToken(_ p: Token, _ a: UnsafePointer<UInt8>, _ q: Token, _ b: UnsafePointer<UInt8>) -> Bool {
    guard p.kind == q.kind else { return false }
    if p.length == q.length, memcmp(a + p.start, b + q.start, p.length) == 0 { return true }
    switch p.kind {
    case .comment, .docComment:
      return sameIgnoringSpaces(a + p.start, p.length, b + q.start, q.length)
    case .string:
      guard p.length == q.length, p.length >= 2 else { return false }
      // Only the two quotes may differ.
      let x = a[p.start]
      let y = b[q.start]
      guard (x == 0x27 && y == 0x22) || (x == 0x22 && y == 0x27) else { return false }
      return memcmp(a + p.start + 1, b + q.start + 1, p.length - 2) == 0
    default:
      return false
    }
  }

  private static func sameIgnoringSpaces(_ a: UnsafePointer<UInt8>, _ m: Int, _ b: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    var i = 0
    var j = 0
    func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }
    while true {
      while i < m, isSpace(a[i]) { i += 1 }
      while j < n, isSpace(b[j]) { j += 1 }
      if i == m || j == n { return i == m && j == n }
      if a[i] != b[j] { return false }
      i += 1
      j += 1
    }
  }
}

/// `.lines`: whitespace may be content, so only what's invisible at the end of lines and of the file.
private struct LineFormatter {
  let source: SourceFile
  let options: PrettyOptions

  func run() -> [UInt8] {
    let t = source.text
    let n = source.count
    guard n > 0 else { return [] }
    let isMarkdown = source.profile.spec.name == "Markdown"
    var out = [UInt8]()
    out.reserveCapacity(n + 1)
    // Lines inside a multi-line string or comment stay as they are.
    let tokens = source.tokens
    var tokenIndex = 0
    var line = 0
    while line < n {
      var end = line
      if let found = memchr(t + line, 0x0A, n - line) {
        end = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - t
      } else {
        end = n
      }
      while tokenIndex < tokens.count, tokens[tokenIndex].end <= end { tokenIndex += 1 }
      let endsInsideToken = tokenIndex < tokens.count && tokens[tokenIndex].start < end
      var stop = end
      if stop > line, t[stop - 1] == 0x0D { stop -= 1 }
      let terminatorStart = stop
      if !endsInsideToken {
        while stop > line, t[stop - 1] == 0x20 || t[stop - 1] == 0x09 { stop -= 1 }
        // Markdown's two spaces are a line break.
        if isMarkdown, terminatorStart - stop == 2, stop > line { stop = terminatorStart }
      } else {
        stop = terminatorStart
      }
      out.append(contentsOf: UnsafeBufferPointer(start: t + line, count: stop - line))
      out.append(contentsOf: UnsafeBufferPointer(start: t + terminatorStart, count: end - terminatorStart))
      if end < n { out.append(0x0A) }
      line = end + 1
    }
    // One newline at the end.
    while out.last == 0x0A || out.last == 0x20 || out.last == 0x09 || out.last == 0x0D { out.removeLast() }
    if !out.isEmpty {
      if source.usesCRLF { out.append(0x0D) }
      out.append(0x0A)
    }
    return out
  }
}

extension SourceFile {
  /// Whether its first line ends in CRLF, which every line of the result then does.
  var usesCRLF: Bool {
    guard let found = memchr(text, 0x0A, count), found > UnsafeMutableRawPointer(mutating: text) else { return false }
    return found.assumingMemoryBound(to: UInt8.self).advanced(by: -1).pointee == 0x0D
  }
}

/// `.full` and `.spacing`.
private struct TokenFormatter {
  let source: SourceFile
  let options: PrettyOptions
  let layout: LanguageRules.Layout
  let rules: LanguageRules
  let t: UnsafePointer<UInt8>
  let tokens: [Token]
  /// Newlines before each token, after the limits.
  var breaks: [UInt16]
  /// The close bracket matching each open one, and -1 elsewhere.
  var closers: [Int32]
  /// The tokens after which a trailing comma goes.
  var commas = Set<Int>()
  let isFullLayout: Bool
  let newline: [UInt8]
  let preferredQuote: UInt8?

  init(source: SourceFile, options: PrettyOptions, layout: LanguageRules.Layout) {
    self.source = source
    self.options = options
    self.layout = layout
    rules = source.profile.rules
    t = source.text
    tokens = source.tokens
    isFullLayout = layout == .full
    newline = source.usesCRLF ? [0x0D, 0x0A] : [0x0A]
    breaks = [UInt16](repeating: 0, count: tokens.count)
    closers = [Int32](repeating: -1, count: tokens.count)
    preferredQuote = Self.quote(in: source, rules: rules, options: options)
    computeBreaks()
    computeClosers()
  }

  private static func quote(in source: SourceFile, rules: LanguageRules, options: PrettyOptions) -> UInt8? {
    guard rules.prefersDoubleQuotes else { return nil }
    if let quote = options.quote { return quote }
    var single = 0
    var double = 0
    for token in source.tokens where token.kind == .string {
      if source.text[token.start] == 0x27 { single += 1 } else if source.text[token.start] == 0x22 { double += 1 }
    }
    if single == 0 || double == 0 { return nil }
    return single > double ? 0x27 : 0x22
  }

  mutating func computeBreaks() {
    let limit = UInt16(options.maxBlankLines + 1)
    for index in tokens.indices where index > 0 {
      let gapStart = tokens[index - 1].end
      let gapEnd = tokens[index].start
      var count: UInt16 = 0
      var i = gapStart
      while i < gapEnd {
        if t[i] == 0x0A { count += 1 }
        i += 1
      }
      guard count > 0 else { continue }
      var allowed = min(count, limit)
      if isFullLayout {
        // No blank line just inside a bracket.
        if tokens[index - 1].kind == .open || tokens[index].kind == .close { allowed = 1 }
      }
      breaks[index] = allowed
    }
  }

  mutating func computeClosers() {
    var stack: [Int] = []
    for (index, token) in tokens.enumerated() {
      switch token.kind {
      case .open, .interpolationOpen: stack.append(index)
      case .close, .interpolationClose:
        if let open = stack.popLast() { closers[open] = Int32(index) }
      default: break
      }
    }
  }

  // MARK: - Lines

  struct Line {
    var first: Int
    var end: Int  // Past its last token.
    var level: Int
    var width: Int
    var isVerbatim = false
    /// The token this line lines up under, when the author aligned it with what follows a bracket.
    var alignedWith = -1
  }

  struct Frame {
    var openerLevel: Int
    var contentLevel: Int
    var isSwitch: Bool
    var byte: UInt8
    var firstOfStatement: Int
    /// A frame for `#if`.
    var isDirective = false
    /// The statement this bracket is part of goes on after it closes.
    var outerStatementFirst = 0
    /// What follows the bracket on its own line, and that token's column in the original.
    var alignToken = -1
    var alignColumn = -1
  }

  @inline(__always) func isByte(_ token: Token, _ byte: UInt8) -> Bool { token.length == 1 && t[token.start] == byte }

  func equals(_ token: Token, _ word: StaticString) -> Bool {
    token.length == word.utf8CodeUnitCount && memcmp(t + token.start, word.utf8Start, token.length) == 0
  }

  /// The level of every line, from the bracket that's open at its start and whether its statement goes on.
  func measureLines() -> [Line] {
    var lines: [Line] = []
    guard !tokens.isEmpty else { return lines }
    lines.reserveCapacity(source.lines.starts.count)
    var frames: [Frame] = []
    frames.reserveCapacity(32)
    var pendingSwitch = false
    var statementFirst = 0
    var index = 0
    var previousCode = -1  // The last token that isn't a comment.
    var afterDirective = false  // `#if os(macOS)` is a line of its own, whatever its last token looks like.
    var previousContinued = false  // A chain's next link goes on where the last one went.
    let indentWidth = options.useTabs ? 4 : options.indentWidth
    let aligned = rules.caseAlignsWithSwitch

    while index < tokens.count {
      let first = index
      var end = index + 1
      while end < tokens.count, breaks[end] == 0 { end += 1 }
      let token = tokens[first]
      let frame = frames.last
      let content = frame?.contentLevel ?? 0
      var level = content
      var isVerbatim = false

      if token.kind == .close || token.kind == .interpolationClose {
        level = frame?.openerLevel ?? 0
      } else if token.kind == .directive {
        if let keyword = directiveWord(token), rules.swiftRawStrings {
          // Swift's `#if` indents what's inside it.
          if keyword == "if" {
            // Inside a chain of `.a()` lines it's one of them.
            level = statementFirst < first && indentOfLine(tokens[statementFirst].start) < indentOfLine(token.start) ? content + 1 : content
          } else if keyword == "else" || keyword == "elseif" || keyword == "endif" {
            level = frame?.isDirective == true ? frame!.openerLevel : content
          }
        } else {
          isVerbatim = true  // A preprocessor line stays where it's written.
        }
      } else if frame?.isSwitch == true, isCaseLabel(token) {
        level = aligned ? frame!.openerLevel : frame!.openerLevel + 1
      } else if first > 0, previousCode >= 0, !afterDirective, continues(first: first, previous: previousCode, statementFirst: statementFirst, frame: frame, previousContinued: previousContinued) {
        level = content + 1
      }
      previousContinued = level > content && token.kind != .close
      var alignedWith = -1
      if let frame, frame.alignToken >= 0, !isVerbatim, token.kind != .close, originalColumn(first) == frame.alignColumn {
        alignedWith = frame.alignToken
      }
      if frame?.byte == 0x28 && tokens[Int(frame!.firstOfStatement)].kind == .interpolationOpen { isVerbatim = true }

      // A line starts a new statement unless it continued one; a bracket's content starts one too.
      if level == content, token.kind != .close { statementFirst = first }
      afterDirective = token.kind == .directive

      var width = (isVerbatim ? 0 : level) * indentWidth
      var tokenIndex = first
      var lineFrameLevel = level
      while tokenIndex < end {
        let currentFrameLevel = lineFrameLevel
        let current = tokens[tokenIndex]
        if tokenIndex > first, shouldSpace(tokenIndex) { width += 1 }
        width += current.length
        switch current.kind {
        case .open, .interpolationOpen:
          let byte = t[current.end - 1]
          let isBrace = byte == 0x7B
          let isSwitch = isBrace && pendingSwitch
          if isBrace { pendingSwitch = false }
          let contentLevel = isSwitch && !aligned ? currentFrameLevel + 2 : currentFrameLevel + 1
          var opened = Frame(openerLevel: currentFrameLevel, contentLevel: contentLevel, isSwitch: isSwitch, byte: byte, firstOfStatement: tokenIndex)
          opened.outerStatementFirst = statementFirst
          if byte != 0x7B, tokenIndex + 1 < end {
            opened.alignToken = tokenIndex + 1
            opened.alignColumn = originalColumn(tokenIndex + 1)
          }
          frames.append(opened)
          statementFirst = tokenIndex + 1
        case .close, .interpolationClose:
          var popped: Frame?
          if !frames.isEmpty, !(frames.last!.isDirective) { popped = frames.removeLast() } else if let found = frames.lastIndex(where: { !$0.isDirective }) { popped = frames.remove(at: found) }
          // A `{` after `b) ` belongs to the statement that `if (a &&` started, not to the line it's on.
          if let popped {
            statementFirst = popped.outerStatementFirst
            lineFrameLevel = min(lineFrameLevel, popped.openerLevel)
          }
        case .keyword:
          if equals(current, "switch") || (equals(current, "match") && !rules.caseAlignsWithSwitch && source.profile.spec.name == "PHP") {
            pendingSwitch = true
          }
        case .directive:
          if rules.swiftRawStrings, let keyword = directiveWord(current) {
            if keyword == "if" {
              // Whether `#if` indents is the author's: swift-format does, Xcode doesn't, and neither is wrong.
              let indents = end < tokens.count && indentOfLine(tokens[end].start) > indentOfLine(current.start)
              frames.append(Frame(openerLevel: level, contentLevel: indents ? level + 1 : level, isSwitch: false, byte: 0x23, firstOfStatement: tokenIndex, isDirective: true))
            } else if keyword == "endif", frames.last?.isDirective == true {
              frames.removeLast()
            }
          }
        case .punctuation:
          if isByte(current, 0x3B) { statementFirst = tokenIndex + 1 }
        default: break
        }
        if current.kind != .comment, current.kind != .docComment { previousCode = tokenIndex }
        tokenIndex += 1
      }
      lines.append(Line(first: first, end: end, level: level, width: width, isVerbatim: isVerbatim, alignedWith: alignedWith))
      index = end
    }
    return lines
  }

  private func directiveWord(_ token: Token) -> String? {
    guard token.length > 1 else { return nil }
    return String(decoding: UnsafeBufferPointer(start: t + token.start + 1, count: token.length - 1), as: UTF8.self)
  }

  private func isCaseLabel(_ token: Token) -> Bool {
    if token.kind == .attribute, equals(token, "@unknown") { return true }
    return (token.kind == .keyword || token.kind == .declarationKeyword) && (equals(token, "case") || equals(token, "default"))
  }

  /// Whether a line goes on with the statement of the line before: an operator ends that one or starts this one,
  /// or a comma list goes on in a statement that a keyword started, or a control word's body has no braces.
  private func continues(first: Int, previous: Int, statementFirst: Int, frame: Frame?, previousContinued: Bool) -> Bool {
    let last = tokens[previous]
    let token = tokens[first]
    // A blank line ends a statement, and a `{` on its own line starts a block.
    if breaks[first] > 1 { return false }
    if token.kind == .open, t[token.start] == 0x7B { return false }
    // In CSS a line is a selector or a declaration: neither `.a` nor `*` is an operator there.
    if case .cssSelectors = rules.outline {
      if last.kind == .close || last.kind == .open || isByte(last, 0x3B) || token.kind == .comment { return false }
      return statementFirst < first && indentOfLine(tokens[statementFirst].start) < indentOfLine(token.start)
    }
    // A comment goes where the code after it goes; only its own indentation can't say.
    if token.kind == .comment || token.kind == .docComment {
      var next = first + 1
      while next < tokens.count, tokens[next].kind == .comment || tokens[next].kind == .docComment { next += 1 }
      if last.kind == .punctuation, !isByte(last, 0x3A), !isByte(last, 0x3B), !isByte(last, 0x2C), endsWithOperator(last, index: previous) { return true }
      guard next < tokens.count, startsWithOperator(tokens[next], index: next), !isByte(last, 0x2C), last.kind != .open else { return false }
      return last.kind != .close || isDeeperThanStatement(token, statementFirst: statementFirst, first: first)
    }
    switch last.kind {
    case .open, .interpolationOpen, .attribute: return false
    case .comment, .docComment, .directive: return false
    default: break
    }
    if last.kind == .punctuation {
      if isByte(last, 0x3B) { return false }
      if isByte(last, 0x2C) {
        // In brackets, a comma separates; in a block, it goes on a `guard a,` or a `let a = 1,` that a keyword started.
        guard frame == nil || frame!.byte == 0x7B || frame!.byte == 0x23 else { return false }
        return statementFirst < tokens.count
          && (tokens[statementFirst].kind == .keyword || tokens[statementFirst].kind == .declarationKeyword)
          && !isCaseLabel(tokens[statementFirst]) && statementFirst != first
      }
      if isByte(last, 0x3A) { return false }
      if endsWithOperator(last, index: previous) { return true }
    }
    if token.kind == .keyword, equals(token, "else") || equals(token, "where") && !rules.caseAlignsWithSwitch { return false }
    if startsWithOperator(token, index: first) {
      // In a list, `.a,` is an element; after a `(` it isn't going on.
      if isByte(last, 0x2C) || last.kind == .open { return false }
      // After a `}` or `)`, both are in use: swift-format lines `.a()` up with the bracket, others indent it.
      return last.kind != .close || previousContinued || isDeeperThanStatement(token, statementFirst: statementFirst, first: first)
    }
    // `if (x)` with its body on the next line, in languages that allow one; `else` likewise.
    if !rules.newlineEndsStatements, last.kind == .close, t[last.start] == 0x29, let open = openerIndex(ofClose: previous), open > 0 {
      let before = tokens[open - 1]
      if before.kind == .keyword, equals(before, "if") || equals(before, "for") || equals(before, "while") || equals(before, "foreach") {
        return !(token.kind == .open && t[token.start] == 0x7B)
      }
    }
    if !rules.newlineEndsStatements, last.kind == .keyword, equals(last, "else") {
      return !(token.kind == .open && t[token.start] == 0x7B)
    }
    // Nothing on these lines says so (`async throws`, `where T: U`, a C return type): the author's indentation does.
    // It holds a statement together that already is, and costs one thing: `a()` over-indented under `b()` in a language
    // without semicolons stays over-indented.
    if last.kind == .close, t[last.start] == 0x7D { return false }
    // `{ a in` and `(a` end their line with a bracket's first words: what's below is its content, not more of them.
    if let frame, frame.firstOfStatement < tokens.count, tokens[frame.firstOfStatement].end <= last.end,
      memchr(t + tokens[frame.firstOfStatement].end, 0x0A, last.end - tokens[frame.firstOfStatement].end) == nil
    {
      return false
    }
    if statementFirst < first, indentOfLine(tokens[statementFirst].start) < indentOfLine(token.start) { return true }
    return false
  }

  private func isDeeperThanStatement(_ token: Token, statementFirst: Int, first: Int) -> Bool {
    statementFirst < first && indentOfLine(tokens[statementFirst].start) < indentOfLine(token.start)
  }

  /// The visual width of the indentation of a line in the original, a tab being 8.
  private func indentOfLine(_ offset: Int) -> Int {
    var start = offset
    while start > 0, t[start - 1] != 0x0A { start -= 1 }
    var column = 0
    while start < offset {
      if t[start] == 0x20 { column += 1 } else if t[start] == 0x09 { column = (column / 8 + 1) * 8 } else { break }
      start += 1
    }
    return column
  }

  /// The visual column of a token in the original.
  private func originalColumn(_ index: Int) -> Int {
    let offset = tokens[index].start
    var start = offset
    while start > 0, t[start - 1] != 0x0A { start -= 1 }
    var column = 0
    while start < offset {
      column = t[start] == 0x09 ? (column / 8 + 1) * 8 : column + ((t[start] & 0xC0) == 0x80 ? 0 : 1)
      start += 1
    }
    return column
  }

  private func openerIndex(ofClose close: Int) -> Int? {
    var i = close - 1
    var depth = 0
    while i >= 0, close - i < 512 {
      if tokens[i].kind == .close { depth += 1 } else if tokens[i].kind == .open {
        if depth == 0 { return i }
        depth -= 1
      }
      i -= 1
    }
    return nil
  }

  private func endsWithOperator(_ token: Token, index: Int) -> Bool {
    let c = t[token.end - 1]
    let hasSpaceBefore = token.start > 0 && (t[token.start - 1] == 0x20 || t[token.start - 1] == 0x09)
    switch c {
    case 0x2B, 0x2D:  // `i++` ended a statement; `a +` didn't.
      if token.length >= 2, t[token.end - 2] == c { return false }
      return true
    case 0x3F, 0x2A, 0x26:  // `String?`, `T*`, `T&` are types.
      return hasSpaceBefore
    case 0x3D, 0x2F, 0x25, 0x7C, 0x5E, 0x2E:  // = / % | ^ .
      return true
    case 0x3E:  // `->`, `=>`, `>=`; a `>` needs a space before it to not be a generic's.
      if token.length >= 2 { return true }
      return token.start > 0 && t[token.start - 1] == 0x20
    case 0x3C:
      return token.start > 0 && t[token.start - 1] == 0x20
    default:
      return false
    }
  }

  private func startsWithOperator(_ token: Token, index: Int) -> Bool {
    guard token.kind == .punctuation else { return false }
    let c = t[token.start]
    switch c {
    case 0x2E, 0x3F, 0x3A:  // . ? :
      return !isByte(token, 0x3A) || token.length == 1
    case 0x3D, 0x2F, 0x25, 0x7C, 0x5E:  // = / % | ^
      return true
    case 0x2B, 0x2D, 0x2A, 0x26, 0x21, 0x7E, 0x3C, 0x3E:
      // An operator with a space after it; `-x`, `*p`, `&x`, `!x` start a statement.
      guard index + 1 < tokens.count else { return false }
      if c == 0x21 || c == 0x7E { return false }
      if c == 0x3C && token.length == 1 { return false }
      if token.length >= 2 && (t[token.start + 1] == c) { return c == 0x26 }  // `&&` goes on; `++x`, `--x` don't.
      return tokens[index + 1].start > token.end
    default:
      return false
    }
  }

  // MARK: - Spacing

  /// Whether a space goes before this token, on the same line.
  func shouldSpace(_ index: Int) -> Bool {
    let a = tokens[index - 1]
    let b = tokens[index]
    let hadGap = b.start > a.end
    // Inside interpolation and next to it: as written.
    switch a.kind {
    case .interpolationOpen: return hadGap
    case .string where b.kind == .interpolationOpen: return false
    default: break
    }
    if b.kind == .interpolationClose { return hadGap }
    if a.kind == .interpolationClose, b.kind == .string { return false }
    if b.kind == .comment || b.kind == .docComment { return true }
    if a.kind == .comment || a.kind == .docComment { return true }
    if a.kind == .directive || b.kind == .directive { return hadGap }

    let aByte = t[a.end - 1]
    let bByte = t[b.start]
    if b.length == 1, bByte == 0x2C || bByte == 0x3B { return false }
    if a.length == 1, aByte == 0x2C || aByte == 0x3B {
      if b.kind == .close { return bByte == 0x7D && hadGap }
      return true
    }
    if a.kind == .open {
      if aByte == 0x7B {
        if b.kind == .close { return false }
        return rules.spacesInsideBraces ? true : hadGap
      }
      return false
    }
    if b.kind == .close {
      if bByte == 0x7D { return rules.spacesInsideBraces ? true : hadGap }
      return false
    }
    if rules.preservesOperatorSpacing { return hadGap }
    if b.kind == .open, bByte == 0x7B {
      switch a.kind {
      case .identifier, .keyword, .declarationKeyword, .close, .string, .number:
        return rules.bracesFollowTightly ? hadGap : true
      default:
        return hadGap
      }
    }
    if a.kind == .keyword, b.kind == .open, bByte == 0x28, rules.spacesAfterControlWords, isControlWord(a) { return true }
    if b.length == 1, bByte == 0x3A { return hadGap }
    if a.length == 1, aByte == 0x3A {
      if hadGap { return true }
      if case .jsonKeys = rules.outline { return true }
      guard rules.colonHugsLeft, isFullLayout || rules.parameters != .none else { return false }
      // `x:Int`, not `a[1:2]`, `foo(a:b:)`, `a:hover`, `::`.
      if rules.extraIdentifierBytes.utf8.contains(0x2D) { return false }
      guard index >= 2 else { return false }
      let before = tokens[index - 2]
      guard before.kind == .identifier || before.kind == .string else { return false }
      guard b.kind == .identifier || b.kind == .string || b.kind == .number || b.kind == .open else { return false }
      if index + 1 < tokens.count, isByte(tokens[index + 1], 0x3A) { return false }
      return !insideSquareBrackets(index)
    }
    if a.kind == .punctuation, isSpacedOperator(a, index - 1) { return true }
    if b.kind == .punctuation, isSpacedOperator(b, index) { return true }
    return hadGap
  }

  /// A cheap look back: is the nearest unclosed bracket a `[`?
  private func insideSquareBrackets(_ index: Int) -> Bool {
    var i = index - 1
    var depth = 0
    while i >= 0, index - i < 128 {
      if tokens[i].kind == .close { depth += 1 } else if tokens[i].kind == .open {
        if depth == 0 { return t[tokens[i].start] == 0x5B }
        depth -= 1
      }
      i -= 1
    }
    return false
  }

  private func isControlWord(_ token: Token) -> Bool {
    equals(token, "if") || equals(token, "for") || equals(token, "while") || equals(token, "switch")
      || equals(token, "catch") || equals(token, "foreach") || equals(token, "when") || equals(token, "guard")
      || equals(token, "elif") || equals(token, "until") || equals(token, "repeat")
  }

  /// `a==b` becomes `a == b`. Only operators that can't be anything else, between values, and never passed as a function.
  private func isSpacedOperator(_ token: Token, _ index: Int) -> Bool {
    guard index > 0, index + 1 < tokens.count else { return false }
    let p = t + token.start
    var isKnown = false
    switch token.length {
    case 1: isKnown = p[0] == 0x3D
    case 2:
      switch (p[0], p[1]) {
      case (0x3D, 0x3D), (0x21, 0x3D), (0x2B, 0x3D), (0x2D, 0x3D), (0x2A, 0x3D), (0x2F, 0x3D), (0x25, 0x3D), (0x26, 0x26), (0x7C, 0x7C), (0x3C, 0x3D), (0x3E, 0x3D), (0x3F, 0x3F), (0x3D, 0x3E), (0x3A, 0x3D):
        isKnown = true
      case (0x2D, 0x3E): isKnown = rules.arrowIsSpaced
      default: break
      }
    case 3:
      isKnown = (p[0] == 0x3D && p[1] == 0x3D && p[2] == 0x3D) || (p[0] == 0x21 && p[1] == 0x3D && p[2] == 0x3D)
    default: break
    }
    guard isKnown else { return false }
    let left = tokens[index - 1]
    let right = tokens[index + 1]
    // `(==)`, `reduce(0, +)`, `operator==(`, `func ==(`, `<T=U>`.
    guard isValueEnd(left), isValueStart(right) else { return false }
    // Written with a space on one side only, it may be a language's own use of it (`T&& x`).
    let gapLeft = token.start > left.end
    let gapRight = right.start > token.end
    if gapLeft != gapRight { return false }
    // Keyword arguments and defaults stay tight where that's the style: `f(a=1)`.
    if token.length == 1, !isFullLayout, !gapLeft, enclosingIsParenthesis(index) { return false }
    if token.length == 1, rules.extraIdentifierBytes.utf8.contains(0x2D) { return gapLeft }
    return true
  }

  private func enclosingIsParenthesis(_ index: Int) -> Bool {
    var i = index - 1
    var depth = 0
    while i >= 0, index - i < 256 {
      if tokens[i].kind == .close { depth += 1 } else if tokens[i].kind == .open {
        if depth == 0 { return t[tokens[i].start] == 0x28 }
        depth -= 1
      }
      i -= 1
    }
    return false
  }

  private func isValueEnd(_ token: Token) -> Bool {
    switch token.kind {
    case .identifier, .number, .string, .close: return true
    case .keyword:
      return equals(token, "self") || equals(token, "this") || equals(token, "true") || equals(token, "false") || equals(token, "nil") || equals(token, "null") || equals(token, "None") || equals(token, "True") || equals(token, "False") || equals(token, "super")
    default: return false
    }
  }

  private func isValueStart(_ token: Token) -> Bool {
    switch token.kind {
    case .identifier, .number, .string, .open, .keyword, .declarationKeyword: return true
    case .punctuation: return token.length == 1 && (t[token.start] == 0x2E || t[token.start] == 0x2D || t[token.start] == 0x21 || t[token.start] == 0x26 || t[token.start] == 0x2A)
    default: return false
    }
  }

  // MARK: - Wrapping

  /// Breaks the outermost list of each line over the print width, until none is or none can be.
  mutating func wrap() {
    guard isFullLayout, options.printWidth > 0 else { return }
    var pass = 0
    while pass < 12 {
      let lines = measureLines()
      var changed = false
      for line in lines where line.width > options.printWidth && !line.isVerbatim {
        if breakOutermostList(line) { changed = true }
      }
      if !changed { return }
      pass += 1
    }
  }

  /// Returns whether it broke anything.
  private mutating func breakOutermostList(_ line: Line) -> Bool {
    var index = line.first
    while index < line.end {
      let token = tokens[index]
      guard token.kind == .open, closers[index] > 0 else {
        // A multi-line token's width isn't this line's to fix.
        if token.kind == .string || token.kind == .comment || token.kind == .docComment, token.length > 0, memchr(t + token.start, 0x0A, token.length) != nil { return false }
        index += 1
        continue
      }
      let close = Int(closers[index])
      if close > index + 1, canBreak(open: index, close: close), breaks[index + 1] == 0 {
        apply(open: index, close: close)
        return true
      }
      // Past it: breaking something inside what stays on one line only makes both ugly.
      guard close < line.end else { return false }
      index = close + 1
    }
    return false
  }

  private func canBreak(open: Int, close: Int) -> Bool {
    let byte = t[tokens[open].start]
    var depth = 0
    var commas = 0
    var semicolons = 0
    var index = open + 1
    while index < close {
      let token = tokens[index]
      if token.kind == .open || token.kind == .interpolationOpen { depth += 1 } else if token.kind == .close || token.kind == .interpolationClose { depth -= 1 } else if depth == 0 {
        if isByte(token, 0x2C) { commas += 1 } else if isByte(token, 0x3B) { semicolons += 1 }
      }
      index += 1
    }
    // A statement block doesn't break into a list, nor `for (;;)`.
    if semicolons > 0 { return false }
    if byte == 0x7B, commas == 0 { return false }
    // A lone string or word gains nothing on its own line.
    if commas == 0, close == open + 2, tokens[open + 1].kind == .string || tokens[open + 1].kind == .identifier { return false }
    if open > 0, tokens[open - 1].kind == .punctuation, tokens[open - 1].length == 1, t[tokens[open - 1].start] == 0x2E { return false }
    return true
  }

  private mutating func apply(open: Int, close: Int) {
    breaks[open + 1] = max(breaks[open + 1], 1)
    breaks[close] = max(breaks[close], 1)
    var depth = 0
    var index = open + 1
    var commas = 0
    var lastCode = open
    while index < close {
      let token = tokens[index]
      if token.kind == .open || token.kind == .interpolationOpen { depth += 1 } else if token.kind == .close || token.kind == .interpolationClose { depth -= 1 } else if depth == 0, isByte(token, 0x2C) {
        commas += 1
        // A comment that stays on its element's line keeps its place.
        var next = index + 1
        while next < close, tokens[next].kind == .comment || tokens[next].kind == .docComment, breaks[next] == 0 { next += 1 }
        if next < close { breaks[next] = max(breaks[next], 1) }
      }
      if token.kind != .comment, token.kind != .docComment { lastCode = index }
      index += 1
    }
    guard !isByte(tokens[lastCode], 0x2C), options.trailingCommas else { return }
    let byte = t[tokens[open].start]
    let isCallShape = open > 0 && (tokens[open - 1].kind == .identifier || tokens[open - 1].kind == .close)
    let isList = byte == 0x5B || byte == 0x7B || (isCallShape && rules.callsTakeTrailingCommas)
    switch rules.trailingCommas {
    case .required: if isList { self.commas.insert(lastCode) }
    case .allowed: if isList, commas > 0 { self.commas.insert(lastCode) }
    case .never: break
    }
  }

  // MARK: - Writing

  mutating func run() -> [UInt8] {
    guard !tokens.isEmpty else { return [] }
    wrap()
    let lines = measureLines()
    var out = [UInt8]()
    out.reserveCapacity(source.count + source.count / 16 + 16)
    let indentUnit: [UInt8] = options.useTabs ? [0x09] : [UInt8](repeating: 0x20, count: options.indentWidth)
    // Where aligned lines line up: a token's column in the result.
    var columns = [Int32: Int]()
    var alignTargets = Set<Int32>()
    for line in lines where line.alignedWith >= 0 { alignTargets.insert(Int32(line.alignedWith)) }
    for (lineIndex, line) in lines.enumerated() {
      if lineIndex > 0 {
        for _ in 0..<breaks[line.first] { out.append(contentsOf: newline) }
      }
      // The indentation.
      let originalLineStart = lineStart(of: tokens[line.first].start)
      let originalIndent = tokens[line.first].start - originalLineStart
      var written = 0
      if !isFullLayout || line.isVerbatim {
        if breaksOriginally(line.first) || line.first == 0 {
          out.append(contentsOf: UnsafeBufferPointer(start: t + originalLineStart, count: originalIndent))
          written = originalIndent
        } else {
          // A new line made here (a wrap) in a layout that keeps indentation doesn't occur; keep the level.
          for _ in 0..<line.level { out.append(contentsOf: indentUnit) }
        }
      } else if line.alignedWith >= 0, let column = columns[Int32(line.alignedWith)] {
        // Tabs as far as they go, spaces the rest of the way.
        let tabs = options.useTabs ? column / 8 : 0
        for _ in 0..<tabs { out.append(0x09) }
        let spaces = column - tabs * 8
        out.append(contentsOf: repeatElement(0x20, count: spaces))
        written = tabs + spaces
      } else {
        for _ in 0..<line.level {
          out.append(contentsOf: indentUnit)
          written += indentUnit.count
        }
      }
      var lineStartInOutput = out.count - written
      var index = line.first
      while index < line.end {
        let token = tokens[index]
        if index > line.first, shouldSpace(index) {
          // A comment's distance is the author's; so is Go's alignment.
          let previous = tokens[index - 1]
          let gap = token.start - previous.end
          if (token.kind == .comment || token.kind == .docComment || rules.preservesOperatorSpacing), gap >= 1, isSpacesOnly(previous.end, token.start) {
            out.append(contentsOf: UnsafeBufferPointer(start: t + previous.end, count: gap))
          } else {
            out.append(0x20)
          }
        }
        if alignTargets.contains(Int32(index)) {
          // Visual, as the column it's compared with.
          var column = 0
          for byte in out[lineStartInOutput...] {
            column = byte == 0x09 ? (column / 8 + 1) * 8 : column + ((byte & 0xC0) == 0x80 ? 0 : 1)
          }
          columns[Int32(index)] = column
        }
        write(token, into: &out, indentChange: written - originalIndent)
        if token.length > 0, memchr(t + token.start, 0x0A, token.length) != nil, let last = out.lastIndex(of: 0x0A) { lineStartInOutput = last + 1 }
        if commas.contains(index) { out.append(0x2C) }
        index += 1
      }
    }
    out.append(contentsOf: newline)
    return out
  }

  private func isSpacesOnly(_ start: Int, _ end: Int) -> Bool {
    var i = start
    while i < end {
      if t[i] != 0x20, t[i] != 0x09 { return false }
      i += 1
    }
    return true
  }

  private func breaksOriginally(_ index: Int) -> Bool {
    guard index > 0 else { return true }
    let gapStart = tokens[index - 1].end
    return memchr(t + gapStart, 0x0A, tokens[index].start - gapStart) != nil
  }

  private func lineStart(of offset: Int) -> Int {
    var i = offset
    while i > 0, t[i - 1] == 0x20 || t[i - 1] == 0x09 { i -= 1 }
    return i
  }

  private func write(_ token: Token, into out: inout [UInt8], indentChange: Int) {
    if token.kind == .string, let preferred = preferredQuote, swapsQuote(token, to: preferred) {
      out.append(preferred)
      out.append(contentsOf: UnsafeBufferPointer(start: t + token.start + 1, count: token.length - 2))
      out.append(preferred)
      return
    }
    // A block comment moves with its first line, so its inner alignment stays.
    if isFullLayout, indentChange != 0, token.kind == .comment || token.kind == .docComment, let first = memchr(t + token.start, 0x0A, token.length) {
      var at = token.start
      var lineEnd = UnsafePointer(first.assumingMemoryBound(to: UInt8.self)) - t
      let end = token.end
      while true {
        out.append(contentsOf: UnsafeBufferPointer(start: t + at, count: lineEnd - at))
        guard lineEnd < end else { break }
        out.append(0x0A)
        at = lineEnd + 1
        if indentChange > 0 {
          if at < end, t[at] != 0x0A, t[at] != 0x0D { out.append(contentsOf: repeatElement(0x20, count: indentChange)) }
        } else {
          var removed = 0
          while removed < -indentChange, at < end, t[at] == 0x20 {
            at += 1
            removed += 1
          }
        }
        if let next = memchr(t + at, 0x0A, end - at) {
          lineEnd = UnsafePointer(next.assumingMemoryBound(to: UInt8.self)) - t
        } else {
          lineEnd = end
        }
      }
      return
    }
    out.append(contentsOf: UnsafeBufferPointer(start: t + token.start, count: token.length))
  }

  private func swapsQuote(_ token: Token, to preferred: UInt8) -> Bool {
    let first = t[token.start]
    guard first == 0x22 || first == 0x27, first != preferred, token.length >= 2, t[token.end - 1] == first else { return false }
    // A triple quote, an escape or the other quote inside: it stays.
    if token.length >= 6, t[token.start + 1] == first, t[token.start + 2] == first { return false }
    var i = token.start + 1
    while i < token.end - 1 {
      let c = t[i]
      if c == 0x5C || c == 0x22 || c == 0x27 || c == 0x0A { return false }
      i += 1
    }
    return true
  }
}

extension PrettyOptions {
  /// The options for a file: from the nearest `.editorconfig`, `.prettierrc`, `.swift-format`, `rustfmt.toml` or
  /// `.clang-format` upward, what the language's own tool does by default, and the text's own indentation.
  public static func resolve(path: String?, source: SourceFile) -> PrettyOptions {
    var options = PrettyOptions()
    let language = source.profile.spec.name
    if language == "Go" {
      options.useTabs = true
      options.indentWidth = 1
      options.printWidth = 0
    }
    if language == "Python" { options.maxBlankLines = 2 }
    if let detected = detectIndent(source) {
      if language != "Go" {
        options.useTabs = detected.tabs
        options.indentWidth = detected.tabs ? 1 : detected.width
      }
    }
    guard let path else { return options }
    var folder = (path as NSString).deletingLastPathComponent
    var found = Set<String>()
    while !folder.isEmpty, folder != "/" {
      read(folder + "/.editorconfig", &found, &options, language: language, path: path)
      for name in [".prettierrc", ".prettierrc.json", ".prettierrc.yaml", ".prettierrc.yml"] {
        read(folder + "/" + name, &found, &options, language: language, path: path)
      }
      read(folder + "/.swift-format", &found, &options, language: language, path: path)
      read(folder + "/rustfmt.toml", &found, &options, language: language, path: path)
      read(folder + "/.rustfmt.toml", &found, &options, language: language, path: path)
      read(folder + "/.clang-format", &found, &options, language: language, path: path)
      if FileManager.default.fileExists(atPath: folder + "/.git") { break }
      folder = (folder as NSString).deletingLastPathComponent
    }
    return options
  }

  private static func read(_ file: String, _ found: inout Set<String>, _ options: inout PrettyOptions, language: String, path: String) {
    let name = (file as NSString).lastPathComponent
    let kind = name.hasPrefix(".prettierrc") ? ".prettierrc" : name.hasSuffix("rustfmt.toml") ? "rustfmt" : name
    guard !found.contains(kind), let data = FileManager.default.contents(atPath: file) else { return }
    let text = String(decoding: data, as: UTF8.self)
    func applies(_ languages: String...) -> Bool { languages.contains(language) }
    switch kind {
    case ".editorconfig":
      found.insert(kind)
      options.applyEditorConfig(text, path: path)
    case ".prettierrc":
      guard applies("JavaScript", "TypeScript", "CSS", "JSON", "HTML", "Markdown", "YAML") else { return }
      found.insert(kind)
      if let width = number(in: text, "tabWidth") { options.indentWidth = width }
      if flag(in: text, "useTabs") == true { options.useTabs = true; options.indentWidth = 1 }
      options.printWidth = number(in: text, "printWidth") ?? 80
      if let single = flag(in: text, "singleQuote") { options.quote = single ? 0x27 : 0x22 } else { options.quote = 0x22 }
      if text.contains("\"none\"") || text.contains("trailingComma: none") { options.trailingCommas = false }
    case ".swift-format":
      guard applies("Swift") else { return }
      found.insert(kind)
      if let width = number(in: text, "lineLength") { options.printWidth = width }
      if let spaces = number(in: text, "spaces") { options.indentWidth = spaces; options.useTabs = false }
      if text.contains("\"tabs\"") { options.useTabs = true; options.indentWidth = 1 }
    case "rustfmt":
      guard applies("Rust") else { return }
      found.insert(kind)
      if let width = number(in: text, "max_width") { options.printWidth = width }
      if let spaces = number(in: text, "tab_spaces") { options.indentWidth = spaces }
      if text.contains("hard_tabs = true") { options.useTabs = true; options.indentWidth = 1 }
    case ".clang-format":
      guard applies("C", "C++", "Objective-C") else { return }
      found.insert(kind)
      if let width = number(in: text, "ColumnLimit") { options.printWidth = width }
      if let spaces = number(in: text, "IndentWidth") { options.indentWidth = spaces }
    default: break
    }
  }

  private mutating func applyEditorConfig(_ text: String, path: String) {
    let name = (path as NSString).lastPathComponent
    let extensionName = (path as NSString).pathExtension
    var applies = true
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        let section = line.dropFirst().dropLast()
        applies = section == "*" || section == "**" || section == "*.\(extensionName)" || section == name
          || (section.hasPrefix("*.{") && section.dropFirst(3).dropLast().split(separator: ",").contains(where: { $0 == extensionName }))
        continue
      }
      guard applies, let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).lowercased()
      switch key {
      case "indent_style":
        useTabs = value == "tab"
        if useTabs { indentWidth = 1 }
      case "indent_size":
        if let size = Int(value), !useTabs { indentWidth = size }
      case "max_line_length":
        if let size = Int(value) { printWidth = size }
      default: break
      }
    }
  }

  private static func number(in text: String, _ key: String) -> Int? {
    guard let range = text.range(of: key) else { return nil }
    var digits = ""
    for character in text[range.upperBound...].prefix(16) {
      if character.isNumber { digits.append(character) } else if !digits.isEmpty { break } else if character == "\n" { return nil }
    }
    return Int(digits)
  }

  private static func flag(in text: String, _ key: String) -> Bool? {
    guard let range = text.range(of: key) else { return nil }
    let rest = text[range.upperBound...].prefix(12)
    if rest.contains("true") { return true }
    if rest.contains("false") { return false }
    return nil
  }

  /// The text's own indentation, as far as code can tell: what a line starting inside a new bracket adds to the line
  /// that opened it. Alignment, comments and continuation lines don't count, as they'd vote for widths no one chose.
  private static func detectIndent(_ source: SourceFile) -> (tabs: Bool, width: Int)? {
    let t = source.text
    let tokens = source.tokens
    var tabs = 0
    var steps = [Int](repeating: 0, count: 9)
    var seen = 0
    func indent(_ offset: Int) -> (width: Int, usesTab: Bool) {
      var start = offset
      while start > 0, t[start - 1] != 0x0A { start -= 1 }
      var width = 0
      var usesTab = false
      while t[start] == 0x20 || t[start] == 0x09 {
        if t[start] == 0x09 { usesTab = true }
        width += 1
        start += 1
      }
      return (width, usesTab)
    }
    for index in tokens.indices.dropLast() where tokens[index].kind == .open {
      let next = tokens[index + 1]
      if next.kind == .close { continue }
      let gap = tokens[index].end
      guard memchr(t + gap, 0x0A, next.start - gap) != nil else { continue }
      let opener = indent(tokens[index].start)
      let inner = indent(next.start)
      if inner.usesTab {
        tabs += 1
      } else {
        let step = inner.width - opener.width
        if step >= 1, step <= 8 { steps[step] += 1 }
      }
      seen += 1
      if seen > 4000 { break }
    }
    if seen == 0 { return nil }
    if tabs * 2 > seen { return (true, 1) }
    guard let best = steps.indices.max(by: { steps[$0] < steps[$1] }), steps[best] > 0 else { return nil }
    return (false, best)
  }
}

/// The changes between two texts by lines, smallest first: what an editor applies to keep its cursor and undo steps.
public struct LineEdit: Equatable, Sendable {
  /// The lines of the old text it replaces.
  public var startLine: Int
  public var endLine: Int
  /// The new text, with its line ends.
  public var text: [UInt8]
}

extension Pretty {
  /// The edits from one text to another. Myers' diff over lines; a huge difference is one edit.
  public static func edits(from old: UnsafeBufferPointer<UInt8>, to new: UnsafeBufferPointer<UInt8>) -> [LineEdit] {
    let a = lines(old)
    let b = lines(new)
    var start = 0
    while start < a.count, start < b.count, equal(old, a[start], new, b[start]) { start += 1 }
    var endA = a.count
    var endB = b.count
    while endA > start, endB > start, equal(old, a[endA - 1], new, b[endB - 1]) {
      endA -= 1
      endB -= 1
    }
    if start == endA, start == endB { return [] }
    func text(_ from: Int, _ to: Int) -> [UInt8] {
      guard from < to else { return [] }
      return Array(new[b[from].lowerBound..<b[to - 1].upperBound])
    }
    let n = endA - start
    let m = endB - start
    let limit = 1024
    guard n + m > 0, n * m > 0 else { return [LineEdit(startLine: start, endLine: endA, text: text(start, endB))] }
    // Forward Myers, kept per D for the path back.
    var trace: [[Int: Int]] = []
    var v: [Int: Int] = [1: 0]
    var found = false
    outer: for d in 0...min(limit, n + m) {
      trace.append(v)
      var k = -d
      while k <= d {
        var x = (k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0))) ? (v[k + 1] ?? 0) : (v[k - 1] ?? 0) + 1
        var y = x - k
        while x < n, y < m, equal(old, a[start + x], new, b[start + y]) {
          x += 1
          y += 1
        }
        v[k] = x
        if x >= n, y >= m {
          found = true
          break outer
        }
        k += 2
      }
    }
    guard found else { return [LineEdit(startLine: start, endLine: endA, text: text(start, endB))] }
    // Back from the end: the matching runs.
    var x = n
    var y = m
    var edits: [LineEdit] = []
    var editEndX = n
    var editEndY = m
    for d in stride(from: trace.count - 1, through: 0, by: -1) {
      let previous = trace[d]
      let k = x - y
      let previousK = (k == -d || (k != d && (previous[k - 1] ?? 0) < (previous[k + 1] ?? 0))) ? k + 1 : k - 1
      let previousX = previous[previousK] ?? 0
      let previousY = previousX - previousK
      let snakeStartX = d == 0 ? 0 : (previousK == k + 1 ? previousX : previousX + 1)
      if x > snakeStartX {
        // A run of equal lines ends an edit that's between it and the one after.
        if x < editEndX || y < editEndY {
          edits.append(LineEdit(startLine: start + x, endLine: start + editEndX, text: text(start + y, start + editEndY)))
        }
        let run = x - snakeStartX
        editEndX = x - run
        editEndY = y - run
      }
      x = previousX
      y = previousY
      if d == 0 { break }
    }
    if editEndX > 0 || editEndY > 0 {
      edits.append(LineEdit(startLine: start, endLine: start + editEndX, text: text(start, start + editEndY)))
    }
    return edits.reversed()
  }

  private static func lines(_ text: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
    var result: [Range<Int>] = []
    var start = 0
    guard let base = text.baseAddress else { return [] }
    while start < text.count {
      if let found = memchr(base + start, 0x0A, text.count - start) {
        let end = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - base + 1
        result.append(start..<end)
        start = end
      } else {
        result.append(start..<text.count)
        start = text.count
      }
    }
    return result
  }

  @inline(__always) private static func equal(_ a: UnsafeBufferPointer<UInt8>, _ x: Range<Int>, _ b: UnsafeBufferPointer<UInt8>, _ y: Range<Int>) -> Bool {
    x.count == y.count && memcmp(a.baseAddress! + x.lowerBound, b.baseAddress! + y.lowerBound, x.count) == 0
  }
}
