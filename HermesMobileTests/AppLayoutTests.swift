import ComposableArchitecture
import HermesKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

@MainActor
final class AppLayoutTests: XCTestCase {
  func testRegularWidthAndHeightUseTheExistingSplitLayout() {
    let host = LayoutHost()
    host.render(horizontal: .regular, vertical: .regular)
    XCTAssertEqual(host.store.layout, .regular)
  }

  func testNarrowOrUnresolvedSizeClassesUseTheStack() {
    let host = LayoutHost()
    for (horizontal, vertical): (UserInterfaceSizeClass?, UserInterfaceSizeClass?) in [
      (.compact, .regular), (.compact, .compact), (nil, .regular), (.regular, nil)
    ] {
      host.render(horizontal: horizontal, vertical: vertical)
      XCTAssertEqual(host.store.layout, .compact)
    }
  }

  func testHeightChangesUpdateTheLayoutWithoutAWidthChange() {
    let host = LayoutHost()
    host.render(horizontal: .regular, vertical: .regular)
    XCTAssertEqual(host.store.layout, .regular)

    // A landscape phone can keep regular width while its height becomes compact.
    host.render(horizontal: .regular, vertical: .compact)
    XCTAssertEqual(host.store.layout, .compact)

    host.render(horizontal: .regular, vertical: .regular)
    XCTAssertEqual(host.store.layout, .regular)
  }

  func testSplitChatRendersOnceInTheDetailColumn() throws {
    let store = withDependencies {
      $0.continuousClock = ContinuousClock()
    } operation: {
      DemoMode.makeStore()
    }
    let host = LayoutHost(store: store)
    host.render(horizontal: .regular, vertical: .regular)
    let transcript = try XCTUnwrap(host.descendants(of: TranscriptCollectionView.self).first)
    let composer = try XCTUnwrap(host.descendants(of: ComposerInputTextView.self).first)
    XCTAssertEqual(host.descendants(of: ComposerInputTextView.self).count, 1)
    XCTAssertEqual(host.descendants(of: TranscriptCollectionView.self).count, 1)
    XCTAssertGreaterThan(transcript.bounds.width, host.window.bounds.width / 2)
    XCTAssertGreaterThan(composer.convert(composer.bounds, to: host.window).minX, 280)
  }
}

@MainActor
private final class LayoutHost {
  let store: StoreOf<AppFeature>
  private let controller = UIHostingController(rootView: AnyView(EmptyView()))
  let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 950, height: 670))

  init(store: StoreOf<AppFeature>? = nil) {
    self.store = store ?? Store(initialState: AppFeature.State()) {
      AppFeature().ignoring(\.task)
    }
    window.rootViewController = controller
    window.isHidden = false
  }

  func render(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) {
    controller.rootView = AnyView(
      AppView(store: store)
        .environment(\.horizontalSizeClass, horizontal)
        .environment(\.verticalSizeClass, vertical)
        .dynamicTypeSize(.large)
    )
    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }

  func descendants<T: UIView>(of type: T.Type) -> [T] {
    func collect(_ view: UIView) -> [T] {
      ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(collect)
    }
    return collect(controller.view)
  }

  deinit {
    MainActor.assumeIsolated {
      window.isHidden = true
      window.rootViewController = nil
    }
  }
}
