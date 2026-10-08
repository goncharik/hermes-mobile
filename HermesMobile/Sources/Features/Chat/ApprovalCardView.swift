import HermesKit
import SwiftUI

/// Pinned card shown when the agent requests approval for an action. Approve/Deny,
/// with an "approve all" toggle for the rest of the session.
///
/// The card lives in `ChatView`'s outer `VStack`, i.e. the **non-scrolling** region between
/// the greedy transcript and the composer. That is the whole reason everything between the
/// title and the button row is rendered by ``scrollableContent`` — one bounded, scrollable
/// region — instead of plain stacked text: when the fixed region runs short (long command,
/// long detail, keyboard up, accessibility text size) the `VStack` compresses whatever it can,
/// and plain `Text` answers that squeeze by truncating with no way to reach the rest (issue
/// #65 — users had to leave and re-enter the chat, where the keyboard was down, to read what
/// they were approving). `.fixedSize` alone would invert the problem and push Approve/Deny off
/// screen.
///
/// **Three rules decide the shape, and each of them is a measured failure of an earlier take:**
///
/// 1. **Only the title and the Deny/Approve row are rigid, and the title is clamped.** A rigid
///    `detail` (the server's `description`, no length limit) or a rigid session toggle was
///    measured to push the buttons — and the composer — off screen at AX3/AX5 and on any phone
///    with a long detail: the rigid remainder outgrew the fixed region on its own. What is left
///    rigid is bounded by construction (one clamped line, one button row).
/// 2. **The command is the FIRST thing in the scroll**, so nothing server-controlled sits
///    between the top of the viewport and the thing being approved. With the title and the
///    detail above it, a 1000-char `detail` pushed the command *entirely* below the fold at
///    first paint (measured: no command pixels in the viewport at all on a 393×516 keyboard-up
///    window), and on the shortest screen the title + a two-line detail alone filled the whole
///    floor (88pt when that was measured; ``contentMinHeight`` is 96 now) — the user was asked
///    to approve a command they could not see.
/// 3. **The toggle's state is mirrored on the Approve button** (``approveTitle(all:)``). The
///    toggle itself has to live inside the scroll (rule 1), so with a long command it sits
///    below the fold — and a session-wide whitelist committed from a control the user cannot
///    see at the moment they tap Approve is a safety problem, not a discoverability one. The
///    button title is rigid, so the state is always legible where the decision is made.
struct ApprovalCardView: View {
  let request: ApprovalRequest
  let onApprove: (_ all: Bool) -> Void
  let onDeny: () -> Void

  @State private var approveAll = false

  /// Bottom-fade state, fed by **live scroll geometry**: whether anything is still hidden
  /// below the viewport, and how tall the ramp may be at the viewport's current height.
  ///
  /// Derived from geometry rather than from the content's measured height because a
  /// measurement-derived flag would be true for the region's whole lifetime, so its last line
  /// would sit permanently inside the ramp and never be readable — the opposite of what #65
  /// asks for. Mirrors `MarkdownTableView`'s trailing fade (#59).
  @State private var fade = FadeState()

  /// Tallest the scrollable region grows before it scrolls in place, scaled with Dynamic Type
  /// so a larger text size keeps roughly the same *line count* visible rather than fewer and
  /// fewer lines. The **effective** cap is ``contentMaxHeight`` — this is only the input to
  /// the ceiling clamp.
  @ScaledMetric(relativeTo: .callout)
  private var scaledContentMaxHeight: CGFloat = ApprovalCardView.contentMaxHeightBase

  /// The cap actually applied: the scaled base, clamped to ``contentMaxHeightCeiling``.
  private var contentMaxHeight: CGFloat {
    min(scaledContentMaxHeight, Self.contentMaxHeightCeiling)
  }

  /// Unscaled base for the cap: about a dozen monospaced `.callout` command lines plus the
  /// detail and the session toggle under them — enough for the shell commands agents actually
  /// ask about.
  static let contentMaxHeightBase: CGFloat = 320

