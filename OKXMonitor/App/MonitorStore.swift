import SwiftUI

struct Resource<Value> {
    var value: Value?
    var error: String?
    var updatedAt: Date?
    mutating func success(_ value: Value) {
        self.value = value
        error = nil
        updatedAt = Date()
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var credentials: Credentials?
    @Published private(set) var isDemo = false
    @Published private(set) var isRefreshing = false
    @Published var storageError: String?
    @Published var valuation = Resource<AssetValuation>()
    @Published var trading = Resource<TradingBalance>()
    @Published var funding = Resource<[FundingBalance]>()
    @Published var perpetuals = Resource<[Position]>()
    @Published var options = Resource<[Position]>()
    @Published var dci = Resource<DCIReport>()
    @Published private(set) var generation = UUID()
    @Published var selectedTab: MonitorTab = .balances
    private var schedule = RefreshSchedule()
    private var service: OKXReadService?
    private var activeRefresh: (scope: RefreshScope, task: Task<Void, Never>)?
    private let session = OKXClient.makeSession()
    var hasAccount: Bool { credentials != nil || isDemo }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
        do { credentials = try KeychainStore.load() }
        catch { storageError = error.localizedDescription }
    }

    func save(_ value: Credentials) throws {
        guard value.isValid else { throw OKXError.invalidCredentials }
        try KeychainStore.save(value)
        clearData()
        credentials = value
        isDemo = false
        storageError = nil
    }

    func remove() throws {
        try KeychainStore.delete()
        clearData()
        credentials = nil
        isDemo = false
    }

    private func clearData() {
        cancelRefresh()
        activeRefresh = nil
        service = nil
        schedule = RefreshSchedule()
        generation = UUID()
        isRefreshing = false
        valuation = Resource()
        trading = Resource()
        funding = Resource()
        perpetuals = Resource()
        options = Resource()
        dci = Resource()
    }

    func showDemo() {
        clearData()
        isDemo = true
        valuation.success(DemoData.valuation)
        trading.success(DemoData.trading)
        funding.success(DemoData.funding)
        perpetuals.success(DemoData.perpetuals)
        options.success(DemoData.options)
        dci.success(DCIReport(orders: DemoData.dci, pageCount: 1))
    }

    func leaveDemo() {
        clearData()
        isDemo = false
    }

    func cancelRefresh() { activeRefresh?.task.cancel() }

    func refresh(force: Bool = false) async {
        guard !isDemo, let credentials else { return }
        let version = generation
        let scope = selectedTab.scope
        while let activeRefresh {
            await activeRefresh.task.value
            guard generation == version, !Task.isCancelled, selectedTab.scope == scope else { return }
            // 同一份進行中的查詢由下拉、按鈕與自動更新共用。
            if activeRefresh.scope == scope { return }
        }
        guard !Task.isCancelled,
              schedule.begin(scope, force: force, now: ProcessInfo.processInfo.systemUptime) else { return }
        let service = self.service ?? OKXReadService(credentials: credentials, session: session)
        self.service = service
        isRefreshing = true
        let task = Task { await performRefresh(scope, service: service, version: version) }
        activeRefresh = (scope, task)
        await task.value
    }

    private enum LoadResult {
        case success, failure(Error), cancelled
    }

    private func performRefresh(_ scope: RefreshScope, service: OKXReadService, version: UUID) async {
        defer {
            if generation == version {
                isRefreshing = false
                activeRefresh = nil
            }
        }
        let results: [LoadResult]
        do {
            let client = try await service.client()
            try Task.checkCancellation()
            guard generation == version else { return }
            switch scope {
            case .balances:
                async let a = load(\MonitorStore.trading, version: version) {
                    let values: [TradingBalance] = try await client.get(.trading)
                    guard let value = values.first else { throw OKXError.invalidResponse }
                    return value
                }
                async let b = load(\MonitorStore.funding, version: version) { try await service.funding(using: client) }
                async let c = load(\MonitorStore.valuation, version: version) {
                    let values: [AssetValuation] = try await client.get(.valuation)
                    guard let value = values.first else { throw OKXError.invalidResponse }
                    return value
                }
                results = await [a, b, c]
            case .positions:
                let report = try await service.positions(using: client)
                try Task.checkCancellation()
                guard generation == version else { return }
                perpetuals.success(report.perpetuals)
                options.success(report.options)
                results = [.success]
            case .dci:
                results = [await load(\MonitorStore.dci, version: version) { try await client.dciOrderReport() }]
            }
        } catch {
            guard generation == version else { return }
            if Task.isCancelled {
                schedule.cancel(scope)
                return
            }
            let message = error.localizedDescription
            switch scope {
            case .balances:
                valuation.error = message
                trading.error = message
                funding.error = message
            case .positions:
                perpetuals.error = message
                options.error = message
            case .dci: dci.error = message
            }
            results = [.failure(error)]
        }
        guard generation == version else { return }
        if Task.isCancelled {
            schedule.cancel(scope)
            return
        }
        let errors = results.compactMap { result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }
        for error in errors {
            if let error = error as? OKXError, case .api("50102") = error {
                await service.invalidateClock()
            }
        }
        guard generation == version else { return }
        schedule.finish(scope, failed: !errors.isEmpty,
                        rateLimited: errors.contains { ($0 as? OKXError)?.isRateLimited == true },
                        now: ProcessInfo.processInfo.systemUptime)
    }

