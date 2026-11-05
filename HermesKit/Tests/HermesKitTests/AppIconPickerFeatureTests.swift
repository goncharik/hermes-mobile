import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct AppIconPickerFeatureTests {
  private struct Refused: Error {}

  /// A recording client over the full test catalog: every `set` argument is
  /// appended to `calls`; `fails` makes `set` throw (after recording) and leaves `current`.
  private func client(
    current: String? = nil,
    calls: LockIsolated<[String?]>,
    fails: Bool = false
  ) -> AppIconClient {
    let currentIcon = LockIsolated(current)
    return AppIconClient(
      catalog: { .testCatalog },
      current: { currentIcon.value },
      set: { name in
        calls.withValue { $0.append(name) }
        if fails { throw Refused() }
        currentIcon.setValue(name)
      }
    )
  }

  private var loadedState: AppIconPickerFeature.State {
    AppIconPickerFeature.State(catalog: .testCatalog, selected: nil)
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
      $0.isApplying = true
    }
    await store.receive(.setSucceeded("AppIconHermesClassic")) { $0.isApplying = false }
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

    await store.send(.iconTapped(nil)) {
      $0.selected = nil
      $0.isApplying = true
    }
    await store.receive(.setSucceeded(nil)) { $0.isApplying = false }
    await store.receive(\.delegate, .iconChanged(nil))
    #expect(calls.value == [nil])
  }

  /// A refusal shows what iOS actually has (re-read), banners, and reports it to the parent.
  @Test func failedSetRollsBackToTheCurrentIconAndBanners() async {
    let calls = LockIsolated<[String?]>([])
    let store = TestStore(
      initialState: AppIconPickerFeature.State(catalog: .testCatalog, selected: "AppIconHermesNeo")
    ) {
      AppIconPickerFeature()
    } withDependencies: {
      $0.appIcon = client(current: "AppIconHermesNeo", calls: calls, fails: true)
    }

    await store.send(.iconTapped("AppIconHermesNeoBlueprint")) {
      $0.selected = "AppIconHermesNeoBlueprint"
      $0.isApplying = true
    }
    await store.receive(.setFailed(current: "AppIconHermesNeo")) {
      $0.selected = "AppIconHermesNeo"
      $0.errorBanner = AppIconPickerFeature.setFailedBanner
      $0.isApplying = false
    }
    await store.receive(\.delegate, .iconChanged("AppIconHermesNeo"))
    #expect(calls.value == ["AppIconHermesNeoBlueprint"])
  }

  /// The rollback target is what iOS reports after the refusal, not the checkmark before the
  /// tap: here the seed was stale (another change landed meanwhile) and iOS has Hermes Classic.
  @Test func failedSetRollsBackToWhatIOSReportsNotTheOldCheckmark() async {
    let store = TestStore(initialState: loadedState) {
      AppIconPickerFeature()
    } withDependencies: {
      $0.appIcon = AppIconClient(
        catalog: { .testCatalog },
        current: { "AppIconHermesClassic" },
        set: { _ in throw Refused() }
      )
    }

    await store.send(.iconTapped("AppIconHermesNeo")) {
      $0.selected = "AppIconHermesNeo"
      $0.isApplying = true
    }
    await store.receive(.setFailed(current: "AppIconHermesClassic")) {
      $0.selected = "AppIconHermesClassic"
      $0.errorBanner = AppIconPickerFeature.setFailedBanner
      $0.isApplying = false
    }
    await store.receive(\.delegate, .iconChanged("AppIconHermesClassic"))
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

    await store.send(.iconTapped("AppIconHermesNeo")) {
      $0.selected = "AppIconHermesNeo"
      $0.errorBanner = nil
      $0.isApplying = true
    }
    await store.receive(.setSucceeded("AppIconHermesNeo")) { $0.isApplying = false }
    await store.receive(\.delegate, .iconChanged("AppIconHermesNeo"))
  }

  /// One change at a time: a tap while a `set` is in flight is ignored (cancelling the effect
  /// would not stop the UIKit change, so a second one could race it).
  @Test func tapWhileApplyingIsIgnored() async {
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
          for await _ in gate { break }
        }
      )
    }

    await store.send(.iconTapped("AppIconHermesNeo")) {
      $0.selected = "AppIconHermesNeo"
      $0.isApplying = true
    }
    await waitUntil({ calls.value.count == 1 })
    await store.send(.iconTapped("AppIconHermesClassic"))
    release.finish()
    await store.receive(.setSucceeded("AppIconHermesNeo")) { $0.isApplying = false }
    await store.receive(\.delegate, .iconChanged("AppIconHermesNeo"))
    #expect(calls.value == ["AppIconHermesNeo"])
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
    let hermes = AppIconOption.named("AppIconHermesNeo")!

    let onPrimary = loadedState
    #expect(onPrimary.iconName(for: primary) == nil)
    #expect(onPrimary.iconName(for: hermes) == "AppIconHermesNeo")
    #expect(onPrimary.isSelected(primary))
    #expect(!onPrimary.isSelected(hermes))

    let onHermes = AppIconPickerFeature.State(catalog: .testCatalog, selected: "AppIconHermesNeo")
    #expect(!onHermes.isSelected(primary))
    #expect(onHermes.isSelected(hermes))
  }
}
