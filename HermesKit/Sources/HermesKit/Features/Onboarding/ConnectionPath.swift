import ComposableArchitecture
import Foundation

/// The onboarding navigation stack (#136): Welcome is the root `ConnectionView` renders, and
/// the two steps push over it. Top-level (not nested in `ConnectionFeature`) per the TCA stack
/// idiom; `ConnectionFeature` appends every element in the reducer so each push is a
/// `TestStore` assertion.
///
/// Popping an element (swipe-back, or Sign in's "Change") cancels that element's effects —
/// which is what abandons an in-flight OAuth attempt when the user leaves Sign in.
@Reducer
public enum ConnectionPath {
  case server(ServerStep)
  case signIn(SignInStep)
}

extension ConnectionPath.State: Equatable {}
