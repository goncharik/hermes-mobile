import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct AppIconPickerFeatureTests {
  private struct Refused: Error {}

  /// A recording client over the full six-icon test catalog: every `set` argument is
  /// appended to `calls`; `fails` makes `set` throw (after recording).
  private func client(
    current: String? = nil,
    calls: LockIsolated<[String?]>,
    fails: Bool = false
  ) -> AppIconClient {
    AppIconClient(
      catalog: { .testCatalog },
      current: { current },
      set: { name in
        calls.withValue { $0.append(name) }
        if fails { throw Refused() }
      }
    )
  }

  private var loadedState: AppIconPickerFeature.State {
    AppIconPickerFeature.State(catalog: .testCatalog, selected: nil)
  }

  // MARK: - Seeding

  @Test func taskSeedsCatalogAndCurrentIcon() async {
    let calls = LockIsolated<[String?]>([])
    let store = TestStore(initialState: AppIconPickerFeature.State()) {
      AppIconPickerFeature()
    } withDependencies: {
      $0.appIcon = client(current: "AppIconHermes", calls: calls)
    }

    await store.send(.task)
    await store.receive(\.loaded) {
      $0.catalog = .testCatalog
      $0.selected = "AppIconHermes"
    }
    #expect(calls.value.isEmpty)
  }

  // MARK: - Selection

  @Test func tappingAnAlternateSetsItAndDelegates() async {
    let calls = LockIsolated<[String?]>([])
    let store = TestStore(initialState: loadedState) {
      AppIconPickerFeature()
    } withDependencies: {
      $0.appIcon = client(calls: calls)
    }

    await store.send(.iconTapped("AppIconHermesClassic")) {
      $0.selected = "AppIconHermesClassic"
    }
    await store.receive(\.delegate, .iconChanged("AppIconHermesClassic"))
    #expect(calls.value == ["AppIconHermesClassic"])
  }

  /// The primary is `setAlternateIconName(nil)`, never its alternate twin.
  @Test func tappingThePrimarySetsNil() async {
    let calls = LockIsolated<[String?]>([])
    let store = TestStore(
      initialState: AppIconPickerFeature.State(catalog: .testCatalog, selected: "AppIconDev")
    ) {
      AppIconPickerFeature()
    } withDependencies: {
      $0.appIcon = client(current: "AppIconDev", calls: calls)
    }

    await store.send(.iconTapped(nil)) { $0.selected = nil }
    await store.receive(\.delegate, .iconChanged(nil))
    #expect(calls.value == [nil])
  }

  @Test func failedSetRollsBackAndBanners() async {
    let calls = LockIsolated<[String?]>([])
    let store = TestStore(
      initialState: AppIconPickerFeature.State(catalog: .testCatalog, selected: "AppIconHermes")
    ) {
      AppIconPickerFeature()
    } withDependencies: {
      $0.appIcon = client(current: "AppIconHermes", calls: calls, fails: true)
    }

    await store.send(.iconTapped("AppIconHermesBlueprint")) {
      $0.selected = "AppIconHermesBlueprint"
    }
    await store.receive(.setFailed(previous: "AppIconHermes")) {
      $0.selected = "AppIconHermes"
      $0.errorBanner = AppIconPickerFeature.setFailedBanner
    }
    // No delegate: the parent's row never shows an icon iOS refused.
    #expect(calls.value == ["AppIconHermesBlueprint"])
  }

  /// A fresh tap clears a stale banner before trying again.
  @Test func nextTapClearsTheBanner() async {
    let calls = LockIsolated<[String?]>([])
    let store = TestStore(
      initialState: AppIconPickerFeature.State(
        catalog: .testCatalog,
        selected: nil,
        errorBanner: AppIconPickerFeature.setFailedBanner
      )
    ) {
      AppIconPickerFeature()
    } withDependencies: {
      $0.appIcon = client(calls: calls)
    }

    await store.send(.iconTapped("AppIconHermes")) {
      $0.selected = "AppIconHermes"
      $0.errorBanner = nil
    }
    await store.receive(\.delegate, .iconChanged("AppIconHermes"))
  }

  /// The last tap wins: a newer tap supersedes a `set` still in flight, so the stale one
  /// never lands a delegate (or a rollback) over the newer choice.
  @Test func newerTapSupersedesAnInFlightSet() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let calls = LockIsolated<[String?]>([])
    let store = TestStore(initialState: loadedState) {
      AppIconPickerFeature()
    } withDependencies: {
      $0.appIcon = AppIconClient(
        catalog: { .testCatalog },
        current: { nil },
        set: { name in
          calls.withValue { $0.append(name) }
          if name == "AppIconHermes" { for await _ in gate { break } }
        }
      )
    }

    await store.send(.iconTapped("AppIconHermes")) { $0.selected = "AppIconHermes" }
    await waitUntil({ calls.value.count == 1 })
    await store.send(.iconTapped("AppIconHermesClassic")) { $0.selected = "AppIconHermesClassic" }
    await store.receive(\.delegate, .iconChanged("AppIconHermesClassic"))
    release.finish()
    #expect(calls.value == ["AppIconHermes", "AppIconHermesClassic"])
  }

  @Test(arguments: [nil, "AppIconHermesClassicBlueprint"] as [String?])
  func tappingTheSelectedIconIsANoOp(selected: String?) async {
    let calls = LockIsolated<[String?]>([])
    let store = TestStore(
      initialState: AppIconPickerFeature.State(
        catalog: .testCatalog,
        selected: selected,
        errorBanner: AppIconPickerFeature.setFailedBanner
      )
    ) {
      AppIconPickerFeature()
    } withDependencies: {
      $0.appIcon = client(current: selected, calls: calls)
    }

    await store.send(.iconTapped(selected))
    #expect(calls.value.isEmpty)
  }

  // MARK: - Tile helpers

  @Test func tileHelpersMapThePrimaryToNil() {
    let primary = AppIconCatalog.testCatalog.primary!
    let hermes = AppIconOption.named("AppIconHermes")!

    let onPrimary = loadedState
    #expect(onPrimary.iconName(for: primary) == nil)
    #expect(onPrimary.iconName(for: hermes) == "AppIconHermes")
    #expect(onPrimary.isSelected(primary))
    #expect(!onPrimary.isSelected(hermes))

    let onHermes = AppIconPickerFeature.State(catalog: .testCatalog, selected: "AppIconHermes")
    #expect(!onHermes.isSelected(primary))
    #expect(onHermes.isSelected(hermes))
  }
}
