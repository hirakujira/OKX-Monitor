import Foundation

struct PositionReport: Sendable {
    let perpetuals: [Position]
    let options: [Position]
}

actor OKXReadService {
    private let base: OKXClient
    private let now: @Sendable () -> TimeInterval
    private var clock: (client: OKXClient, time: TimeInterval)?
    private var clockTask: Task<OKXClient, Error>?
    private var instruments: (values: [String: ContractInstrument], time: TimeInterval)?
    private var usdPrices: (values: [USDIndexPrice], time: TimeInterval)?

    init(credentials: Credentials, session: URLSession = OKXClient.makeSession(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        base = OKXClient(credentials: credentials, session: session)
        self.now = now
    }

    func client() async throws -> OKXClient {
        if let clock, now() - clock.time < 600 { return clock.client }
        if let clockTask { return try await clockTask.value }
        let base = base
        let task = Task { try await base.synchronized() }
        clockTask = task
        do {
            let client = try await task.value
            clock = (client, now())
            clockTask = nil
            return client
        } catch {
            clockTask = nil
            throw error
        }
    }

    func invalidateClock() { clock = nil }

    func funding(using client: OKXClient) async throws -> [FundingBalance] {
        let balances: [FundingBalance] = try await client.get(.funding)
        try Task.checkCancellation()
        guard !balances.isEmpty else { return [] }
        if usdPrices.map({ now() - $0.time >= 60 }) ?? true {
            let prices: [USDIndexPrice] = try await client.get(.usdIndexPrices)
            try Task.checkCancellation()
            usdPrices = (prices, now())
        }
        return BalanceValuation.funding(balances, prices: usdPrices?.values ?? [])
    }

    func positions(using client: OKXClient) async throws -> PositionReport {
        let values: [Position] = try await client.get(.positions(nil))
        try Task.checkCancellation()
        let open = values.filter(\.isOpen)
        let swaps = open.filter { $0.instType == "SWAP" }
        let options = open.filter { $0.instType == "OPTION" }
        guard !swaps.isEmpty else { return PositionReport(perpetuals: [], options: options) }

        let missing = swaps.contains { instruments?.values[$0.instId] == nil }
        let age = instruments.map { now() - $0.time } ?? .infinity
        // 規格每小時更新；出現新合約時提早補讀，但不反覆查詢不存在的規格。
        if instruments == nil || age >= 3600 || (missing && age >= 30) {
            let specs: [ContractInstrument] = try await client.get(.swapInstruments)
            try Task.checkCancellation()
            instruments = (Dictionary(specs.map { ($0.instId, $0) }, uniquingKeysWith: { _, latest in latest }), now())
        }
        let enriched = swaps.map { position in
            var position = position
            position.contract = instruments?.values[position.instId]
            return position
        }
        return PositionReport(perpetuals: enriched, options: options)
    }
}
