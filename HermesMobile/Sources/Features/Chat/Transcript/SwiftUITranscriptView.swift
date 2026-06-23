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

/// Stable id for the invisible bottom-anchor row — the imperative scroll target and the pin
/// detector. File-scope (not a `static` on the generic `SwiftUITranscriptView`, which can't have
/// stored statics). A `String` so it never collides with the `UUID` row ids.
private let transcriptBottomAnchorID = "transcript.bottom.anchor"

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

  /// Renderer-local pin state. Driven by the bottom anchor's *scroll visibility* (the anchor row
  /// is on screen ⇒ the user is at the bottom) rather than fragile offset math. Never lives in
  /// the reducer.
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
    // A `ScrollViewReader` drives every scroll via `proxy.scrollTo(id:)`. We deliberately do NOT
    // use `.defaultScrollAnchor(.bottom)`: it silently neutralises `proxy.scrollTo`, so the jump
    // button and the streaming-follow did nothing. Instead the content is bottom-aligned with a
    // `minHeight` frame (so a SHORT transcript still rests at the bottom — the role
    // `defaultScrollAnchor` used to play) and we scroll imperatively for open/hydrate/follow. The
    // overlay lives inside the reader so the button can use the same proxy.
    ScrollViewReader { proxy in
      GeometryReader { geo in
        // The jump button is a ZStack SIBLING of the ScrollView, NOT an `.overlay` on it: an
        // overlay-on-ScrollView `Button` does not reliably receive taps — that is why the button did
        // nothing while the streaming-follow (same `jump`, but triggered by `.onChange` state)
        // worked. A sibling mirrors the UICollectionView engine, whose hosted button is also a
        // sibling subview and is tappable.
        ZStack(alignment: .bottomTrailing) {
        ScrollView {
          // A plain `VStack` (not `LazyVStack`): the transcript is windowed to ~50 rows, so eager
          // measurement is cheap and keeps heights known up front (a `LazyVStack` measures rows
          // only as they appear, mis-placing them on open and making `scrollTo` unreliable).
          VStack(alignment: .leading, spacing: 10) {
            // Top sentinel: appearing it means the user scrolled to the top of the window → request
            // the previous page (we capture the first row id first, to re-anchor after the prepend).
            Color.clear.frame(height: 1)
              .onAppear { maybeLoadOlder() }
            ForEach(rows) { row in
              cell(row)
                .id(row.id)
            }
            // Bottom anchor: the imperative scroll target AND the pin detector. When this 1pt row is
            // visible in the viewport the user is at the bottom (pinned); when it scrolls off, it's
            // not. `onScrollVisibilityChange` answers "at the bottom?" directly — far more robust
            // than offset math across SwiftUI's coordinate edge cases (short content, insets).
            Color.clear.frame(height: 1)
              .id(transcriptBottomAnchorID)
              .onScrollVisibilityChange(threshold: 0.01) { visible in
                if visible != isPinnedToBottom { isPinnedToBottom = visible }
              }
          }
          .padding()
          // Fill at least the viewport, bottom-aligned, so a short transcript sticks to the bottom
          // (replacing `.defaultScrollAnchor(.bottom)` without breaking `proxy.scrollTo`).
          .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottom)
        }
        .onAppear {
          // Open/hydrate: jump to the bottom. Deferred to after first layout so the eager VStack
          // heights are resolved and the imperative scroll actually lands.
          previousRowIDs = rows.map(\.id)
          guard !didInitialJump else { return }
          didInitialJump = true
          DispatchQueue.main.async { jump(proxy, animated: false) }
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
            proxy.scrollTo(anchor, anchor: .top)
            prependAnchorID = nil
          }
        case .reset:
          // A wholesale replace — a server-authoritative re-hydrate (`session.resume` rebuilds
          // rows to the bottom window). Per the open/hydrate contract, force a jump-to-bottom
          // regardless of pin state so a re-hydrate while scrolled up doesn't park mid-history.
          prependAnchorID = nil
          jump(proxy, animated: false)
        case .appendOrMutate:
          // A new row appended at the bottom: follow only if pinned (never yank a scrolled-up
          // reader). Reduce-motion degrades the follow to an instant jump.
          if isPinnedToBottom { jump(proxy, animated: !reduceMotion) }
        case .inPlace:
          // A streaming delta grew the last cell without changing the id sequence. Follow under
          // the same pin rule while a turn is in flight.
          if turnState == .streaming, isPinnedToBottom { jump(proxy, animated: !reduceMotion) }
        }
      }
        if !isPinnedToBottom {
          ScrollToBottomButton { jump(proxy, animated: false) }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .transition(.scale.combined(with: .opacity))
        }
        }
        .animation(.spring(duration: 0.25), value: isPinnedToBottom)
      }
    }
  }

  /// Request the previous page when the top sentinel appears — but ONLY from a genuine scroll-up,
  /// never the initial layout. When the window fits the viewport the sentinel is on screen
  /// immediately, so firing on bare `.onAppear` would auto-page on open and keep paging until
  /// `windowStart` hits 0. Two guards prevent that: `didInitialJump` (the open jump must have run)
  /// and `!isPinnedToBottom` (the user must have actually scrolled up off the bottom — a short chat
  /// stays pinned, so its visible top sentinel never auto-pages). Real scroll-up pagination unpins
  /// first, so it still works.
  private func maybeLoadOlder() {
    guard canLoadOlder, didInitialJump, !isPinnedToBottom, let first = rows.first else { return }
    // Arm prepend re-anchoring (capture the current first row) only when a load actually fires.
    prependAnchorID = first.id
    onLoadOlder()
  }

  /// Imperatively scroll to the bottom anchor.
  ///
  /// We call `proxy.scrollTo` WITHOUT `withAnimation`. Wrapping it in `withAnimation` silently fails
  /// to scroll in this layout — that was the actual reason the jump button and streaming-follow did
  /// nothing while the (un-wrapped) open-at-bottom worked. Plain `scrollTo` is reliable; the scroll
  /// is instant, which is an acceptable trade for it actually working. The `animated` parameter is
  /// kept for call-site symmetry with the UIKit engine but is intentionally not honoured here.
  private func jump(_ proxy: ScrollViewProxy, animated: Bool) {
    proxy.scrollTo(transcriptBottomAnchorID, anchor: .bottom)
  }
}
