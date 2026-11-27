#if canImport(AppKit)
  import AppKit
  import ObjectiveC

  /// Where a wrapped line of code breaks. AppKit's own answer (`NSAttributedString.lineBreak(before:within:)`,
  /// which the typesetter asks the text storage for) is made for prose: it never breaks before a period, so a line
  /// such as `    case .text, .localized, …` had one place to break, after its indentation. That left the first
  /// row empty and cut the rest wherever the width ended, inside words.
  ///
  /// Code breaks after whitespace; a row with none breaks after `,` `;` `:` or an opening bracket, or before a
  /// period; and only then inside a word. A break that would leave a row of nothing but indentation isn't one.
  enum CodeLineBreaks {
    /// The break at or before `location` for a row that starts at `range.location`; `range.location` when there
    /// is none (the typesetter then cuts at the width).
    static func lineBreak(before location: Int, within range: NSRange, in text: NSString, appKit: Int) -> Int {
      let start = range.location
      let last = min(location, text.length - 1)
      guard last > start else { return start }
      // The row's text starts here: a break at or before it leaves a row of indentation.
      var content = start
      while content <= last, isSpace(text.character(at: content)) { content += 1 }
      var punctuation = start
      var index = last
      while index > content {
        let character = text.character(at: index)
        let previous = text.character(at: index - 1)
        if isSpace(previous), !isSpace(character) { return max(index, appKit) }
        if punctuation == start, !isSpace(character), breaksAfter(previous) || character == 0x2E {
          punctuation = index
        }
        index -= 1
      }
      // AppKit's own break when it is a real one (in text without spaces, such as Chinese or Japanese).
      if appKit > content { return max(appKit, punctuation) }
      return punctuation
    }

    private static func isSpace(_ character: unichar) -> Bool { character == 0x20 || character == 0x09 }

    /// `,` `;` `:` `(` `[` `{`
    private static func breaksAfter(_ character: unichar) -> Bool {
      switch character {
      case 0x2C, 0x3B, 0x3A, 0x28, 0x5B, 0x7B: true
      default: false
      }
    }

    private static let selector = #selector(NSAttributedString.lineBreak(before:within:))
    private typealias Implementation = @convention(c) (AnyObject, Selector, Int, NSRange) -> Int

    /// A subclass of the text storage's own class (NSTextStorage is a class cluster, and a subclass of the abstract
    /// class would have to store the text itself) that answers the typesetter with `lineBreak` above.
    @MainActor private static let storageClass: AnyClass? = {
      let base: AnyClass = type(of: NSTextStorage())
      let selector = CodeLineBreaks.selector
      guard let method = class_getInstanceMethod(base, selector),
        let subclass = objc_allocateClassPair(base, "CodeEditorTextStorage", 0)
      else { return nil }
      let original = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
      let block: @convention(block) (AnyObject, Int, NSRange) -> Int = { storage, location, range in
        let appKit = original(storage, selector, location, range)
        guard let text = (storage as? NSAttributedString)?.string else { return appKit }
        return lineBreak(before: location, within: range, in: text as NSString, appKit: appKit)
      }
      class_addMethod(subclass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
      objc_registerClassPair(subclass)
      return subclass
    }()

    /// Makes `storage` break its lines as code. Only for a storage made with `NSTextStorage(…)`.
    @MainActor static func install(on storage: NSTextStorage) {
      guard let storageClass, type(of: storage) == class_getSuperclass(storageClass) else { return }
      object_setClass(storage, storageClass)
    }
  }
#endif
