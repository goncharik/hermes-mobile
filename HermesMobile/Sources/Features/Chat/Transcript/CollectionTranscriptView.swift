import HermesKit
import SwiftUI

/// The turn's high-level activity, supplied by the reducer so the renderer can apply the
/// stick-to-bottom contract without reaching into feature state. `.streaming` covers any
/// in-flight turn (deltas growing the last cell / new rows appended); `.idle` is a settled
/// transcript. (Declared outside the `#if canImport(UIKit)` guard so `ChatView` can name it.)
enum TurnState: Equatable {
  case idle
  case streaming
}

/// The transcript's row geometry and its compositional-layout recipe, in one namespace so
/// content rendered *into* a row can size itself against the same numbers the layout uses —
/// `MarkdownTableView`'s column ceiling is ``narrowestRowWidth``, so widening the section
/// insets here moves the ceiling with it instead of silently re-opening a panning regression.
///
/// The measurements live here; the `UICollectionViewLayout` factory is in the
/// `#if canImport(UIKit)` extension below, so pure-SwiftUI views can name the namespace on
/// any platform.
enum TranscriptLayout {
  /// Inset applied to each horizontal edge of the transcript section, i.e. a row is
  /// `screen width − 2 × this`.
  static let horizontalSectionInset: CGFloat = 16

  /// The narrowest logical screen width this app can be rendered at.
  ///
  /// Not the narrowest *default* iPhone width (that is 375pt): 320pt is what **Display Zoom**
  /// ("Zoomed" in Settings → Display & Brightness) renders at on every iOS-18 iPhone — SE 2/3
  /// at 320×568, the X-class and later at 320×693 (Apple's device metrics).
  static let narrowestLayoutWidth: CGFloat = 320

  /// The width a transcript row gets on the narrowest layout: 288pt. Anything that must fit a
  /// row on *every* device sizes against this.
  static let narrowestRowWidth: CGFloat = narrowestLayoutWidth - 2 * horizontalSectionInset

  /// The shortest logical screen height this app can be rendered at: 568pt — the same
  /// **Display Zoom** mode as ``narrowestLayoutWidth``, where an SE 2/3 renders at 320×568.
  ///
  /// Anything competing for the chat screen's *vertical* budget sizes against this the way
  /// row content sizes against ``narrowestRowWidth`` — `ApprovalCardView`'s scrollable-content
  /// ceiling is three fifths of it.
  static let shortestLayoutHeight: CGFloat = 568
}

#if canImport(UIKit)
import UIKit

/// A `UICollectionView` that reports when its viewport *height* shrinks — e.g. the keyboard
/// appears and SwiftUI shrinks our frame to make room. The coordinator uses this to re-pin to
/// the bottom so a user parked at the latest message stays there when the keyboard eats vertical
/// space (instead of the keyboard covering the last rows without scrolling). Generic over rotation
/// / split-view too; only a height *decrease* fires.
final class TranscriptCollectionView: UICollectionView {
  var onViewportHeightShrink: (() -> Void)?
  /// Fired after every layout pass (once the view actually has a frame). The coordinator uses it
  /// to flush an apply deferred while the view couldn't be measured (#128 — in a
  /// `UIViewRepresentable` the first `updateUIView` runs *before* the collection view is sized or
  /// in a window) and to complete the open-at-bottom settle: self-sizing cells keep growing
  /// `contentSize` after the first scroll, and re-pinning on real layout passes is what makes
  /// "open at bottom" stick.
  var onLayout: (() -> Void)?
  private var lastViewportHeight: CGFloat = 0

  override func layoutSubviews() {
    super.layoutSubviews()
    let height = bounds.height
    if height < lastViewportHeight - 0.5 {
      onViewportHeightShrink?()
    }
    lastViewportHeight = height
    onLayout?()
  }

  /// Re-attaching to a window at an unchanged size need not schedule a layout pass on its own,
  /// and the layout pass is what flushes an apply deferred while the view had no window (#128).
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { setNeedsLayout() }
  }
}

extension TranscriptLayout {
  /// The transcript's single-section vertical compositional layout, with **self-sizing** items:
  /// the `UIHostingConfiguration` measures its SwiftUI content, so heights track streaming deltas.
  ///
  /// Built here rather than inline in `makeUIView` so the measured layout tests can lay a row
  /// out under the *production* recipe instead of a hand-copied one that could drift from it.
  static func makeLayout() -> UICollectionViewLayout {
    let item = NSCollectionLayoutItem(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .estimated(60)
      )
    )
    let group = NSCollectionLayoutGroup.vertical(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .estimated(60)
      ),
      subitems: [item]
    )
    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 10
    section.contentInsets = NSDirectionalEdgeInsets(
      top: 12,
      leading: horizontalSectionInset,
      bottom: 12,
      trailing: horizontalSectionInset
    )
    return UICollectionViewCompositionalLayout(section: section)
  }
}

