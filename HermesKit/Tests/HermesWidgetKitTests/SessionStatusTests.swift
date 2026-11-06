import Foundation
import HermesWidgetKit
import Testing

struct SessionStatusTests {
  /// The raw values are the App Group mirror's wire format: renaming a case must fail here.
  @Test func codableUsesStableRawValues() throws {
    let all: [SessionStatus] = [.needsInput, .working, .unread, .idle]
    let data = try JSONEncoder().encode(all)
    #expect(String(decoding: data, as: UTF8.self) == #"["needsInput","working","unread","idle"]"#)
    #expect(try JSONDecoder().decode([SessionStatus].self, from: data) == all)
  }

  @Test func flagsResolveInPriorityOrder() {
    #expect(SessionStatus(needsInput: true, isWorking: true, isUnread: true) == .needsInput)
    #expect(SessionStatus(needsInput: false, isWorking: true, isUnread: true) == .working)
    #expect(SessionStatus(needsInput: false, isWorking: false, isUnread: true) == .unread)
    #expect(SessionStatus(needsInput: false, isWorking: false, isUnread: false) == .idle)
  }
}
