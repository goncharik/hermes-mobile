import ComposableArchitecture
import HermesKit
import SwiftUI

/// The chat screen: a scrolling transcript, a transient error footer, and
/// the composer. Streams over the gateway via `ChatFeature`.
struct ChatView: View {
  @Bindable var store: StoreOf<ChatFeature>
  @State private var isAtBottom = true
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

  private var transcript: some View {
    ScrollViewReader { proxy in
      GeometryReader { outer in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            // Top sentinel: when older rows are windowed out, appearing near the top
            // (the first visible row's leading edge) reveals the previous page. Kept
            // iOS 17-safe via plain `.onAppear` rather than scroll-geometry APIs.
            if store.hasMoreAbove {
              Color.clear.frame(height: 1)
                .id(Self.topSentinel)
                .onAppear { store.send(.loadOlderRequested) }
            }
            ForEach(store.visibleRows) { row in
              rowView(row)
                .id(row.id)
                .contextMenu {
                  Button {
                    store.send(.copyRow(id: row.id))
                  } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                  }
                }
            }
            // Invisible anchor at the very bottom; its position relative to the viewport
            // tells us whether the user is scrolled to the latest message.
            Color.clear.frame(height: 1)
              .id(Self.bottomAnchor)
              .background(GeometryReader { inner in
                Color.clear.preference(
                  key: BottomDistanceKey.self,
                  value: inner.frame(in: .global).minY - outer.frame(in: .global).maxY
                )
              })
          }
          .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        // Tap on empty transcript space dismisses the keyboard without stealing taps
        // from row buttons, context menus, or markdown links.
        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
        .onPreferenceChange(BottomDistanceKey.self) { distance in
          isAtBottom = distance < 60 // within ~60pt of the bottom counts as "at bottom"
        }
        // Scroll on row count changes, not just the last row's id: the thinking row is
        // pinned last, so appending a tool/answer row reorders without changing `last?.id`.
        .onChange(of: store.transcript.count) { _, count in
          guard count > 0 else { return }
          withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
          if !isAtBottom {
            ScrollToBottomButton {
              withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .transition(.scale.combined(with: .opacity))
          }
        }
        .animation(.spring(duration: 0.25), value: isAtBottom)
      }
    }
  }

  private static let bottomAnchor = "transcript-bottom-anchor"
  private static let topSentinel = "transcript-top-sentinel"

  /// Bottom anchor's distance below the viewport bottom (≤0 ⇒ visible ⇒ at bottom).
  private struct BottomDistanceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
