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
  /// The row-id sequence from the previous update, so we can classify the structural change
  /// (`TranscriptDiffKind`) and detect a wholesale `.reset` (a server-authoritative re-hydrate)
  /// that must force a jump-to-bottom regardless of pin state.
  @State private var previousRowIDs: [ChatRow.ID] = []

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
      // A plain `VStack` (not `LazyVStack`): the transcript is windowed to ~50 rows, so eager
      // measurement is cheap and — critically — gives `.defaultScrollAnchor(.bottom)` and
      // `onScrollGeometryChange` a STABLE `contentSize` from first layout. A `LazyVStack`
      // measures rows only as they appear, so on open the bottom anchor positions against
      // estimated heights (rows render mis-placed until you scroll) and the pin math reads a
      // shifting `contentSize` (so the jump button never hides and streaming never follows).
      VStack(alignment: .leading, spacing: 10) {
        // Top sentinel: a 1pt marker above the first row. Appearing it means the user
        // scrolled to the top of the window → request the previous page. Before the
        // prepend we capture the first visible row's id so we can re-anchor to it.
        Color.clear.frame(height: 1)
          .onAppear { maybeLoadOlder() }
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
    // Compute pin state from live scroll geometry. We measure the distance from the bottom edge
    // using the unambiguous content/container sizes (`maxOffset = contentSize - containerSize`,
    // the true scrollable range; `contentOffset.y` runs 0…maxOffset) rather than inset-relative
    // offsets, which are coordinate-system-dependent in SwiftUI. Both renderers still agree on the
    // shared `TranscriptScrollMath.bottomThreshold` (≤ threshold ⇒ pinned).
    .onScrollGeometryChange(for: CGFloat.self) { geo in
      let maxOffset = max(0, geo.contentSize.height - geo.containerSize.height)
      return maxOffset - geo.contentOffset.y
    } action: { _, distanceFromBottom in
      let pinned = distanceFromBottom <= TranscriptScrollMath.bottomThreshold
      if pinned != isPinnedToBottom {
        isPinnedToBottom = pinned
      }
    }
    .onAppear {
      // Open/hydrate: jump to the bottom (no animation) — always. `.defaultScrollAnchor`
      // covers first layout; this guards async row population after appearance.
      previousRowIDs = rows.map(\.id)
      guard !didInitialJump else { return }
      didInitialJump = true
      jumpToBottom(animated: false)
    }
    .onChange(of: rows) { _, newRows in
      let newIDs = newRows.map(\.id)
      let diff = TranscriptDiffKind.classify(old: previousRowIDs, new: newIDs)
      previousRowIDs = newIDs

      switch diff {
      case .prepend:
        // A prepend (older page loaded): re-anchor to the previously-first row so the viewport
        // doesn't jump. No follow. (`prependAnchorID` was captured before the load fired.)
        if let anchor = prependAnchorID {
          scrollPosition.scrollTo(id: anchor)
          prependAnchorID = nil
        }
      case .reset:
        // A wholesale replace of the visible slice — a server-authoritative re-hydrate
        // (`session.resume` rebuilds rows to the bottom window). Per the open/hydrate contract
        // force a jump-to-bottom regardless of pin state, so a re-hydrate while the user was
        // scrolled up doesn't leave the list parked mid-history. (A stale prepend anchor, if
        // any, is irrelevant now — clear it.)
        prependAnchorID = nil
        jumpToBottom(animated: false)
      case .appendOrMutate:
        // A new row appended at the bottom: follow only if pinned (never yank a scrolled-up
        // reader). Reduce-motion degrades the follow to an instant jump.
        if isPinnedToBottom {
          jumpToBottom(animated: !reduceMotion)
        }
      case .inPlace:
        // No structural change (a streaming delta that grew the last cell without changing the
        // id sequence). Follow under the same pin rule while a turn is in flight.
        if turnState == .streaming, isPinnedToBottom {
          jumpToBottom(animated: !reduceMotion)
        }
      }
    }
  }

  /// Request the previous page when the top sentinel appears — but ONLY from a genuine
  /// scroll-up, never from the initial layout. When the current window fits in the viewport the
  /// sentinel is on screen immediately, so firing on bare `.onAppear` would auto-page on first
  /// open with no user scroll and keep paging until `windowStart` hits 0, defeating windowing.
  /// Two guards prevent that:
  ///   - `didInitialJump` — the open-at-bottom jump must have run first (we never page during
  ///     the initial population pass);
  ///   - `!isPinnedToBottom` — the user must have actually scrolled up off the bottom. A short
  ///     chat that fits the viewport stays pinned, so its visible top sentinel never auto-pages.
  /// A legitimate scroll toward the top unpins first (reaching the sentinel requires scrolling
  /// up), so real pagination still works.
  private func maybeLoadOlder() {
    guard canLoadOlder, didInitialJump, !isPinnedToBottom, let first = rows.first else { return }
    // Arm prepend re-anchoring (capture the current first row) only when a load actually fires;
    // otherwise the anchor would never clear (no prepend) and would misfire the next append.
    prependAnchorID = first.id
    onLoadOlder()
  }

  /// Imperatively pin to the bottom edge. Animation degrades to instant under reduce-motion.
  private func jumpToBottom(animated: Bool) {
    if animated {
      withAnimation(.spring(duration: 0.25)) { scrollPosition.scrollTo(edge: .bottom) }
    } else {
      scrollPosition.scrollTo(edge: .bottom)
    }
  }
}
