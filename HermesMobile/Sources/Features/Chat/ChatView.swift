import ComposableArchitecture
import HermesKit
import SwiftUI

/// The chat screen: a scrolling transcript, a transient error footer, and
/// the composer. Streams over the gateway via `ChatFeature`.
struct ChatView: View {
  @Bindable var store: StoreOf<ChatFeature>
  @FocusState private var composerFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      connectionBanner
      transcript
      footer
      pendingCard
      Divider()
      ComposerView(
        text: $store.composerText,
        isSending: store.isSending,
        canSend: store.canSend,
        model: store.model,
        reasoningEffort: store.reasoningEffort,
        usage: store.usage,
        recording: store.recording,
        waveformLevels: store.waveformLevels,
        recordingSeconds: store.recordingSeconds,
        attachmentsSupported: !store.attachmentsUnsupported,
        attachments: store.attachments,
        focused: $composerFocused,
        onModelTap: { store.send(.modelChipTapped) },
        onSend: { store.send(.composerSubmitted) },
        onInterrupt: { store.send(.interruptTapped) },
        onVoiceTap: { store.send(.voiceButtonTapped) },
        onCancelRecording: { store.send(.recordingCancelled) },
        onAttachPhotos: { store.send(.attachPhotosTapped) },
        onAttachCamera: { store.send(.attachCameraTapped) },
        onAttachFiles: { store.send(.attachFilesTapped) },
        onRemoveAttachment: { store.send(.removeAttachment(id: $0)) }
      )
    }
    .navigationTitle(store.title ?? "Chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("Rename") { store.send(.renameButtonTapped) }
            .disabled(!store.canRename)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .alert("Rename session", isPresented: renameBinding) {
      TextField("Title", text: renameDraftBinding)
      Button("Save") { store.send(.confirmRename) }
      Button("Cancel", role: .cancel) { store.send(.cancelRename) }
    }
    .task { store.send(.task) }
    .onDisappear { store.send(.onDisappear) }
    .sheet(item: toolDetailBinding) { row in
      if case let .tool(name, title, _, detail, durationS) = row.kind {
        ToolDetailSheet(name: name, title: title, detail: detail ?? ToolDetail(), durationS: durationS)
      }
    }
    .sheet(isPresented: modelPickerBinding) {
      if let picker = store.modelPicker {
        ModelPickerSheet(
          picker: picker,
          currentModel: store.model,
          currentEffort: store.reasoningEffort,
          isBusy: store.isSending,
          onSelectModel: { store.send(.modelSelected($0)) },
          onSelectEffort: { store.send(.reasoningSelected($0)) },
          onDone: { store.send(.modelPickerDismissed) }
        )
      }
    }
  }

  /// Drives the rename alert's presentation; dismissing routes through `.cancelRename`.
  private var renameBinding: Binding<Bool> {
    Binding(
      get: { store.renameDraft != nil },
      set: { if !$0 { store.send(.cancelRename) } }
    )
  }

  /// A non-optional proxy over the optional draft so the `TextField` stays authoritative
  /// in the reducer (writes go through the binding action).
  private var renameDraftBinding: Binding<String> {
    Binding(
      get: { store.renameDraft ?? "" },
      set: { store.renameDraft = $0 }
    )
  }

  private var modelPickerBinding: Binding<Bool> {
    Binding(
      get: { store.modelPicker != nil },
      set: { if !$0 { store.send(.modelPickerDismissed) } }
    )
  }

  /// Drives the tool-detail sheet; dismissing routes through the reducer.
  private var toolDetailBinding: Binding<ChatRow?> {
    Binding(
      get: { store.presentedTool },
      set: { if $0 == nil { store.send(.toolDetailDismissed) } }
    )
  }

  /// The transcript, rendered behind the shared renderer boundary (`SwiftUITranscriptView`).
  /// The reducer owns no scroll state — stick-to-bottom / pin behaviour is renderer-local.
  /// `canLoadOlder` (= `hasMoreAbove`) gates the top sentinel so it can't page past the start
  /// and can't get stuck mid-load when already at the true top of history.
  @ViewBuilder
  private var transcript: some View {
    let rows = Array(store.visibleRows)
    let turnState: TurnState = store.isSending ? .streaming : .idle
    let canLoadOlder = store.hasMoreAbove
    let onLoadOlder = { _ = store.send(.loadOlderRequested) }

    // The device-local A/B preference selects the engine. Both renderers share the same
    // initializer shape and the same `cell` closure, so flipping the pref re-instantiates
    // the chosen renderer with identical rows.
    Group {
      switch store.chatRenderer {
      case .swiftUI:
        SwiftUITranscriptView(
          rows: rows,
          turnState: turnState,
          canLoadOlder: canLoadOlder,
          onLoadOlder: onLoadOlder,
          cell: transcriptCell
        )
      case .collectionView:
        CollectionTranscriptView(
          rows: rows,
          turnState: turnState,
          canLoadOlder: canLoadOlder,
          onLoadOlder: onLoadOlder,
          cell: transcriptCell
        )
      }
    }
    // Keyboard dismissal is drag-driven (`.interactively`). We intentionally do NOT add a
    // `.simultaneousGesture(TapGesture())` here: over the SwiftUI engine's `.plain`-style
    // `ScrollToBottomButton` that combination swallows the button's tap (the button only worked in
    // the UICollectionView engine, whose hosted button sits outside this gesture). Dropping it
    // makes the jump-to-bottom button tappable in both engines.
    .scrollDismissesKeyboard(.interactively)
  }

  @ViewBuilder
  private func transcriptCell(_ row: ChatRow) -> some View {
    // Only user messages get the long-press "Copy whole message" menu (mirrors their bubble).
    // Assistant/tool/thinking rows render bubble-less plain text — no context menu, so a
    // long-press starts native text selection (select any range → system Copy/Share) instead
    // of grabbing the entire row. The menu's long-press gesture would otherwise pre-empt
    // `.textSelection`.
    if row.kind.role == .user {
      rowView(row)
        .contextMenu {
          Button {
            store.send(.copyRow(id: row.id))
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
        }
    } else {
      rowView(row)
    }
  }

  @ViewBuilder
  private func rowView(_ row: ChatRow) -> some View {
    switch row.kind {
    case let .message(role, text, isComplete):
      MessageBubbleView(
        role: role, text: text, isComplete: isComplete,
        copiedToken: store.recentlyCopiedToken,
        tokenPrefix: "\(row.id)",
        onCopyCode: { text, token in store.send(.copyCode(text: text, token: token)) },
        attachmentImages: row.attachmentImages
      )
    case let .tool(name, title, state, detail, durationS):
      ToolStatusView(
        name: name, title: title, state: state, durationS: durationS,
        hasDetail: detail?.isEmpty == false,
        onTap: { store.send(.toolTapped(id: row.id)) }
      )
    case let .thinking(reasoning, status, elapsedSeconds, isComplete):
      ThinkingIndicatorView(
        liveSeconds: store.thinkingSeconds,
        reasoning: reasoning,
        status: status,
        elapsedSeconds: elapsedSeconds,
        isComplete: isComplete
      )
    case let .status(_, text):
      Text(text).font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var pendingCard: some View {
    switch store.pendingInteraction {
    case let .approval(request):
      ApprovalCardView(
        request: request,
        onApprove: { all in store.send(.respondToApproval(approve: true, all: all)) },
        onDeny: { store.send(.respondToApproval(approve: false, all: false)) }
      )
    case let .clarify(request):
      ClarifyCardView(mode: .clarify(request)) { answer in
        store.send(.respondToClarify(answer: answer))
      }
    case let .secret(kind, prompt):
      ClarifyCardView(mode: .secret(kind, prompt)) { value in
        store.send(.respondToSecret(value: value))
      }
    case .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private var connectionBanner: some View {
    switch store.status {
    case .connecting:
      banner("Connecting…", systemImage: "wifi", tint: .secondary)
    case .reconnecting:
      banner("Reconnecting…", systemImage: "wifi.exclamationmark", tint: .orange)
    case .ready:
      EmptyView()
    }
  }

  private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(text)
      Spacer()
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(tint)
    .padding(.horizontal)
    .padding(.vertical, 6)
    .background(tint.opacity(0.12))
  }

  @ViewBuilder
  private var footer: some View {
    if let error = store.errorBanner {
      Label(error, systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
  }
}
