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
  /// Columns a statement's continuation lines go in; 0 is one indentation level. clang-format's and dart format's
  /// are 4 whatever the indentation.
  public var continuationIndent = 0
  /// Where the language's tools differ, a project's configuration settles these (`.clang-format`'s
  /// `IndentCaseLabels`, `NamespaceIndentation`, `AccessModifierOffset`); nil follows the file.
  public var indentsCaseLabels: Bool?
  public var indentsNamespaces: Bool?
  public var accessModifierOffset: Int?

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

  public static func format(_ source: SourceFile, path: String? = nil, options given: PrettyOptions) -> Output {
    // A byte order mark stays where it is; what follows it is the start of the file. No token can show it's kept.
    if hasByteOrderMark(source.text, source.count) {
      var inner = format(SourceFile(bytes: source.bytes.dropFirst(3), profile: source.profile), path: path, options: given)
      inner.text.insert(contentsOf: source.bytes.prefix(3), at: 0)
      return inner
    }
    // Widths come from editors and project files, which can say anything.
    var options = given
    options.indentWidth = min(max(options.indentWidth, 1), 16)
    options.printWidth = max(options.printWidth, 0)
    options.maxBlankLines = max(options.maxBlankLines, 0)
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
    // Scala 3 without braces: indentation is its blocks, which tokens can't see.
    if layout == .full, source.profile.rules.optionalBraces, IndentationBlocks.used(in: source) { layout = .spacing }
    // A PHP template: its code's indentation follows the markup around it, which the formatter doesn't see.
    if layout == .full, source.profile.rules.inlineMarkup, hasMarkup(source) { layout = .spacing }
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

  /// Whether text sits between the code's `?>` and `<?php`, or before the first.
  private static func hasMarkup(_ source: SourceFile) -> Bool {
    let tokens = source.tokens
    guard let first = tokens.first else { return false }
    if first.kind == .string { return true }
    for (index, token) in tokens.enumerated() where token.length == 2 && source.text[token.start] == 0x3F && source.text[token.start + 1] == 0x3E && token.kind == .punctuation {
      if index + 1 < tokens.count { return true }
    }
    return false
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

/// Whether a file of a language with optional braces (Scala 3) has blocks made by indentation: a line ending in `:`
/// with deeper lines below, an `end` marker, or a line ending in `=`, `=>` or a word like `then` or `match` with two
/// statements below it at one deeper column.
enum IndentationBlocks {
  static func used(in source: SourceFile) -> Bool {
    let t = source.text
    let tokens = source.tokens
    struct Row { var first: Int; var last: Int; var indent: Int; var depth: Int }
    var rows: [Row] = []
    var depth = 0
    var index = 0
    func indent(_ offset: Int) -> Int { offset - Int(source.lines.starts[source.lines.line(of: offset)]) }
    while index < tokens.count {
      var end = index + 1
      while end < tokens.count, memchr(t + tokens[end - 1].end, 0x0A, tokens[end].start - tokens[end - 1].end) == nil { end += 1 }
      var last = end - 1
      while last > index, tokens[last].kind == .comment || tokens[last].kind == .docComment { last -= 1 }
      let startDepth = depth
      for i in index..<end {
        let token = tokens[i]
        if token.kind == .open, t[token.start] != 0x7B { depth += 1 } else if token.kind == .close, t[token.start] != 0x7D { depth = max(0, depth - 1) }
      }
      if tokens[index].kind != .comment, tokens[index].kind != .docComment, tokens[index].kind != .string || last > index {
        rows.append(Row(first: index, last: last, indent: indent(tokens[index].start), depth: startDepth))
      }
      index = end
    }
    func word(_ token: Token) -> String { String(decoding: UnsafeBufferPointer(start: t + token.start, count: token.length), as: UTF8.self) }
    func isOperatorStart(_ row: Row) -> Bool {
      let token = tokens[row.first]
      return token.kind == .punctuation && token.length <= 3
    }
    for (n, row) in rows.enumerated() where row.depth == 0 {
      let first = word(tokens[row.first])
      if first == "end", row.last - row.first <= 1 { return true }
      let last = tokens[row.last]
      let ending = word(last)
      guard n + 1 < rows.count, rows[n + 1].indent > row.indent, rows[n + 1].depth == 0 else { continue }
      if last.kind == .punctuation, ending == ":" { return true }
      let opens = ["=", "=>", "then", "else", "do", "with", "match", "yield", "try", "finally", "catch"]
      guard opens.contains(ending), n + 2 < rows.count else { continue }
      let a = rows[n + 1]
      let b = rows[n + 2]
      if b.indent == a.indent, b.depth == 0, !isOperatorStart(b), tokens[a.last].kind != .punctuation || word(tokens[a.last]) == ")" || word(tokens[a.last]) == "]" {
        return true
      }
    }
    return false
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
  /// Inside a string's interpolation: all of it stays as written, as whitespace can be content there
  /// (`f"{a: >2}"`), which comparing tokens can't see.
  var interpolated: [Bool]
  /// The tokens after which a trailing comma goes.
  var commas = Set<Int>()
  let isFullLayout: Bool
  let newline: [UInt8]
  let preferredQuote: UInt8?
  var style = Style()
  /// Gaps written exactly as they are: before the token after a Haskell `do`, `where`, `let` or `of` on its line (its
  /// column is the block's), next to PHP's `?>` and `<?php` (whitespace there is output).
  var keptGaps: [Bool]

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
    interpolated = [Bool](repeating: false, count: tokens.count)
    var depth = 0
    for (index, token) in tokens.enumerated() {
      if token.kind == .interpolationClose { depth -= 1 }
      interpolated[index] = depth > 0
      if token.kind == .interpolationOpen { depth += 1 }
    }
    preferredQuote = Self.quote(in: source, rules: rules, options: options)
    keptGaps = [Bool](repeating: false, count: tokens.count + 1)
    computeKeptGaps()
    computeBreaks()
    computeClosers()
    style = detectStyle()
  }

  /// Votes from the file where a language's tools differ: `case` under `switch` or in from it, a namespace's content
  /// indented or not, `public:`'s offset.
  private func detectStyle() -> Style {
    var style = Style()
    style.casesAlignWithSwitch = rules.caseAlignsWithSwitch
    guard isFullLayout, rules.followsFileStyle else { return style }
    var alignedCases = 0
    var indentedCases = 0
    var flatNamespaces = 0
    var indentedNamespaces = 0
    var offsets = [Int: Int]()
    var stack: [Int] = []
    var switchBraces = Set<Int>()
    var pendingSwitch = false
    var statementFirst = 0
    for (index, token) in tokens.enumerated() {
      let firstOnLine = index == 0 || breaks[index] > 0
      switch token.kind {
      case .open where t[token.start] == 0x7B:
        if pendingSwitch { switchBraces.insert(index) }
        pendingSwitch = false
        let head = tokens[statementFirst]
        if statementFirst < index, equals(head, "namespace") || (equals(head, "extern") && tokens[index - 1].kind == .string),
          index + 1 < tokens.count, breaks[index + 1] > 0, tokens[index + 1].kind != .close
        {
          if indentOfLine(tokens[index + 1].start) > indentOfLine(token.start) { indentedNamespaces += 1 } else { flatNamespaces += 1 }
        }
        stack.append(index)
        statementFirst = index + 1
      case .open:
        stack.append(index)
      case .close:
        _ = stack.popLast()
        if t[token.start] == 0x7D { statementFirst = index + 1 }
      case .keyword where equals(token, "switch"):
        pendingSwitch = true
      case .keyword where firstOnLine && (equals(token, "case") || equals(token, "default")):
        if let open = stack.last, switchBraces.contains(open), index + 1 < tokens.count {
          if indentOfLine(token.start) > indentOfLine(tokens[open].start) { indentedCases += 1 } else { alignedCases += 1 }
        }
      case .punctuation where isByte(token, 0x3B):
        statementFirst = index + 1
      default:
        if firstOnLine, rules.outdentsLabels, index + 1 < tokens.count, isByte(tokens[index + 1], 0x3A),
          equals(token, "public") || equals(token, "private") || equals(token, "protected"), let open = stack.last, t[tokens[open].start] == 0x7B
        {
          offsets[indentOfLine(token.start) - indentOfLine(tokens[open].start), default: 0] += 1
        }
      }
      // Comments and preprocessor lines before a statement aren't its start.
      if index == statementFirst, token.kind == .comment || token.kind == .docComment || token.kind == .directive { statementFirst = index + 1 }
    }
    if let indents = options.indentsCaseLabels {
      style.casesAlignWithSwitch = !indents
    } else if alignedCases + indentedCases > 0 {
      style.casesAlignWithSwitch = alignedCases > indentedCases
    }
    if let indents = options.indentsNamespaces {
      style.indentsNamespaces = indents
    } else {
      style.indentsNamespaces = indentedNamespaces > flatNamespaces
    }
    let unit = options.useTabs ? 8 : options.indentWidth
    if let offset = options.accessModifierOffset {
      style.accessOffset = max(0, unit + offset)
    } else if let best = offsets.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), best.key >= 0, best.key <= unit {
      style.accessOffset = options.useTabs ? (best.key >= unit ? unit : 0) : best.key
    }
    return style
  }

  /// A line written exactly as it is: a here-document's body, which starts its line, and Ruby's `=begin` and
  /// `__END__`, which must.
  private func keepsVerbatim(_ index: Int) -> Bool {
    let token = tokens[index]
    if index == 0, rules.inlineMarkup { return true }
    // `a\` then `b` at the line's start is one word `ab`: indenting it would make two.
    if rules.codeEscape != 0, index > 0, token.start > 0, t[token.start - 1] == 0x0A, isByte(tokens[index - 1], rules.codeEscape) { return true }
    guard token.start > 0, t[token.start - 1] == 0x0A else { return token.start == 0 && rules.embeddedDocuments }
    switch token.kind {
    case .string: return rules.hereDocuments && followsHereDocumentStart(index)
    case .comment, .docComment: return rules.embeddedDocuments && (t[token.start] == 0x3D || t[token.start] == 0x5F)
    default: return false
    }
  }

  /// A string at a line's start is a here-document's body when the line before holds its `<<`; `"a" >b` isn't one.
  private func followsHereDocumentStart(_ index: Int) -> Bool {
    var i = index - 1
    while i >= 0 {
      let token = tokens[i]
      if token.length >= 2, t[token.start] == 0x3C, t[token.start + 1] == 0x3C { return true }
      // Its line's first token: stop.
      if token.start == 0 || memchr(t + (i > 0 ? tokens[i - 1].end : 0), 0x0A, token.start - (i > 0 ? tokens[i - 1].end : 0)) != nil { return false }
      i -= 1
    }
    return false
  }

  private static func quote(in source: SourceFile, rules: LanguageRules, options: PrettyOptions) -> UInt8? {
    guard rules.prefersDoubleQuotes else { return nil }
    if let quote = options.quote { return quote }
    var single = 0
    var double = 0
    var depth = 0
    for token in source.tokens {
      if token.kind == .interpolationOpen { depth += 1 } else if token.kind == .interpolationClose { depth -= 1 }
      guard token.kind == .string, depth == 0 else { continue }
      if source.text[token.start] == 0x27 { single += 1 } else if source.text[token.start] == 0x22 { double += 1 }
    }
    if single == 0 || double == 0 { return nil }
    return single > double ? 0x27 : 0x22
  }

  mutating func computeKeptGaps() {
    if rules.inlineMarkup {
      for (index, token) in tokens.enumerated() where token.kind == .punctuation && token.length >= 2 {
        let first = t[token.start]
        if first == 0x3F, t[token.start + 1] == 0x3E {
          keptGaps[index + 1] = true  // After `?>`, to the end of the file too.
        } else if first == 0x3C, t[token.start + 1] == 0x3F {
          keptGaps[index] = true
        }
      }
    }
    guard !rules.layoutWords.isEmpty else { return }
    var lineFirst = 0
    for (index, token) in tokens.enumerated() {
      if index > 0, memchr(t + tokens[index - 1].end, 0x0A, token.start - tokens[index - 1].end) != nil { lineFirst = index }
      guard token.kind == .keyword || token.kind == .declarationKeyword, index + 1 < tokens.count else { continue }
      let next = tokens[index + 1]
      guard memchr(t + token.end, 0x0A, next.start - token.end) == nil, !(next.kind == .open && t[next.start] == 0x7B) else { continue }
      let word = String(decoding: UnsafeBufferPointer(start: t + token.start, count: token.length), as: UTF8.self)
      // `\case` opens one; a plain `case` waits for its `of`.
      let opens = rules.layoutWords.contains(word) && (word != "case" || (index > 0 && isByte(tokens[index - 1], 0x5C)))
      guard opens else { continue }
      for gap in (lineFirst + 1)...(index + 1) { keptGaps[gap] = true }
    }
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
      if interpolated[index] || keptGaps[index] {
        breaks[index] = count
        continue
      }
      var allowed = min(count, limit)
      if isFullLayout {
        // No blank line just inside a bracket.
        // zig fmt keeps one before a comment, though.
        let keepsBeforeComment = rules.bracesHoldLists && (tokens[index].kind == .comment || tokens[index].kind == .docComment)
        if tokens[index - 1].kind == .open && !keepsBeforeComment || tokens[index].kind == .close { allowed = 1 }
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
    /// Columns past the token it lines up under.
    var alignOffset = 0
    /// Columns past its levels.
    var extra = 0
  }

  /// What the file's own layout says where languages' styles differ, else the language's default.
  struct Style {
    var casesAlignWithSwitch = false
    var indentsNamespaces = false
    /// Where `public:` sits, in columns past its class's level.
    var accessOffset = 0
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
    /// Columns past the levels, of the opener's line and of the content's lines: where continuation lines indent by
    /// something other than a level (clang-format's and dart format's 4 columns).
    var openerExtra = 0
    var contentExtra = 0
    /// Opened by a word (`then`, `do`, `def`) rather than a bracket.
    var word = WordFrame.none
    /// Whether the opener's line was a chain's head (1) or link (2), which its closing line goes on as.
    var openerChain = 0
  }

  enum WordFrame { case none, block, loopHead, caseList, caseItem }

  @inline(__always) func isByte(_ token: Token, _ byte: UInt8) -> Bool { token.length == 1 && t[token.start] == byte }

  func equals(_ token: Token, _ word: StaticString) -> Bool {
    token.length == word.utf8CodeUnitCount && memcmp(t + token.start, word.utf8Start, token.length) == 0
  }

  /// The role a word plays in blocks, if it's one of the language's block words where it stands.
  private func blockWord(_ index: Int) -> LanguageRules.BlockWord? {
    let token = tokens[index]
    guard !rules.blockWords.isEmpty, token.kind == .keyword || token.kind == .declarationKeyword, token.length <= 8 else { return nil }
    let word = String(decoding: UnsafeBufferPointer(start: t + token.start, count: token.length), as: UTF8.self)
    guard let role = rules.blockWords[word] else { return nil }
    // `echo done`: an argument, not the shell's word.
    if rules.blockWordsAtCommandStart, role != .caseIn, !isCommandStart(index) { return nil }
    return role
  }

  /// Whether a word stands where a shell command starts: a line's first, or after `;`, `&&`, `|`, `(`, `{` or
  /// another reserved word.
  private func isCommandStart(_ index: Int) -> Bool {
    var i = index - 1
    while i >= 0, tokens[i].kind == .comment || tokens[i].kind == .docComment { i -= 1 }
    guard i >= 0 else { return true }
    let previous = tokens[i]
    if breaks[index] > 0 || memchr(t + previous.end, 0x0A, tokens[index].start - previous.end) != nil {
      // A line break ends the command unless the line asked to go on.
      // `a &&` goes on; `a &` runs in the background and ends.
      let isAnd = t[previous.end - 1] == 0x26 && (previous.length == 2 || (i > 0 && tokens[i - 1].end == previous.start && isByte(tokens[i - 1], 0x26)))
      return !(previous.kind == .punctuation && (t[previous.end - 1] == 0x7C || isAnd || t[previous.end - 1] == 0x5C))
    }
    switch previous.kind {
    case .open: return true
    case .punctuation:
      let c = t[previous.end - 1]
      return c == 0x3B || c == 0x26 || c == 0x7C || (c == 0x21 && previous.length == 1)
    case .keyword:
      return equals(previous, "then") || equals(previous, "do") || equals(previous, "else") || equals(previous, "elif")
        || equals(previous, "if") || equals(previous, "while") || equals(previous, "until") || equals(previous, "time")
    case .close:
      return isByte(previous, 0x7D)
    default: return false
    }
  }

  /// Whether `if`, `while` and the like start a statement here, so they open a block: `x = if a` does, `y if a` (a
  /// modifier) doesn't.
  private func startsStatement(_ index: Int) -> Bool {
    var i = index - 1
    while i >= 0, tokens[i].kind == .comment || tokens[i].kind == .docComment { i -= 1 }
    guard i >= 0 else { return true }
    if memchr(t + tokens[i].end, 0x0A, tokens[index].start - tokens[i].end) != nil { return true }
    let previous = tokens[i]
    switch previous.kind {
    case .open, .interpolationOpen: return true
    case .punctuation: return true
    case .keyword, .declarationKeyword:
      return equals(previous, "then") || equals(previous, "else") || equals(previous, "do") || equals(previous, "begin")
        || equals(previous, "and") || equals(previous, "or") || equals(previous, "not") || equals(previous, "when")
        || equals(previous, "in") || equals(previous, "ensure") || equals(previous, "rescue")
    default: return false
    }
  }

  /// `def a(x) = x`: Ruby's endless method, which has no `end`.
  private func isEndlessDefinition(_ index: Int, lineEnd: Int) -> Bool {
    var depth = 0
    var i = index + 1
    while i < lineEnd {
      let token = tokens[i]
      if token.kind == .open { depth += 1 } else if token.kind == .close { depth -= 1 } else if depth == 0, isByte(token, 0x3D) {
        // `def x=(v)` names a setter.
        let named = i == index + 2 || (i >= 2 && isByte(tokens[i - 2], 0x2E))
        if !(named && token.start == tokens[i - 1].end && i + 1 < tokens.count && tokens[i + 1].start == token.end && isByte(tokens[i + 1], 0x28)) {
          return true
        }
      }
      i += 1
    }
    return false
  }

  /// A `{` that holds a list, not statements: `f({ a, b })`, Dart's named parameters.
  private func isListBrace(_ open: Int) -> Bool {
    guard open > 0 else { return false }
    let before = tokens[open - 1]
    return (before.kind == .open && t[before.start] != 0x7B) || isByte(before, 0x2C)
  }

  /// `if (` with its condition on the lines below and `)` on its own: the condition's lines don't indent again
  /// (Prettier's rule).
  private func isBrokenCondition(_ open: Int) -> Bool {
    guard open > 0, open + 1 < tokens.count, t[tokens[open].start] == 0x28, breaks[open + 1] > 0 else { return false }
    let before = tokens[open - 1]
    guard before.kind == .keyword, equals(before, "if") || equals(before, "while") || equals(before, "switch") || equals(before, "elseif") else { return false }
    let close = Int(closers[open])
    return close > 0 && breaks[close] > 0
  }

  /// A goto label alone on its line (`fail:`), in a block.
  private func isGotoLabel(_ first: Int, end: Int, previousCode: Int) -> Bool {
    guard rules.outdentsLabels, tokens[first].kind == .identifier, first + 1 < end, isByte(tokens[first + 1], 0x3A) else { return false }
    if first + 2 < end, tokens[first + 2].kind != .comment, tokens[first + 2].kind != .docComment { return false }
    guard previousCode >= 0 else { return true }
    let previous = tokens[previousCode]
    return isByte(previous, 0x3B) || isByte(previous, 0x3A) || (previous.kind == .open && t[previous.start] == 0x7B) || (previous.kind == .close && t[previous.start] == 0x7D)
  }

  /// `public:`, `private:`, `protected:` (C++).
  private func isAccessSpecifier(_ first: Int, end: Int) -> Bool {
    guard rules.outdentsLabels, first + 1 < end, tokens[first].kind == .keyword || tokens[first].kind == .identifier, isByte(tokens[first + 1], 0x3A) else { return false }
    let token = tokens[first]
    return equals(token, "public") || equals(token, "private") || equals(token, "protected")
  }

  /// The level of every line, from the bracket that's open at its start and whether its statement goes on.
  func measureLines() -> [Line] {
    var lines: [Line] = []
    guard !tokens.isEmpty else { return lines }
    lines.reserveCapacity(source.lines.starts.count)
    var frames: [Frame] = []
    frames.reserveCapacity(32)
    var pendingSwitch = false
    var pendingCase = false
    var expectsPattern = false
    var skippedPatternOpen = -1
    var statementFirst = 0
    var index = 0
    var previousCode = -1  // The last token that isn't a comment.
    var afterDirective = false  // `#if os(macOS)` is a line of its own, whatever its last token looks like.
    var previousContinued = false  // A chain's next link goes on where the last one went.
    var previousLevel = 0
    var previousChain = 0  // The line before went on its statement as a chain's head (1) or a link (2).
    let indentWidth = options.useTabs ? 4 : options.indentWidth
    let aligned = style.casesAlignWithSwitch
    let continuationDelta = options.useTabs || options.continuationIndent <= 0 ? 0 : options.continuationIndent - options.indentWidth
    let switchWords = source.profile.spec.keywords.contains("case")

    func lastWordFrame() -> Int? { frames.lastIndex(where: { $0.word != .none }) }

    while index < tokens.count {
      let first = index
      var end = index + 1
      while end < tokens.count, breaks[end] == 0 { end += 1 }
      let token = tokens[first]
      let frame = frames.last
      let content = frame?.contentLevel ?? 0
      var level = content
      var extra = frame?.contentExtra ?? 0
      var isVerbatim = false
      let word = blockWord(first)

      if token.kind == .close || token.kind == .interpolationClose {
        level = frame?.openerLevel ?? 0
        extra = frame?.openerExtra ?? 0
      } else if let word, word == .close || word == .middle || word == .caseEnd, var found = lastWordFrame() {
        // `esac` lines up with its `case`, past the open pattern's body.
        if word == .caseEnd, frames[found].word == .caseItem, found > 0, frames[found - 1].word == .caseList { found -= 1 }
        level = frames[found].openerLevel
        extra = frames[found].openerExtra
      } else if keepsVerbatim(first) {
        isVerbatim = true
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
        extra = frame!.openerExtra
      } else if rules.bracesHoldLists, isByte(token, 0x2C), previousCode >= 0, tokens[previousCode].kind == .string,
        tokens[previousCode].length >= 2, t[tokens[previousCode].start] == 0x5C, t[tokens[previousCode].start + 1] == 0x5C
      {
        // zig fmt puts the comma after a `\\` string's lines under the bracket's line.
        level = frame?.openerLevel ?? 0
        extra = frame?.openerExtra ?? 0
      } else if let frame, frame.byte == 0x7B, isAccessSpecifier(first, end: end) {
        level = frame.openerLevel
        extra = frame.openerExtra + style.accessOffset
      } else if frame?.byte == 0x7B, isGotoLabel(first, end: end, previousCode: previousCode) {
        level = originalColumn(first) == 0 ? 0 : max(content - 1, 0)
        extra = level == 0 ? 0 : frame!.openerExtra
      } else if first > 0, previousCode >= 0, !afterDirective, continues(first: first, previous: previousCode, statementFirst: statementFirst, frame: frame, previousContinued: previousContinued) {
        level = content + 1
        // A body without braces is a statement of its own, a level in; anything else goes on its statement.
        if !isControlBody(previousCode, first: first) { extra += continuationDelta }
        // `=>` / `app` / `.api()`: a chain whose head went on a line of its own goes in from that head.
        if previousChain > 0, isChainLink(first) {
          level = previousChain == 1 ? previousLevel + 1 : previousLevel
        }
      }
      if level > content, token.kind != .close {
        previousChain = isChainLink(first) ? 2 : startsWithOperator(token, index: first) || token.kind == .comment ? 0 : 1
      } else if token.kind == .close, let frame, frame.openerChain == 2 {
        previousChain = 2  // `})` closing a link's bracket: the next link lines up with it.
      } else {
        previousChain = 0
      }
      let lineChain = previousChain
      previousLevel = level
      previousContinued = level > content && token.kind != .close
      var alignedWith = -1
      var alignOffset = 0
      if let frame, frame.alignToken >= 0, !isVerbatim, token.kind != .close {
        let column = originalColumn(first)
        if column == frame.alignColumn {
          alignedWith = frame.alignToken
        } else if level > content, column > frame.alignColumn {
          // Going on with an aligned element (`: "b"` under `a ? x`): as far past the alignment as it was.
          alignedWith = frame.alignToken
          alignOffset = column - frame.alignColumn
        }
      }
      if interpolated[first] { isVerbatim = true }

      // A line starts a new statement unless it continued one; a bracket's content starts one too.
      if level == content, token.kind != .close { statementFirst = first }
      afterDirective = token.kind == .directive

      var width = (isVerbatim ? 0 : level) * indentWidth + (isVerbatim ? 0 : extra)
      var tokenIndex = first
      var lineFrameLevel = level
      var lineFrameExtra = extra
      while tokenIndex < end {
        let currentFrameLevel = lineFrameLevel
        let currentFrameExtra = lineFrameExtra
        let current = tokens[tokenIndex]
        if tokenIndex > first, shouldSpace(tokenIndex) { width += 1 }
        width += current.length
        // A shell `case`'s patterns: `a|b)` opens its body, which `;;` ends; `(a)` is the same pattern.
        if let top = frames.last, top.word == .caseList, expectsPattern {
          if current.kind == .open, t[current.start] == 0x28, skippedPatternOpen < 0 {
            skippedPatternOpen = tokenIndex
            if current.kind != .comment { previousCode = tokenIndex }
            tokenIndex += 1
            continue
          }
          if current.kind == .close, t[current.start] == 0x29 {
            var item = Frame(openerLevel: top.contentLevel, contentLevel: top.contentLevel + 1, isSwitch: false, byte: 0x7B, firstOfStatement: tokenIndex)
            item.openerExtra = top.contentExtra
            item.contentExtra = top.contentExtra
            item.word = .caseItem
            item.outerStatementFirst = statementFirst
            frames.append(item)
            expectsPattern = false
            skippedPatternOpen = -1
            statementFirst = tokenIndex + 1
            previousCode = tokenIndex
            tokenIndex += 1
            continue
          }
        }
        switch current.kind {
        case .open, .interpolationOpen:
          let byte = t[current.end - 1]
          let isBrace = byte == 0x7B
          let isSwitch = isBrace && pendingSwitch
          if isBrace { pendingSwitch = false }
          // `class A(…)` / `extends B {`: the block belongs to the statement, not to the line that went on with it.
          var blockLevel = currentFrameLevel
          var blockExtra = currentFrameExtra
          if isBrace, current.kind == .open, currentFrameLevel > content, currentFrameLevel == level, continuesHeader(first), opensAtLineEnd(tokenIndex, end: end) {
            blockLevel = content
            blockExtra = frame?.contentExtra ?? 0
          }
          // Flat content: C++'s `namespace a {`, Lua's `f(` / `{` / `})`, and a shell's `x=$(a |` mid-line, whose lines go
          // on the command one level in, not two.
          let contentLevel = isSwitch && !aligned ? blockLevel + 2 : (isBrace && opensFlatBlock(tokenIndex, statementFirst: statementFirst) || hugsBlock(tokenIndex, end: end)
              || rules.blockWordsAtCommandStart && byte == 0x28 && tokenIndex > first && !opensAtLineEnd(tokenIndex, end: end) ? blockLevel : blockLevel + 1)
          var opened = Frame(openerLevel: blockLevel, contentLevel: contentLevel, isSwitch: isSwitch, byte: byte, firstOfStatement: tokenIndex)
          opened.outerStatementFirst = statementFirst
          opened.openerExtra = blockExtra
          opened.contentExtra = blockExtra
          opened.openerChain = lineChain
          if byte != 0x7B, tokenIndex + 1 < end {
            opened.alignToken = tokenIndex + 1
            opened.alignColumn = originalColumn(tokenIndex + 1)
          }
          // `f(a,` or `f(` with `)` after the last argument: they go on the statement, by its continuation; only
          // `f(` … `)` on lines of their own is a block.
          if continuationDelta != 0, current.kind == .open, !isBrace, closers[tokenIndex] > 0,
            !(opensAtLineEnd(tokenIndex, end: end) && breaks[Int(closers[tokenIndex])] > 0)
          {
            opened.contentExtra += continuationDelta
          }
          frames.append(opened)
          statementFirst = tokenIndex + 1
        case .close, .interpolationClose:
          var popped: Frame?
          if !frames.isEmpty, !(frames.last!.isDirective), frames.last!.word == .none {
            popped = frames.removeLast()
          } else if let found = frames.lastIndex(where: { !$0.isDirective && $0.word == .none }) {
            popped = frames.remove(at: found)
          }
          // A `{` after `b) ` belongs to the statement that `if (a &&` started, not to the line it's on.
          if let popped {
            statementFirst = popped.outerStatementFirst
            if popped.openerLevel <= lineFrameLevel { lineFrameExtra = popped.openerExtra }
            lineFrameLevel = min(lineFrameLevel, popped.openerLevel)
          }
        case .keyword, .declarationKeyword:
          if switchWords, (equals(current, "switch") && !rules.bracesHoldLists) || (equals(current, "match") && !rules.caseAlignsWithSwitch && source.profile.spec.name == "PHP") {
            pendingSwitch = true
          }
          if let role = tokenIndex == first ? word : blockWord(tokenIndex) {
            func open(_ kind: WordFrame) {
              var opened = Frame(openerLevel: currentFrameLevel, contentLevel: currentFrameLevel + 1, isSwitch: false, byte: 0x7B, firstOfStatement: tokenIndex)
              opened.outerStatementFirst = statementFirst
              opened.openerExtra = currentFrameExtra
              opened.contentExtra = currentFrameExtra
              opened.word = kind
              frames.append(opened)
              statementFirst = tokenIndex + 1
            }
            func close() -> Frame? {
              guard let found = lastWordFrame() else { return nil }
              let popped = frames.remove(at: found)
              if popped.openerLevel <= lineFrameLevel { lineFrameExtra = popped.openerExtra }
              lineFrameLevel = min(lineFrameLevel, popped.openerLevel)
              statementFirst = tokenIndex + 1
              return popped
            }
            switch role {
            case .open:
              if !(equals(current, "def") && isEndlessDefinition(tokenIndex, lineEnd: end)) { open(.block) }
            case .openAtStatementStart:
              if startsStatement(tokenIndex) { open(.block) }
            case .loopHead:
              if startsStatement(tokenIndex) { open(.loopHead) }
            case .loopBody:
              // `while a do`: the loop's own `do`.
              if let top = frames.last, top.word == .loopHead, top.firstOfStatement < tokenIndex,
                memchr(t + tokens[top.firstOfStatement].end, 0x0A, current.start - tokens[top.firstOfStatement].end) == nil
              {
                frames[frames.count - 1].word = .block
              } else {
                open(.block)
              }
            case .close:
              _ = close()
            case .middle:
              // At a line's start only: `x rescue y` and `a; else b` in one line change nothing.
              if tokenIndex == first, let popped = close() {
                var reopened = popped
                reopened.firstOfStatement = tokenIndex
                reopened.word = popped.word == .loopHead ? .block : popped.word
                frames.append(reopened)
              }
            case .caseHead:
              pendingCase = true
            case .caseIn:
              if pendingCase {
                pendingCase = false
                open(.caseList)
                expectsPattern = true
              }
            case .caseEnd:
              if frames.last?.word == .caseItem { _ = close() }
              _ = close()
              expectsPattern = false
            }
          }
        case .directive:
          if rules.swiftRawStrings, let keyword = directiveWord(current) {
            if keyword == "if" {
              // Whether `#if` indents is the author's: swift-format does, Xcode doesn't, and neither is wrong.
              let indents = end < tokens.count && indentOfLine(tokens[end].start) > indentOfLine(current.start)
              var opened = Frame(openerLevel: level, contentLevel: indents ? level + 1 : level, isSwitch: false, byte: 0x23, firstOfStatement: tokenIndex, isDirective: true)
              opened.openerExtra = extra
              opened.contentExtra = extra
              frames.append(opened)
            } else if keyword == "endif", frames.last?.isDirective == true {
              frames.removeLast()
            }
          }
        case .punctuation:
          if isByte(current, 0x3B) {
            statementFirst = tokenIndex + 1
            // `;;` (also `;&`, `;;&`) ends a case's body.
            if tokenIndex + 1 < end, tokens[tokenIndex + 1].start == current.end, isByte(tokens[tokenIndex + 1], 0x3B) || isByte(tokens[tokenIndex + 1], 0x26),
              frames.last?.word == .caseItem
            {
              frames.removeLast()
              expectsPattern = true
            }
          }
        default: break
        }
        if current.kind != .comment, current.kind != .docComment { previousCode = tokenIndex }
        tokenIndex += 1
      }
      lines.append(Line(first: first, end: end, level: level, width: width, isVerbatim: isVerbatim, alignedWith: alignedWith, alignOffset: alignOffset, extra: isVerbatim ? 0 : extra))
      index = end
    }
    return lines
  }

  /// `f(a,` with `{` … `}` as its last argument starting the next line, written under the call's line: Lua's
  /// `data:extend(` / `{` / `})`. The braces stay where the author put them.
  private func hugsBlock(_ open: Int, end: Int) -> Bool {
    guard t[tokens[open].start] == 0x28, closers[open] > 0 else { return false }
    let next = end
    guard next < tokens.count, tokens[next].kind == .open, t[tokens[next].start] == 0x7B, closers[next] > 0,
      Int(closers[next]) + 1 == Int(closers[open])
    else { return false }
    return originalColumn(next) == indentOfLine(tokens[open].start)
  }

  /// Whether only comments follow this token on its line.
  private func opensAtLineEnd(_ index: Int, end: Int) -> Bool {
    var i = index + 1
    while i < end {
      if tokens[i].kind != .comment, tokens[i].kind != .docComment { return false }
      i += 1
    }
    return i < tokens.count
  }

  /// A block whose content stays at its own level: C++'s `namespace a {` and `extern "C" {`, unless the file indents them.
  private func opensFlatBlock(_ open: Int, statementFirst: Int) -> Bool {
    guard rules.flatNamespaces, !style.indentsNamespaces, statementFirst < open else { return false }
    let head = tokens[statementFirst]
    if equals(head, "namespace") || (equals(head, "inline") && statementFirst + 1 < open && equals(tokens[statementFirst + 1], "namespace")) {
      return true
    }
    return equals(head, "extern") && tokens[open - 1].kind == .string
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
    // A TOML line is a table, a key or an array's element: none goes on another.
    if case .tomlKeys = rules.outline { return false }
    if token.kind == .open, t[token.start] == 0x7B, !(rules.blockWordsAtCommandStart && last.kind == .punctuation && (t[last.end - 1] == 0x7C || t[last.end - 1] == 0x26)) {
      return false
    }
    // After a here-document's body the next command starts.
    if rules.hereDocuments, last.kind == .string, keepsVerbatim(previous) { return false }
    // Lua's `init =` / `[[`: a long string written under its key is a block like a table.
    if token.kind == .string, t[token.start] == 0x5B, statementFirst < first,
      originalColumn(first) == indentOfLine(tokens[statementFirst].start)
    {
      return false
    }
    // In CSS a line is a selector or a declaration: neither `.a` nor `*` is an operator there.
    if case .cssSelectors = rules.outline {
      if last.kind == .close || last.kind == .open || isByte(last, 0x3B) || token.kind == .comment { return false }
      return statementFirst < first && indentOfLine(tokens[statementFirst].start) < indentOfLine(token.start)
    }
    // A shell's `cmd &` runs in the background and ends its command, like `;`.
    if rules.blockWordsAtCommandStart, isByte(last, 0x26), previous == 0 || tokens[previous - 1].end < last.start || !isByte(tokens[previous - 1], 0x26) {
      return false
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
    // `if (` broken over lines: its condition's lines stand at one level.
    if let frame, frame.byte == 0x28, isBrokenCondition(frame.firstOfStatement) { return false }
    // `do |a|` and `{ |a|`: the block's parameters, not an operator.
    if isByte(last, 0x7C), closesBlockParameters(previous) { return false }
    // `{ case a =>` and `{ a ->`: a closure's head, its body below.
    if let frame, frame.byte == 0x7B, frame.word == .none, last.length == 2, t[last.start + 1] == 0x3E, t[last.start] == 0x3D || t[last.start] == 0x2D,
      memchr(t + tokens[frame.firstOfStatement].end, 0x0A, last.start - tokens[frame.firstOfStatement].end) == nil
    {
      return false
    }
    if last.kind == .punctuation {
      if isByte(last, 0x3B) { return false }
      if isByte(last, 0x2C) {
        // In brackets, a comma separates; in a block, it goes on a `guard a,` or a `let a = 1,` that a keyword started.
        guard frame == nil || frame!.byte == 0x7B && !rules.bracesHoldLists || frame!.byte == 0x23 else { return false }
        // `f({ this.a,` is a list, and `this` a value, not a statement's word.
        if let frame, frame.word == .none, frame.byte == 0x7B, isListBrace(frame.firstOfStatement) { return false }
        return statementFirst < tokens.count
          && (tokens[statementFirst].kind == .keyword || tokens[statementFirst].kind == .declarationKeyword)
          && !isCaseLabel(tokens[statementFirst]) && statementFirst != first && !isValueKeyword(tokens[statementFirst])
          && !(statementFirst + 1 < tokens.count && isByte(tokens[statementFirst + 1], 0x3A))  // `from: a,` is a key.
      }
      if isByte(last, 0x3A) { return false }
      if endsWithOperator(last, index: previous) { return true }
    }
    // Zig's word operators go on like any other.
    if rules.bracesHoldLists, last.kind == .keyword, equals(last, "or") || equals(last, "and") || equals(last, "orelse") { return true }
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
    return isDeeperThanStatement(token, statementFirst: statementFirst, first: first)
  }

  /// `if (x)` or `else` ending the line before, with no `{`: what follows is its body.
  private func isControlBody(_ previous: Int, first: Int) -> Bool {
    guard !rules.newlineEndsStatements, !(tokens[first].kind == .open && t[tokens[first].start] == 0x7B) else { return false }
    let last = tokens[previous]
    if last.kind == .keyword, equals(last, "else") { return true }
    guard last.kind == .close, t[last.start] == 0x29, let open = openerIndex(ofClose: previous), open > 0 else { return false }
    let before = tokens[open - 1]
    return before.kind == .keyword && (equals(before, "if") || equals(before, "for") || equals(before, "while") || equals(before, "foreach"))
  }

  /// A line that goes on with a declaration's head: `extends`, `with`, `implements`, `throws`, `where`, `: Base`.
  private func continuesHeader(_ index: Int) -> Bool {
    let token = tokens[index]
    if isByte(token, 0x3A) { return true }
    guard token.kind == .keyword || token.kind == .declarationKeyword || token.kind == .identifier else { return false }
    return equals(token, "extends") || equals(token, "with") || equals(token, "implements") || equals(token, "throws") || equals(token, "where")
  }

  /// `.a()` and `?.a()` starting a line.
  private func isChainLink(_ index: Int) -> Bool {
    let token = tokens[index]
    guard token.kind == .punctuation, index + 1 < tokens.count, tokens[index + 1].kind == .identifier, tokens[index + 1].start == token.end else { return false }
    return isByte(token, 0x2E) || (token.length == 2 && t[token.start] == 0x3F && t[token.start + 1] == 0x2E)
  }

  private func isValueKeyword(_ token: Token) -> Bool {
    equals(token, "this") || equals(token, "self") || equals(token, "super") || equals(token, "true") || equals(token, "false")
      || equals(token, "null") || equals(token, "nil")
  }

  /// Whether this `|` ends `do |a, b|` or `{ |a|` on its line.
  private func closesBlockParameters(_ index: Int) -> Bool {
    var i = index - 1
    while i > 0, tokens[i].kind != .open || i == index, memchr(t + tokens[i].end, 0x0A, tokens[i + 1].start - tokens[i].end) == nil {
      if isByte(tokens[i], 0x7C) {
        let before = tokens[i - 1]
        return equals(before, "do") || (before.kind == .open && t[before.start] == 0x7B)
      }
      i -= 1
    }
    return false
  }

  private func isDeeperThanStatement(_ token: Token, statementFirst: Int, first: Int) -> Bool {
    statementFirst < first && statementIndent(statementFirst) < indentOfLine(token.start)
  }

  /// Where a statement's lines start in the original: its line's indentation, one step in when it starts right after a
  /// bracket that opened on that line (`.a(&(b {` … `})` then `.c()`), as its content is that deep once formatted.
  private func statementIndent(_ statementFirst: Int) -> Int {
    let indent = indentOfLine(tokens[statementFirst].start)
    guard statementFirst > 0, tokens[statementFirst - 1].kind == .open, !breaksOriginally(statementFirst) else { return indent }
    return indent + (options.useTabs ? 8 : options.indentWidth)
  }

  /// The visual width of the indentation of a line in the original, a tab being 8.
  private func indentOfLine(_ offset: Int) -> Int {
    // The line index, not a walk back: a minified file is one line of megabytes.
    var start = Int(source.lines.starts[source.lines.line(of: offset)])
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
    var start = Int(source.lines.starts[source.lines.line(of: offset)])
    // Nothing lines up that far out.
    if offset - start > 4096 { return offset - start }
    var column = 0
    while start < offset {
      column = t[start] == 0x09 ? (column / 8 + 1) * 8 : column + ((t[start] & 0xC0) == 0x80 ? 0 : 1)
      start += 1
    }
    return column
  }

  /// With `bracesHoldLists`, whether the braces opened at `open` hold one element: no `,`, `;`, `=` or `=>` outside
  /// inner brackets (`.{x}`, `error{A}`, but not `.{ .x = 1 }`, `.{ a, b }` or a block).
  private func holdsOneElement(open: Int?) -> Bool {
    guard rules.bracesHoldLists, let open, closers[open] > 0 else { return false }
    var depth = 0
    for index in (open + 1)..<Int(closers[open]) {
      let token = tokens[index]
      if token.kind == .open || token.kind == .interpolationOpen {
        depth += 1
      } else if token.kind == .close || token.kind == .interpolationClose {
        depth -= 1
      } else if depth == 0, token.kind == .punctuation,
        isByte(token, 0x2C) || isByte(token, 0x3B) || isByte(token, 0x3D) || (token.length == 2 && t[token.start] == 0x3D && t[token.start + 1] == 0x3E)
      {
        return false
      }
    }
    return true
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
    // A shell's `a |` and `a &&` go on; `X=` is an empty assignment.
    if rules.blockWordsAtCommandStart { return c == 0x7C || c == 0x26 }
    switch c {
    case 0x2B, 0x2D:  // `i++` ended a statement; `a +` didn't.
      // Zig has no `++` increment: `a ++` is a concatenation going on.
      if token.length >= 2, t[token.end - 2] == c, !rules.bracesHoldLists { return false }
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
    // A shell line starts a command (`/usr/bin/make`, `& $tool`); only `|` and `&&` go on one.
    if rules.linesStartCommands { return c == 0x7C || (c == 0x26 && index + 1 < tokens.count && isByte(tokens[index + 1], 0x26)) || (c == 0x26 && token.length == 2) }
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
    if interpolated[index] || keptGaps[index] { return hadGap }
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
    // Lua's `t[ [[key]] ]`: without the spaces the brackets would be the long string's.
    if a.kind == .string || b.kind == .string, (aByte == 0x5B && bByte == 0x5B) || (aByte == 0x5D && bByte == 0x5D) { return hadGap }
    // Where spaces separate words, a gap stays one and none is made, but where the language says it's safe.
    if let allowed = rules.wordGaps {
      if hadGap { return true }
      if allowed.contains(.afterCommas), a.length == 1, aByte == 0x2C, b.kind != .close, b.kind != .punctuation { return true }
      if allowed.contains(.aroundOperators), (a.kind == .punctuation && isSpacedOperator(a, index - 1)) || (b.kind == .punctuation && isSpacedOperator(b, index)) { return true }
      if allowed.contains(.beforeBraces), b.kind == .open, bByte == 0x7B, a.kind == .close && aByte == 0x29 || a.kind == .keyword { return true }
      if allowed.contains(.afterControlWords), a.kind == .keyword, b.kind == .open, bByte == 0x28, isControlWord(a) { return true }
      return false
    }
    if b.length == 1, bByte == 0x2C || bByte == 0x3B { return false }
    if a.length == 1, aByte == 0x2C || aByte == 0x3B {
      if b.kind == .close { return bByte == 0x7D && hadGap }
      return true
    }
    if a.kind == .open {
      if aByte == 0x7B {
        if b.kind == .close { return false }
        return rules.spacesInsideBraces && !holdsOneElement(open: index - 1) ? true : hadGap
      }
      return false
    }
    if b.kind == .close {
      if bByte == 0x7D { return rules.spacesInsideBraces && !holdsOneElement(open: openerIndex(ofClose: index)) ? true : hadGap }
      return false
    }
    if rules.preservesOperatorSpacing { return hadGap }
    if b.kind == .open, bByte == 0x7B {
      // `a = {`: the operator was spaced on its left, so on its right too.
      if a.kind == .punctuation, isSpacedOperator(a, index - 1) { return true }
      switch a.kind {
      case .identifier, .keyword, .declarationKeyword, .close, .string, .number:
        return rules.bracesFollowTightly ? hadGap : true
      case .punctuation where rules.bracesFollowTightly:
        // `1=>{}` is `1 => {}`, spaced on both sides (Zig's switch prongs, Elixir's maps).
        return hadGap || isSpacedOperator(a, index - 1)
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
    // PHP's `declare(strict_types=1)` is written tight (PSR-12).
    if token.length == 1, index >= 3, isByte(tokens[index - 2], 0x28), equals(tokens[index - 3], "declare") { return false }
    // Ruby's `def name=(v)` names a setter; `def name = v` would be an endless method.
    if token.length == 1, token.start == left.end, index >= 2 {
      let before = tokens[index - 2]
      if equals(before, "def") || (isByte(before, 0x2E) && index >= 4 && equals(tokens[index - 4], "def")) { return false }
    }
    // Written with a space on one side only, it may be a language's own use of it (`T&& x`).
    let gapLeft = token.start > left.end
    let gapRight = right.start > token.end
    if gapLeft != gapRight { return false }
    // Keyword arguments and defaults stay tight where that's the style: `f(a=1)`.
    if token.length == 1, !isFullLayout, !gapLeft, enclosingIsParenthesis(index) { return false }
    // In TOML `=` only ever joins a key and its value.
    if case .tomlKeys = rules.outline { return true }
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
    guard isFullLayout, options.printWidth > 0, rules.wrapsLists else { return }
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
      // A string can't hold a line break, and neither can what's interpolated into it.
      if token.kind == .interpolationOpen {
        guard closers[index] > 0 else { return false }
        index = Int(closers[index]) + 1
        continue
      }
      guard token.kind == .open, closers[index] > 0 else {
        // A multi-line token's width isn't this line's to fix.
        if token.kind == .string || token.kind == .comment || token.kind == .docComment, token.length > 0, memchr(t + token.start, 0x0A, token.length) != nil { return false }
        index += 1
        continue
      }
      let close = Int(closers[index])
      // Only what fixes the line: breaking `a(x)` of `a(x) || b(y) || c(z)` makes it longer and no shorter.
      let saved = formattedWidth(from: index + 1, to: close)
      if close > index + 1, line.width - saved <= options.printWidth, canBreak(open: index, close: close), breaks[index + 1] == 0 {
        apply(open: index, close: close)
        return true
      }
      // Past it: breaking something inside what stays on one line only makes both ugly.
      guard close < line.end else { return false }
      index = close + 1
    }
    return false
  }

  /// The width tokens `from..<to` take on one line once spaced, and the space before `to`: measured as they'll be
  /// written, as a minified original would undercount it.
  private func formattedWidth(from: Int, to: Int) -> Int {
    var width = 0
    var index = from
    while index < to {
      if index > 0, shouldSpace(index) { width += 1 }
      width += tokens[index].length
      index += 1
    }
    if to > from, shouldSpace(to) { width += 1 }
    return width
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
    // `{ a, b in …}` is a closure in these, and its commas are its parameters'.
    if byte == 0x7B, rules.closureHead != nil { return false }
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
    // In `f"{a['b']}"` the inner quotes can't become the outer ones, in Python before 3.12.
    var interpolationDepth = 0
    for line in lines where line.alignedWith >= 0 { alignTargets.insert(Int32(line.alignedWith)) }
    // Whitespace before PHP's first `<?php` is output: the lines above it stay, its own is kept below.
    if rules.inlineMarkup { out.append(contentsOf: UnsafeBufferPointer(start: t, count: lineStart(of: tokens[0].start))) }
    for (lineIndex, line) in lines.enumerated() {
      let keepsGap = lineIndex > 0 && keptGaps[line.first]
      if keepsGap {
        let gapStart = tokens[line.first - 1].end
        out.append(contentsOf: UnsafeBufferPointer(start: t + gapStart, count: tokens[line.first].start - gapStart))
      }
      if lineIndex > 0, !keepsGap {
        for _ in 0..<breaks[line.first] { out.append(contentsOf: newline) }
      }
      // The indentation.
      let originalLineStart = lineStart(of: tokens[line.first].start)
      let originalIndent = tokens[line.first].start - originalLineStart
      var written = 0
      if keepsGap {
        written = originalIndent
      } else if !isFullLayout || line.isVerbatim {
        if breaksOriginally(line.first) || line.first == 0 {
          out.append(contentsOf: UnsafeBufferPointer(start: t + originalLineStart, count: originalIndent))
          written = originalIndent
        } else {
          // A new line made here (a wrap) in a layout that keeps indentation doesn't occur; keep the level.
          for _ in 0..<line.level { out.append(contentsOf: indentUnit) }
        }
      } else if line.alignedWith >= 0, let aligned = columns[Int32(line.alignedWith)] {
        let column = aligned + line.alignOffset
        // Tabs as far as they go, spaces the rest of the way.
        let tabs = options.useTabs ? column / 8 : 0
        for _ in 0..<tabs { out.append(0x09) }
        let spaces = column - tabs * 8
        out.append(contentsOf: repeatElement(0x20, count: spaces))
        written = tabs + spaces
      } else {
        let columns = line.level * indentUnit.count + line.extra
        if options.useTabs || line.extra == 0 || columns < 0 {
          for _ in 0..<line.level {
            out.append(contentsOf: indentUnit)
            written += indentUnit.count
          }
        } else {
          out.append(contentsOf: repeatElement(0x20, count: columns))
          written += columns
        }
      }
      var lineStartInOutput = out.count - written
      var index = line.first
      while index < line.end {
        let token = tokens[index]
        if token.kind == .interpolationOpen { interpolationDepth += 1 } else if token.kind == .interpolationClose { interpolationDepth -= 1 }
        if index > line.first, shouldSpace(index) {
          // A comment's distance is the author's; so is Go's alignment.
          let previous = tokens[index - 1]
          let gap = token.start - previous.end
          // zig fmt lines a list's rows up in columns: spaces after a comma stay too.
          let keeps = token.kind == .comment || token.kind == .docComment || rules.preservesOperatorSpacing || interpolated[index]
            || keptGaps[index] || rules.bracesHoldLists && isByte(previous, 0x2C)
          if keeps, gap >= 1, isSpacesOnly(previous.end, token.start) {
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
        // A piece of an interpolated string between two interpolations (`" kind="`) has no quotes of its own.
        let isPiece = (index > 0 && tokens[index - 1].kind == .interpolationClose) || (index + 1 < tokens.count && tokens[index + 1].kind == .interpolationOpen)
        write(token, into: &out, indentChange: written - originalIndent, swapsQuotes: interpolationDepth == 0 && !isPiece)
        if token.length > 0, memchr(t + token.start, 0x0A, token.length) != nil, let last = out.lastIndex(of: 0x0A) { lineStartInOutput = last + 1 }
        if commas.contains(index) { out.append(0x2C) }
        index += 1
      }
    }
    // What follows PHP's last `?>` is output.
    if keptGaps[tokens.count], tokens.last!.end < source.count {
      out.append(contentsOf: UnsafeBufferPointer(start: t + tokens.last!.end, count: source.count - tokens.last!.end))
    } else if !(tokens.last!.length > 0 && t[tokens.last!.end - 1] == 0x0A) {
      // A token that ends in a newline already ends the file: markup after `?>`, a here-document to the end.
      out.append(contentsOf: newline)
    }
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

  private func write(_ token: Token, into out: inout [UInt8], indentChange: Int, swapsQuotes: Bool) {
    if swapsQuotes, token.kind == .string, let preferred = preferredQuote, swapsQuote(token, to: preferred) {
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
  /// The configuration files read for a file's options, in the order they're read (in each folder from the file's up to
  /// the repository's root, the first of a kind found wins): what makes a project's formatting its own.
  public static let configFileNames = [
    ".editorconfig", ".prettierrc", ".prettierrc.json", ".prettierrc.yaml", ".prettierrc.yml", ".swift-format",
    "rustfmt.toml", ".rustfmt.toml", ".clang-format",
  ]

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
    if ["C", "C++", "Objective-C", "Dart"].contains(language) { options.continuationIndent = 4 }
    // zig fmt: four spaces, whatever the file has.
    if language == "Zig" { options.indentWidth = 4 }
    // dart format and zig fmt have one indentation, as gofmt has.
    let fixed = language == "Go" || language == "Dart" || language == "Zig"
    if let detected = detectIndent(source, bracesOnly: options.continuationIndent > 0) {
      if !fixed {
        options.useTabs = detected.tabs
        options.indentWidth = detected.tabs ? 1 : detected.width
      }
    }
    // google-java-format goes on by 4 with 2 in, Android's and IntelliJ's by 8 with 4: two levels either way.
    func finished(_ options: PrettyOptions) -> PrettyOptions {
      var options = options
      if language == "Java", !options.useTabs, options.continuationIndent == 0 { options.continuationIndent = options.indentWidth * 2 }
      return options
    }
    guard let path else { return finished(options) }
    var folder = (path as NSString).deletingLastPathComponent
    var found = Set<String>()
    while !folder.isEmpty, folder != "/" {
      for name in configFileNames { read(folder + "/" + name, &found, &options, language: language, path: path) }
      if FileManager.default.fileExists(atPath: folder + "/.git") { break }
      folder = (folder as NSString).deletingLastPathComponent
    }
    return finished(options)
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
      // The base style first, then what the file sets.
      let base = text.range(of: "BasedOnStyle").map { text[$0.upperBound...].prefix(40).lowercased() } ?? ""
      if base.contains("google") || base.contains("chromium") {
        options.indentsCaseLabels = true
        options.accessModifierOffset = -1
      } else if base.contains("mozilla") {
        options.indentsCaseLabels = true
        options.continuationIndent = 2
        options.accessModifierOffset = -2
      } else if base.contains("webkit") || base.contains("microsoft") {
        options.indentsCaseLabels = false
        options.accessModifierOffset = -4
      } else if base.contains("llvm") || base.contains("gnu") {
        options.indentsCaseLabels = false
        options.accessModifierOffset = -2
      }
      if let width = number(in: text, "ColumnLimit") { options.printWidth = width }
      if let spaces = number(in: text, "IndentWidth") { options.indentWidth = spaces }
      if let spaces = number(in: text, "ContinuationIndentWidth") { options.continuationIndent = spaces }
      if let indents = flag(in: text, "IndentCaseLabels") { options.indentsCaseLabels = indents }
      if let range = text.range(of: "NamespaceIndentation") {
        let value = text[range.upperBound...].prefix(16)
        options.indentsNamespaces = !value.contains("None")
      }
      if let range = text.range(of: "AccessModifierOffset") {
        let value = text[range.upperBound...].prefix(16).drop(while: { $0 == ":" || $0 == " " })
        if let offset = Int(value.prefix(while: { $0 == "-" || $0.isNumber })) { options.accessModifierOffset = offset }
      }
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
  private static func detectIndent(_ source: SourceFile, bracesOnly: Bool) -> (tabs: Bool, width: Int)? {
    let t = source.text
    let tokens = source.tokens
    var tabs = 0
    var steps = [Int](repeating: 0, count: 9)
    var seen = 0
    func indent(_ offset: Int) -> (width: Int, usesTab: Bool) {
      var start = Int(source.lines.starts[source.lines.line(of: offset)])
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
      // Where arguments go in by a continuation's width, only blocks say what a level is.
      if bracesOnly, t[tokens[index].start] != 0x7B { continue }
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
    // Where words open blocks (`then`, `do`, `function`), a line holding one and the deeper line after it vote too.
    let words = source.profile.rules.blockWords
    if !words.isEmpty, seen <= 4000 {
      var lineIndent: (width: Int, usesTab: Bool)? = nil
      var opensBlock = false
      var previousEnd = 0
      for token in tokens {
        if token.start == 0 || memchr(t + previousEnd, 0x0A, token.start - previousEnd) != nil {
          let here = indent(token.start)
          if opensBlock, let lineIndent, here.width > lineIndent.width {
            if here.usesTab {
              tabs += 1
            } else {
              let step = here.width - lineIndent.width
              if step <= 8 { steps[step] += 1 }
            }
            seen += 1
          }
          lineIndent = here
          opensBlock = false
        }
        previousEnd = token.end
        if token.kind == .keyword || token.kind == .declarationKeyword,
          let role = words[String(decoding: UnsafeBufferPointer(start: t + token.start, count: token.length), as: UTF8.self)]
        {
          switch role {
          case .close, .caseEnd: break
          default: opensBlock = true
          }
        }
      }
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
