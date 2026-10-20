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
