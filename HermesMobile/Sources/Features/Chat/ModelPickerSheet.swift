import ComposableArchitecture
import HermesKit
import SwiftUI

/// Interactive model + reasoning-effort picker (#81, redesigned for #130). Renders the pure
/// `ModelPickerLayout` derivation as cards: an Options card whose `Reasoning` row pushes the
/// effort list, a Favorites card of starred models, then one collapsible card per provider
/// (configured providers only — the fetch sends `explicit_only: true`; a lost-credential
/// current provider shows its `warning` over its saved model, disabled). Every rule — section order,
/// favorites resolution, collapse, search, the scroll target — lives in the layout; the view
/// only iterates it and centers on `scrollTarget` once per presentation.
///
/// Driven by the presented `ModelPickerFeature` store (it loads `model.options` and the
/// collapse/favorites prefs on `.task`); the chat-owned display inputs (current model +
/// effort, busy, the max/ultra latch) are parameters.
struct ModelPickerSheet: View {
  let store: StoreOf<ModelPickerFeature>
  let currentModel: String?
  let currentEffort: String?
  let isBusy: Bool
  /// `ChatFeature.State.extendedReasoningSupported`: false hides `max`/`ultra` after this
  /// slot's agent rejected one.
  var extendedReasoningSupported: Bool = true

  /// Internal (not private) only so a snapshot can seed the search state through the
  /// memberwise init; production always opens with an empty query.
  @State var searchText = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The list centers on the current model ONCE per presentation — never again after the
  /// user scrolls, collapses a card, or comes back from the effort page.
  @State private var hasCentered = false
  @State private var isShowingEfforts = false

