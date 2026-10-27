import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Toggles the system idle timer (auto-lock) so the screen stays awake during the hands-off
/// read-aloud loop. Wraps `UIApplication.isIdleTimerDisabled` behind a dependency so
/// `ChatFeature` never touches UIKit directly; the reducer owns the policy
/// (`wantsScreenAwake`) and only reports edges through `setDisabled`.
@DependencyClient
public struct IdleTimerClient: Sendable {
  /// `true` keeps the screen awake (idle timer disabled); `false` restores auto-lock.
  /// SYNCHRONOUS on purpose: reducers call it in reduction order, and the live value applies
  /// the calls in that same order (one FIFO main-queue hop each). An `Effect.run` per edge
  /// would not — two runs can reach the main actor in either order and leave auto-lock off.
  public var setDisabled: @Sendable (_ disabled: Bool) -> Void
}

extension IdleTimerClient: DependencyKey {
  /// No-op double. Override `setDisabled` with a recorder to assert the transitions.
  /// (Spelled out so the `@DependencyClient` macro's unimplemented closure doesn't leak
  /// into the default.)
  public static var testValue: IdleTimerClient {
    IdleTimerClient(setDisabled: { _ in })
  }
}

public extension DependencyValues {
  var idleTimer: IdleTimerClient {
    get { self[IdleTimerClient.self] }
    set { self[IdleTimerClient.self] = newValue }
  }
}

// MARK: - Live (iOS only)

// `UIApplication` is iOS-only; the package is also built/tested on macOS via `swift test`,
// so the live wrapper is compiled in only where UIKit exists. Elsewhere `liveValue` falls
// back to the no-op double.
#if canImport(UIKit)
  import UIKit

  extension IdleTimerClient {
    public static var liveValue: IdleTimerClient {
      IdleTimerClient(setDisabled: { disabled in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            UIApplication.shared.isIdleTimerDisabled = disabled
          }
        }
      })
    }
  }
#else
  extension IdleTimerClient {
    /// No idle timer off-device (macOS `swift test`): the no-op double.
    public static var liveValue: IdleTimerClient { testValue }
  }
#endif