/// The transcript renderer (the only one): a `UICollectionView` whose diffable data source is
/// keyed on `TranscriptItem.ID` — the turn fold's display items (headers, run summaries, call
/// lines, rows), each id deterministic so a re-layout reconfigures cells instead of recreating
/// them.
///
/// Why UIKit: the list owns scroll/pin behaviour imperatively, which lets us re-pin
/// `contentOffset` the instant a streaming delta resizes the last cell (the primary
/// streaming-jank mitigation) and preserve the on-screen anchor across a top prepend, a window
/// slide, or a fold change — all of which are awkward to do reliably in pure SwiftUI scroll APIs.
///
/// - `items` — the window laid out as display items (`store.transcriptItems`); never the full
///   transcript.
/// - `rowIDs` — the raw window's ROW ids (`store.windowRowIDs`), what the open/hydrate/prepend/
///   slide classification runs on: a fold expanding or collapsing changes the items but not the
///   rows, so it can never read as a hydrate (jump to bottom) or a prepend; and the raw window,
///   unlike the snapped one the items are built from, keeps its size across a live append.
/// - `turnState` — `.idle` / `.streaming`, drives the follow-to-bottom decision.
/// - `canLoadOlder` — whether older history exists above the window (`store.hasMoreAbove`).
///   When `false` the top sentinel does NOT fire `onLoadOlder` nor arm prepend preservation,
///   so a transcript scrolled to its true top never gets stuck with `pendingPrependPreservation`.
/// - `onLoadOlder` — fired when the top sentinel is reached (older page requested).
/// - `cell` — builds an item's content, hosted via `UIHostingConfiguration`.
///
/// Scroll/pin behavior is **renderer-local**: the reducer issues no imperative scroll
/// commands. Pinned → follow the bottom; scrolled up → never yanked, and a window slide or a
/// fold change keeps the first visible surviving item where it was on screen.
struct CollectionTranscriptView<Cell: View>: UIViewRepresentable {
  let items: [TranscriptItem]
  let rowIDs: [ChatRow.ID]
  let turnState: TurnState
  let canLoadOlder: Bool
  let onLoadOlder: () -> Void
  let cell: (TranscriptItem) -> Cell

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    items: [TranscriptItem],
    rowIDs: [ChatRow.ID],
    turnState: TurnState,
    canLoadOlder: Bool,
    onLoadOlder: @escaping () -> Void,
    @ViewBuilder cell: @escaping (TranscriptItem) -> Cell
  ) {
    self.items = items
    self.rowIDs = rowIDs
    self.turnState = turnState
    self.canLoadOlder = canLoadOlder
    self.onLoadOlder = onLoadOlder
    self.cell = cell
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onLoadOlder: onLoadOlder,
      cell: cell
    )
  }

  func makeUIView(context: Context) -> UICollectionView {
    let layout = TranscriptLayout.makeLayout()
    let collectionView = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.keyboardDismissMode = .interactive
    collectionView.alwaysBounceVertical = true
    // Rows are never "selected" as cells; turning this off stops the cell's tap/long-press
    // highlight gesture from competing with text selection inside hosted UITextViews.
    collectionView.allowsSelection = false
    collectionView.delegate = context.coordinator
    collectionView.onViewportHeightShrink = { [weak coordinator = context.coordinator] in
      coordinator?.viewportDidShrink()
    }
    collectionView.onLayout = { [weak coordinator = context.coordinator] in
      coordinator?.didLayout()
    }
    context.coordinator.configure(collectionView: collectionView)
    context.coordinator.installJumpButton(in: collectionView)
    return collectionView
  }

  func updateUIView(_ collectionView: UICollectionView, context: Context) {
    // Refresh the closures each update so SwiftUI captures stay fresh (state from the store).
    context.coordinator.onLoadOlder = onLoadOlder
    context.coordinator.cell = cell
    context.coordinator.reduceMotion = reduceMotion
    context.coordinator.turnState = turnState
    context.coordinator.canLoadOlder = canLoadOlder
    context.coordinator.apply(items: items, rowIDs: rowIDs)
  }

  // MARK: - Coordinator

  /// Owns the diffable data source, cell hosting, and all imperative scroll behaviour: pin
  /// detection, follow-on-delta, prepend offset-preservation, slide anchor-preservation for a
  /// scrolled-up reader (#125), and the open/hydrate jump.
  final class Coordinator: NSObject, UICollectionViewDelegate {
    enum Section { case main }

    /// An offset change below this is a no-op: not worth a programmatic write or an animation.
    private static var minimumOffsetChange: CGFloat { 0.5 }

    var onLoadOlder: () -> Void
    var cell: (TranscriptItem) -> Cell
    var reduceMotion = false
    var turnState: TurnState = .idle
    /// Whether older history exists above the window. Gates the top-sentinel load trigger so
    /// `pendingPrependPreservation` is only armed when a prepend can actually follow.
    var canLoadOlder = false

    private weak var collectionView: UICollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<Section, TranscriptItem.ID>!

    /// The full item payload, keyed by id, so the diffable data source (which carries only ids)
    /// can resolve the `TranscriptItem` to host. Items are content-mutated in place across
    /// deltas; the id is stable (deterministic identity) so the cell is reconfigured, not
    /// re-created.
    private var itemsByID: [TranscriptItem.ID: TranscriptItem] = [:]
    private var currentOrder: [TranscriptItem.ID] = []
    /// The window's row ids at the last apply — the open/hydrate/prepend classification input.
    private var currentRowIDs: [ChatRow.ID] = []
    /// The latest update that arrived while the view couldn't be measured
    /// (`TranscriptScrollMath.canApplySnapshot`, #128) — overwritten by each deferred update,
    /// never queued, and flushed through `apply` by the next `didLayout` that passes the gate.
    /// Nothing above (`itemsByID`, `currentOrder`, `currentRowIDs`) moves until the flush, so
    /// the diff classification spans the gap as one change.
    private var pendingApply: (items: [TranscriptItem], rowIDs: [ChatRow.ID])?

    /// Renderer-local pin state. Never lives in the reducer. Starts pinned so the first
    /// population follows the open-at-bottom contract; afterwards only the user's own scrolling
    /// (`TranscriptScrollMath.pinnedAfterUserScroll`), the jump button, or a jump changes it.
    private var isPinnedToBottom = true
    /// The offset at the last `scrollViewDidScroll`, so a user scroll's direction is known.
    private var lastOffsetY: CGFloat?
    /// Guards the one-shot open/hydrate jump for this view instance.
    private var didInitialJump = false
    /// True while the initial (or post-hydrate) open-at-bottom is still *settling*. Two things make
    /// "open at bottom" hard here: (1) in a `UIViewRepresentable` the first diff `apply` runs before
    /// the collection view is sized, so its scroll-to-bottom targets a zero-height viewport; and
    /// (2) self-sizing `UIHostingConfiguration` cells finish measuring over several later layout
    /// passes, growing `contentSize` after that first scroll. While this is set we re-pin to the
    /// bottom on every layout pass (`didLayout`) and every `contentSize` growth, and `updatePinState`
    /// won't flip the pin off — so the view converges on the true bottom. It's cleared by the first
    /// real user scroll (`scrollViewWillBeginDragging`), after which normal pin rules resume.
    private var needsInitialBottomSettle = false
    /// Set by the top-sentinel trigger so the next `apply` (which will be a prepend) preserves
    /// the on-screen anchor instead of following or jumping.
    private var pendingPrependPreservation = false
    /// Re-entrancy guard: programmatic offset changes shouldn't be read back as user scrolls.
    ///
    /// Lifecycle: set `true` when we kick off a programmatic offset change — `setContentOffset`
    /// (`scrollToBottom`) or a direct `contentOffset` write (`assignOffset`: the anchor hold and
    /// the prepend preserve). A *non-animated* change settles synchronously, so we clear it on the
    /// next runloop (`assignOffset` skips that clear if an animated follow took the guard since).
    /// For an *animated* follow we must keep it set across the whole animation (UIKit emits
    /// intermediate `scrollViewDidScroll` frames that would otherwise be misread as user scrolls
    /// and flip the pin mid-follow); it is cleared by whichever of these fires first:
    ///   - `scrollViewDidEndScrollingAnimation` (the animation completed normally), or
    ///   - `scrollViewWillBeginDragging` (a user touch cancelled the animation — no end callback), or
    ///   - the `animationGuardGeneration` watchdog (a safety net if neither fires, e.g. the
    ///     animation is superseded/cancelled by view churn).
    /// This belt-and-braces clearing guarantees the guard can never be left permanently `true`,
    /// which would otherwise freeze pin/pagination updates and suppress the contentSize re-pin.
    private var isAdjustingOffset = false
    /// Monotonic token identifying the latest animated follow, so a stale watchdog from a
    /// superseded animation can't clear the guard belonging to a newer one.
    private var animationGuardGeneration = 0
    /// True while a snapshot apply is in flight (until its completion runs). The `contentSize`
    /// KVO fires during a diff apply (the layout grows as rows are inserted/resized); `apply`
    /// and its completion already own the authoritative hold/preserve/re-pin/jump, so the KVO
    /// must not also snap mid-apply (which could fight the prepend-preservation). Streaming-delta growth
    /// happens *outside* an apply, where this is false, so the KVO still handles that.
    private var isApplyingSnapshot = false
    /// KVO token watching `contentSize` so a self-sizing cell that grows (a streaming delta
    /// resizing the last bubble) re-pins to the bottom while pinned — the primary jank fix.
    private var contentSizeObservation: NSKeyValueObservation?
    /// The floating "jump to latest" button (a hosted `ScrollToBottomButton`), shown only when
    /// scrolled up — mirrors the SwiftUI engine's overlay.
    private weak var jumpButton: UIView?
    /// Strong reference to the button's hosting controller. Without this the controller would
    /// deallocate the instant `installJumpButton` returns (only its `view` is retained by the
    /// collection-view hierarchy), stripping the SwiftUI update/lifecycle machinery off a view
    /// still on screen. No retain cycle: the button's action closure captures `self` weakly.
    private var jumpHost: UIHostingController<ScrollToBottomButton>?

    init(
      onLoadOlder: @escaping () -> Void,
      cell: @escaping (TranscriptItem) -> Cell
    ) {
      self.onLoadOlder = onLoadOlder
      self.cell = cell
    }

    deinit { contentSizeObservation?.invalidate() }

    // MARK: Setup

    func configure(collectionView: UICollectionView) {
      self.collectionView = collectionView

      // Re-pin on cell bounds-change while pinned: when a self-sizing cell grows (streaming
      // delta), `contentSize` changes outside the `apply` completion. If we're pinned and not
      // mid-prepend, snap the offset back to the bottom so the latest text stays visible
      // without the layout "jumping" the viewport.
      contentSizeObservation = collectionView.observe(\.contentSize, options: [.old, .new]) {
        [weak self] _, change in
        guard
          let self,
          let old = change.oldValue,
          let new = change.newValue,
          new.height > old.height,                 // content grew
          self.isPinnedToBottom || self.needsInitialBottomSettle, // at bottom, or still settling open
          !self.isAdjustingOffset,                 // not our own programmatic change
          !self.isApplyingSnapshot,                // apply completion owns the re-pin
          !self.pendingPrependPreservation,        // a prepend handles its own offset
          self.didInitialJump                      // skip first population (handled by jump)
        else { return }
        self.scrollToBottom(animated: false)
      }

      let registration = UICollectionView.CellRegistration<UICollectionViewCell, TranscriptItem.ID> {
        [weak self] cell, _, id in
        guard let self, let item = self.itemsByID[id] else { return }
        let builder = self.cell
        cell.contentConfiguration = UIHostingConfiguration { builder(item) }
          .margins(.all, 0)
        cell.backgroundConfiguration = .clear()
      }

      dataSource = UICollectionViewDiffableDataSource<Section, TranscriptItem.ID>(
        collectionView: collectionView
      ) { collectionView, indexPath, id in
        collectionView.dequeueConfiguredReusableCell(
          using: registration, for: indexPath, item: id
        )
      }
    }

    /// Host `ScrollToBottomButton` over the list, pinned bottom-trailing. Hidden while pinned;
    /// tapping jumps to the latest row (instant under reduce-motion).
    func installJumpButton(in collectionView: UICollectionView) {
      let host = UIHostingController(
        rootView: ScrollToBottomButton { [weak self] in
          guard let self else { return }
          self.isPinnedToBottom = true
          self.setJumpButtonVisible(false)
          self.scrollToBottom(animated: !self.reduceMotion)
        }
      )
      host.view.backgroundColor = .clear
      host.view.translatesAutoresizingMaskIntoConstraints = false
      host.view.isHidden = isPinnedToBottom
      collectionView.addSubview(host.view)
      NSLayoutConstraint.activate([
        host.view.trailingAnchor.constraint(
          equalTo: collectionView.frameLayoutGuide.trailingAnchor, constant: -16
        ),
        host.view.bottomAnchor.constraint(
          equalTo: collectionView.frameLayoutGuide.bottomAnchor, constant: -12
        ),
      ])
      jumpButton = host.view
      jumpHost = host
    }

    private func setJumpButtonVisible(_ visible: Bool) {
      guard let jumpButton, jumpButton.isHidden == visible else { return }
      UIView.animate(withDuration: reduceMotion ? 0 : 0.2) {
        jumpButton.isHidden = !visible
        jumpButton.alpha = visible ? 1 : 0
      }
    }

    // MARK: Diff application

    /// Apply new display `items` over the window's `rowIDs`: classify the structural change (on
    /// the ROWS — see the type doc), refresh the payload, snapshot the diff, then honour the
    /// stick-to-bottom contract:
    /// - **jump** — first population, or a `.reset` (hydrate / wholesale replace): to the bottom,
    ///   regardless of pin state.
    /// - **preserve** — a `.prepend` armed by the top sentinel keeps the on-screen anchor.
    /// - **hold** — any change that keeps old rows (`holdsReaderAnchor`: `.slide`, e.g. #125's
    ///   live window dropping its head, or an append/mutate), or a fold expanding or collapsing
    ///   over unchanged rows, keeps the reader's anchor item at the same on-screen y; a shift
    ///   that carries them to the window top pages older rows in.
    /// - **follow** — then, if pinned, go to the new bottom: an animated scroll for an
    ///   append/mutate or a fold change, the jump-and-settle for a `.slide`.
    ///
    /// The preserve and the hold run right after the (non-animated, synchronous) apply, in the same
    /// pass; the jump and the follow run in the apply's completion, which UIKit calls on a later
    /// pass.
    ///
    /// A hydrate is classified like any other update, so it jumps a scrolled-up reader only when
    /// their rows are gone (`.reset`: nothing survives, or the window shrank and lost its head — a
    /// paged-up window re-trimmed to the bottom). A hydrate whose rows survive keeps their place.
    ///
    /// An update that lands while the view can't be measured (no window, or a degenerate frame:
    /// `TranscriptScrollMath.canApplySnapshot`) is deferred instead — only the latest is kept —
    /// and `didLayout` flushes it back through here (#128). The open's first update is one of
    /// these (zero frame, no window), so its flush is what performs the open jump.
    func apply(items: [TranscriptItem], rowIDs: [ChatRow.ID]) {
      guard canApplySnapshotNow else {
        pendingApply = (items, rowIDs)
        return
      }
      pendingApply = nil
      let newOrder = items.map(\.id)
      let oldOrder = currentOrder
      let diff = TranscriptDiffKind.classify(old: currentRowIDs, new: rowIDs)
      currentRowIDs = rowIDs

      // Refresh the payload first so cell reconfiguration sees mutated content.
      itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
      currentOrder = newOrder

      // Determine which existing items need a *content* reconfigure (same id, changed body) —
      // streaming deltas mutate text without changing the id, so the snapshot must reconfigure.
      let oldIDs = Set(oldOrder)
      let changedIDs = newOrder.filter(oldIDs.contains)

      let preservePrepend = pendingPrependPreservation && diff.isPrepend
      pendingPrependPreservation = false

      // Open, or a wholesale replace of the reader's rows (`.reset`, e.g. a hydrate re-trimming a
      // paged-up window to the bottom): jump to the bottom regardless of pin state.
      let jumps = !didInitialJump || diff == .reset
      let isSlide = if case .slide = diff { true } else { false }

      // Capture against the PRE-apply layout.
      let previousOffsetY = collectionView?.contentOffset.y ?? 0
      let previousContentHeight = collectionView?.contentSize.height ?? 0
      // A row change that keeps old rows, or a fold expanding or collapsing (a tap, or a finished
      // turn auto-collapsing) under a scrolled-up reader: hold the reader's place.
      let holdsAnchor = TranscriptScrollMath.holdsReaderAnchor(
        rowDiff: diff, didInitialJump: didInitialJump, isPinned: isPinnedToBottom,
        itemOrderChanged: newOrder != oldOrder
      )
      let anchor = holdsAnchor
        ? captureReaderAnchor(oldOrder: oldOrder, survivors: Set(newOrder)) : nil

      var snapshot = NSDiffableDataSourceSnapshot<Section, TranscriptItem.ID>()
      snapshot.appendSections([.main])
      snapshot.appendItems(newOrder, toSection: .main)
      if !changedIDs.isEmpty {
        snapshot.reconfigureItems(changedIDs)
      }

      // Suppress the contentSize KVO for the duration of the apply: this method and its
      // completion are the single authority on where the offset lands for this change.
      isApplyingSnapshot = true
      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        // UIKit runs this on a later run-loop pass. It reads the live pin state, so a reader who
        // scrolled away since the apply is not pulled back.
        guard let self else { return }
        defer { self.isApplyingSnapshot = false }
        guard !newOrder.isEmpty else { return }
        if jumps || !self.didInitialJump || (isSlide && self.isPinnedToBottom) {
          // Open / reset — or a pinned reader's slide (a hydrate re-iding the tail rows lands on
          // estimated heights, which an animated follow would stop short of): jump and settle.
          self.jumpToBottomAndSettle()
        } else if !preservePrepend, self.isPinnedToBottom {
          // Appended row, streaming delta grew the last cell, or a fold changed while at the
          // bottom: follow only if pinned.
          self.scrollToBottom(animated: !self.reduceMotion)
        }
        // Scrolled-up reader: no yank, the jump button stays.
      }

      // The non-animated apply has already updated the collection view, so correct the offset
      // now, in the same pass, so the changed layout is never drawn uncorrected.
      if jumps { return }
      if preservePrepend {
        preserveOffsetAfterPrepend(
          previousOffsetY: previousOffsetY, previousContentHeight: previousContentHeight
        )
      } else if let anchor, holdAnchor(anchor, previousOffsetY: previousOffsetY), !isPinnedToBottom {
        // A programmatic shift never reaches `scrollViewDidScroll`'s top sentinel, so check it
        // here — after this view update, since paging older rows sends a store action.
        DispatchQueue.main.async { [weak self] in self?.loadOlderIfNearTop() }
      }
    }

    /// The reader's reference item: its id and its content-space `frame.minY` before the apply.
    private struct ReaderAnchor {
      let id: TranscriptItem.ID
      let minY: CGFloat
    }

    /// The reader's anchor (`TranscriptScrollMath.preservationAnchor`): the topmost on-screen
    /// item (below the top inset) that survives into the new order — or, when every on-screen
    /// item is going away (the reader is inside a tall row the slide drops, or looking at a
    /// turn's tool lines as it collapses), the first survivor after them, else the last one
    /// before. Measured against the current (pre-apply) layout; `nil` only when no item survives.
    private func captureReaderAnchor(
      oldOrder: [TranscriptItem.ID], survivors: Set<TranscriptItem.ID>
    ) -> ReaderAnchor? {
      guard let collectionView else { return nil }
      let visibleTop = collectionView.bounds.minY + collectionView.adjustedContentInset.top
      let onScreen = collectionView.indexPathsForVisibleItems
        .compactMap { indexPath -> (id: TranscriptItem.ID, frame: CGRect)? in
          guard
            let id = dataSource.itemIdentifier(for: indexPath),
            let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
            frame.maxY > visibleTop
          else { return nil }
          return (id, frame)
        }
        .sorted { $0.frame.minY < $1.frame.minY }
      guard
        let id = TranscriptScrollMath.preservationAnchor(
          visible: onScreen.map(\.id), oldOrder: oldOrder, surviving: survivors
        ),
        let indexPath = dataSource.indexPath(for: id),
        let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
      else { return nil }
      return ReaderAnchor(id: id, minY: frame.minY)
    }

    /// Keep `anchor` where it was on screen: lay out the new snapshot, measure how far the row
    /// moved in content space, and shift the pre-apply offset by that delta. Runs in the same pass
    /// as the apply, so no user scroll lies between the capture and the shift. A row that did not
    /// move (a plain append below the reader) leaves the offset alone. Returns whether it shifted.
    private func holdAnchor(_ anchor: ReaderAnchor, previousOffsetY: CGFloat) -> Bool {
      guard
        let collectionView,
        let indexPath = dataSource.indexPath(for: anchor.id)
      else { return false }
      collectionView.layoutIfNeeded()
      guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
        return false
      }
      let anchorShift = frame.minY - anchor.minY
      guard abs(anchorShift) > Self.minimumOffsetChange else { return false }
      assignOffset(
        TranscriptScrollMath.offsetAfterAnchorShift(
          previousOffsetY: previousOffsetY,
          anchorShift: anchorShift,
          contentHeight: collectionView.contentSize.height,
          viewportHeight: collectionView.bounds.height,
          topInset: collectionView.adjustedContentInset.top,
          bottomInset: collectionView.adjustedContentInset.bottom
        )
      )
      return true
    }

    /// A programmatic, non-animated offset change. Assigned directly rather than through
    /// `setContentOffset(_:animated:)`, which also stops an in-flight deceleration; whether a fling
    /// continues smoothly across the shift is not verified on device.
    private func assignOffset(_ y: CGFloat) {
      guard let collectionView else { return }
      isAdjustingOffset = true
      collectionView.contentOffset = CGPoint(x: 0, y: y)
      // Clear on the next runloop — unless an animated follow started since and owns the guard.
      let generation = animationGuardGeneration
      DispatchQueue.main.async { [weak self] in
        guard let self, self.animationGuardGeneration == generation else { return }
        self.isAdjustingOffset = false
      }
    }

    /// The open / hydrate / reset jump: re-pin, hide the jump button, and begin a "settle" so
    /// self-sizing cell growth keeps re-pinning until the real bottom is reached.
    private func jumpToBottomAndSettle() {
      didInitialJump = true
      isPinnedToBottom = true
      setJumpButtonVisible(false)
      beginInitialBottomSettle()
    }

    // MARK: Scroll behaviour

    private func scrollToBottom(animated: Bool) {
      guard let collectionView, !currentOrder.isEmpty else { return }
      let target = TranscriptScrollMath.maxOffsetY(
        contentHeight: collectionView.contentSize.height,
        viewportHeight: collectionView.bounds.height,
        topInset: collectionView.adjustedContentInset.top,
        bottomInset: collectionView.adjustedContentInset.bottom
      )
      // Animate only when there's a meaningful distance to travel; an animated call that is
      // already at the target produces NO `scrollViewDidEndScrollingAnimation`, which would
      // strand `isAdjustingOffset == true` forever. Treat a no-op as a synchronous settle.
      let willAnimate =
        animated && abs(collectionView.contentOffset.y - target) > Self.minimumOffsetChange
      isAdjustingOffset = true
      collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: willAnimate)
      // For non-animated jumps the offset settles synchronously; clear the guard on the next
      // runloop so the resulting `scrollViewDidScroll` doesn't read it back as a user scroll.
      //
      // For *animated* follows we must KEEP the guard set for the full animation: UIKit emits a
      // stream of `scrollViewDidScroll` frames as the offset animates, and if the guard were
      // cleared synchronously those programmatic frames would be read as user scrolls and could
      // flip `isPinnedToBottom` to false mid-animation — then later contentSize growth would no
      // longer re-pin and fast streaming would race the follow, leaving the list above the
      // latest content. The guard is normally cleared in `scrollViewDidEndScrollingAnimation`,
      // or earlier in `scrollViewWillBeginDragging` if the user interrupts; the watchdog below is
      // a final safety net so the guard can never be stranded by a cancelled/superseded animation.
      if willAnimate {
        animationGuardGeneration &+= 1
        let generation = animationGuardGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
          guard let self, self.animationGuardGeneration == generation, self.isAdjustingOffset
          else { return }
          self.isAdjustingOffset = false
        }
      } else {
        DispatchQueue.main.async { [weak self] in self?.isAdjustingOffset = false }
      }
    }

    /// Preserve the on-screen anchor after older rows are inserted at the top: shift the offset
    /// down by exactly the inserted height so the row that was on-screen stays put.
    private func preserveOffsetAfterPrepend(
      previousOffsetY: CGFloat,
      previousContentHeight: CGFloat
    ) {
      guard let collectionView else { return }
      collectionView.layoutIfNeeded()
      let insertedHeight = collectionView.contentSize.height - previousContentHeight
      guard insertedHeight > 0 else { return }
      let newOffsetY = TranscriptScrollMath.offsetAfterAnchorShift(
        previousOffsetY: previousOffsetY,
        anchorShift: insertedHeight,
        contentHeight: collectionView.contentSize.height,
        viewportHeight: collectionView.bounds.height,
        topInset: collectionView.adjustedContentInset.top,
        bottomInset: collectionView.adjustedContentInset.bottom
      )
      assignOffset(newOffsetY)
    }

    /// Drive the open-at-bottom across self-sizing cell measurement. The first `scrollToBottom`
    /// runs against estimated (60pt) cell heights, so `contentSize` keeps growing over the next
    /// few layout passes; the `contentSize` KVO re-pins on each growth while `needsInitialBottomSettle`
    /// holds. We force one synchronous layout to get closer immediately, then release the settle
    /// after a short window once the layout has stabilised.
    private func beginInitialBottomSettle() {
      needsInitialBottomSettle = true
      // Pin now against whatever frame we have; `didLayout` re-pins on every subsequent layout
      // pass (when the real frame and self-sized cell heights arrive) until the user scrolls.
      collectionView?.layoutIfNeeded()
      scrollToBottom(animated: false)
    }

    /// Called after every collection-view layout pass. While the initial open-at-bottom is still
    /// settling, keep pinning to the true bottom (the frame/cell sizes are only correct here, not
    /// in the pre-layout `apply` completion).
    ///
    /// First, flush an update deferred while the view couldn't be measured (#128), now that it
    /// can — through the normal `apply`, so a first population still jumps and settles and a
    /// later one follows or holds by the usual rules.
    func didLayout() {
      if let pending = pendingApply, canApplySnapshotNow {
        apply(items: pending.items, rowIDs: pending.rowIDs)
      }
      guard needsInitialBottomSettle else { return }
      scrollToBottom(animated: false)
    }

    /// Whether the collection view can take a diff apply now: in a window, at a finite, positive
    /// size wide enough to leave a row any width (`TranscriptScrollMath.canApplySnapshot`).
    private var canApplySnapshotNow: Bool {
      guard let collectionView else { return false }
      return TranscriptScrollMath.canApplySnapshot(
        width: collectionView.bounds.width,
        height: collectionView.bounds.height,
        hasWindow: collectionView.window != nil,
        horizontalSectionInset: TranscriptLayout.horizontalSectionInset
      )
    }

    /// The viewport lost height (typically the keyboard appeared and SwiftUI shrank our frame).
    /// If the user was parked at the bottom, keep them there so the keyboard doesn't cover the
    /// latest rows without scrolling.
    func viewportDidShrink() {
      guard isPinnedToBottom || needsInitialBottomSettle else { return }
      scrollToBottom(animated: false)
    }

    /// Update the pin from a user scroll that moved the offset by `delta`, and toggle the jump
    /// button on a change.
    private func updatePinState(delta: CGFloat) {
      // While settling the initial open-at-bottom, intermediate cell-sizing can momentarily look
      // "not at bottom"; don't let that flip the pin off (a drag ends the settle first).
      guard !needsInitialBottomSettle else { return }
      guard let collectionView else { return }
      let maxY = TranscriptScrollMath.maxOffsetY(
        contentHeight: collectionView.contentSize.height,
        viewportHeight: collectionView.bounds.height,
        topInset: collectionView.adjustedContentInset.top,
        bottomInset: collectionView.adjustedContentInset.bottom
      )
      let pinned = TranscriptScrollMath.pinnedAfterUserScroll(
        wasPinned: isPinnedToBottom, delta: delta,
        distanceFromBottom: maxY - collectionView.contentOffset.y
      )
      if pinned != isPinnedToBottom {
        isPinnedToBottom = pinned
        setJumpButtonVisible(!pinned)
      }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      // Track every offset change, programmatic included, so a user scroll's delta is measured
      // from where our own adjustments left the list.
      let offsetY = scrollView.contentOffset.y
      let delta = offsetY - (lastOffsetY ?? offsetY)
      lastOffsetY = offsetY
      // Skip programmatic adjustments (jump / follow / anchor hold / prepend-preserve) — only
      // real user scrolls mutate pin state.
      guard !isAdjustingOffset else { return }
      updatePinState(delta: delta)
      loadOlderIfNearTop()
    }

    /// Top sentinel: when the offset is near the top of the window AND older history exists,
    /// request the older page. Arm prepend preservation so the next `apply` keeps the anchor
    /// row fixed. Gating on `canLoadOlder` is essential: without it, a transcript scrolled to
    /// its true top would fire `onLoadOlder` every scroll tick and leave
    /// `pendingPrependPreservation` stuck `true` (no prepend ever clears it), which would then
    /// suppress the next legitimate page.
    private func loadOlderIfNearTop() {
      guard let collectionView else { return }
      let atTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        <= TranscriptScrollMath.loadOlderTopThreshold
      if atTop, canLoadOlder, !pendingPrependPreservation {
        pendingPrependPreservation = true
        onLoadOlder()
      }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
      // An animated programmatic follow (`scrollToBottom(animated: true)`) has settled. Clear
      // the re-entrancy guard now — not synchronously when the animation was kicked off — so the
      // intermediate animation frames were never mistaken for user scrolls (which would have
      // dropped the pin mid-follow). The pin stays as the follow found it: only a user scroll
      // changes it.
      isAdjustingOffset = false
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      // A user touch cancels any in-flight programmatic animation: UIKit will NOT then emit a
      // `scrollViewDidEndScrollingAnimation` for the cancelled follow, so that callback can no
      // longer be relied on to clear `isAdjustingOffset`. Clear it here so the guard can never be
      // left permanently set by an interrupted animated follow (after which `scrollViewDidScroll`
      // would stop updating pin/pagination and the contentSize KVO re-pin would stay suppressed).
      // The subsequent user-driven `scrollViewDidScroll` frames then correctly mutate pin state.
      isAdjustingOffset = false
      lastOffsetY = scrollView.contentOffset.y
      // A deliberate user scroll also ends any initial open-at-bottom settle — respect their
      // intent rather than yanking back to the bottom as cells finish sizing.
      needsInitialBottomSettle = false
    }
  }
}
#endif
