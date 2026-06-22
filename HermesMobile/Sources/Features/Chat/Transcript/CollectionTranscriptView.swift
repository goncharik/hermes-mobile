import HermesKit
import SwiftUI

#if canImport(UIKit)
import UIKit

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
/// - `onLoadOlder` — fired when the top sentinel is reached (older page requested).
/// - `onScrollPositionChanged` — `true` when pinned to the bottom (~60pt threshold).
/// - `cell` — builds the row content; reused verbatim via `UIHostingConfiguration` so the
///   bubble subviews render identically across engines.
///
/// Scroll/pin behavior is **renderer-local**: the reducer issues no imperative scroll
/// commands. Mirrors the shared stick-to-bottom contract documented on `SwiftUITranscriptView`.
struct CollectionTranscriptView<Cell: View>: UIViewRepresentable {
  let rows: [ChatRow]
  let turnState: TurnState
  let onLoadOlder: () -> Void
  let onScrollPositionChanged: (Bool) -> Void
  let cell: (ChatRow) -> Cell

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    rows: [ChatRow],
    turnState: TurnState,
    onLoadOlder: @escaping () -> Void,
    onScrollPositionChanged: @escaping (Bool) -> Void,
    @ViewBuilder cell: @escaping (ChatRow) -> Cell
  ) {
    self.rows = rows
    self.turnState = turnState
    self.onLoadOlder = onLoadOlder
    self.onScrollPositionChanged = onScrollPositionChanged
    self.cell = cell
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onLoadOlder: onLoadOlder,
      onScrollPositionChanged: onScrollPositionChanged,
      cell: cell
    )
  }

  func makeUIView(context: Context) -> UICollectionView {
    let layout = Self.makeLayout()
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.keyboardDismissMode = .interactive
    collectionView.alwaysBounceVertical = true
    collectionView.delegate = context.coordinator
    context.coordinator.configure(collectionView: collectionView)
    context.coordinator.installJumpButton(in: collectionView)
    return collectionView
  }

  func updateUIView(_ collectionView: UICollectionView, context: Context) {
    // Refresh the closures each update so SwiftUI captures stay fresh (state from the store).
    context.coordinator.onLoadOlder = onLoadOlder
    context.coordinator.onScrollPositionChanged = onScrollPositionChanged
    context.coordinator.cell = cell
    context.coordinator.reduceMotion = reduceMotion
    context.coordinator.turnState = turnState
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
    var onScrollPositionChanged: (Bool) -> Void
    var cell: (ChatRow) -> Cell
    var reduceMotion = false
    var turnState: TurnState = .idle

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
    /// Set by the top-sentinel trigger so the next `apply` (which will be a prepend) preserves
    /// the on-screen anchor instead of following or jumping.
    private var pendingPrependPreservation = false
    /// Re-entrancy guard: programmatic offset changes shouldn't be read back as user scrolls.
    private var isAdjustingOffset = false
    /// KVO token watching `contentSize` so a self-sizing cell that grows (a streaming delta
    /// resizing the last bubble) re-pins to the bottom while pinned — the primary jank fix.
    private var contentSizeObservation: NSKeyValueObservation?
    /// The floating "jump to latest" button (a hosted `ScrollToBottomButton`), shown only when
    /// scrolled up — mirrors the SwiftUI engine's overlay.
    private weak var jumpButton: UIView?

    init(
      onLoadOlder: @escaping () -> Void,
      onScrollPositionChanged: @escaping (Bool) -> Void,
      cell: @escaping (ChatRow) -> Cell
    ) {
      self.onLoadOlder = onLoadOlder
      self.onScrollPositionChanged = onScrollPositionChanged
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
          self.isPinnedToBottom,                   // user is at the bottom
          !self.isAdjustingOffset,                 // not our own programmatic change
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

      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        guard let self else { return }
        if isFirstPopulation || !self.didInitialJump, !newOrder.isEmpty {
          // Open/hydrate: jump to bottom (no animation) — always.
          self.didInitialJump = true
          self.scrollToBottom(animated: false)
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
      isAdjustingOffset = true
      collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
      // For non-animated jumps the offset settles synchronously; clear the guard on the next
      // runloop so the resulting `scrollViewDidScroll` doesn't read it back as a user scroll.
      if !animated {
        DispatchQueue.main.async { [weak self] in self?.isAdjustingOffset = false }
      } else {
        isAdjustingOffset = false
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

    /// Re-evaluate pin state from live geometry and notify the reducer on a change.
    private func updatePinState() {
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
        onScrollPositionChanged(pinned)
      }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      // Skip programmatic adjustments (jump / prepend-preserve) — only real user scrolls
      // should mutate pin state.
      guard !isAdjustingOffset else { return }
      updatePinState()

      // Top sentinel: when the user pulls near the top of the window, request the older page.
      // Arm prepend preservation so the next `apply` keeps the anchor row fixed.
      let topThreshold = TranscriptScrollMath.bottomThreshold
      let atTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top <= topThreshold
      if atTop, !pendingPrependPreservation {
        pendingPrependPreservation = true
        onLoadOlder()
      }
    }
  }
}
#endif
