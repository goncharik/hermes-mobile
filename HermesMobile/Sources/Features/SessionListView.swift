import ComposableArchitecture
import HermesKit
import SwiftUI

/// The session list: searchable, pull-to-refresh, inbox-style cards sectioned by update date
/// (Today, Yesterday, …). The top-trailing button opens the Archived sessions sheet. "New
/// chat" lives in the bottom bar (alongside the iOS 26 bottom search field).
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
  /// Slides the selected-tab capsule between the bottom bar's tabs.
  @Namespace private var tabSelection
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
      case .sessions:
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
      if store.showsEmptyPlaceholder {
        ContentUnavailableView("No sessions", systemImage: "bubble.left.and.bubble.right")
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
        Button("Settings", systemImage: "gearshape") {
          store.send(.settingsButtonTapped)
        }
      }
      if store.profilesSupported {
        ToolbarItem(placement: .principal) {
          profilePill
        }
      }
      // One trailing group, so iOS 26 draws Archive + Search in a single glass pill.
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          store.send(.archivedButtonTapped)
        } label: {
          Label("Archived sessions", systemImage: "archivebox")
        }
        if store.effectiveTab == .sessions {
          Button {
            store.send(.searchButtonTapped, animation: reduceMotion ? nil : .snappy)
          } label: {
            Label("Search sessions", systemImage: "magnifyingglass")
          }
        }
      }
    }
    // The bottom bar: the Sessions | Cron Jobs tabs (only with cron content) and New chat.
    // A `safeAreaInset` keeps it in the normal view hierarchy, above the home indicator.
    .safeAreaInset(edge: .bottom) {
      bottomBar
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

  /// The Sessions tab's non-search body: the "Sessions" header, the pinned section, then the
  /// interactive sessions split into update-date sections (cron runs live in their own tab).
  /// Extracted from `body` to keep the `List` builder within the compiler's type-check
  /// budget.
  @ViewBuilder
  private var sessionListContent: some View {
    // Top-level "Sessions" header, scoped to the active profile pill.
    tabTitleHeader("Sessions")
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

  /// The Cron Jobs tab. When the agent exposes `/api/cron/jobs` the rows are the *jobs*
  /// (state dot, next-run countdown, unread dot), desktop-style: tapping a job expands a
  /// single-open inline peek of its recent *runs* (the compact `cronRunRow(_:)` — a dense
  /// tree surface keeps the one-liner, like the desktop); a context menu offers Run now /
  /// Pause / Resume. Older agents (or before the first jobs fetch) fall back to the flat run
  /// list. The tab's own badge carries the aggregate unread count.
  @ViewBuilder
  private var cronTabContent: some View {
    tabTitleHeader("Cron Jobs")
    if store.cronJobGroups.isEmpty {
      // Flat fallback: agent without the jobs API, or the jobs fetch hasn't landed yet.
      ForEach(store.cronSessions) { session in
        cronRunRow(session)
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
            cronRunRow(run)
              .padding(.leading, 24) // indented under the owning job
          }
        }
      }
      // Runs whose job no longer exists (deleted job, legacy id) — never hide output.
      ForEach(store.unmatchedCronSessions) { session in
        cronRunRow(session)
      }
    }
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
  /// The bottom bar: a glass Sessions | Cron Jobs tab pill on the leading side (only while
  /// there is cron content — `showsTabBar`) and the round glass New chat button trailing.
  private var bottomBar: some View {
    HStack(alignment: .center) {
      if store.showsTabBar {
        tabPill
      }
      Spacer(minLength: 0)
      Button {
        store.send(.newSessionButtonTapped)
      } label: {
        Image(systemName: "square.and.pencil")
          .font(.title2.weight(.semibold))
          .foregroundStyle(.primary)
          .frame(width: Self.barHeight, height: Self.barHeight)
          .contentShape(Circle())
          .modifier(GlassBackground(
            shape: Circle(), isInteractive: true, fallbackShadowRadius: 6, fallbackShadowY: 3
          ))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("New session")
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  /// The bar's shared height: the tab pill and the New chat circle line up.
  private static let barHeight: CGFloat = 64

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

  private var tabPill: some View {
    HStack(spacing: 0) {
      tabButton(.sessions, title: "Sessions", systemImage: "text.bubble.fill")
      tabButton(.cron, title: "Cron Jobs", systemImage: "clock.fill", badge: store.cronUnreadCount)
    }
    .padding(4)
    .frame(height: Self.barHeight)
    .modifier(GlassBackground(shape: Capsule(), fallbackShadowRadius: 6, fallbackShadowY: 3))
  }

  /// One tab: icon over label, the selected one on an inner capsule in the accent color. The
  /// Cron Jobs tab carries the aggregate unread-run badge (the desktop's `CRON JOBS 4`).
  private func tabButton(
    _ tab: SessionListTab,
    title: String,
    systemImage: String,
    badge: Int = 0
  ) -> some View {
    let isSelected = store.effectiveTab == tab
    return Button {
      store.send(.selectTab(tab), animation: reduceMotion ? nil : .snappy)
    } label: {
      VStack(spacing: 2) {
        Image(systemName: systemImage)
          .font(.title3)
          .overlay(alignment: .topTrailing) {
            if badge > 0 {
              Text("\(badge)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.hermesAccent, in: Capsule())
                .offset(x: 12, y: -6)
            }
          }
        Text(title)
          .font(.caption.weight(.semibold))
      }
      .foregroundStyle(isSelected ? Color.hermesAccent : Color.primary)
      .padding(.horizontal, 18)
      .frame(maxHeight: .infinity)
      .background {
        if isSelected {
          Capsule()
            .fill(Color(.systemBackground).opacity(0.55))
            .matchedGeometryEffect(id: "selectedTab", in: tabSelection)
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tabAccessibilityLabel(title: title, badge: badge))
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private func tabAccessibilityLabel(title: String, badge: Int) -> String {
    switch badge {
    case 0: title
    case 1: "\(title), 1 unread cron run"
    default: "\(title), \(badge) unread cron runs"
    }
  }

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

  /// A cron run (job peek, flat fallback, unmatched runs) as the compact one-line row — a
  /// dense tree surface, like the desktop's cron section. Same affordances as a card.
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