    private func load<Value>(_ keyPath: ReferenceWritableKeyPath<MonitorStore, Resource<Value>>,
                             version: UUID, operation: () async throws -> Value) async -> LoadResult {
        guard generation == version, !Task.isCancelled else { return .cancelled }
        do {
            let value = try await operation()
            guard generation == version, !Task.isCancelled else { return .cancelled }
            self[keyPath: keyPath].success(value)
            return .success
        } catch {
            guard generation == version, !Task.isCancelled else { return .cancelled }
            self[keyPath: keyPath].error = error.localizedDescription
            return .failure(error)
        }
    }

}

enum DemoData {
    static let valuation: AssetValuation = decode(#"{"totalBal":"41122.72","details":{"funding":"7669","trading":"28453.72","earn":"5000","classic":"0"}}"#)
    private static func decode<T: Decodable>(_ json: String) -> T {
        // 內建展示資料在開發時固定驗證，不讀取任何真實帳戶。
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
    static let trading: TradingBalance = decode(#"{"totalEq":"28453.72","details":[{"ccy":"USDT","cashBal":"18420.58","eq":"18753.72","eqUsd":"18753.72","availBal":"12420.58","frozenBal":"6000","liab":"0"},{"ccy":"BTC","cashBal":"0.12","eq":"0.12","eqUsd":"9700","availBal":"0.08","frozenBal":"0.04","liab":"0"}]}"#)
    static let funding: [FundingBalance] = decode(#"[{"ccy":"USDT","bal":"5000","usdValue":"5000","availBal":"5000","frozenBal":"0"},{"ccy":"ETH","bal":"0.85","usdValue":"2669","availBal":"0.85","frozenBal":"0"}]"#)
    static let perpetuals: [Position] = decode(#"[{"contract":{"instId":"BTC-USDT-SWAP","ctType":"linear","ctVal":"0.01","ctValCcy":"BTC"},"posId":"demo-swap","instId":"BTC-USDT-SWAP","instType":"SWAP","pos":"10","posSide":"long","mgnMode":"cross","ccy":"USDT","avgPx":"79200","markPx":"80850","liqPx":"64510","lever":"3","upl":"165","uplRatio":"0.0625","notionalUsd":"8085"},{"contract":{"instId":"ETH-USDT-SWAP","ctType":"linear","ctVal":"0.1","ctValCcy":"ETH"},"posId":"demo-short","instId":"ETH-USDT-SWAP","instType":"SWAP","pos":"-5","posSide":"net","mgnMode":"isolated","ccy":"USDT","avgPx":"3100","markPx":"3140","liqPx":"3700","lever":"5","upl":"-20","uplRatio":"-0.0645","notionalUsd":"1570"}]"#)
    static let options: [Position] = decode(#"[{"posId":"demo-option","instId":"BTC-USD-261225-90000-C","instType":"OPTION","pos":"2","posSide":"net","mgnMode":"cross","ccy":"BTC","avgPx":"0.035","markPx":"0.041","upl":"0.0012","uplRatio":"0.1714","deltaBS":"0.046","gammaBS":"0.000003","thetaBS":"-0.0007","vegaBS":"0.0021"}]"#)
    static let dci: [DCIOrder] = decode(#"[{"cTime":"1795591800000","interestAccrualTime":"1795593600000","baseCcy":"BTC","absYield":"0.003532","ordId":"demo-dci","productId":"BTC-USDT-261127-75000-P","state":"live","notionalSz":"5000","notionalCcy":"USDT","quoteCcy":"USDT","strike":"75000","annualizedYield":"0.1842","expTime":"1795766400000","yieldSz":"17.66","yieldCcy":"USDT"}]"#)
}
