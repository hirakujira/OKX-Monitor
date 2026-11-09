import XCTest
import Foundation
@testable import OKXMonitorCore

private final class ReadFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 100
    private var requests: [String: Int] = [:]
    private var queries: [String?] = []
    private var specificationFails = false
    private var emptyFunding = false
    private var pricesFail = false
    private var symbol = "ETH"
    var now: TimeInterval { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant += seconds } }
    func count(_ path: String) -> Int { lock.withLock { requests[path, default: 0] } }
    var positionQueries: [String?] { lock.withLock { queries } }
    func failSpecifications() { lock.withLock { specificationFails = true } }
    func useUnknownSymbol() { lock.withLock { symbol = "UNKNOWN" } }
    func clearFunding() { lock.withLock { emptyFunding = true } }
    func failPrices() { lock.withLock { pricesFail = true } }

    func response(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            let path = request.url!.path
            requests[path, default: 0] += 1
            let json: String
            switch path {
            case "/api/v5/public/time":
                json = #"{"code":"0","data":[{"ts":"1794247200000"}]}"#
            case "/api/v5/asset/balances":
                json = emptyFunding ? #"{"code":"0","data":[]}"#
                    : #"{"code":"0","data":[{"ccy":"BTC","bal":"0.01"},{"ccy":"USDT","bal":"100"}]}"#
            case "/api/v5/market/index-tickers":
                json = pricesFail ? #"{"code":"50011","data":[]}"#
                    : #"{"code":"0","data":[{"instId":"BTC-USD","idxPx":"75000"},{"instId":"USDT-USD","idxPx":"0.998"}]}"#
            case "/api/v5/account/positions":
                queries.append(request.url?.query)
                json = """
                {"code":"0","data":[
                {"posId":"1","instId":"\(symbol)-USDT-SWAP","instType":"SWAP","pos":"-63.16","posSide":"net"},
                {"posId":"2","instId":"BTC-USD-261225-90000-C","instType":"OPTION","pos":"2","posSide":"net"},
                {"posId":"3","instId":"BTC-USDT","instType":"MARGIN","pos":"1","posSide":"net"},
                {"posId":"4","instId":"BTC-USDT-SWAP","instType":"SWAP","pos":"0","posSide":"net"}]}
                """
            case "/api/v5/public/instruments":
                json = specificationFails ? #"{"code":"50011","data":[]}"#
                    : #"{"code":"0","data":[{"instId":"ETH-USDT-SWAP","ctType":"linear","ctVal":"0.1","ctValCcy":"ETH"}]}"#
            default:
                json = #"{"code":"0","data":[]}"#
            }
            return (200, Data(json.utf8))
        }
    }

    func service() -> OKXReadService {
        MockURLProtocol.handler = { [self] in response($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return OKXReadService(credentials: Credentials(apiKey: "test", secretKey: "test", passphrase: "test"),
                              session: URLSession(configuration: configuration), now: { [self] in now })
    }
}

final class ReadServiceTests: XCTestCase, @unchecked Sendable {
    func testFundingPriceBatchIsCachedForSixtySecondsAndSkippedForEmptyAccount() async throws {
        let fixture = ReadFixture()
        let service = fixture.service()
        let client = try await service.client()
        let balances = try await service.funding(using: client)
        XCTAssertEqual(balances.map(\.usdValue), ["750", "99.8"])
        fixture.advance(59)
        _ = try await service.funding(using: client)
        XCTAssertEqual(fixture.count("/api/v5/market/index-tickers"), 1)
        fixture.advance(1)
        _ = try await service.funding(using: client)
        XCTAssertEqual(fixture.count("/api/v5/market/index-tickers"), 2)
        XCTAssertEqual(fixture.count("/api/v5/asset/balances"), 3)
        fixture.clearFunding()
        fixture.advance(60)
        let empty = try await service.funding(using: client)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(fixture.count("/api/v5/market/index-tickers"), 2)
    }

    func testExpiredFundingPricesFailureDoesNotReturnStaleValuationsAsFresh() async throws {
        let fixture = ReadFixture()
        let service = fixture.service()
        let client = try await service.client()
        _ = try await service.funding(using: client)
        fixture.advance(60)
        fixture.failPrices()
        do {
            _ = try await service.funding(using: client)
            XCTFail("美元估值更新失敗不可標示為完整的新資料")
        } catch { XCTAssertTrue((error as? OKXError)?.isRateLimited == true) }
    }

    func testConcurrentTimeSynchronizationIsSharedAndExpires() async throws {
        let fixture = ReadFixture()
        let service = fixture.service()
        async let first = service.client()
        async let second = service.client()
        _ = try await (first, second)
        XCTAssertEqual(fixture.count("/api/v5/public/time"), 1)
        fixture.advance(599)
        _ = try await service.client()
        XCTAssertEqual(fixture.count("/api/v5/public/time"), 1)
        fixture.advance(1)
        _ = try await service.client()
        XCTAssertEqual(fixture.count("/api/v5/public/time"), 2)
        await service.invalidateClock()
        _ = try await service.client()
        XCTAssertEqual(fixture.count("/api/v5/public/time"), 3)
    }

    func testCombinedPositionsUseOneRequestAndReuseSpecifications() async throws {
        let fixture = ReadFixture()
        let service = fixture.service()
        let client = try await service.client()
        let first = try await service.positions(using: client)
        XCTAssertEqual(first.perpetuals.count, 1)
        XCTAssertEqual(first.perpetuals[0].quantityText, "-6.316 ETH")
        XCTAssertEqual(first.options.count, 1)
        XCTAssertEqual(first.options[0].quantityText, "2 張")
        fixture.advance(30)
        _ = try await service.positions(using: client)
        XCTAssertEqual(fixture.count("/api/v5/account/positions"), 2)
        XCTAssertTrue(fixture.positionQueries.allSatisfy { $0 == nil })
        XCTAssertEqual(fixture.count("/api/v5/public/instruments"), 1)
        XCTAssertEqual(fixture.count("/api/v5/public/time"), 1)
        fixture.advance(3570)
        _ = try await service.positions(using: client)
        XCTAssertEqual(fixture.count("/api/v5/public/instruments"), 2)
    }

    func testUnknownContractRefreshIsBoundedAndDoesNotReuseWrongSpec() async throws {
        let fixture = ReadFixture()
        let service = fixture.service()
        let client = try await service.client()
        _ = try await service.positions(using: client)
        fixture.useUnknownSymbol()
        let missing = try await service.positions(using: client)
        XCTAssertEqual(missing.perpetuals[0].quantityText, "暫無換算資料")
        XCTAssertEqual(fixture.count("/api/v5/public/instruments"), 1)
        fixture.advance(30)
        _ = try await service.positions(using: client)
        XCTAssertEqual(fixture.count("/api/v5/public/instruments"), 2)
        _ = try await service.positions(using: client)
        XCTAssertEqual(fixture.count("/api/v5/public/instruments"), 2)
    }

    func testExpiredSpecificationsFailureDoesNotSilentlyUseOldValues() async throws {
        let fixture = ReadFixture()
        let service = fixture.service()
        let client = try await service.client()
        _ = try await service.positions(using: client)
        fixture.advance(3600)
        fixture.failSpecifications()
        do {
            _ = try await service.positions(using: client)
            XCTFail("規格更新失敗不可標示為完整的新資料")
        } catch { XCTAssertTrue((error as? OKXError)?.isRateLimited == true) }
    }

    func testNewAccountServiceDoesNotReusePreviousClockOrSpecifications() async throws {
        let fixture = ReadFixture()
        let first = fixture.service()
        _ = try await first.positions(using: first.client())
        let second = fixture.service()
        _ = try await second.positions(using: second.client())
        XCTAssertEqual(fixture.count("/api/v5/public/time"), 2)
        XCTAssertEqual(fixture.count("/api/v5/public/instruments"), 2)
    }
}
