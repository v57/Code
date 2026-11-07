import Foundation

/// What an editor shows besides the text, from the app's settings.
public struct EditorFeatures: Equatable, Sendable {
  public var showsMinimap = true
  public var showsIssueMessages = true
  public var breakpointsEnabled = true
  /// The completion list opens while typing (else only with Esc and
  /// ⌃Space).
  public var suggestsCompletions = true

  public init(
    showsMinimap: Bool = true, showsIssueMessages: Bool = true, breakpointsEnabled: Bool = true,
    suggestsCompletions: Bool = true
  ) {
    self.showsMinimap = showsMinimap
    self.showsIssueMessages = showsIssueMessages
    self.breakpointsEnabled = breakpointsEnabled
    self.suggestsCompletions = suggestsCompletions
  }
}

/// Where things floating over the editor keep clear of: the minimap (or the scroller) at its trailing edge, and the
/// caret's line.
public struct EditorOverlayGeometry: Equatable, Sendable {
  /// The width the minimap takes at the editor's trailing edge, or the scroller's when there's no minimap.
  public var trailingInset: CGFloat
  /// The text of the caret's line, in its window's content space (origin at the top left: SwiftUI's global space);
  /// nil when it's off screen, empty, or text is selected.
  public var caretLine: CGRect?
}