  var body: some View {
    NavigationStack {
      Group {
        if store.isLoading {
          ProgressView("Loading models…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.error {
          ContentUnavailableView("Couldn’t load models", systemImage: "exclamationmark.triangle",
                                 description: Text(error))
        } else if let options = store.options {
          modelList(ModelPickerLayout(
            options: options,
            favorites: store.favorites,
            collapsedProviders: store.collapsedProviders,
            query: searchText,
            currentModel: currentModel
          ))
        }
      }
      .navigationTitle("Model")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, placement: searchPlacement, prompt: "Search models")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", systemImage: "checkmark") { store.send(.doneButtonTapped) }
        }
      }
      .navigationDestination(isPresented: $isShowingEfforts) {
        ReasoningEffortList(
          store: store,
          currentEffort: currentEffort,
          isBusy: isBusy,
          extendedReasoningSupported: extendedReasoningSupported
        )
      }
    }
    .task { store.send(.task) }
  }

  /// iOS 18's automatic placement is a nav-bar drawer that collapses once the list scrolls —
  /// which the open-time centering does — so pin it there; iOS 26 keeps its default.
  private var searchPlacement: SearchFieldPlacement {
    if #available(iOS 26, *) { .automatic } else { .navigationBarDrawer(displayMode: .always) }
  }

  private func modelList(_ layout: ModelPickerLayout) -> some View {
    ScrollViewReader { proxy in
      List {
        // An apply failure keeps the list usable — the rolled-back row is right below.
        if let applyError = store.applyError {
          Section {
            Label(applyError, systemImage: "exclamationmark.triangle")
              .font(.footnote).foregroundStyle(.red)
          }
        }
        if isBusy {
          Section {
            Label("Finish or stop the current turn to switch models.", systemImage: "hourglass")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }
        ForEach(layout.sections) { section in
          switch section {
          case .options:
            optionsSection
          case let .favorites(rows):
            Section("Favorites") {
              ForEach(rows) { modelRow($0) }
            }
          case let .provider(providerSection):
            providerCard(providerSection)
          }
        }
      }
      .listStyle(.insetGrouped)
      .overlay {
        if layout.sections.isEmpty && !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
          ContentUnavailableView.search(text: searchText)
        }
      }
      .task { listAppeared(scrollTarget: layout.scrollTarget, proxy: proxy) }
    }
  }

  /// Centers the current model the first time the loaded list appears (the `.task` fires
  /// again after popping back from the effort page — `hasCentered` keeps that a no-op).
  private func listAppeared(scrollTarget: String?, proxy: ScrollViewProxy) {
    guard !hasCentered else { return }
    hasCentered = true
    guard let scrollTarget else { return }
    proxy.scrollTo(scrollTarget, anchor: .center)
  }

  // MARK: Options card

  private var optionsSection: some View {
    Section("Options") {
      Button {
        isShowingEfforts = true
      } label: {
        HStack {
          Text("Reasoning").foregroundStyle(isBusy ? .secondary : .primary)
          Spacer()
          Text(currentEffort.flatMap { $0.isEmpty ? nil : $0 } ?? "Default")
            .foregroundStyle(.secondary)
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(isBusy)
      .accessibilityHint("Shows the reasoning effort levels")
    }
  }

  // MARK: Provider cards

  private func providerCard(_ section: ModelPickerLayout.ProviderSection) -> some View {
    Section {
      if !section.isSelectable && !section.isCollapsed {
        Label(section.provider.warning ?? "Not configured", systemImage: "lock")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach(section.rows) { modelRow($0, isSelectable: section.isSelectable) }
    } header: {
      providerHeader(section)
    }
  }

  /// The collapse toggle — inert while searching (every card is forced open). The section's
  /// own `ForEach(layout.sections)` id is the scroll target for a collapsed card; the header
  /// carries no `.id` of its own.
  @ViewBuilder
  private func providerHeader(_ section: ModelPickerLayout.ProviderSection) -> some View {
    if section.isCollapsible {
      Button {
        store.send(.providerHeaderTapped(section.provider.id), animation: reduceMotion ? nil : .snappy)
      } label: {
        providerHeaderLabel(section)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(headerAccessibilityLabel(section))
      .accessibilityValue(section.isCollapsed ? "Collapsed" : "Expanded")
      .accessibilityHint(section.isCollapsed ? "Expand" : "Collapse")
      .accessibilityAddTraits(.isHeader)
    } else {
      providerHeaderLabel(section)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerAccessibilityLabel(section))
        .accessibilityAddTraits(.isHeader)
    }
  }

  private func providerHeaderLabel(_ section: ModelPickerLayout.ProviderSection) -> some View {
    HStack(spacing: 6) {
      Text(section.provider.name)
      if section.isCollapsed && section.modelCount > 0 {
        Text("\(section.modelCount)")
          .monospacedDigit()
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      if let current = section.currentModelName {
        Text(current)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "checkmark")
          .fontWeight(.semibold)
          .foregroundStyle(Color.hermesAccent)
      }
      Image(systemName: "chevron.down")
        .fontWeight(.semibold)
        .rotationEffect(.degrees(section.isCollapsed ? -90 : 0))
    }
    .textCase(nil)
    .contentShape(.rect)
  }

  private func headerAccessibilityLabel(_ section: ModelPickerLayout.ProviderSection) -> String {
    var label = section.provider.name
    if section.isCollapsed && section.modelCount > 0 {
      label += ", \(section.modelCount) \(section.modelCount == 1 ? "model" : "models")"
    }
    if let current = section.currentModelName { label += ", current model \(current)" }
    return label
  }

  // MARK: Model rows

  /// A model row (tap applies; disabled while busy) with its own star button (always
  /// enabled — favorites are display-only). Both buttons are `.plain` so a `List` row keeps
  /// two separate tap targets instead of firing both. A non-configured card's row
  /// (`isSelectable == false`: the lost-credential saved model) is disabled and has no star.
  private func modelRow(_ row: ModelPickerLayout.Row, isSelectable: Bool = true) -> some View {
    HStack(spacing: 12) {
      Button {
        store.send(.modelRowTapped(model: row.model, providerSlug: row.providerSlug))
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(row.model).foregroundStyle(isBusy || !isSelectable ? .secondary : .primary)
            if row.showsProviderCaption {
              Text(row.providerName).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          if row.isCurrent {
            Image(systemName: "checkmark").foregroundStyle(Color.hermesAccent).fontWeight(.semibold)
          }
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(isBusy || !isSelectable)
      .accessibilityAddTraits(row.isCurrent ? .isSelected : [])

      if isSelectable {
        Button {
          store.send(.starButtonTapped(row.favorite), animation: reduceMotion ? nil : .snappy)
        } label: {
          Image(systemName: row.isFavorite ? "star.fill" : "star")
            .foregroundStyle(row.isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.isFavorite ? "Remove from favorites" : "Add to favorites")
      }
    }
    .id(row.id)
  }
}

/// The pushed reasoning-effort page behind the Options card's `Reasoning` row. Lists the
/// FULL upstream scale (`none … xhigh, max, ultra`) — the server clamps per provider on the
/// wire — except once this slot's agent rejected an extended level
/// (`extendedReasoningSupported == false`), when `max`/`ultra` drop out. The filter is
/// `ModelOptions.offeredEfforts(extendedSupported:)`. A tap applies and pops back.
struct ReasoningEffortList: View {
  let store: StoreOf<ModelPickerFeature>
  let currentEffort: String?
  let isBusy: Bool
  var extendedReasoningSupported: Bool = true

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      if isBusy {
        Section {
          Label("Finish or stop the current turn to change reasoning.", systemImage: "hourglass")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      Section {
        ForEach(ModelOptions.offeredEfforts(extendedSupported: extendedReasoningSupported), id: \.self) { effort in
          Button {
            effortRowTapped(effort)
          } label: {
            HStack {
              Text(effort).foregroundStyle(isBusy ? .secondary : .primary)
              Spacer()
              if effort == currentEffort {
                Image(systemName: "checkmark").foregroundStyle(Color.hermesAccent).fontWeight(.semibold)
              }
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .disabled(isBusy)
          .accessibilityAddTraits(effort == currentEffort ? .isSelected : [])
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Reasoning")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func effortRowTapped(_ effort: String) {
    store.send(.effortRowTapped(effort))
    dismiss()
  }
}
