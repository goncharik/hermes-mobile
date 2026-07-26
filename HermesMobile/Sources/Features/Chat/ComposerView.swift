import HermesKit
import SwiftUI

/// The message composer: a growing text field above a toolbar row with a model/reasoning
/// chip (tappable → picker), a voice button, and a send/interrupt button in the Hermes
/// brand colour. While recording (#7) the field is replaced by a live waveform, elapsed
/// time, and cancel/stop controls.
struct ComposerView: View {
  @Binding var text: String
  let isSending: Bool
  let canSend: Bool
  var canQueue: Bool = false
  let model: String?
  let reasoningEffort: String?
  /// Context-window usage (#4): a compact gauge beside the model chip. Hidden when nil or
  /// when the usage has no usable label.
  var usage: Usage? = nil
  /// Voice-input state (#7): drives whether the composer shows text entry or the recorder.
  var recording: ChatFeature.State.RecordingState = .idle
  var waveformLevels: [Float] = []
  var recordingSeconds: Int = 0
  /// Attachments (#8): hide the attach control when the agent can't accept uploads.
  var attachmentsSupported: Bool = true
  var attachments: [ComposerAttachment] = []
  /// Owned by the parent's `@FocusState` so the transcript can dismiss the keyboard.
  var focused: FocusState<Bool>.Binding
  let onModelTap: () -> Void
  let onSend: () -> Void
  let onInterrupt: () -> Void
  var onVoiceTap: () -> Void = {}
  var onCancelRecording: () -> Void = {}
  var onAttachPhotos: () -> Void = {}
  var onAttachCamera: () -> Void = {}
  var onAttachFiles: () -> Void = {}
  var onRemoveAttachment: (ComposerAttachment.ID) -> Void = { _ in }

