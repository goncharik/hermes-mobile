import ComposableArchitecture
import HermesKit
import SwiftUI

/// The session list: a flat (Codex-style) list, searchable, pull-to-refresh. Grouping
/// (by workspace / chronological) is chosen from the top-trailing menu, which also opens
/// the Archived sessions sheet. "New chat" lives in the bottom bar (alongside the iOS 26
/// bottom search field).
struct SessionListView: View {
  @Bindable var store: StoreOf<SessionListFeature>
  /// The session shown in the split view's detail column (#80), whose row gets the
  /// brand-tinted `SelectedRowBackground`. `nil` (the default, and always in compact
  /// width) highlights nothing — the iPhone list is unchanged. Passed in by `AppView` from
  /// `AppFeature.State.currentViewingSessionID`; the list itself never tracks selection.
  var highlightedSessionID: String? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    List {
      if let error = store.loadError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .listRowSeparator(.hidden)
      }
      if store.isSearching {
        // Search results are flat, with the matching snippet shown.
        ForEach(store.sessions) { session in
          row(session, showsPreview: true)
        }
      } else {
        sessionListContent
      }
    }
    .listStyle(.plain)
    .listSectionSeparator(.hidden) // flat list — no section hairlines (row hairlines hidden per-row)
    .overlay {
      if store.sessions.isEmpty, !store.isLoading, store.loadError == nil {
        ContentUnavailableView("No sessions", systemImage: "bubble.left.and.bubble.right")
      }
    }
    // Applied BEFORE the bottom `safeAreaInset` so the toast floats inside the list area,
    // above the "New chat" bar rather than covering it.
    .overlay(alignment: .bottom) {
      CopiedToastView(token: store.copiedIDToastToken)
    }
    // The profile pill is the centered (principal) title; "Sessions" is a list section
    // header instead, leaving room for future sibling sections (e.g. "Cron jobs"). The
    // pill needs the inline bar, so keep the nav title empty + inline in both cases.
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $store.searchQuery, prompt: "Search sessions")
    .refreshable { store.send(.pulledToRefresh) }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Settings", systemImage: "gearshape") {
          store.send(.settingsButtonTapped)
        }
      }
      if store.profilesSupported {
        ToolbarItem(placement: .principal) {
          profilePill
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        organizeMenu
      }
    }
    // New chat lives at the bottom (Codex-style). A `safeAreaInset` keeps it in the
    // normal view hierarchy so it sits above the home indicator — and, on iOS 26 where
    // `.searchable` moves to the bottom, above the search field too.
    .safeAreaInset(edge: .bottom) {
      newChatBar
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
    .sheet(item: $store.scope(state: \.settings, action: \.settings)) { settingsStore in
      NavigationStack {
        SettingsView(store: settingsStore)
      }
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
    // Push onboarding info sheet — raised by the reducer when the plugin isn't ready and the
    // prompt isn't snoozed. Its two buttons send `SessionListFeature` actions.
    .sheet(isPresented: $store.showPushSetupSheet) {
      PushSetupGuideView(
        // This sheet is only raised when the plugin isn't ready, so always show the install actions.
        pluginInstalled: false,
        onAskAgent: { store.send(.pushSetupAskAgentTapped) },
        onLater: { store.send(.pushSetupLaterTapped) }
      )
    }
  }

  /// The non-search list body: the "Sessions" header, the pinned section, the interactive
  /// sessions (workspace groups or chronological), then the always-on Cron Jobs section.
  /// Extracted from `body` to keep the `List` builder within the compiler's type-check
  /// budget.
  @ViewBuilder
  private var sessionListContent: some View {
    // Top-level "Sessions" section header. Future sibling areas (e.g. "Cron jobs")
    // render their own header the same way, all scoped to the active profile pill.
    sessionsSectionHeader
    // Pinned sessions float to the top in both grouping modes.
    if !store.pinnedSessions.isEmpty {
      Section("Pinned") {
        ForEach(store.pinnedEntries) { entry in
          row(entry)
        }
      }
    }
    switch store.groupingMode {
    case .workspace:
      ForEach(store.groups) { group in
        groupSection(group)
      }
    case .chronological:
      // One last-active-ordered list — no workspace headers; branches nest under
      // their parent with elbow stems.
      ForEach(store.chronologicalEntries) { entry in
        row(entry)
      }
    }
    // Cron-scheduled sessions live in their own always-on section below the
    // interactive list, in both grouping modes (filtered out of pinned/groups/
    // chronological by the reducer). Hidden when there are none, or when the
    // user turned the section off in the organize menu.
    if store.showCronSection, !store.cronSessions.isEmpty {
      cronJobsSection
    }
  }

  /// Top-level content section header. The active profile is shown in the pill (the
  /// centered nav title); this labels the sessions list as one section so future sibling
  /// sections (e.g. "Cron jobs") can sit alongside it under the same profile.
  private var sessionsSectionHeader: some View {
    Text("Sessions")
      .font(.title2.weight(.bold))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .accessibilityAddTraits(.isHeader)
  }

  /// Always-on "Cron Jobs" section. When the agent exposes `/api/cron/jobs` the rows are
  /// the *jobs* (state dot, next-run countdown, unread dot), desktop-style: tapping a job
  /// expands a single-open inline peek of its recent *runs* (standard `row(_:)`, so
  /// tap-to-open and unread styling stay identical); a context menu offers Run now /
  /// Pause / Resume. Older agents (or before the first jobs fetch) fall back to the flat
  /// run list. The header carries the aggregate unread badge either way.
  @ViewBuilder
  private var cronJobsSection: some View {
    cronSectionHeader
    if store.cronJobGroups.isEmpty {
      // Flat fallback: agent without the jobs API, or the jobs fetch hasn't landed yet.
      ForEach(store.cronSessions) { session in
        row(session)
      }
    } else {
      ForEach(store.cronJobGroups) { group in
        cronJobRow(group)
        if store.expandedCronJobID == group.id {
          if group.runs.isEmpty {
            Text("No runs yet")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .padding(.leading, 24)
              .listRowSeparator(.hidden)
          }
          ForEach(group.runs) { run in
            row(run)
              .padding(.leading, 24) // indented under the owning job
          }
        }
      }
      // Runs whose job no longer exists (deleted job, legacy id) — never hide output.
      ForEach(store.unmatchedCronSessions) { session in
        row(session)
      }
    }
  }

  /// "Cron Jobs" header with the aggregate unread badge (count of cron runs with unseen
  /// output — the desktop's `CRON JOBS 4`), so activity is visible even from the header.
  private var cronSectionHeader: some View {
    HStack(spacing: 8) {
      Label("Cron Jobs", systemImage: "clock")
        .font(.title2.weight(.bold))
      if store.cronUnreadCount > 0 {
        Text("\(store.cronUnreadCount)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Color.hermesAccent, in: Capsule())
          .accessibilityLabel("\(store.cronUnreadCount) unread cron runs")
      }
      Spacer()
    }
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .accessibilityAddTraits(.isHeader)
  }

  /// One cron *job* row: state dot, title, next-run countdown (relative, from the same
  /// `now` the row timestamps use — refreshed by the poll, no per-second ticker), unread
  /// dot when any of the job's runs is unread, and a disclosure chevron for the peek.
  private func cronJobRow(_ group: CronJobGroup) -> some View {
    let isExpanded = store.expandedCronJobID == group.id
    return Button {
      store.send(.cronJobTapped(id: group.id), animation: reduceMotion ? nil : .snappy)
    } label: {
      HStack(spacing: 10) {
        Circle()
          .fill(cronStateColor(group.job.effectiveState))
          .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 2) {
          Text(group.job.title)
            .fontWeight(group.hasUnread ? .semibold : .regular)
            .lineLimit(1)
          if let next = group.job.nextRunAt {
            Text("Next \(CronJob.relativeRunLabel(for: next, now: store.now))")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if let schedule = group.job.scheduleDisplay {
            Text(schedule)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
        if group.hasUnread {
          Circle().fill(Color.hermesAccent).frame(width: 8, height: 8)
        }
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowSeparator(.hidden)
    .accessibilityLabel(cronJobAccessibilityLabel(group, isExpanded: isExpanded))
    .contextMenu {
      Button("Run now", systemImage: "play") {
        store.send(.triggerCronJob(id: group.id))
      }
      if group.job.isPaused {
        Button("Resume", systemImage: "play.circle") {
          store.send(.resumeCronJob(id: group.id))
        }
      } else {
        Button("Pause", systemImage: "pause.circle") {
          store.send(.pauseCronJob(id: group.id))
        }
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

  private func cronJobAccessibilityLabel(_ group: CronJobGroup, isExpanded: Bool) -> String {
    var parts = [group.job.title]
    if group.job.isPaused { parts.append("paused") }
    if let next = group.job.nextRunAt {
      parts.append("next run \(CronJob.relativeRunLabel(for: next, now: store.now))")
    }
    if group.hasUnread { parts.append("unread runs") }
    parts.append(isExpanded ? "expanded" : "collapsed")
    return parts.joined(separator: ", ")
  }

  // MARK: Profile pill

  /// Safari-style centered pill in the navigation bar: the active profile's icon (a house
  /// for the default profile; none for custom ones), its name, and a chevron. Tapping it
  /// opens the profile `Menu`. Rendered only when the agent supports profiles
  /// (`profilesSupported`); otherwise the static "Sessions" title is shown instead.
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

  /// The profile `Menu`'s contents: each profile (checkmark on the active one; custom
  /// profiles offer rename/delete in a nested menu), a divider, then "Add profile".
  @ViewBuilder
  private var profileMenuContent: some View {
    ForEach(store.profiles) { profile in
      if profile.isDefault {
        Button {
          store.send(.selectProfile(name: profile.name))
        } label: {
          Label(profile.name, systemImage: "house")
        }
      } else {
        // Custom profiles: select on tap, with a nested menu for rename/delete.
        Menu {
          Button {
            store.send(.selectProfile(name: profile.name))
          } label: {
            Label("Switch to this profile", systemImage: "arrow.right.circle")
          }
          Divider()
          Button {
            store.send(.renameProfileTapped(name: profile.name))
          } label: {
            Label("Rename", systemImage: "pencil")
          }
          Button(role: .destructive) {
            store.send(.deleteProfileButtonTapped(name: profile.name))
          } label: {
            Label("Delete", systemImage: "trash")
          }
        } label: {
          Label(profile.name, systemImage: "person.crop.circle")
        }
      }
    }

    Divider()

    Button {
      store.send(.addProfileTapped)
    } label: {
      Label("Add profile", systemImage: "plus")
    }
  }

  private var isSelectedDefault: Bool {
    store.profiles[id: store.selectedProfileName]?.isDefault
      ?? (store.selectedProfileName == SessionListFeature.State.defaultProfileName)
  }

  /// The bottom "new session" button — a trailing circular FAB in the Hermes accent
  /// (icon-only: it starts a new session, not a chat). Rendered via `safeAreaInset` so the
  /// list content scrolls clear of it.
  private var newChatBar: some View {
    HStack {
      Spacer()
      Button {
        store.send(.newSessionButtonTapped)
      } label: {
        Image(systemName: "square.and.pencil")
          .font(.title2.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 56, height: 56)
          .background(Color.hermesAccent, in: Circle())
          .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
      }
      .accessibilityLabel("New session")
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  /// Top-trailing menu: choose the grouping mode (checkmark on the active one), then a
  /// divider and the Archived sessions entry. Mirrors the Codex "Organize / Manage" menu.
  private var organizeMenu: some View {
    Menu {
      Picker(
        "Grouping",
        selection: Binding(
          get: { store.groupingMode },
          set: { store.send(.setGroupingMode($0)) }
        )
      ) {
        Label("By workspace", systemImage: "folder").tag(SessionGroupingMode.workspace)
        Label("Chronological", systemImage: "clock").tag(SessionGroupingMode.chronological)
      }
      .pickerStyle(.inline)

      Divider()

      Toggle(isOn: Binding(
        get: { store.showCronSection },
        set: { store.send(.setShowCronSection($0)) }
      )) {
        Label("Cron Jobs section", systemImage: "clock")
      }

      Divider()

      Button {
        store.send(.archivedButtonTapped)
      } label: {
        Label("Archived sessions", systemImage: "archivebox")
      }
    } label: {
      Label("Organize", systemImage: "line.3.horizontal.decrease.circle")
    }
  }

  @ViewBuilder
  private func groupSection(_ group: SessionGroup) -> some View {
    let visible = store.state.visibleEntries(in: group)
    let hidden = group.sessions.count - visible.count
    let isExpanded = store.expandedGroups.contains(group.id)
    Section(group.label) {
      ForEach(visible) { entry in
        row(entry)
      }
      if hidden > 0 || isExpanded, group.sessions.count > SessionListFeature.State.collapsedLimit {
        Button(isExpanded ? "Show less" : "Show \(hidden) more") {
          store.send(.toggleGroupExpansion(groupID: group.id))
        }
        .font(.subheadline)
        .listRowSeparator(.hidden)
      }
    }
  }

  /// Stemmed-entry convenience: renders a lane's `SessionBranchEntry` — the standard row
  /// with the branch elbow stem (`└─`/`├─`) and a leading indent when nested.
  private func row(_ entry: SessionBranchEntry) -> some View {
    row(entry.session, branchStem: entry.branchStem)
  }

  private func row(
    _ session: Session,
    branchStem: String? = nil,
    showsPreview: Bool = false
  ) -> some View {
    // Derive pinned state from the store so every row (search, grouped, Pinned section)
    // reflects the true state — search rows used to default to unpinned and offered a
    // no-op "Pin" for already-pinned sessions.
    let isPinned = store.pinnedIDs.contains(session.id)
    return Button {
      store.send(.sessionTapped(session.id))
    } label: {
      // Branch rows get the desktop-style elbow stem + indent; nesting is display-only,
      // so the row content (and its swipe/context affordances below) stay unchanged.
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        if let branchStem {
          Text(branchStem)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        SessionRowView(
          session: session,
          now: store.now,
          showsPreview: showsPreview,
          isUnread: store.unreadSessionIDs.contains(session.id),
          isPinned: isPinned,
          isActive: session.isActive == true
        )
      }
      .padding(.leading, branchStem == nil ? 0 : 16)
    }
    .buttonStyle(.plain)
    .listRowSeparator(.hidden)
    // `nil` for every row but the highlighted one, so non-highlighted rows keep the
    // list's default background (a `Color.clear` here would change the iPhone render).
    .listRowBackground(session.id == highlightedSessionID ? SelectedRowBackground() : nil)
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
    // Animate the send so the row glides between its workspace group and the Pinned
    // section (and the section itself fades in/out) instead of jumping.
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