  /// Hard ceiling on the scaled cap. `@ScaledMetric(relativeTo: .callout)` runs to roughly
  /// 3.3× at `.accessibility5`, i.e. a ~1050pt region — taller than any iPhone screen, let
  /// alone the fixed region one has left with the keyboard up.
  ///
  /// **Derived, not typed** (the `MarkdownTableView.columnMaxWidthCeiling` convention): three
  /// fifths of ``TranscriptLayout/shortestLayoutHeight``, so on the shortest screen this app
  /// can render at the remaining two fifths are always left for the pinned button row, the
  /// composer and a slice of transcript. Effective cap: 320pt through roughly `.accessibility1`,
  /// then flat at 340pt.
  ///
  /// It only binds in a *roomy* container. In a tight one ``BoundedHeightLayout`` yields to
  /// whatever the region offers regardless, so the ceiling is a guard against a runaway
  /// `@ScaledMetric`, never the thing that keeps the buttons on screen.
  static let contentMaxHeightCeiling: CGFloat = TranscriptLayout.shortestLayoutHeight * 0.6

  /// The region never compresses below this under a `VStack` squeeze (or below its own
  /// content, whichever is smaller — a one-line recovered card is never padded out to it).
  ///
  /// **Derived from what the user must be able to read, not chosen by taste**: on the shortest
  /// screen with the keyboard up the region lands exactly here, and there the *command* has to
  /// show three full `.callout` lines **at `.large`** outside the bottom ramp —
  /// ``commandPadding`` (8) + 3 × 20.9 + ``bottomFadeHeight`` (24) ≈ 95, rounded to 96. That
  /// arithmetic only works because the command is the FIRST thing in the scroll: with the
  /// title and the detail above it, the same region showed about half a line of command
  /// (measured — no command pixels above the ramp at all with a long detail).
  ///
  /// Deliberately *not* scaled, so **the three-line contract is a `.large` one and degrades
  /// with Dynamic Type**: the readable band is a constant 64pt (96 − a 24pt ramp − 8pt of block
  /// padding), which is ~3.1 `.callout` lines at `.large`, ~1.3 at AX3 and under one at AX5
  /// (`ApprovalCardLayoutTests.testTheFloorsReadableBandDegradesWithDynamicType` pins those
  /// numbers off the real font metrics). Scaling it is not an option and not merely a taste
  /// call: three AX5 lines are ~210pt, and reserving that on a 320×352 keyboard-up region is
  /// measurably what pushes Deny/Approve — the safety-critical half — off the screen. A floor
  /// small enough to keep the answer reachable everywhere is the trade, and one the *cap* (not
  /// the floor) undoes as soon as there is any room: this binds only in the tightest
  /// configuration there is.
  static let contentMinHeight: CGFloat = 96

  /// Tallest the bottom ramp that signals "there is more below" is allowed to be.
  static let bottomFadeHeight: CGFloat = 24

  /// Padding inside the command's tinted block. Internal rather than private so the measured
  /// "how many command lines are legible" tests can discount it.
  static let commandPadding: CGFloat = 8

