import HermesKit
import SwiftUI

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
  /// to complete the open-at-bottom settle: in a `UIViewRepresentable` the first diff `apply`
  /// runs *before* the collection view is sized, so a scroll-to-bottom there targets a bogus
  /// (zero-height) viewport. Re-pinning on real layout passes is what makes "open at bottom" stick.
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
}

/// Renderer A: a `UICollectionView`-backed transcript engine, drop-in interchangeable with
/// `SwiftUITranscriptView`. **Same initializer shape** so `ChatView` can swap between the two
/// behind a single call site (Task 8 wires the toggle).
///
/// Why UIKit: the list owns scroll/pin behaviour imperatively, which lets us re-pin
/// `contentOffset` the instant a streaming delta resizes the last cell (the primary
/// streaming-jank mitigation) and preserve the on-screen anchor across a top prepend — both
/// of which are awkward to do reliably in pure SwiftUI scroll APIs.
///
/// - `rows` — the windowed slice (`store.visibleRows`); never the full transcript.
/// - `turnState` — `.idle` / `.streaming`, drives the follow-to-bottom decision.
/// - `canLoadOlder` — whether older history exists above the window (`store.hasMoreAbove`).
///   When `false` the top sentinel does NOT fire `onLoadOlder` nor arm prepend preservation,
///   so a transcript scrolled to its true top never gets stuck with `pendingPrependPreservation`.
/// - `onLoadOlder` — fired when the top sentinel is reached (older page requested).
/// - `cell` — builds the row content; reused verbatim via `UIHostingConfiguration` so the
///   bubble subviews render identically across engines.
///
/// Scroll/pin behavior is **renderer-local**: the reducer issues no imperative scroll
/// commands. Mirrors the shared stick-to-bottom contract documented on `SwiftUITranscriptView`.
struct CollectionTranscriptView<Cell: View>: UIViewRepresentable {
  let rows: [ChatRow]
  let turnState: TurnState
  let canLoadOlder: Bool
  let onLoadOlder: () -> Void
  let cell: (ChatRow) -> Cell

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onLoadOlder: onLoadOlder,
      cell: cell
    )
  }

  func makeUIView(context: Context) -> UICollectionView {
    let layout = Self.makeLayout()
    let collectionView = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.keyboardDismissMode = .interactive
    collectionView.alwaysBounceVertical = true
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
    context.coordinator.apply(rows: rows)
  }

  /// Single-section vertical compositional layout with **self-sizing** items: the
  /// `UIHostingConfiguration` measures its SwiftUI content, so heights track streaming deltas.
  private static func makeLayout() -> UICollectionViewLayout {
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
    section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    return UICollectionViewCompositionalLayout(section: section)
  }

  // MARK: - Coordinator

  /// Owns the diffable data source, cell hosting, and all imperative scroll behaviour: pin
  /// detection, follow-on-delta, prepend offset-preservation, and the open/hydrate jump.
  final class Coordinator: NSObject, UICollectionViewDelegate {
    enum Section { case main }

    var onLoadOlder: () -> Void
    var cell: (ChatRow) -> Cell
    var reduceMotion = false
    var turnState: TurnState = .idle
    /// Whether older history exists above the window. Gates the top-sentinel load trigger so
    /// `pendingPrependPreservation` is only armed when a prepend can actually follow.
    var canLoadOlder = false

    private weak var collectionView: UICollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<Section, ChatRow.ID>!

    /// The full row payload, keyed by id, so the diffable data source (which carries only ids)
    /// can resolve the `ChatRow` to host. Rows are content-mutated in place across deltas; the
    /// id is stable (deterministic identity) so the cell is reconfigured, not re-created.
    private var rowsByID: [ChatRow.ID: ChatRow] = [:]
    private var currentOrder: [ChatRow.ID] = []

    /// Renderer-local pin state (~60pt). Never lives in the reducer. Starts pinned so the
    /// first population follows the open-at-bottom contract.
    private var isPinnedToBottom = true
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
    /// Lifecycle: set `true` when we kick off a programmatic `setContentOffset`. For a
    /// *non-animated* jump the offset settles synchronously, so we clear it on the next runloop.
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
    /// True while a snapshot apply is in flight. The `contentSize` KVO fires during a diff
    /// apply (the layout grows as rows are inserted/resized); the apply *completion* already
    /// owns the authoritative re-pin/preserve/jump, so the KVO must not also snap mid-apply
    /// (which could fight the completion's prepend-preservation). Streaming-delta growth
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
      cell: @escaping (ChatRow) -> Cell
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

      let registration = UICollectionView.CellRegistration<UICollectionViewCell, ChatRow.ID> {
        [weak self] cell, _, id in
        guard let self, let row = self.rowsByID[id] else { return }
        let builder = self.cell
        cell.contentConfiguration = UIHostingConfiguration { builder(row) }
          .margins(.all, 0)
        cell.backgroundConfiguration = .clear()
      }

      dataSource = UICollectionViewDiffableDataSource<Section, ChatRow.ID>(
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

    /// Apply a new `rows` slice: classify the structural change, refresh the payload, snapshot
    /// the diff, then honour the stick-to-bottom contract (jump / follow / preserve / nothing).
    func apply(rows: [ChatRow]) {
      let newOrder = rows.map(\.id)
      let oldOrder = currentOrder
      let diff = TranscriptDiffKind.classify(old: oldOrder, new: newOrder)

      // Refresh the payload first so cell reconfiguration sees mutated content.
      rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
      currentOrder = newOrder

      // Determine which existing items need a *content* reconfigure (same id, changed body) —
      // streaming deltas mutate text without changing the id, so the snapshot must reconfigure.
      let changedIDs = newOrder.filter { id in
        oldOrder.contains(id)
      }

      let preservePrepend = pendingPrependPreservation && {
        if case .prepend = diff { return true } else { return false }
      }()
      pendingPrependPreservation = false

      let capturedOffsetY = collectionView?.contentOffset.y ?? 0
      let capturedContentHeight = collectionView?.contentSize.height ?? 0
      let wasPinned = isPinnedToBottom

      var snapshot = NSDiffableDataSourceSnapshot<Section, ChatRow.ID>()
      snapshot.appendSections([.main])
      snapshot.appendItems(newOrder, toSection: .main)
      if !changedIDs.isEmpty {
        snapshot.reconfigureItems(changedIDs)
      }

      let isFirstPopulation = oldOrder.isEmpty && !newOrder.isEmpty
      // A wholesale replace of the visible slice — a server-authoritative re-hydrate
      // (`session.resume` rebuilds rows to the bottom window) or a reorder. Per the open/hydrate
      // contract this forces a jump-to-bottom regardless of pin state, so a re-hydrate while the
      // user is scrolled up doesn't leave the list parked mid-history. A prepend that is *also*
      // being offset-preserved (`preservePrepend`) is explicitly NOT a reset — the prepend path
      // owns the offset there.
      let isReset = !preservePrepend && {
        if case .reset = diff { return true } else { return false }
      }()

      // Suppress the contentSize KVO for the duration of the apply: the completion below is the
      // single authority on where the offset lands for this structural change.
      isApplyingSnapshot = true
      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        guard let self else { return }
        defer { self.isApplyingSnapshot = false }
        if isFirstPopulation || !self.didInitialJump || isReset, !newOrder.isEmpty {
          // Open / hydrate / wholesale-reset: jump to bottom (no animation) — always, regardless
          // of pin state (honours the open/hydrate→bottom contract on a re-hydrate while the
          // user had scrolled up). Begin a "settle" so self-sizing cell growth keeps re-pinning
          // until the real bottom is reached.
          self.didInitialJump = true
          self.isPinnedToBottom = true
          self.setJumpButtonVisible(false)
          self.beginInitialBottomSettle()
        } else if preservePrepend {
          self.preserveOffsetAfterPrepend(
            previousOffsetY: capturedOffsetY,
            previousContentHeight: capturedContentHeight
          )
        } else if wasPinned {
          // Appended row or streaming delta grew the last cell: follow only if pinned.
          self.scrollToBottom(animated: !self.reduceMotion)
        }
        // Scrolled-up reader: do nothing (no yank), the jump button stays.
      }
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
      let willAnimate = animated && abs(collectionView.contentOffset.y - target) > 0.5
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
          self.updatePinState()
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
      let insertedHeight = collectionView.contentSize.height - previousContentHeight
      guard insertedHeight > 0 else { return }
      let newOffsetY = TranscriptScrollMath.offsetAfterPrepend(
        previousOffsetY: previousOffsetY,
        insertedHeight: insertedHeight,
        contentHeight: collectionView.contentSize.height,
        viewportHeight: collectionView.bounds.height,
        topInset: collectionView.adjustedContentInset.top,
        bottomInset: collectionView.adjustedContentInset.bottom
      )
      isAdjustingOffset = true
      collectionView.setContentOffset(CGPoint(x: 0, y: newOffsetY), animated: false)
      DispatchQueue.main.async { [weak self] in self?.isAdjustingOffset = false }
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
    func didLayout() {
      guard needsInitialBottomSettle else { return }
      scrollToBottom(animated: false)
    }

    /// The viewport lost height (typically the keyboard appeared and SwiftUI shrank our frame).
    /// If the user was parked at the bottom, keep them there so the keyboard doesn't cover the
    /// latest rows without scrolling.
    func viewportDidShrink() {
      guard isPinnedToBottom || needsInitialBottomSettle else { return }
      scrollToBottom(animated: false)
    }

    /// Re-evaluate pin state from live geometry and toggle the jump button on a change.
    private func updatePinState() {
      // While settling the initial open-at-bottom, intermediate cell-sizing can momentarily look
      // "not at bottom"; don't let that flip the pin off (it would stop the re-pin and strand the
      // list short of the real bottom). The settle-release timer re-evaluates once stable.
      guard !needsInitialBottomSettle else { return }
      guard let collectionView else { return }
      let pinned = TranscriptScrollMath.isPinnedToBottom(
        contentHeight: collectionView.contentSize.height,
        viewportHeight: collectionView.bounds.height,
        bottomInset: collectionView.adjustedContentInset.bottom,
        offsetY: collectionView.contentOffset.y + collectionView.adjustedContentInset.top
      )
      if pinned != isPinnedToBottom {
        isPinnedToBottom = pinned
        setJumpButtonVisible(!pinned)
      }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      // Skip programmatic adjustments (jump / prepend-preserve) — only real user scrolls
      // should mutate pin state.
      guard !isAdjustingOffset else { return }
      updatePinState()

      // Top sentinel: when the user pulls near the top of the window AND older history exists,
      // request the older page. Arm prepend preservation so the next `apply` keeps the anchor
      // row fixed. Gating on `canLoadOlder` is essential: without it, a transcript scrolled to
      // its true top would fire `onLoadOlder` every scroll tick and leave
      // `pendingPrependPreservation` stuck `true` (no prepend ever clears it), which would then
      // suppress the next legitimate page.
      let topTriggerThreshold = TranscriptScrollMath.loadOlderTopThreshold
      let atTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        <= topTriggerThreshold
      if atTop, canLoadOlder, !pendingPrependPreservation {
        pendingPrependPreservation = true
        onLoadOlder()
      }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
      // An animated programmatic follow (`scrollToBottom(animated: true)`) has settled. Clear
      // the re-entrancy guard now — not synchronously when the animation was kicked off — so the
      // intermediate animation frames were never mistaken for user scrolls (which would have
      // dropped the pin mid-follow). Re-evaluate pin state from the final resting offset.
      isAdjustingOffset = false
      updatePinState()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      // A user touch cancels any in-flight programmatic animation: UIKit will NOT then emit a
      // `scrollViewDidEndScrollingAnimation` for the cancelled follow, so that callback can no
      // longer be relied on to clear `isAdjustingOffset`. Clear it here so the guard can never be
      // left permanently set by an interrupted animated follow (after which `scrollViewDidScroll`
      // would stop updating pin/pagination and the contentSize KVO re-pin would stay suppressed).
      // The subsequent user-driven `scrollViewDidScroll` frames then correctly mutate pin state.
      isAdjustingOffset = false
      // A deliberate user scroll also ends any initial open-at-bottom settle — respect their
      // intent rather than yanking back to the bottom as cells finish sizing.
      needsInitialBottomSettle = false
    }
  }
}
#endif