  var body: some View {
    Group {
      if recording.isBusy {
        recordingBar
      } else {
        textComposer
      }
    }
    .padding(12)
    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 22))
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var textComposer: some View {
    VStack(spacing: 10) {
      if !attachments.isEmpty { attachmentChips }
      TextField("Message", text: $text, axis: .vertical)
        .lineLimit(1 ... 6)
        .focused(focused)
        .onSubmit(submitDraft)

      HStack(spacing: 12) {
        // Let the model chip claim its ideal width before the Spacer, so the model name
        // shows in full when there's room (it truncated even with space to spare otherwise).
        modelChip
          .layoutPriority(1)
        if let usage { ContextUsageRing(usage: usage) }
        Spacer()
        if attachmentsSupported { attachButton }
        voiceButton
        sendButton
      }
    }
  }

  private var attachmentChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(attachments) { attachment in
          AttachmentChip(attachment: attachment) { onRemoveAttachment(attachment.id) }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var attachButton: some View {
    Menu {
      Button { onAttachPhotos() } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
      Button { onAttachCamera() } label: { Label("Camera", systemImage: "camera") }
      Button { onAttachFiles() } label: { Label("Files", systemImage: "folder") }
    } label: {
      Image(systemName: "paperclip")
        .font(.title3)
        .foregroundStyle(.secondary)
    }
    // Menu tints its label with the accent by default; pin it to match the mic button.
    .tint(.secondary)
    .accessibilityLabel("Add attachment")
  }

  @ViewBuilder
  private var recordingBar: some View {
    if recording == .transcribing {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("Transcribing…").font(.callout).foregroundStyle(.secondary)
        Spacer()
      }
      .frame(minHeight: 40)
    } else {
      HStack(spacing: 12) {
        Button(action: onCancelRecording) {
          Image(systemName: "xmark").font(.body.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Cancel recording")

        RecordingWaveform(levels: waveformLevels)

        Text(Self.elapsed(recordingSeconds))
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)

        Button(action: onVoiceTap) {
          Image(systemName: "stop.circle.fill").font(.title)
        }
        .foregroundStyle(Color.hermesAccent)
        .accessibilityLabel("Stop and transcribe")
      }
      .frame(minHeight: 40)
    }
  }

  /// `m:ss` elapsed-time readout for the recorder.
  static func elapsed(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private var modelChip: some View {
    Button(action: onModelTap) {
      HStack(spacing: 5) {
        Text(modelLabel)
          .lineLimit(1)
        if let effort = reasoningEffort, !effort.isEmpty {
          Text("·").foregroundStyle(.tertiary)
          Text(effort)
        }
        Image(systemName: "chevron.up.chevron.down").font(.caption2)
      }
      .font(.footnote.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.quaternary, in: Capsule())
    }
    .buttonStyle(.plain)
  }

  private var voiceButton: some View {
    Button(action: onVoiceTap) {
      Image(systemName: "mic.fill").font(.title3)
    }
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var sendButton: some View {
    if isSending {
      if canQueue {
        Button(action: submitDraft) {
          Image(systemName: "square.stack.3d.up.fill").font(.title2)
        }
        .foregroundStyle(Color.hermesAccent)
        .accessibilityLabel("Queue message")
      }
      Button(action: onInterrupt) {
        Image(systemName: "stop.circle.fill").font(.title)
      }
      .foregroundStyle(.red)
      .accessibilityLabel("Stop current task")
    } else {
      Button(action: submitDraft) {
        Image(systemName: "arrow.up.circle.fill").font(.title)
      }
      .foregroundStyle(Color.hermesAccent)
      .disabled(!canSend)
    }
  }

  /// Submit synchronously and reinforce an accepted reducer clear at the focused field
  /// boundary. Rejected submissions and attachment uploads intentionally keep their draft.
  private func submitDraft() {
    let original = text
    onSend()
    if text.isEmpty || text != original {
      // A second binding write closes iOS's TextField/onSubmit stale-repaint race.
      text = ""
    }
  }

  private var modelLabel: String {
    if let model, !model.isEmpty { return model }
    return "Model"
  }
}

/// Live amplitude bars for the active voice recording (#7). Newest sample is on the
/// right; bars grow from the vertical center. Honors reduce-motion (no height animation).
struct RecordingWaveform: View {
  let levels: [Float]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geo in
      HStack(alignment: .center, spacing: 2) {
        ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
          Capsule()
            .fill(Color.hermesAccent.opacity(0.85))
            .frame(width: 2.5, height: barHeight(level, in: geo.size.height))
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .animation(reduceMotion ? nil : .linear(duration: 0.1), value: levels)
    }
    .frame(height: 28)
    .accessibilityHidden(true)
  }

  private func barHeight(_ level: Float, in height: CGFloat) -> CGFloat {
    max(3, CGFloat(min(max(level, 0), 1)) * height)
  }
}

/// A staged attachment shown above the composer input (#8): image thumbnail or a
/// file/PDF glyph, the filename, and an upload-state indicator (spinner / error) or a
/// remove button.
struct AttachmentChip: View {
  let attachment: ComposerAttachment
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      thumbnail
      Text(attachment.filename)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 120, alignment: .leading)
      trailing
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary, in: .rect(cornerRadius: 10))
  }

  @ViewBuilder private var thumbnail: some View {
    switch attachment.kind {
    case .image:
      if let image = UIImage(data: attachment.data) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 28, height: 28)
          .clipShape(.rect(cornerRadius: 5))
      } else {
        glyph("photo")
      }
    case .pdf:
      glyph("doc.richtext")
    case .file:
      glyph("doc")
    }
  }

  private func glyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.title3)
      .foregroundStyle(.secondary)
      .frame(width: 28, height: 28)
  }

  @ViewBuilder private var trailing: some View {
    switch attachment.uploadState {
    case .uploading:
      ProgressView().controlSize(.mini)
    case .failed:
      HStack(spacing: 4) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        removeButton
      }
      .font(.caption)
    case .pending, .uploaded:
      removeButton
    }
  }

  private var removeButton: some View {
    Button(action: onRemove) {
      Image(systemName: "xmark.circle.fill").font(.caption)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .accessibilityLabel("Remove \(attachment.filename)")
  }
}
