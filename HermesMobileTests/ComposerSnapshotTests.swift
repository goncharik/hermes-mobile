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

  // MARK: ModelPickerSheet

  func testModelPickerSheet() {
    let picker = ChatFeature.State.ModelPicker(
      isLoading: false,
      options: ModelOptions(
        providers: [
          .init(name: "OpenAI", slug: "openai", models: ["gpt-5", "gpt-5-mini"], authenticated: true,
                capabilities: ["gpt-5": .init(reasoning: true), "gpt-5-mini": .init(reasoning: true)]),
          // Unconfigured — appears disabled below, with a configure hint.
          .init(name: "Anthropic", slug: "anthropic", models: [], authenticated: false,
                warning: "paste ANTHROPIC_API_KEY to activate"),
        ],
        currentModel: "gpt-5"
      )
    )
    let view = ModelPickerSheet(
      picker: picker,
      currentModel: "gpt-5", // reasoning-capable → effort options drop down under it, "high" selected
      currentEffort: "high",
      isBusy: false,
      onSelectModel: { _, _ in }, onSelectEffort: { _ in }, onDone: {}
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// The per-slot latch (#81): once this slot's agent has answered 4002 "unknown reasoning
  /// value", `extendedReasoningSupported` is false and the two extended levels drop out —
  /// the list ends at `xhigh`, with `max`/`ultra` absent. Same fixture as
  /// `testModelPickerSheet`, so the two baselines differ by exactly those two rows.
  func testModelPickerSheet_latchedHidesExtendedEfforts() {
    let picker = ChatFeature.State.ModelPicker(
      isLoading: false,
      options: ModelOptions(
        providers: [
          .init(name: "OpenAI", slug: "openai", models: ["gpt-5", "gpt-5-mini"], authenticated: true,
                capabilities: ["gpt-5": .init(reasoning: true), "gpt-5-mini": .init(reasoning: true)]),
          .init(name: "Anthropic", slug: "anthropic", models: [], authenticated: false,
                warning: "paste ANTHROPIC_API_KEY to activate"),
        ],
        currentModel: "gpt-5"
      )
    )
    let view = ModelPickerSheet(
      picker: picker,
      currentModel: "gpt-5",
      currentEffort: "high",
      isBusy: false,
      extendedReasoningSupported: false,
      onSelectModel: { _, _ in }, onSelectEffort: { _ in }, onDone: {}
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// A `config.set` rejection while the sheet is up (#81): `errorBanner` alone would sit behind
  /// the modal, so the same text renders inline ABOVE a still-usable list — the rolled-back
  /// selection stays visible in the rows below it. Same fixture as `testModelPickerSheet`, so
  /// the two baselines differ by exactly that row.
  func testModelPickerSheet_applyError() {
    let picker = ChatFeature.State.ModelPicker(
      isLoading: false,
      options: ModelOptions(
        providers: [
          .init(name: "OpenAI", slug: "openai", models: ["gpt-5", "gpt-5-mini"], authenticated: true,
                capabilities: ["gpt-5": .init(reasoning: true), "gpt-5-mini": .init(reasoning: true)]),
          .init(name: "Anthropic", slug: "anthropic", models: [], authenticated: false,
                warning: "paste ANTHROPIC_API_KEY to activate"),
        ],
        currentModel: "gpt-5"
      ),
      applyError: "Couldn’t change model: cannot switch mid-turn"
    )
    let view = ModelPickerSheet(
      picker: picker,
      currentModel: "gpt-5",
      currentEffort: "high",
      isBusy: false,
      onSelectModel: { _, _ in }, onSelectEffort: { _ in }, onDone: {}
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  func testModelPickerSheet_nonReasoningModelHidesEffort() {
    let picker = ChatFeature.State.ModelPicker(
      isLoading: false,
      options: ModelOptions(
        providers: [
          .init(name: "Anthropic", slug: "anthropic",
                models: ["claude-opus-4-8", "claude-haiku-4-5"], authenticated: true,
                capabilities: [
                  "claude-opus-4-8": .init(reasoning: true),
                  "claude-haiku-4-5": .init(reasoning: false),
                ]),
        ],
        currentModel: "claude-haiku-4-5"
      )
    )
    let view = ModelPickerSheet(
      picker: picker,
      currentModel: "claude-haiku-4-5", // no reasoning → effort section hidden
      currentEffort: nil,
      isBusy: false,
      onSelectModel: { _, _ in }, onSelectEffort: { _ in }, onDone: {}
    )
    assertSnapshot(of: view, as: deviceImage())
  }
}
