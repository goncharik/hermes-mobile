import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class ComposerSnapshotTests: SnapshotTestCase {
  // MARK: ComposerView

  func testComposer_idle() {
    let view = ComposerView(
      text: .constant(""),
      isSending: false,
      canSend: false,
      model: "claude-opus-4-8",
      reasoningEffort: "high",
      onModelTap: {}, onSend: {}, onInterrupt: {}
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_typingAndSending() {
    let view = VStack(spacing: 20) {
      ComposerView(
        text: .constant("Summarize the streaming protocol"),
        isSending: false, canSend: true,
        model: "claude-sonnet-4-6", reasoningEffort: "medium",
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
      ComposerView(
        text: .constant(""),
        isSending: true, canSend: false,
        model: "claude-opus-4-8", reasoningEffort: nil,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
    }
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  /// The `1 ... 6` line growth of the UIKit-backed input (#54): a few lines of prose grow the
  /// field, and a long paragraph stops at the six-line ceiling and scrolls internally. Nothing
  /// else in the suite renders a multi-line composer.
  func testComposer_multilineGrowth() {
    let paragraph = """
    Can you take the streaming fold apart for me? I want to know exactly how the thinking row \
    is created, when the elapsed timer starts, and what happens to it if the socket drops \
    halfway through a turn — including which parts survive a foreground re-hydrate and which \
    ones the server replaces wholesale.
    """
    let view = VStack(spacing: 20) {
      ComposerView(
        text: .constant("Two lines of prose, just enough to make the field grow past one."),
        isSending: false, canSend: true,
        model: "claude-opus-4-8", reasoningEffort: "high",
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
      ComposerView(
        text: .constant(paragraph),
        isSending: false, canSend: true,
        model: "claude-opus-4-8", reasoningEffort: "high",
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
    }
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_recordingWaveform() {
    let view = ComposerView(
      text: .constant(""),
      isSending: false, canSend: false,
      model: "claude-opus-4-8", reasoningEffort: "high",
      recording: .recording,
      waveformLevels: [0.1, 0.35, 0.6, 0.8, 0.5, 0.25, 0.4, 0.7, 0.9, 0.55, 0.3, 0.15, 0.45, 0.65],
      recordingSeconds: 7,
      onModelTap: {}, onSend: {}, onInterrupt: {}
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_transcribing() {
    let view = ComposerView(
      text: .constant(""),
      isSending: false, canSend: false,
      model: "claude-opus-4-8", reasoningEffort: "high",
      recording: .transcribing,
      onModelTap: {}, onSend: {}, onInterrupt: {}
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_attachmentChips() {
    let attachments = [
      ComposerAttachment(id: id(1), kind: .image, filename: "sunset.png", mimeType: "image/png", data: solidPNG(.systemOrange)),
      ComposerAttachment(id: id(2), kind: .pdf, filename: "report.pdf", mimeType: "application/pdf", data: Data([0x25])),
      ComposerAttachment(id: id(3), kind: .file, filename: "notes.txt", mimeType: "text/plain", data: Data([0x41])),
    ]
    let view = ComposerView(
      text: .constant("What's in these?"),
      isSending: false, canSend: true,
      model: "claude-opus-4-8", reasoningEffort: "high",
      attachments: attachments,
      onModelTap: {}, onSend: {}, onInterrupt: {}
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testComposer_attachmentUploadingAndFailed() {
    let attachments = [
      ComposerAttachment(id: id(1), kind: .image, filename: "photo.png", mimeType: "image/png", data: solidPNG(.systemBlue), uploadState: .uploading),
      ComposerAttachment(id: id(2), kind: .file, filename: "data.csv", mimeType: "text/csv", data: Data([0x41]), uploadState: .failed("boom")),
    ]
    let view = ComposerView(
      text: .constant(""),
      isSending: true, canSend: false,
      model: "claude-opus-4-8", reasoningEffort: "high",
      attachments: attachments,
      onModelTap: {}, onSend: {}, onInterrupt: {}
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  /// Mid-turn with queueable content (#66): the red Stop swaps back to the send arrow —
  /// tapping it queues the draft. (Stop-with-empty-composer is covered by
  /// `testComposer_typingAndSending`'s second shape, which pins `canQueue`'s default.)
  func testComposer_midTurnQueueable() {
    let view = ComposerView(
      text: .constant("Queue this for after the current turn"),
      isSending: true, canSend: false,
      canQueue: true,
      model: "claude-opus-4-8", reasoningEffort: "high",
      onModelTap: {}, onSend: {}, onInterrupt: {}
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Read replies aloud (#74)

  /// The auto-speak toggle, top to bottom: ON (accent `speaker.wave.2.fill`), OFF (secondary
  /// `speaker.slash`), and HIDDEN (`showsAutoSpeak: false` — the agent answered `speak` with
  /// a missing-endpoint verdict), where the row falls back to paperclip + mic + send.
  func testComposer_autoSpeakToggle() {
    assertSnapshot(of: autoSpeakToggleStack(), as: componentImage())
  }

  /// Light rendering of the same three shapes: the accent-vs-secondary contrast of the ON
  /// glyph is the thing under test in both appearances.
  func testComposer_autoSpeakToggle_light() {
    assertSnapshot(of: autoSpeakToggleStack(), as: componentImage(appearance: .light))
  }

  private func autoSpeakToggleStack() -> some View {
    VStack(spacing: 20) {
      ComposerView(
        text: .constant(""),
        isSending: false, canSend: false,
        model: "claude-opus-4-8", reasoningEffort: "high",
        autoSpeak: true,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
      ComposerView(
        text: .constant(""),
        isSending: false, canSend: false,
        model: "claude-opus-4-8", reasoningEffort: "high",
        autoSpeak: false,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
      ComposerView(
        text: .constant(""),
        isSending: false, canSend: false,
        model: "claude-opus-4-8", reasoningEffort: "high",
        showsAutoSpeak: false,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
    }
    .frame(width: device.size?.width ?? 390)
  }

  // MARK: Approval mode (#118)

  func testComposer_approvalManual_phone() {
    assertSnapshot(of: approvalComposer(.manual), as: componentImage())
  }

  func testComposer_approvalOff_phone() {
    assertSnapshot(of: approvalComposer(.off), as: componentImage())
  }

  private func approvalComposer(_ mode: ApprovalMode) -> some View {
    ComposerView(
      text: .constant("Review this attachment"),
      isSending: false, canSend: true,
      model: "claude-opus-4-8", reasoningEffort: "high",
      approvalMode: mode,
      attachmentsSupported: true,
      attachments: [ComposerAttachment(
        id: id(1), kind: .file, filename: "notes.txt",
        mimeType: "text/plain", data: Data([0x41])
      )],
      autoSpeak: true, showsAutoSpeak: true,
      onModelTap: {}, onSend: {}, onInterrupt: {}
    )
    .environment(\.dynamicTypeSize, .large)
    .frame(width: 390)
  }

  func testApprovalModePopover_large() {
    let view = ApprovalModePopover(selectedMode: .manual, isPending: false, onSelect: { _ in })
      .environment(\.dynamicTypeSize, .large)
      .frame(width: 340, height: 420)
    assertSnapshot(of: view, as: componentImage())
  }

  func testApprovalModePopover_accessibility5() {
    let view = ApprovalModePopover(selectedMode: .off, isPending: false, onSelect: { _ in })
      .environment(\.dynamicTypeSize, .accessibility5)
      .frame(width: 340, height: 650)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: ModelPickerSheet (#81, redesigned for #130)

  /// The base shape: an Options card (`Reasoning › high` — the current model reasons), the
  /// OpenAI card with the current row checked and an empty star on every row, and an
  /// unconfigured Anthropic card rendered as a disabled lock row with its configure hint.
  func testModelPickerSheet() {
    let view = modelPickerSheet(ModelPickerFeature.State(
      sessionID: "s", options: singleProviderOptions
    ))
    assertSnapshot(of: view, as: deviceImage())
  }

  /// A `config.set` rejection while the sheet is up (#81): `errorBanner` alone would sit behind
  /// the modal, so the same text renders inline ABOVE a still-usable list — the rolled-back
  /// selection stays visible in the rows below it. Same fixture as `testModelPickerSheet`, so
  /// the two baselines differ by exactly that row.
  func testModelPickerSheet_applyError() {
    let view = modelPickerSheet(ModelPickerFeature.State(
      sessionID: "s", options: singleProviderOptions,
      applyError: "Couldn’t change model: cannot switch mid-turn"
    ))
    assertSnapshot(of: view, as: deviceImage())
  }

  /// A current model without reasoning has no Options card at all — the list opens on the
  /// provider card.
  func testModelPickerSheet_nonReasoningModelHidesEffort() {
    let picker = ModelPickerFeature.State(
      sessionID: "s",
      options: ModelOptions(
        providers: [
          .init(name: "Anthropic", slug: "anthropic",
                models: ["claude-opus-4-8", "claude-haiku-4-5"], authenticated: true,
                capabilities: [
                  "claude-opus-4-8": .init(reasoning: true),
                  "claude-haiku-4-5": .init(reasoning: false),
                ]),
        ],
        currentModel: "claude-haiku-4-5",
        currentProvider: "anthropic"
      )
    )
    let view = modelPickerSheet(picker, currentModel: "claude-haiku-4-5", currentEffort: nil)
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Mid-turn: the busy note sits above the list, the model rows and the `Reasoning` row dim
  /// and disable, while the stars stay live (favorites are display-only).
  func testModelPickerSheet_busy() {
    let view = modelPickerSheet(
      ModelPickerFeature.State(sessionID: "s", options: singleProviderOptions),
      isBusy: true
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Starred models from three providers pin to a Favorites card under Options, in star
  /// order, each captioned with its provider (they span more than one); the current model is
  /// favorited, so its checkmark lives in Favorites and the Anthropic card no longer lists it.
  /// Every favorited model is gone from its provider card. Taller than one phone screen, so
  /// the last (OpenRouter) card renders clear of the bottom search field.
  func testModelPickerSheet_favorites() {
    assertSnapshot(of: favoritesSheet(), as: deviceImage(height: favoritesSheetHeight))
  }

  /// Light rendering of the Favorites shape: the yellow filled star and the accent checkmark
  /// over a light grouped background are the contrast under test.
  func testModelPickerSheet_favorites_light() {
    assertSnapshot(
      of: favoritesSheet(),
      as: deviceImage(appearance: .light, height: favoritesSheetHeight)
    )
  }

  /// Collapsed cards (persisted per device): Anthropic collapses to its header, which carries
  /// the model count, the CURRENT model's name and its checkmark (it lives inside), and a
  /// sideways chevron; OpenRouter collapses to name + count; OpenAI stays expanded.
  func testModelPickerSheet_collapsedProviderShowsCurrent() {
    let view = modelPickerSheet(ModelPickerFeature.State(
      sessionID: "s", options: multiProviderOptions,
      collapsedProviders: ["anthropic", "openrouter"]
    ))
    assertSnapshot(of: view, as: deviceImage())
  }

  /// An active search (`gpt`): no Options or Favorites card, every matching provider card
  /// expanded (OpenRouter is collapsed in prefs but search overrides it), and a favorited match
  /// stays in its provider card with a filled star. Anthropic has no match and drops out.
  func testModelPickerSheet_searchActive() {
    let picker = ModelPickerFeature.State(
      sessionID: "s", options: multiProviderOptions,
      collapsedProviders: ["openrouter"],
      favorites: [
        FavoriteModel(providerID: "openai", model: "gpt-5"),
        FavoriteModel(providerID: "anthropic", model: "claude-opus-4-8"),
      ]
    )
    let view = modelPickerSheet(picker, searchText: "gpt")
    assertSnapshot(of: view, as: deviceImage())
  }

  // MARK: ReasoningEffortList (the Options card's pushed page)

  /// The FULL upstream ladder (`none … xhigh, max, ultra`) with the current effort checked.
  func testReasoningEffortList() {
    assertSnapshot(of: reasoningEffortList(extendedReasoningSupported: true), as: deviceImage())
  }

  /// The per-slot latch (#81): once this slot's agent has answered 4002 "unknown reasoning
  /// value", `extendedReasoningSupported` is false and the two extended levels drop out —
  /// the list ends at `xhigh`, with `max`/`ultra` absent. Same fixture as
  /// `testReasoningEffortList`, so the two baselines differ by exactly those two rows.
  func testReasoningEffortList_latchedHidesExtendedEfforts() {
    assertSnapshot(of: reasoningEffortList(extendedReasoningSupported: false), as: deviceImage())
  }

  // MARK: Model picker fixtures

  /// One configured provider plus an unconfigured one (shown disabled, with its hint).
  private var singleProviderOptions: ModelOptions {
    ModelOptions(
      providers: [
        .init(name: "OpenAI", slug: "openai", models: ["gpt-5", "gpt-5-mini"], authenticated: true,
              capabilities: ["gpt-5": .init(reasoning: true), "gpt-5-mini": .init(reasoning: true)]),
        .init(name: "Anthropic", slug: "anthropic", models: [], authenticated: false,
              warning: "paste ANTHROPIC_API_KEY to activate"),
      ],
      currentModel: "gpt-5",
      currentProvider: "openai"
    )
  }

  /// Three configured providers; the current model is Anthropic's `claude-opus-4-8`.
  private var multiProviderOptions: ModelOptions {
    ModelOptions(
      providers: [
        .init(name: "OpenAI", slug: "openai", models: ["gpt-5", "gpt-5-mini", "o4-mini"],
              authenticated: true,
              capabilities: ["gpt-5": .init(reasoning: true), "gpt-5-mini": .init(reasoning: true)]),
        .init(name: "Anthropic", slug: "anthropic",
              models: ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"],
              authenticated: true,
              capabilities: ["claude-opus-4-8": .init(reasoning: true)]),
        .init(name: "OpenRouter", slug: "openrouter",
              models: ["openai/gpt-5", "google/gemini-3-pro", "x-ai/grok-4", "deepseek/deepseek-r2"],
              authenticated: true),
      ],
      currentModel: "claude-opus-4-8",
      currentProvider: "anthropic"
    )
  }

  /// Options + Favorites (3) + three provider cards run past the 844 pt phone height.
  private let favoritesSheetHeight: CGFloat = 1180

  private func favoritesSheet() -> some View {
    modelPickerSheet(ModelPickerFeature.State(
      sessionID: "s", options: multiProviderOptions,
      favorites: [
        FavoriteModel(providerID: "anthropic", model: "claude-opus-4-8"),
        FavoriteModel(providerID: "openrouter", model: "google/gemini-3-pro"),
        FavoriteModel(providerID: "openai", model: "gpt-5"),
      ]
    ))
  }

  /// The sheet over a reducer-less store — no `.task` load or prefs read in a snapshot. The
  /// current model follows the fixture's `currentModel` unless overridden.
  private func modelPickerSheet(
    _ picker: ModelPickerFeature.State,
    currentModel: String? = nil,
    currentEffort: String? = "high",
    isBusy: Bool = false,
    searchText: String = ""
  ) -> some View {
    ModelPickerSheet(
      store: Store(initialState: picker) { EmptyReducer() },
      currentModel: currentModel ?? picker.options?.currentModel,
      currentEffort: currentEffort,
      isBusy: isBusy,
      searchText: searchText
    )
  }

  /// The pushed effort page, inside a stack so its inline `Reasoning` title renders.
  private func reasoningEffortList(extendedReasoningSupported: Bool) -> some View {
    NavigationStack {
      ReasoningEffortList(
        store: Store(initialState: ModelPickerFeature.State(sessionID: "s")) {
          EmptyReducer()
        },
        currentEffort: "high",
        isBusy: false,
        extendedReasoningSupported: extendedReasoningSupported
      )
    }
  }
}
