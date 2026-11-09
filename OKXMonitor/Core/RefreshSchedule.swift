import Foundation

enum MonitorTab: String, CaseIterable, Identifiable, Sendable {
    case balances = "資產", perpetuals = "永續合約", dci = "雙幣贏", options = "期權"
    var id: String { rawValue }
    var scope: RefreshScope {
        switch self {
        case .balances: .balances
        case .perpetuals, .options: .positions
        case .dci: .dci
        }
    }
}

enum RefreshScope: String, Sendable {
    case balances, positions, dci
    var interval: TimeInterval { self == .dci ? 120 : 30 }
}

struct RefreshSchedule {
    private struct Entry {
        var lastAttempt: TimeInterval = -.infinity
        var nextAutomatic: TimeInterval = 0
        var retryNotBefore: TimeInterval = 0
        var rateLimitFailures = 0
    }
    private var entries: [RefreshScope: Entry] = [:]

    // 使用單調時間，手機校時不會令快取意外長期有效或重複觸發查詢。
    mutating func begin(_ scope: RefreshScope, force: Bool, now: TimeInterval) -> Bool {
        var entry = entries[scope] ?? Entry()
        guard now >= entry.retryNotBefore, now - entry.lastAttempt >= 3,
              force || now >= entry.nextAutomatic else { return false }
        entry.lastAttempt = now
        entry.nextAutomatic = now + scope.interval
        entries[scope] = entry
        return true
    }

    mutating func finish(_ scope: RefreshScope, failed: Bool, rateLimited: Bool, now: TimeInterval) {
        var entry = entries[scope] ?? Entry()
        if rateLimited {
            entry.rateLimitFailures = min(entry.rateLimitFailures + 1, 5)
            let delay = min(30 * pow(2, Double(entry.rateLimitFailures - 1)), 300)
            entry.retryNotBefore = now + delay
            entry.nextAutomatic = entry.retryNotBefore
        } else {
            entry.rateLimitFailures = 0
            entry.retryNotBefore = 0
            entry.nextAutomatic = now + (failed ? 30 : scope.interval)
        }
        entries[scope] = entry
    }

    mutating func cancel(_ scope: RefreshScope) {
        entries[scope]?.nextAutomatic = 0
    }
}
