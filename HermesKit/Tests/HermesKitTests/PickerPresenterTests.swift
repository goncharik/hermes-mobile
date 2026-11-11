import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// The picker presenter's lifetime contract (#170): it lives exactly as long as its picker and
/// reports exactly once. A plain `NSObject` stands in for the UIKit picker.
@MainActor
struct PickerPresenterTests {
  private let picked = PickedBatch(
    items: [PickedItem(data: Data([1]), filename: "photo.jpg", mimeType: "image/jpeg", kind: .image)]
  )

  /// A presenter owned only by `picker`, plus a weak handle and the batches it reported.
  private func attachedPresenter(
    to picker: NSObject
  ) -> (presenter: () -> PickerPresenter?, reports: LockIsolated<[PickedBatch]>) {
    let reports = LockIsolated<[PickedBatch]>([])
    let presenter = PickerPresenter { batch in reports.withValue { $0.append(batch) } }
    presenter.attach(to: picker)
    return ({ [weak presenter] in presenter }, reports)
  }

  @Test func picker_keepsItsPresenterAlive_untilItGoes() {
    var picker: NSObject? = NSObject()
    let (presenter, reports) = attachedPresenter(to: picker!)

    // A delayed presentation: nobody but the picker holds the presenter, and it must still be
    // there for Done/Cancel.
    #expect(presenter() != nil)
    #expect(reports.value.isEmpty)

    presenter()?.finish(picked)
    #expect(reports.value == [picked])

    // Dismissed: the picker goes, the presenter with it, without a second report.
    picker = nil
    #expect(presenter() == nil)
    #expect(reports.value == [picked])
  }

  @Test func pickerGoneWithoutCallback_reportsTheEmptyBatch() {
    // A refused presentation: UIKit drops the picker and no delegate callback ever comes.
    var picker: NSObject? = NSObject()
    let (presenter, reports) = attachedPresenter(to: picker!)

    picker = nil
    #expect(presenter() == nil)
    #expect(reports.value == [PickedBatch()])
  }

  @Test func finish_reportsOnlyOnce() {
    let picker = NSObject()
    let (presenter, reports) = attachedPresenter(to: picker)

    presenter()?.finish(picked)
    presenter()?.finish(PickedBatch())
    #expect(reports.value == [picked])
  }
}
