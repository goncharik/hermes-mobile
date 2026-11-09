import ComposableArchitecture
import HermesKit
import SwiftUI

/// The session list: searchable, pull-to-refresh, inbox-style cards sectioned by update date
/// (Today, Yesterday, …). The top-leading button opens the Archived sessions sheet; Search and
/// the selected profile's Edit menu sit top-trailing. The tabs and New session live in the
/// bottom bar (`HomeTabBar`).
struct SessionListView: View {
  @Bindable var store: StoreOf<SessionListFeature>
  /// The session shown in the split view's detail column (#80), whose row gets the
  /// brand-tinted `SelectedRowBackground`. `nil` (the default, and always in compact
  /// width) highlights nothing — the iPhone list is unchanged. Passed in by `AppView` from
  /// `AppFeature.State.currentViewingSessionID`; the list itself never tracks selection.
  var highlightedSessionID: String? = nil
  /// Sessions whose card shows the needs-input status dot — `AppFeature.State
  /// .needsInputSessionIDs`, passed in by `AppView` like the highlight.
  var needsInputSessionIDs: Set<String> = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Keyboard focus for the search field, raised as soon as the field opens.
  @FocusState private var isSearchFieldFocused: Bool

  var body: some View {
    List {
      if let error = store.loadError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .listRowSeparator(.hidden)
      }
      switch store.effectiveTab {
      // Under the Settings layer (`AppView`) the list keeps the Sessions rows: leaving Settings
      // always lands on Sessions, so they come back with their scroll position intact.
      case .sessions, .settings:
        if store.isSearching {
          // Search results are flat cards. A hit carries only id, snippet (as `preview`) and
          // start time: the untitled card promotes the snippet to its title, and the header
          // leaves out the workspace it doesn't know.
          ForEach(store.sessions) { session in
            row(session, showsWorkspace: false)
          }
        } else {
          sessionListContent
        }
      case .cron:
        cronTabContent
      }
    }
    .listStyle(.plain)
    .listSectionSeparator(.hidden) // flat list — no section hairlines (row hairlines hidden per-row)
    // Let the compact date headers size to their text instead of the plain list's tall default,
    // and drop the built-in gap between sections: the header's own top inset separates them.
    .environment(\.defaultMinListHeaderHeight, 0)
    .listSectionSpacing(0)
    .overlay {
      // Under the push card / tips the placeholder is a row instead (`showsInlineEmptyPlaceholder`).
      if store.showsEmptyPlaceholder, !store.showsInlineEmptyPlaceholder {
        emptyPlaceholder
      }
    }
    // Applied BEFORE the bottom `safeAreaInset` so the toast floats inside the list area,
    // above the "New chat" bar rather than covering it.
    .overlay(alignment: .bottom) {
      CopiedToastView(token: store.copiedIDToastToken)
    }
    // The profile pill is the centered (principal) title; "Sessions" / "Cron Jobs" is a list
    // header row instead. The pill needs the inline bar, so keep the nav title empty + inline.
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    // Search is opened from the toolbar's search button (Sessions tab only): the field then
    // replaces the nav bar row, so the bottom stays the tab bar + New chat.
    .toolbar(store.isSearchPresented ? .hidden : .visible, for: .navigationBar)
    .safeAreaInset(edge: .top) {
      if store.isSearchPresented {
        searchBar
      }
    }
    .refreshable { store.send(.pulledToRefresh) }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          store.send(.archivedButtonTapped)
        } label: {
          Label("Archived sessions", systemImage: "archivebox")
        }
      }
      if store.profilesSupported {
        ToolbarItem(placement: .principal) {
          profilePill
        }
      }
      // One trailing group, so iOS 26 draws Search + Edit profile in a single glass pill.
      ToolbarItemGroup(placement: .topBarTrailing) {
        if store.effectiveTab == .sessions {
          Button {
            store.send(.searchButtonTapped, animation: reduceMotion ? nil : .snappy)
          } label: {
            Label("Search sessions", systemImage: "magnifyingglass")
          }
        }
        if store.canEditSelectedProfile {
          profileEditMenu
        }
      }
    }
    // The bottom bar: the tab pill (Sessions, Cron Jobs with cron content, Settings) and New
    // session. A `safeAreaInset` keeps it in the normal view hierarchy, above the home
    // indicator.
    .safeAreaInset(edge: .bottom) {
      HomeTabBar(store: store)
    }
    // `bottomActionSheet`, not `.confirmationDialog`: on iOS 26 the SwiftUI modifier
    // renders as a floating popover (dropping the title and Cancel) wherever it's
    // attached — the custom sheet presenter restores the bottom action sheet for every
    // entry point (swipe button and context menu alike). See `BottomActionSheet.swift`.
    .bottomActionSheet($store.scope(state: \.confirmationDialog, action: \.confirmationDialog))
    .task { store.send(.task) }
    .onDisappear { store.send(.onDisappear) }
    .alert(
      "Rename session",
      isPresented: Binding(
        get: { store.renamingID != nil },
        set: { presented in if !presented { store.send(.cancelRename) } }
      )
    ) {
      TextField("Title", text: $store.renameDraft)
      Button("Save") { store.send(.confirmRename) }
      Button("Cancel", role: .cancel) { store.send(.cancelRename) }
    }
    .alert(
      "Rename profile",
      isPresented: Binding(
        get: { store.renamingProfileName != nil },
        set: { presented in if !presented { store.send(.cancelRenameProfile) } }
      )
    ) {
      TextField("Profile name", text: $store.profileRenameDraft)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Button("Save") { store.send(.confirmRenameProfile) }
      Button("Cancel", role: .cancel) { store.send(.cancelRenameProfile) }
    } message: {
      Text(ProfileName.hint)
    }
    .sheet(item: $store.scope(state: \.archived, action: \.archived)) { archivedStore in
      NavigationStack {
        ArchivedSessionsView(store: archivedStore)
      }
    }
    .sheet(item: $store.scope(state: \.addProfile, action: \.addProfile)) { addProfileStore in
      NavigationStack {
        AddProfileView(store: addProfileStore)
      }
    }
  }

  /// The Sessions tab's non-search body: the "Sessions" header, the push card, the tips row
  /// and the inline "No sessions" placeholder, the pinned section, then the interactive
  /// sessions split into update-date sections (cron runs live in their own tab).
  /// Extracted from `body` to keep the `List` builder within the compiler's type-check
  /// budget.
  @ViewBuilder
  private var sessionListContent: some View {
    // Top-level "Sessions" header, scoped to the active profile pill.
    tabTitleHeader("Sessions")
    // The push card and the tips row (#136) lead the list, above Pinned and the date
    // sections; never while searching. With no sessions the placeholder follows them as a row.
    if store.showsPushCard, let card = store.pushCard {
      pushCardRow(card)
    }
    if store.showsOnboardingTipsRow {
      onboardingTipsRow
    }
    if store.showsInlineEmptyPlaceholder {
      emptyPlaceholder
        .padding(.top, 24)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
    // Pinned sessions float to the top — as cards too, so the column never mixes card and
    // one-line geometry (desktop parity).
    if !store.pinnedSessions.isEmpty {
      Section {
        ForEach(store.pinnedEntries) { entry in
          row(entry)
        }
      } header: {
        sectionHeader("Pinned")
      }
    }
    // The last-active-ordered lane, split into date sections (Today, Yesterday, …);
    // branches nest under their parent with elbow stems and never split across a header.
    ForEach(store.dateSections) { section in
      Section {
        ForEach(section.entries) { entry in
          row(entry)
        }
      } header: {
        sectionHeader(section.label)
      }
    }
  }

  private var emptyPlaceholder: some View {
    ContentUnavailableView("No sessions", systemImage: "bubble.left.and.bubble.right")
  }

  /// The push card as a plain list row: no separator, no row background (the card draws its
  /// own surface), and the same 16pt side insets as the session cards below it.
  private func pushCardRow(_ card: SessionListFeature.PushCard) -> some View {
    let animation: Animation? = reduceMotion ? nil : .snappy
    return PushCardView(
      card: card,
      askAgentButtonTapped: { store.send(.pushCardAskAgentButtonTapped) },
      enableButtonTapped: { store.send(.pushCardEnableButtonTapped, animation: animation) },
      notNowButtonTapped: { store.send(.pushCardNotNowButtonTapped, animation: animation) }
    )
    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  /// The tips row as a plain list row. Zero side insets: the row's own header and scroll
  /// content margins supply the 16pt inset, so the paging cards run to the trailing edge.
  private var onboardingTipsRow: some View {
    OnboardingTipsView(
      tips: store.onboardingTips,
      swipeAction: store.effectiveSwipeAction,
      hideButtonTapped: {
        store.send(.onboardingTipsHideButtonTapped, animation: reduceMotion ? nil : .snappy)
      }
    )
    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  /// A Pinned / date-section header: the title on the leading side and a hairline running to
  /// the trailing edge, centred on the title, hugging the cards below it.
  private func sectionHeader(_ label: String) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .fixedSize()
      Rectangle()
        .fill(Color.secondary.opacity(0.3))
        .frame(height: 1)
    }
    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 2, trailing: 16))
  }

  /// A tab's top-level title row ("Sessions" / "Cron Jobs"). The active profile is shown in
  /// the pill (the centered nav title); both tabs are scoped to it.
  private func tabTitleHeader(_ title: String) -> some View {
    Text(title)
      .font(.title2.weight(.bold))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .accessibilityAddTraits(.isHeader)
  }

  /// The Cron Jobs tab. When the agent exposes `/api/cron/jobs` the rows are the *jobs* only
  /// (state dot, status caption), desktop-style: tapping a job expands a single-open inline
  /// list of its recent *runs*, loaded from `/runs` into `expandedCronRuns` — one timestamp
  /// row per run (`cronJobRunRow(_:)`); a context menu offers Run now / Pause / Resume /
  /// Delete. Only agents without the jobs API fall back to the flat run list.
  @ViewBuilder
  private var cronTabContent: some View {
    tabTitleHeader("Cron Jobs")
    if !store.cronJobsSupported {
      // Flat fallback: agent without the jobs API.
      ForEach(store.cronSessions) { session in
        cronRunRow(session)
      }
    } else {
      ForEach(store.sortedCronJobs) { job in
        cronJobRow(job)
        if store.expandedCronJobID == job.id {
          expandedCronRuns
        }
      }
    }
  }

  /// The expanded job's runs, indented under it: a spinner until the first `/runs` load
  /// lands, "Couldn’t load runs" when it failed, "No runs yet" when empty, else one
  /// timestamp row per run (a failed refresh keeps the last runs — reducer rule).
  @ViewBuilder
  private var expandedCronRuns: some View {
    if let runs = store.expandedCronRuns {
      if runs.isEmpty {
        cronRunsPlaceholder("No runs yet")
      }
      ForEach(runs) { run in
        cronJobRunRow(run)
      }
    } else if store.expandedCronRunsFailed {
      cronRunsPlaceholder("Couldn’t load runs")
    } else {
      ProgressView()
        .padding(.leading, Self.cronRunIndent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
    }
  }

  /// Leading indent that sets a job's runs under the job's title.
  private static let cronRunIndent: CGFloat = 24

  private func cronRunsPlaceholder(_ text: String) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .padding(.leading, Self.cronRunIndent)
      .listRowSeparator(.hidden)
  }

  /// One run under an expanded job: only its timestamp, like the desktop (sibling runs share
  /// the job's title). A session run opens its chat on tap (unread dot while it has unseen
  /// activity) — tap only, no swipe or context menu. A script-only `cron_output` run has no
  /// session behind it, so it is plain secondary text.
  @ViewBuilder
  private func cronJobRunRow(_ run: Session) -> some View {
    let label = CronJob.runTimestampLabel(
      for: run.updatedAt ?? run.startedAt, timeZone: store.calendar.timeZone
    )
    if run.isCron {
      let isUnread = store.unreadSessionIDs.contains(run.id)
      Button {
        store.send(.cronRunTapped(id: run.id))
      } label: {
        HStack(spacing: 8) {
          if isUnread {
            Circle().fill(Color.hermesAccent).frame(width: 8, height: 8)
          }
          Text(label)
            .font(.subheadline)
            .fontWeight(isUnread ? .semibold : .regular)
            .monospacedDigit()
          Spacer(minLength: 0)
        }
        .padding(.leading, Self.cronRunIndent)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .listRowSeparator(.hidden)
      .listRowBackground(run.id == highlightedSessionID ? SelectedRowBackground() : nil)
      .accessibilityLabel(isUnread ? "Run \(label), unread" : "Run \(label)")
      .accessibilityAddTraits(run.id == highlightedSessionID ? [.isSelected] : [])
    } else {
      Text(label)
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.leading, Self.cronRunIndent)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Script run \(label)")
    }
  }

  /// One cron *job* row: state dot, title, the status caption (`CronJob.statusCaption` —
  /// the state in words, or the next-run countdown from the same `now` the row timestamps
  /// use, refreshed by the poll with no per-second ticker; overdue tinted orange), and a
  /// disclosure chevron for the runs.
  private func cronJobRow(_ job: CronJob) -> some View {
    let isExpanded = store.expandedCronJobID == job.id
    let caption = job.statusCaption(now: store.now)
    return Button {
      store.send(.cronJobTapped(id: job.id), animation: reduceMotion ? nil : .snappy)
    } label: {
      HStack(spacing: 10) {
        Circle()
          .fill(cronStateColor(job.effectiveState))
          .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 2) {
          Text(job.title)
            .lineLimit(1)
          if let caption {
            Text(caption.text)
              .font(.caption)
              .foregroundStyle(caption.isOverdue ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
              .lineLimit(1)
          }
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowSeparator(.hidden)
    .accessibilityLabel(cronJobAccessibilityLabel(job, caption: caption?.text, isExpanded: isExpanded))
    .contextMenu {
      Button("Run now", systemImage: "play") {
        store.send(.triggerCronJob(id: job.id))
      }
      if job.isPaused {
        Button("Resume", systemImage: "play.circle") {
          store.send(.resumeCronJob(id: job.id))
        }
      } else {
        Button("Pause", systemImage: "pause.circle") {
          store.send(.pauseCronJob(id: job.id))
        }
      }
      Divider()
      // Confirmed through the reducer's dialog (`.bottomActionSheet`), never sent directly.
      Button("Delete", systemImage: "trash", role: .destructive) {
        store.send(.deleteCronJobTapped(id: job.id))
      }
    }
  }

  /// Status-pip color per job state — mirrors the desktop's `STATE_DOT` mapping, except
  /// live states are green (the desktop uses its accent, but ours is orange and would be
  /// indistinguishable from the amber paused pip): green live, amber paused, red error,
  /// gray inactive/unknown.
  private func cronStateColor(_ state: String) -> Color {
    switch state {
    case "scheduled", "running", "enabled": .green
    case "paused": .orange
    case "error": .red
    default: Color(.systemGray3) // completed / disabled / unknown
    }
  }

  /// Title, the visible status caption ("Paused", "Next in 1 hr.", "Overdue · 2 hr. ago" —
  /// so the state word is announced), and the disclosure state.
  private func cronJobAccessibilityLabel(_ job: CronJob, caption: String?, isExpanded: Bool) -> String {
    var parts = [job.title]
    if let caption { parts.append(caption) }
    parts.append(isExpanded ? "expanded" : "collapsed")
    return parts.joined(separator: ", ")
  }

  // MARK: Profile pill

  /// Safari-style centered pill in the navigation bar: the active profile's icon (a house
  /// for the default profile; none for custom ones), its name, and a chevron. Tapping it
  /// opens the profile `Menu`, where ONE tap on any profile switches to it. Rendered only
  /// when the agent supports profiles (`profilesSupported`).
  private var profilePill: some View {
    Menu {
      profileMenuContent
    } label: {
      HStack(spacing: 4) {
        if isSelectedDefault {
          Image(systemName: "house.fill")
            .imageScale(.small)
        }
        Text(store.selectedProfileName)
          .fontWeight(.semibold)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      // Safari-style glass chip in the navigation bar.
      .modifier(GlassBackground(shape: Capsule(), isInteractive: true))
    }
    .accessibilityLabel("Profile: \(store.selectedProfileName)")
  }

  /// The profile `Menu`'s contents: every profile as a plain button — ONE tap selects it — a
  /// divider, then "Add profile". No checkmarks (Safari-style): the default profile shows a
  /// house, custom ones a person glyph, and the pill title names the active one. Rename and
  /// Delete live in the trailing Edit menu (`profileEditMenu`), for the selected profile only.
  @ViewBuilder
  private var profileMenuContent: some View {
    ForEach(store.profiles) { profile in
      Button {
        store.send(.selectProfile(name: profile.name))
      } label: {
        Label(profile.name, systemImage: profile.isDefault ? "house" : "person.crop.circle")
      }
    }

    Divider()

    Button {
      store.send(.addProfileTapped)
    } label: {
      Label("Add profile", systemImage: "plus")
    }
  }

  /// The trailing pencil: Rename / Delete for the SELECTED custom profile. Shown only while
  /// `canEditSelectedProfile` (never for the default profile). Both go through the reducer —
  /// the rename alert and the `.bottomActionSheet` delete confirmation.
  private var profileEditMenu: some View {
    Menu {
      Button {
        store.send(.renameProfileTapped(name: store.selectedProfileName))
      } label: {
        Label("Rename profile", systemImage: "pencil")
      }
      Button(role: .destructive) {
        store.send(.deleteProfileButtonTapped(name: store.selectedProfileName))
      } label: {
        Label("Delete profile", systemImage: "trash")
      }
    } label: {
      Label("Edit profile", systemImage: "pencil")
    }
  }

  private var isSelectedDefault: Bool {
    store.profiles[id: store.selectedProfileName]?.isDefault
      ?? (store.selectedProfileName == SessionListFeature.State.defaultProfileName)
  }

  /// The open search field in place of the nav bar row: a glass capsule field (focused on
  /// open) beside a round glass close button that hides it and clears the query.
  private var searchBar: some View {
    HStack(spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .font(.body.weight(.semibold))
          .foregroundStyle(.secondary)
        TextField("Search sessions", text: $store.searchQuery)
          .focused($isSearchFieldFocused)
          .submitLabel(.search)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
      }
      .padding(.horizontal, 16)
      .frame(height: Self.searchBarHeight)
      .modifier(GlassBackground(shape: Capsule()))
      Button {
        isSearchFieldFocused = false
        store.send(.searchCloseTapped, animation: reduceMotion ? nil : .snappy)
      } label: {
        Image(systemName: "xmark")
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
          .frame(width: Self.searchBarHeight, height: Self.searchBarHeight)
          .contentShape(Circle())
          .modifier(GlassBackground(shape: Circle(), isInteractive: true))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close search")
    }
    .padding(.horizontal)
    .padding(.vertical, 6)
    .onAppear { isSearchFieldFocused = true }
  }

  private static let searchBarHeight: CGFloat = 48

  /// Stemmed-entry convenience: renders a lane's `SessionBranchEntry` — the card with the
  /// branch elbow stem (`└─`/`├─`) in its header and a leading indent when nested.
  private func row(_ entry: SessionBranchEntry) -> some View {
    row(entry.session, branchStem: entry.branchStem)
  }

  /// An interactive session (Pinned, date sections, search) as an inbox-style card.
  private func row(
    _ session: Session,
    branchStem: String? = nil,
    showsWorkspace: Bool = true
  ) -> some View {
    sessionRow(session) { isPinned in
      // Branch cards keep the 16pt indent on top of the header's elbow stem, so a nested
      // card's whole body (not just its header) reads as belonging to the parent above.
      SessionCardView(
        session: session,
        now: store.now,
        branchStem: branchStem,
        isUnread: store.unreadSessionIDs.contains(session.id),
        isPinned: isPinned,
        isActive: session.isActive == true,
        needsInput: needsInputSessionIDs.contains(session.id),
        showsWorkspace: showsWorkspace
      )
      .padding(.leading, branchStem == nil ? 0 : 16)
    }
    // Tighter than the plain list's default row padding: the card's own line spacing already
    // separates its parts, so the gap between cards stays small.
    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
  }

  /// A cron run in the flat fallback (agents without the jobs API) as the compact one-line
  /// row. Same affordances as a card.
  private func cronRunRow(_ session: Session) -> some View {
    sessionRow(session) { isPinned in
      SessionRowView(
        session: session,
        now: store.now,
        isUnread: store.unreadSessionIDs.contains(session.id),
        isPinned: isPinned,
        isActive: session.isActive == true
      )
    }
  }

  /// The single affordance funnel every session row goes through, whatever its body: tap to
  /// open, highlight, swipe actions, context menu.
  private func sessionRow<Content: View>(
    _ session: Session,
    @ViewBuilder content: (_ isPinned: Bool) -> Content
  ) -> some View {
    // Derive pinned state from the store so every row (search, date sections, Pinned
    // section) reflects the true state — search rows used to default to unpinned and
    // offered a no-op "Pin" for already-pinned sessions.
    let isPinned = store.pinnedIDs.contains(session.id)
    return Button {
      store.send(.sessionTapped(session.id))
    } label: {
      content(isPinned)
    }
    .buttonStyle(.plain)
    .listRowSeparator(.hidden)
    // `nil` for every row but the highlighted one, so non-highlighted rows keep the
    // list's default background (a `Color.clear` here would change the iPhone render).
    .listRowBackground(session.id == highlightedSessionID ? SelectedRowBackground() : nil)
    // The tint alone is invisible to VoiceOver/Switch Control — the trait is what announces
    // which session the detail column is showing. Empty option set = no trait added.
    .accessibilityAddTraits(session.id == highlightedSessionID ? [.isSelected] : [])
    .swipeActions(edge: .leading) {
      pinButton(session, isPinned: isPinned)
        .tint(.orange)
    }
    .swipeActions(edge: .trailing) {
      // Destructive default FIRST: SwiftUI places the first listed button nearest the
      // edge and makes it the full-swipe target (Mail-style) — full swipe must trigger
      // the default destructive action, never Rename.
      defaultSwipeActionButton(session)
      renameButton(session)
        .tint(.blue)
    }
    .contextMenu {
      pinButton(session, isPinned: isPinned)
      renameButton(session)
      // Context menu only — copying an id is a rare debugging affordance, not worth a
      // swipe slot next to Rename/Archive.
      Button("Copy ID", systemImage: "doc.on.doc") {
        store.send(.copyIDButtonTapped(id: session.id))
      }
      // The context menu always offers BOTH destructive actions regardless of the swipe
      // default; Delete only exists on agents with the DELETE endpoint.
      archiveButton(session)
      if store.deleteSupported {
        deleteButton(session)
      }
    }
  }

  /// The trailing swipe's destructive slot: Archive or Delete per the user's persisted
  /// preference (`effectiveSwipeAction` clamps back to Archive on agents without the
  /// DELETE endpoint). Both confirm through the same reducer-owned dialog.
  @ViewBuilder
  private func defaultSwipeActionButton(_ session: Session) -> some View {
    switch store.effectiveSwipeAction {
    case .archive:
      archiveButton(session)
    case .delete:
      deleteButton(session)
    }
  }

  private func archiveButton(_ session: Session) -> some View {
    Button("Archive", systemImage: "archivebox", role: .destructive) {
      store.send(.archiveButtonTapped(id: session.id))
    }
  }

  private func deleteButton(_ session: Session) -> some View {
    Button("Delete", systemImage: "trash", role: .destructive) {
      store.send(.deleteButtonTapped(id: session.id))
    }
  }

  private func renameButton(_ session: Session) -> some View {
    Button("Rename", systemImage: "pencil") {
      store.send(.renameButtonTapped(id: session.id))
    }
  }

  /// The selected-row highlight for the split view's sidebar (#80): an inset, rounded
  /// brand-accent tint behind the row that mirrors the detail column — the iPad Mail /
  /// Notes idiom. A `listRowBackground`, so the row content, its natural height, and its
  /// swipe/context affordances are untouched; the corner radius matches the working glow's.
  /// A flat tint, not a material, so Reduce Transparency has nothing to strip.
  private struct SelectedRowBackground: View {
    var body: some View {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.hermesAccent.opacity(0.18))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
  }

  @ViewBuilder
  private func pinButton(_ session: Session, isPinned: Bool) -> some View {
    // Animate the send so the row glides between its date section and the Pinned
    // section (and the section itself fades in/out) instead of jumping.
    // Use the reducer's ownership and operation checks, not just search visibility.
    if store.state.canChangePin(id: session.id) {
      if isPinned {
        Button("Unpin", systemImage: "pin.slash") {
          store.send(.unpinSession(id: session.id), animation: .snappy)
        }
      } else {
        Button("Pin", systemImage: "pin") {
          store.send(.pinSession(id: session.id), animation: .snappy)
        }
      }
    }
  }
}