  /// Points of the fixed region the content region hands back, so the transcript — the context
  /// for the approve/deny decision — is not starved to nothing.
  ///
  /// `ChatView` gives the card `.layoutPriority(1)` (without it the region collapses onto its
  /// floor with the keyboard up), and a priority-1 child is offered *everything* the other
  /// children do not strictly need: the greedy transcript's minimum is zero, so the card took
  /// the whole region and the transcript was measured at **0pt** on every phone.
  ///
  /// **Absolute, not a fraction.** A proportional reserve (this was `0.75` of the offer) cuts
  /// the region even when the content had room to fit: at an offer of 320 with 320pt of content
  /// it handed back 80pt — about four command lines — that nothing else had asked for, on the
  /// one surface whose rule is "the user must be able to read what they are approving". An
  /// absolute reserve can only ever spend room the card does not want: the content hugs itself
  /// whenever it fits under `offer − reserve`, and past that it gives back this much and no
  /// more. One 44pt tap target's worth, the HIG minimum — enough that the conversation behind
  /// the card is a row rather than a sliver, small enough to be invisible when the card is
  /// short. The floor still outranks it, so the shortest screen gives the card what it needs.
  static let transcriptReserve: CGFloat = 44

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Rigid, and deliberately tiny. The card's identity has to survive every squeeze, but
      // every rigid point here is a point the command's viewport does not get — so it is one
      // line, and its Dynamic Type is clamped: at AX5 an unclamped two-word title wraps into
      // three lines of chrome and pushes the answer off screen. The content it labels is NOT
      // clamped — the command, the detail and the toggle all scale in full inside the scroll.
      Label("Approval requested", systemImage: "lock.shield")
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)

      scrollableContent

      // The other rigid part. Outside the scroll on purpose: whatever the region is squeezed
      // to, the answer the user has to give stays on screen and tappable — and its title
      // carries the session-toggle's state, which is otherwise a scroll away.
      HStack(spacing: 12) {
        Button(role: .destructive, action: onDeny) {
          Text("Deny").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        if request.allowsOnce {
          Button { onApprove(approveAll) } label: {
            Text(Self.approveTitle(all: approveAll)).frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding()
    .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.5)))
    .padding(.horizontal)
  }

  /// Everything the user has to read before answering, in a vertical `ScrollView` bounded by
  /// ``BoundedHeightLayout``: it asks for its natural height while that fits under the cap and
  /// for the cap past it, and yields to a shorter proposal down to ``contentMinHeight``.
  ///
  /// - **Order is load-bearing**: command, then detail, then toggle. The command is the thing
  ///   being approved, the viewport's first screenful is the only thing guaranteed to be read,
  ///   and `detail` is server-controlled and unbounded — putting it first let it push the
  ///   command out of the viewport entirely (measured).
  ///
  /// - Every `Text` inside is `.fixedSize(horizontal: false, vertical: true)`, so it sizes to
  ///   its ideal within the scroll content and every byte exists in the hierarchy and is
  ///   reachable by scrolling — never truncated, whatever height the region ends up at.
  /// - The layout answers the enclosing `VStack`'s squeeze by **shrinking the viewport**
  ///   rather than by dropping content, so the card fits the region it is given (Deny/Approve
  ///   stay on screen) *and* the text stays whole. A rigid `.frame(height:)` gets the first
  ///   half wrong: at the cap the card wants ~400pt while the fixed region with the keyboard
  ///   up on a small phone is ~230–370pt, so the card would over-subscribe its container and
  ///   push the buttons (and the composer) under the keyboard — the failure `.fixedSize`
  ///   would have caused, reached by another route.
  /// - Deliberately **not** `ViewThatFits(in: .vertical)`: that picks a *variant* per the
  ///   incoming proposal, so in this compressed `VStack` it would swap layouts as the
  ///   keyboard comes and goes; the layout instead keeps one variant and bounds it, which is
  ///   also what makes the height assertable (`ApprovalCardLayoutTests`).
  private var scrollableContent: some View {
    BoundedHeightLayout(
      cap: contentMaxHeight, minHeight: Self.contentMinHeight, reserve: Self.transcriptReserve
    ) {
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 10) {
          if let command = request.command, !command.isEmpty {
            commandText(command)
              .textSelection(.enabled)
              .padding(Self.commandPadding)
              .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 8))
          }

          if let detail = request.detail, !detail.isEmpty {
            Text(detail)
              .font(.footnote)
              .foregroundStyle(.secondary)
              // Wrap instead of truncating — the recovered-approval card (#30 workaround)
              // carries a multi-line detail and no command, so the copy must stay readable.
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          // Hidden on the push-tap-recovered card (#30 workaround): with no command and no
          // pattern to show, "Approve all" would whitelist an unseen danger pattern for the
          // whole session — a blind single approve is the most the recovery copy covers.
          // Its state is mirrored on the Approve button, which is rigid: with a long command
          // this control is below the fold, and a session-wide whitelist must never be
          // committed from a switch the user cannot see at the moment they approve.
          if request.offersSessionApproval {
            Toggle("Approve all in this session", isOn: $approveAll)
              .font(.footnote)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
      .onScrollGeometryChange(for: FadeState.self) { geometry in
        FadeState(
          isFaded: Self.hasBottomOverflow(
            visibleRect: geometry.visibleRect, contentHeight: geometry.contentSize.height
          ),
          rampHeight: Self.fadeRampHeight(viewportHeight: geometry.containerSize.height)
        )
      } action: { _, newFade in
        fade = newFade
      }
    }
    .mask { Self.bottomFadeMask(fade) }
  }

  /// The command's text, laid out at its natural height — `.fixedSize` so it wraps to its
  /// ideal instead of truncating, which inside the scroll content is what keeps every byte
  /// reachable.
  private func commandText(_ command: String) -> some View {
    Text(command)
      .font(.callout.monospaced())
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The primary button's title, which is where the session toggle's state is made visible at
  /// the moment the decision is committed (the toggle itself is a scroll away whenever the
  /// command is long). Pure so the mirroring is assertable without rendering the card.
  static func approveTitle(all: Bool) -> String {
    all ? "Approve all" : "Approve"
  }

  /// What the bottom ramp looks like right now. Both halves come from live scroll geometry.
  struct FadeState: Equatable {
    /// Is there still content below what the viewport shows?
    var isFaded: Bool = false
    /// How tall the ramp may be — see ``fadeRampHeight(viewportHeight:)``.
    var rampHeight: CGFloat = 0
  }

  /// Pure scroll-geometry rule behind the bottom fade: is there content below what the
  /// viewport shows? (Kept out of the view so it is unit-testable — the flag itself is
  /// private `@State`.) The 1pt slack absorbs fractional layout.
  ///
  /// Takes the whole `visibleRect` — the framework's own answer to "which part of the content
  /// is on screen" — rather than `contentOffset.y + containerSize.height`, mirroring
  /// `MarkdownTableView.hasTrailingOverflow`. Going false at the scroll end is the point: the
  /// last line of the command must be readable, not permanently ramped to transparent.
  static func hasBottomOverflow(visibleRect: CGRect, contentHeight: CGFloat) -> Bool {
    visibleRect.maxY < contentHeight - 1
  }

  /// The ramp is a **fraction** of the viewport, capped at ``bottomFadeHeight``.
  ///
  /// A constant 24pt ramp is fine against `MarkdownTableView`'s trailing edge, whose viewport
  /// is always at least a screen wide — but this region compresses, and against a squeezed
  /// one a fixed ramp would tint most of what is left toward transparent: a hint would have
  /// eaten the content it was hinting about, on the one surface where the user must be able
  /// to read what they are approving. A quarter leaves three quarters of any viewport, at any
  /// size, fully opaque.
  static func fadeRampHeight(viewportHeight: CGFloat) -> CGFloat {
    max(0, min(bottomFadeHeight, viewportHeight / 4))
  }

  /// The overflow hint, as `.mask` content: opaque everywhere except a `rampHeight` ramp at
  /// the bottom, and opaque there too when nothing is hidden below.
  ///
  /// Same rationale as `MarkdownTableView`'s trailing fade (#59): iOS only flashes the
  /// scroll indicator while a drag is in flight, so without the ramp a scrollable card
  /// looks exactly like the clipped one #65 reported. Applied unconditionally (an `if`
  /// would rebuild the `ScrollView` and throw away the user's scroll offset the moment the
  /// state flipped — which, driven by scroll geometry, is every time they reach the end);
  /// when nothing overflows the mask is fully opaque, i.e. a no-op. Vertical, so unlike
  /// #59's horizontal fade there is no layout-direction mirroring to handle.
  @ViewBuilder
  static func bottomFadeMask(_ fade: FadeState) -> some View {
    VStack(spacing: 0) {
      Rectangle().fill(Color.black)
      LinearGradient(
        colors: [.black, .black.opacity(fade.isFaded ? 0 : 1)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: fade.rampHeight)
    }
  }
}

/// Sizes its subview to `min(its natural height, cap)` when there is room — minus `reserve`,
/// which is held back for a greedy sibling — and yields to a shorter proposal down to
/// `minHeight`.
///
/// Two things a plain `.frame` cannot do together, both load-bearing for #65:
///
/// - **it asks for an ideal height a `ScrollView` will not volunteer.** A scroll view is
///   fully flexible along its scroll axis: hand it a concrete height proposal — which is what
///   every enclosing stack does — and it answers with the whole proposal, so short content
///   pads out to the cap and long content never scrolls, while a `ZStack`'d hidden twin plus a
///   `.frame(maxHeight:)` only clips the result. Probed with the height **unspecified**
///   (`ProposedViewSize(width:height: nil)`, below) the very same scroll view instead reports
///   its *content's* ideal height, which is exactly the number the card needs. That probe is
///   therefore the whole mechanism: propose a concrete height there and the region silently
///   goes back to "always the cap" (measured, and covered by
///   `ApprovalCardLayoutTests.testShortCommandHugsItsContentWithoutScrolling` /
///   `testUnmeasuredCardAccountsForTheWholeContentRegion` — the latter runs with no layout
///   pass at all, the shape a `sizeThatFits` snapshot render takes).
/// - **compressibility.** `.frame(height:)` fixes the region, which is deterministic but
///   incompressible: the card then demands ~400pt from a fixed region that is ~230–370pt with
///   the keyboard up, and the overflow pushes Deny/Approve out of reach. Shrinking a *scroll
///   viewport* costs nothing — every byte is still there and still reachable — so the region
///   is the right thing to squeeze, and taking the squeeze here is what keeps the buttons on
///   screen.
struct BoundedHeightLayout: Layout {
  /// Tallest the region will ask for, however long the content is.
  let cap: CGFloat
  /// Shortest it will compress to — never taller than the content itself.
  let minHeight: CGFloat
  /// Points of a *concrete* offer held back for a greedy sibling that is served after this one
  /// (the transcript), so it is not left with nothing.
  ///
  /// **Absolute on purpose**: it may only ever spend room the content did not want. Content
  /// that fits under `offer − reserve` still hugs itself exactly, and content that does not is
  /// cut by this much and no more — a *proportional* reserve instead scales with the offer, so
  /// it kept cutting a region that had room to fit (see `ApprovalCardView.transcriptReserve`).
  /// Applied above the floor only: under a real squeeze the floor still wins. `0` opts out.
  var reserve: CGFloat = 0

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    // Height *unspecified* on purpose — see the type's doc comment: that is what makes a
    // scroll view report its content's ideal height instead of swallowing the proposal.
    let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(
      width: proposal.width ?? ideal.width,
      height: height(natural: ideal.height, offered: proposal.height)
    )
  }

  /// The height rule, pure so it is assertable without rendering: the content's own height
  /// while it fits both the cap and `offered − reserve`, that bound past it — and never below
  /// `minHeight`, nor above the content when the content is shorter than `minHeight` (a
  /// one-line card is not padded out to a floor).
  func height(natural: CGFloat, offered: CGFloat?) -> CGFloat {
    let bounded = min(natural, cap)
    guard let offered else { return bounded }
    // The floor outranks the reserve: handing points back to a sibling is for the *comfortable*
    // case, and must never be the thing that squeezes the card below what it needs.
    let claimable = max(minHeight, offered - reserve)
    // One `min` covers both halves of the rule: `claimable` is at least `minHeight`, so the
    // result is at least `min(bounded, minHeight)` — i.e. the floor, or the content itself when
    // the content is shorter than the floor. No second clamp needed.
    return min(bounded, claimable)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    // Only the first subview, matching what `sizeThatFits` measures (and `CappedWidthLayout`).
    subviews.first?.place(
      at: CGPoint(x: bounds.minX, y: bounds.minY),
      anchor: .topLeading,
      proposal: ProposedViewSize(bounds.size)
    )
  }
}
