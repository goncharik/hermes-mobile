import HermesKit
import SwiftUI

/// The turn's high-level activity, supplied by the reducer so the renderer can apply the
/// shared stick-to-bottom contract without reaching into feature state. `.streaming` covers
/// any in-flight turn (deltas growing the last cell / new rows appended); `.idle` is a
/// settled transcript.
enum TurnState: Equatable {
  case idle
  case streaming
}

/// Shared renderer boundary for the chat transcript.
///
/// Both rendering engines — this pure-SwiftUI one and `CollectionTranscriptView` (the
/// `UICollectionView` one) — expose the **same** initializer shape so `ChatView` can swap
/// between them behind a single call site:
///
/// ```
/// init(rows:turnState:canLoadOlder:onLoadOlder:cell:)
/// ```
///
/// - `rows` — the windowed slice (`store.visibleRows`); never the full transcript.
/// - `turnState` — `.idle` / `.streaming`, drives the follow-to-bottom decision.
/// - `canLoadOlder` — whether older history exists above the window (`store.hasMoreAbove`).
///   When `false` the top sentinel does NOT fire `onLoadOlder` nor arm prepend preservation,
///   so a transcript scrolled to its true top never stays stuck mid-load.
/// - `onLoadOlder` — fired when the top sentinel is reached (older page requested).
/// - `cell` — builds the row content; the caller passes its existing `rowView` switch so the
///   reused bubble subviews (`MessageBubbleView` / `MarkdownText` / `ThinkingIndicatorView` /
///   `ToolStatusView`) render identically across engines.
///
/// Scroll/pin behavior is **renderer-local**: the reducer issues no imperative scroll
/// commands. See the stick-to-bottom contract below.
struct SwiftUITranscriptView<Cell: View>: View {
  let rows: [ChatRow]
  let turnState: TurnState
  let canLoadOlder: Bool
  let onLoadOlder: () -> Void
  @ViewBuilder let cell: (ChatRow) -> Cell

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The live scroll position. We bind it so we can imperatively jump to the bottom on
  /// open/hydrate and during a pinned streaming follow without a `ScrollViewReader` proxy.
  @State private var scrollPosition = ScrollPosition(edge: .bottom)
  /// Renderer-local pin state (~60pt from the bottom). Never lives in the reducer.
  @State private var isPinnedToBottom = true
  /// Whether we've performed the initial open-at-bottom jump for this view instance.
  @State private var didInitialJump = false
  /// The id of the first currently-visible row, captured *before* a prepend so we can
  /// re-anchor scroll to it afterwards (keeps the viewport from jumping on `loadOlder`).
  @State private var prependAnchorID: ChatRow.ID?

  init(
    rows: [ChatRow],
    turnState: TurnState,
    canLoadOlder: Bool,
    onLoadOlder: @escaping () -> Void,
    @ViewBuilder cell: @escaping (ChatRow) -> Cell
  ) {
    self.rows = rows
    self.turnState = turnState
    self.canLoadOlder = canLoadOlder
    self.onLoadOlder = onLoadOlder
    self.cell = cell
  }

  var body: some View {
    scroll
      .overlay(alignment: .bottomTrailing) {
        if !isPinnedToBottom {
          ScrollToBottomButton { jumpToBottom(animated: !reduceMotion) }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.25), value: isPinnedToBottom)
  }

  private var scroll: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        // Top sentinel: a 1pt marker above the first row. Appearing it means the user
        // scrolled to the top of the window → request the previous page. Before the
        // prepend we capture the first visible row's id so we can re-anchor to it.
        Color.clear.frame(height: 1)
          .onAppear {
            // Only arm prepend re-anchoring when a load can actually happen; otherwise the
            // anchor would never clear (no prepend) and would misfire the next append.
            guard canLoadOlder, let first = rows.first else { return }
            prependAnchorID = first.id
            onLoadOlder()
          }
        ForEach(rows) { row in
          cell(row)
            .id(row.id)
        }
      }
      .padding()
      // Enables `scrollPosition.scrollTo(id:)` to resolve row ids to scroll targets (used by
      // the prepend re-anchor in `.onChange(of: rows.count)` below).
      .scrollTargetLayout()
    }
    .defaultScrollAnchor(.bottom)
    .scrollPosition($scrollPosition)
    // Compute pin state from live scroll geometry via the shared math so both renderers agree
    // on the at-bottom contract (≤ `TranscriptScrollMath.bottomThreshold` ⇒ pinned).
    .onScrollGeometryChange(for: Bool.self) { geo in
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: geo.contentSize.height,
        viewportHeight: geo.containerSize.height,
        bottomInset: geo.contentInsets.bottom,
        offsetY: geo.contentOffset.y
      )
    } action: { _, pinned in
      if pinned != isPinnedToBottom {
        isPinnedToBottom = pinned
      }
    }
    .onAppear {
      // Open/hydrate: jump to the bottom (no animation) — always. `.defaultScrollAnchor`
      // covers first layout; this guards async row population after appearance.
      guard !didInitialJump else { return }
      didInitialJump = true
      jumpToBottom(animated: false)
    }
    .onChange(of: rows.count) { old, new in
      guard new > old else { return }
      if let anchor = prependAnchorID {
        // A prepend (older page loaded): re-anchor to the previously-first row so the
        // viewport doesn't jump. No follow.
        scrollPosition.scrollTo(id: anchor)
        prependAnchorID = nil
        return
      }
      // A new row appended at the bottom: follow only if pinned (never yank a
      // scrolled-up reader). Reduce-motion degrades the follow to an instant jump.
      if isPinnedToBottom {
        jumpToBottom(animated: !reduceMotion)
      }
    }
    .onChange(of: lastRowSignature) { _, _ in
      // A streaming delta grew the last cell (no count change). Same pin rule.
      guard turnState == .streaming, isPinnedToBottom else { return }
      jumpToBottom(animated: !reduceMotion)
    }
  }

  /// Imperatively pin to the bottom edge. Animation degrades to instant under reduce-motion.
  private func jumpToBottom(animated: Bool) {
    if animated {
      withAnimation(.spring(duration: 0.25)) { scrollPosition.scrollTo(edge: .bottom) }
    } else {
      scrollPosition.scrollTo(edge: .bottom)
    }
  }

  /// A cheap fingerprint of the last row's mutable content so we can detect a streaming
  /// delta that grows the final cell without changing the row count or its id.
  private var lastRowSignature: String {
    guard let last = rows.last else { return "" }
    switch last.kind {
    case let .message(_, text, isComplete): return "m:\(text.count):\(isComplete)"
    case let .thinking(reasoning, status, _, isComplete):
      return "t:\(reasoning.count):\(status?.count ?? 0):\(isComplete)"
    case let .tool(_, _, state, _, _): return "x:\(state)"
    case let .status(_, text): return "s:\(text.count)"
    }
  }
}
