// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RationbookCore

@Suite struct ClaudeRefreshTests {
    @Test(arguments: ClaudeRefreshInterval.allCases)
    func respectsSelectedInterval(_ interval: ClaudeRefreshInterval) {
        let now = Date(timeIntervalSince1970: 10_000)
        let due = now.addingTimeInterval(-Double(interval.rawValue * 60))
        #expect(interval.isDue(lastAttempt: nil, observations: [], now: now) == (interval != .manual))
        #expect(interval.isDue(lastAttempt: due, observations: [due], now: now) == (interval != .manual))
        #expect(!interval.isDue(lastAttempt: now, observations: [due], now: now))
        #expect(!interval.isDue(lastAttempt: due, observations: [now], now: now))
    }
}
