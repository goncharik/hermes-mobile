import Foundation

/// What one session-list card (`SessionCardView`) shows — derived here so the rules are
/// unit-tested; the view only lays it out.
public struct SessionCardContent: Equatable, Sendable {
  /// Header workspace label, or `nil` when the workspace is unknown (a search hit carries no
  /// `cwd`), in which case the header leaves the slot out rather than claim "No workspace".
  public let workspace: String?
  /// `Session.displayName` — an untitled session promotes its preview here.
  public let title: String
  /// The preview line, only under a real title — never the title's text twice.
  public let preview: String?
  /// The raw server model id, shown verbatim like the chat's model chip.
  public let model: String?
  /// "N message(s)", or `nil` when the count is unknown or zero.
  public let messageCountText: String?

  public init(session: Session, showsWorkspace: Bool = true) {
    workspace = showsWorkspace ? session.workspaceLabel : nil
    title = session.displayName
    preview = session.resolvedTitle == nil ? nil : session.resolvedPreview
    model = session.model
    messageCountText = Self.messageCountText(session.messageCount)
  }

  private static func messageCountText(_ count: Int?) -> String? {
    guard let count, count > 0 else { return nil }
    return count == 1 ? "1 message" : "\(count) messages"
  }

  /// Whether the footer line (model · message count) renders at all.
  public var hasFooter: Bool { model != nil || messageCountText != nil }

  /// The card's one combined VoiceOver label, in visual order: workspace, title, preview,
  /// model, message count, age, then the status and the pin.
  public func accessibilityLabel(age: String?, status: SessionStatus, isPinned: Bool) -> String {
    var parts = [workspace, title, preview, model, messageCountText, age].compactMap { $0 }
    if let statusText = status.accessibilityText { parts.append(statusText) }
    if isPinned { parts.append("Pinned") }
    return parts.joined(separator: ", ")
  }
}

extension Session {
  /// The card header's workspace label: `workspaceName`, else "No workspace".
  public var workspaceLabel: String { workspaceName ?? "No workspace" }

  /// The folder basename of `cwd`, or `nil` when `cwd` is missing or blank. Mirrors desktop
  /// `baseName(path) || path` (root "/" has no basename, so the path itself is shown).
  public var workspaceName: String? {
    guard let path = cwd?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
      return nil
    }
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    if let base = trimmed.split(separator: "/").last, !base.isEmpty {
      return String(base)
    }
    return path
  }
}
