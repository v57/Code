#if canImport(AppKit)
  import AppKit

  /// Xcode's completion list: a borderless panel under the word being typed,
  /// a row per completion (kind badge, name with the typed characters in
  /// bold, signature, type), and the selected one's documentation below.
  /// It never takes focus: the editor keeps typing and sends it the arrow
  /// keys.
  @MainActor final class CompletionWindow: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
      var item: CompletionItem
      var positions: [Int]
    }

    static let rowHeight: CGFloat = 22
    static let visibleRows = 9
    static let badgeWidth: CGFloat = 26

    private(set) var rows: [Row] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let documentation = NSTextField(wrappingLabelWithString: "")
    private let separator = NSBox()
    private let background = NSVisualEffectView()
    /// The font of names, matching the editor's.
    var nameFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var onAccept: ((Int) -> Void)?
    var onSelect: ((Int) -> Void)?

    init() {
      super.init(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
      isFloatingPanel = true
      hidesOnDeactivate = true
      becomesKeyOnlyIfNeeded = true
      hasShadow = true
      isOpaque = false
      backgroundColor = .clear
      isReleasedWhenClosed = false
      animationBehavior = .none

      background.material = .popover
      background.state = .active
      background.blendingMode = .behindWindow
      background.wantsLayer = true
      background.layer?.cornerRadius = 8
      background.layer?.masksToBounds = true
      background.layer?.borderWidth = 0.5
      background.layer?.borderColor = NSColor.separatorColor.cgColor
      contentView = background

      let column = NSTableColumn(identifier: .init("item"))
      table.addTableColumn(column)
      table.headerView = nil
      table.rowHeight = Self.rowHeight
      table.intercellSpacing = .zero
      table.style = .plain
      table.backgroundColor = .clear
      table.focusRingType = .none
      table.refusesFirstResponder = true
      table.allowsEmptySelection = false
      table.dataSource = self
      table.delegate = self
      table.target = self
      table.doubleAction = #selector(doubleClicked)
      scroll.documentView = table
      scroll.drawsBackground = false
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = true
      scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
      scroll.automaticallyAdjustsContentInsets = false
      background.addSubview(scroll)

      separator.boxType = .separator
      background.addSubview(separator)
      documentation.font = .systemFont(ofSize: 11)
      documentation.textColor = .secondaryLabelColor
      documentation.maximumNumberOfLines = 4
      documentation.lineBreakMode = .byTruncatingTail
      documentation.cell?.truncatesLastVisibleLine = true
      background.addSubview(documentation)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Content

    var selectedRow: Int { table.selectedRow }

    func show(_ rows: [Row], selecting index: Int) {
      self.rows = rows
      table.reloadData()
      select(min(max(index, 0), rows.count - 1))
    }

    /// The row's item changed (resolved with documentation).
    func update(_ item: CompletionItem, at row: Int) {
      guard rows.indices.contains(row) else { return }
      rows[row].item = item
      table.reloadData(forRowIndexes: [row], columnIndexes: [0])
      if row == selectedRow { updateDocumentation() }
    }

    func select(_ row: Int) {
      guard !rows.isEmpty else { return }
      let row = min(max(row, 0), rows.count - 1)
      table.selectRowIndexes([row], byExtendingSelection: false)
      table.scrollRowToVisible(row)
      updateDocumentation()
    }

    func moveSelection(by offset: Int) {
      guard !rows.isEmpty else { return }
      var row = selectedRow + offset
      // Arrows wrap around at the ends, as in Xcode; pages stop there.
      if abs(offset) == 1 { row = (row + rows.count) % rows.count }
      select(row)
    }

    private func updateDocumentation() {
      guard rows.indices.contains(selectedRow) else { return }
      let item = rows[selectedRow].item
      documentation.attributedStringValue = Self.documentationText(for: item)
      layoutContent()
    }

    /// The detail when it didn't fit in the row, then the documentation's
    /// first paragraph.
    static func documentationText(for item: CompletionItem) -> NSAttributedString {
      let result = NSMutableAttributedString()
      let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
      ]
      if let documentation = item.documentation?.trimmingCharacters(in: .whitespacesAndNewlines),
        !documentation.isEmpty
      {
        let paragraph =
          documentation.components(separatedBy: "\n\n").first { paragraph in
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("```")
          } ?? ""
        let text = paragraph.replacingOccurrences(of: "\n", with: " ")
        if let parsed = try? AttributedString(
          markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
          let string = NSMutableAttributedString(parsed)
          string.addAttributes(body, range: NSRange(location: 0, length: string.length))
          result.append(string)
        } else {
          result.append(NSAttributedString(string: text, attributes: body))
        }
      }
      return result
    }

    // MARK: - Layout

    /// Sizes the panel for its rows and places it under `anchor` (the
    /// word's first character, in screen coordinates), or above when there
    /// is no room below.
    func layout(under anchor: NSRect, on screen: NSScreen?) {
      let visibleRows = min(rows.count, Self.visibleRows)
      let width = preferredWidth()
      let listHeight = CGFloat(visibleRows) * Self.rowHeight + 8
      let docHeight = documentationHeight(width: width)
      let height = listHeight + docHeight
      let frame = screen?.visibleFrame ?? .infinite
      var origin = NSPoint(x: anchor.minX - Self.badgeWidth - 4, y: anchor.minY - height - 2)
      if origin.y < frame.minY { origin.y = anchor.maxY + 2 }
      origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - width - 4)
      setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: false)
      layoutContent()
    }

    private func documentationHeight(width: CGFloat) -> CGFloat {
      guard documentation.attributedStringValue.length > 0 else { return 0 }
      documentation.preferredMaxLayoutWidth = width - 20
      let size = documentation.attributedStringValue.boundingRect(
        with: NSSize(width: width - 20, height: 60), options: [.usesLineFragmentOrigin])
      return min(ceil(size.height), 58) + 13
    }

    private func layoutContent() {
      let bounds = background.bounds
      let docHeight = documentationHeight(width: bounds.width)
      separator.isHidden = docHeight == 0
      documentation.isHidden = docHeight == 0
      scroll.frame = NSRect(
        x: 0, y: docHeight, width: bounds.width, height: bounds.height - docHeight)
      separator.frame = NSRect(x: 0, y: docHeight - 1, width: bounds.width, height: 1)
      documentation.frame = NSRect(
        x: 10, y: 6, width: bounds.width - 20, height: max(0, docHeight - 12))
      table.tableColumns.first?.width = bounds.width
    }

    private func preferredWidth() -> CGFloat {
      var width: CGFloat = 300
      let detailFont = NSFont.systemFont(ofSize: 11)
      for row in rows.prefix(60) {
        let item = row.item
        var w = Self.badgeWidth + 16
        w +=
          ((item.label + (item.labelDetail ?? "")) as NSString).size(withAttributes: [
            .font: nameFont
          ]).width
        if let detail = item.detail {
          w += min(200, (detail as NSString).size(withAttributes: [.font: detailFont]).width + 16)
        }
        width = max(width, w)
      }
      return min(ceil(width), 640)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      let view =
        tableView.makeView(withIdentifier: CompletionRowView.identifier, owner: nil)
        as? CompletionRowView ?? CompletionRowView()
      view.identifier = CompletionRowView.identifier
      view.row = rows[row]
      view.nameFont = nameFont
      view.needsDisplay = true
      return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      CompletionSelectionView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      updateDocumentation()
      onSelect?(selectedRow)
    }

    @objc private func doubleClicked() {
      guard table.clickedRow >= 0 else { return }
      onAccept?(table.clickedRow)
    }
  }

  /// The selected row in the accent color, even though the list never has
  /// focus.
  private final class CompletionSelectionView: NSTableRowView {
    override var isEmphasized: Bool {
      get { true }
      set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
      NSColor.selectedContentBackgroundColor.setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
  }

  /// One completion: badge, name and signature, type at the right.
  private final class CompletionRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionRow")

    var row: CompletionWindow.Row?
    var nameFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var isSelected: Bool { (superview as? NSTableRowView)?.isSelected ?? false }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
      guard let row else { return }
      let item = row.item
      let selected = isSelected
      let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
      let secondary: NSColor =
        selected
        ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor

      // The kind badge.
      let badge = NSRect(x: 9, y: (bounds.height - 16) / 2, width: 16, height: 16)
      let style = CompletionBadge.style(for: item.kind)
      style.color.setFill()
      NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
      let letterAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: style.letter.count > 1 ? 8 : 10, weight: .bold), .foregroundColor: NSColor.white,
      ]
      let letterSize = (style.letter as NSString).size(withAttributes: letterAttributes)
      (style.letter as NSString).draw(
        at: NSPoint(x: badge.midX - letterSize.width / 2, y: badge.midY - letterSize.height / 2),
        withAttributes: letterAttributes)

      // The type at the right, then the name in what is left.
      let detailFont = NSFont.systemFont(ofSize: 11)
      var right = bounds.width - 10
      if let detail = item.detail?.split(separator: "\n").first.map(String.init), !detail.isEmpty {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
          .font: detailFont, .foregroundColor: secondary, .paragraphStyle: paragraph,
        ]
        let width = min(
          ceil((detail as NSString).size(withAttributes: attributes).width), bounds.width * 0.4)
        let height = (detail as NSString).size(withAttributes: attributes).height
        (detail as NSString).draw(
          with: NSRect(
            x: right - width, y: (bounds.height - height) / 2, width: width, height: height),
          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        right -= width + 12
      }

      let name = NSMutableAttributedString(
        string: item.label, attributes: [.font: nameFont, .foregroundColor: primary])
      let bold = NSFontManager.shared.convert(nameFont, toHaveTrait: .boldFontMask)
      let length = name.length
      for position in row.positions where position < length {
        name.addAttribute(.font, value: bold, range: NSRange(location: position, length: 1))
      }
      if item.isDeprecated {
        name.addAttribute(
          .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
          range: NSRange(location: 0, length: length))
      }
      if let detail = item.labelDetail {
        name.append(
          NSAttributedString(
            string: detail, attributes: [.font: nameFont, .foregroundColor: secondary]))
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byTruncatingTail
      name.addAttribute(
        .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: name.length))
      let height = name.size().height
      let left = badge.maxX + 7
      name.draw(
        with: NSRect(
          x: left, y: (bounds.height - height) / 2, width: max(0, right - left), height: height),
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
  }

  /// Xcode's letters and colors for each kind of completion.
  enum CompletionBadge {
    static func style(for kind: CompletionKind) -> (letter: String, color: NSColor) {
      switch kind {
      case .method: return ("M", .systemBlue)
      case .function: return ("F", .systemBlue)
      case .constructor: return ("I", .systemBlue)
      case .field, .property: return ("P", .systemTeal)
      case .variable: return ("V", .systemGreen)
      case .class: return ("C", .systemPurple)
      case .interface: return ("Pr", .systemPurple)
      case .struct: return ("S", .systemPurple)
      case .enum: return ("E", .systemPurple)
      case .typeParameter: return ("T", .systemPurple)
      case .enumMember: return ("C", .systemPink)
      case .constant, .value: return ("K", .systemPink)
      case .module: return ("Mo", .systemBrown)
      case .keyword: return ("K", .systemGray)
      case .snippet: return ("{}", .systemOrange)
      case .operator: return ("O", .systemIndigo)
      case .event: return ("Ev", .systemYellow)
      case .file, .folder, .reference: return ("Fi", .systemGray)
      case .color: return ("Co", .systemOrange)
      case .unit: return ("U", .systemGray)
      case .text: return ("T", .systemGray)
      }
    }
  }
#endif
