import XCTest
import Foundation
@testable import OKXMonitorCore

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class OKXClientTests: XCTestCase, @unchecked Sendable {
    let credentials = Credentials(apiKey: "test-key", secretKey: "test-secret", passphrase: "test-passphrase")
    func client(response: String, status: Int = 200) -> OKXClient {
        MockURLProtocol.handler = { _ in (status, Data(response.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return OKXClient(credentials: credentials, session: URLSession(configuration: configuration))
    }

    func testSignatureUsesQueryAndBase64HMAC() throws {
        let client = OKXClient(credentials: credentials)
        let date = ISO8601DateFormatter().date(from: "2026-11-09T18:00:00Z")!
        let request = try client.request(.positions("SWAP"), date: date)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://openapi.okx.com/api/v5/account/positions?instType=SWAP")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OK-ACCESS-SIGN"), "MWJJCRAbuUGTa8jNm8pt8iw9M1BYmjjgsRiJbK+LPho=")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OK-ACCESS-TIMESTAMP"), "2026-11-09T18:00:00.000Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OK-ACCESS-PASSPHRASE"), "test-passphrase")
        XCTAssertNil(request.httpBody)
    }

    func testPublicTimeHasNoCredentials() throws {
        let request = try OKXClient(credentials: credentials).request(.time)
        XCTAssertNil(request.value(forHTTPHeaderField: "OK-ACCESS-KEY"))
        XCTAssertNil(request.value(forHTTPHeaderField: "OK-ACCESS-SIGN"))
    }

    func testSwapInstrumentsArePublicAndRequestContractSpecifications() throws {
        let request = try OKXClient(credentials: Credentials()).request(.swapInstruments)
        XCTAssertEqual(request.url?.absoluteString, "https://openapi.okx.com/api/v5/public/instruments?instType=SWAP")
        XCTAssertEqual(request.httpMethod, "GET")
        for header in ["OK-ACCESS-KEY", "OK-ACCESS-SIGN", "OK-ACCESS-PASSPHRASE", "OK-ACCESS-TIMESTAMP"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header))
        }
    }

    private func swapPosition(id: String = "ETH-USDT-SWAP", quantity: String, side: String = "net", price: String = "2000") throws -> Position {
        let data = try JSONSerialization.data(withJSONObject: ["posId": "test", "instId": id, "instType": "SWAP",
            "pos": quantity, "posSide": side, "markPx": price, "avgPx": "1000"])
        return try JSONDecoder().decode(Position.self, from: data)
    }

    func testLinearQuantityUsesFaceValueAndPreservesSideAndPrecision() throws {
        for (raw, side, expected, short) in [("-63.16", "net", "-6.316 ETH", true),
                                            ("63.16", "short", "6.316 ETH", true),
                                            ("63.16", "long", "6.316 ETH", false),
                                            ("0.00000001", "net", "0.000000001 ETH", false)] {
            var position = try swapPosition(quantity: raw, side: side)
            position.contract = ContractInstrument(instId: position.instId, ctType: "linear", ctVal: "0.1", ctValCcy: "ETH")
            XCTAssertEqual(position.quantityText, expected)
            XCTAssertEqual(position.isShort, short)
        }
    }

    func testInverseQuantityUsesMarkPriceInsteadOfEntryPrice() throws {
        var position = try swapPosition(id: "BTC-USD-SWAP", quantity: "-10", price: "25000")
        position.contract = ContractInstrument(instId: position.instId, ctType: "inverse", ctVal: "100", ctValCcy: "USD")
        XCTAssertEqual(position.quantityText, "-0.04 BTC")
        for price in ["", "0", "-1", "invalid"] {
            var invalid = try swapPosition(id: position.instId, quantity: "10", price: price)
            invalid.contract = position.contract
            XCTAssertNil(invalid.baseQuantity)
            XCTAssertEqual(invalid.quantityText, "暫無換算資料")
        }
    }

    func testMissingOrIncompatibleSpecificationsNeverLabelContractsAsCoins() throws {
        var position = try swapPosition(quantity: "10")
        let invalid: [ContractInstrument?] = [nil,
            ContractInstrument(instId: "BTC-USDT-SWAP", ctType: "linear", ctVal: "0.01", ctValCcy: "BTC"),
            ContractInstrument(instId: position.instId, ctType: "linear", ctVal: "0.1", ctValCcy: "USD"),
            ContractInstrument(instId: position.instId, ctType: "unknown", ctVal: "0.1", ctValCcy: "ETH"),
            ContractInstrument(instId: position.instId, ctType: "linear", ctVal: "", ctValCcy: "ETH"),
            ContractInstrument(instId: position.instId, ctType: "linear", ctVal: "0", ctValCcy: "ETH")]
        for contract in invalid {
            position.contract = contract
            XCTAssertNil(position.baseQuantity)
            XCTAssertEqual(position.quantityText, "暫無換算資料")
        }
        let option = try JSONDecoder().decode(Position.self, from: Data(#"{"posId":"1","instId":"BTC-USD-261225-90000-C","instType":"OPTION","pos":"2","posSide":"net"}"#.utf8))
        XCTAssertEqual(option.quantityText, "2 張")
    }

    func testPerpetualPositionsJoinSpecificationsByInstrumentID() async throws {
        let client = client(response: "")
        MockURLProtocol.handler = { request in
            let json = request.url?.path == "/api/v5/account/positions"
                ? #"{"code":"0","data":[{"posId":"1","instId":"ETH-USDT-SWAP","instType":"SWAP","pos":"-63.16","posSide":"net"},{"posId":"2","instId":"BTC-USDT-SWAP","instType":"SWAP","pos":"0","posSide":"net"},{"posId":"3","instId":"UNKNOWN-USDT-SWAP","instType":"SWAP","pos":"2","posSide":"net"}]}"#
                : #"{"code":"0","data":[{"instId":"BTC-USDT-SWAP","ctType":"linear","ctVal":"0.01","ctValCcy":"BTC"},{"instId":"ETH-USDT-SWAP","ctType":"linear","ctVal":"0.1","ctValCcy":"ETH"}]}"#
            return (200, Data(json.utf8))
        }
        let service = OKXReadService(credentials: credentials, session: client.session)
        let values = try await service.positions(using: client).perpetuals
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].quantityText, "-6.316 ETH")
        XCTAssertEqual(values[1].quantityText, "暫無換算資料")
    }

    func testPerpetualSpecificationsFailureIsNotReportedAsSuccessfulUpdate() async {
        let client = client(response: "")
        MockURLProtocol.handler = { request in
            let json = request.url?.path == "/api/v5/account/positions"
                ? #"{"code":"0","data":[{"posId":"1","instId":"ETH-USDT-SWAP","instType":"SWAP","pos":"2","posSide":"long"}]}"#
                : #"{"code":"50011","data":[]}"#
            return (200, Data(json.utf8))
        }
        do {
            let service = OKXReadService(credentials: credentials, session: client.session)
            _ = try await service.positions(using: client)
            XCTFail("合約規格查詢失敗時不可將更新標示成功")
        } catch { XCTAssertTrue(error.localizedDescription.contains("50011")) }
    }

    func testAllRequestsAreGETAndUseOnlyRegionalHosts() throws {
        for region in APIRegion.allCases {
            var credentials = credentials
            credentials.region = region
            let client = OKXClient(credentials: credentials)
            for endpoint in [Endpoint.valuation, .trading, .funding, .positions("OPTION"), .dci(state: "live", endID: "123")] {
                let request = try client.request(endpoint)
                XCTAssertEqual(request.url?.host, region.host)
                XCTAssertEqual(request.url?.scheme, "https")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.httpBody)
            }
        }
    }

    func testEmptyOrMalformedCredentialsAreRejected() {
        XCTAssertFalse(Credentials().isValid)
        var bad = credentials
        bad.apiKey = "hello\r\nheader"
        XCTAssertThrowsError(try OKXClient(credentials: bad).request(.trading))
    }

    func testBalanceDecodePreservesPrecisionAndEmptyValues() async throws {
        let client = client(response: #"{"code":"0","data":[{"totalEq":"123.4567890123456789","details":[{"ccy":"BTC","cashBal":"0.000000001","availBal":"","eq":"0.000000001"}]}]}"#)
        let balances: [TradingBalance] = try await client.get(.trading)
        XCTAssertEqual(balances[0].totalEq, "123.4567890123456789")
        XCTAssertEqual(Numbers.format(balances[0].details[0].cashBal), "0.000000001")
        XCTAssertEqual(Numbers.format(balances[0].details[0].availBal), "—")
        XCTAssertEqual(Numbers.percent("0.1842"), "18.42%")
    }

    func testAssetValuationRequestsUSDAndPreservesOfficialTotal() async throws {
        let client = client(response: #"{"code":"0","data":[{"totalBal":"3791.1234567890123456","details":{"classic":"124.6","earn":"1122.73","funding":"0.09","trading":"2544.28"}}]}"#)
        let request = try client.request(.valuation)
        XCTAssertEqual(request.url?.absoluteString, "https://openapi.okx.com/api/v5/asset/asset-valuation?ccy=USD")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "OK-ACCESS-SIGN"))
        let values: [AssetValuation] = try await client.get(.valuation)
        // 總額直接採用 OKX 回傳值，不能用分類或持倉再次加總。
        XCTAssertEqual(values[0].totalBal, "3791.1234567890123456")
        XCTAssertEqual(values[0].details.funding, "0.09")
        XCTAssertEqual(values[0].details.trading, "2544.28")
        XCTAssertEqual(values[0].details.earn, "1122.73")
        XCTAssertEqual(values[0].details.classic, "124.6")
    }

    func testAssetValuationMissingAmountsDoNotBecomeZero() async throws {
        let client = client(response: #"{"code":0,"data":[{"totalBal":12.123456789012345678,"details":{"funding":0,"trading":"","earn":null}}]}"#)
        let values: [AssetValuation] = try await client.get(.valuation)
        XCTAssertEqual(values[0].totalBal, "12.123456789012345678")
        XCTAssertEqual(Numbers.format(values[0].details.funding), "0")
        XCTAssertEqual(Numbers.format(values[0].details.trading), "—")
        XCTAssertEqual(Numbers.format(values[0].details.earn), "—")
        XCTAssertNil(values[0].details.classic)
    }

    func testAssetValuationInvalidTotalIsAnError() async {
        for body in [#"{"details":{}}"#, #"{"totalBal":"","details":{}}"#, #"{"totalBal":null,"details":{}}"#] {
            let client = client(response: "{\"code\":\"0\",\"data\":[\(body)]}")
            do {
                let _: [AssetValuation] = try await client.get(.valuation)
                XCTFail("缺少總額不可視為零或改用交易帳戶權益")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("總資產"))
                XCTAssertTrue(error.localizedDescription.contains("totalBal"))
            }
        }
    }

    func testAPIErrorsDoNotDecodeDataOrExposeResponse() async {
        let client = client(response: #"{"code":"50105","msg":"sensitive-debug-info","data":{}}"#)
        do {
            let _: [FundingBalance] = try await client.get(.funding)
            XCTFail("錯誤回應不得視為空餘額")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("50105"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-debug-info"))
        }
    }

    func testHTTPErrorAndMissingDataAreFailures() async {
        for (status, response) in [(403, "Forbidden"), (200, #"{"code":"0"}"#), (200, "<html>error</html>")] {
            let client = client(response: response, status: status)
            do {
                let _: [FundingBalance] = try await client.get(.funding)
                XCTFail("無效回應不得視為成功")
            } catch { XCTAssertNotNil(error as? OKXError) }
        }
    }

    func testSignedNetPositionsAndHedgePositions() throws {
        for (side, quantity, short, open) in [("net", "-2", true, true), ("short", "2", true, true), ("long", "2", false, true), ("net", "0", false, false)] {
            let json = "{\"posId\":\"1\",\"instId\":\"BTC-USDT-SWAP\",\"instType\":\"SWAP\",\"pos\":\"\(quantity)\",\"posSide\":\"\(side)\"}"
            let value = try JSONDecoder().decode(Position.self, from: Data(json.utf8))
            XCTAssertEqual(value.isShort, short)
            XCTAssertEqual(value.isOpen, open)
            XCTAssertEqual(value.priceCurrency, "USDT")
        }
    }

    func testOptionContractAndDCIStates() {
        let option = OptionContract("BTC-USD-261225-90000-C")
        XCTAssertEqual(option?.type, "買權 Call")
        XCTAssertEqual(option?.expiry, "2026-12-25")
        XCTAssertEqual(option?.strike, "90000")
        XCTAssertNil(OptionContract("BTC-USDT-SWAP"))
        XCTAssertFalse(DCIOrder.activeStates.contains("settled"))
        XCTAssertTrue(DCIOrder.activeStates.contains("pending_redeem"))
    }

    func testClockSyncCorrectsDeviceClock() async throws {
        let client = client(response: #"{"code":"0","data":[{"ts":"1794247200000"}]}"#)
        let synced = try await client.synchronized()
        let request = try synced.request(.funding)
        XCTAssertTrue(request.value(forHTTPHeaderField: "OK-ACCESS-TIMESTAMP")!.hasPrefix("2026-11-09T18:00:00"))
    }

    func testDCINumericFieldsPreserveIDsAndDecimalPrecision() async throws {
        let client = client(response: #"{"code":0,"data":[{"ordId":9876543210123456789,"productId":"BTC-USDT-261225-90000-C","state":"live","notionalSz":0.1234567890123456789,"notionalCcy":"BTC","strike":90000,"annualizedYield":0.1842,"expTime":1795766400000,"yieldSz":null}]}"#)
        let orders: [DCIOrder] = try await client.get(.dci(state: "live", endID: nil))
        XCTAssertEqual(orders[0].ordId, "9876543210123456789")
        XCTAssertEqual(orders[0].notionalSz, "0.1234567890123456789")
        XCTAssertEqual(orders[0].strike, "90000")
        XCTAssertEqual(orders[0].annualizedYield, "0.1842")
        XCTAssertEqual(orders[0].expTime, "1795766400000")
        XCTAssertNil(orders[0].yieldSz)
    }

    func testDCIUppercaseLiveWithoutTimingIsActiveButDoesNotGuessAccrualPhase() async throws {
        let client = client(response: #"{"code":"0","data":[{"ordId":"test-order","productId":"BTC-USDT-261225-90000-C","state":"LIVE"}]}"#)
        let report = try await client.dciOrderReport()
        XCTAssertEqual(report.activeOrders.count, 1)
        XCTAssertEqual(report.activeOrders.first?.stateTitle, "持有中")
        XCTAssertEqual(report.activeOrders.first?.state, "LIVE")
        XCTAssertTrue(report.unrecognizedOrders.isEmpty)
        XCTAssertTrue(report.closedOrders.isEmpty)
        XCTAssertNil(report.emptyMessage)
    }

    func testDCIStateClassificationIgnoresCaseAndSurroundingWhitespace() throws {
        let cases = [("INITIAL", "處理中", true), (" Pending_Settle ", "待結算", true),
                     ("PENDING_REDEEM", "贖回中", true), ("SETTLED", "已結算", false),
                     ("Redeemed", "已贖回", false), ("REJECTED", "未成立", false)]
        for (state, title, active) in cases {
            let data = try JSONSerialization.data(withJSONObject: ["ordId": "1", "productId": "test", "state": state])
            let order = try JSONDecoder().decode(DCIOrder.self, from: data)
            XCTAssertEqual(order.state, state)
            XCTAssertEqual(order.stateTitle, title)
            XCTAssertEqual(order.isActive, active)
            XCTAssertEqual(order.isClosed, !active)
            XCTAssertFalse(order.needsReview)
        }
    }

    func testDCIRequiredFieldDiagnosticDoesNotLeakAccountValues() async {
        let client = client(response: #"{"code":"0","data":[{"ordId":"PRIVATE-ORDER-ID","state":"live","notionalSz":"12345.9876","privateKey":"PRIVATE-SECRET"}]}"#)
        do {
            let _: [DCIOrder] = try await client.get(.dci(state: "initial", endID: nil))
            XCTFail("不得略過格式異常的訂單")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("雙幣贏（initial）"))
            XCTAssertTrue(message.contains("data[0].productId"))
            XCTAssertTrue(message.contains("缺少必要欄位"))
            for privateValue in ["PRIVATE-ORDER-ID", "12345.9876", "PRIVATE-SECRET", "privateKey"] {
                XCTAssertFalse(message.contains(privateValue))
            }
        }
    }

    func testUnexpectedContainerIsDiagnosedInsteadOfEmptyHoldings() async {
        let client = client(response: #"{"code":"0","data":{"list":[],"private-account-name":"hidden"}}"#)
        do {
            let _: [DCIOrder] = try await client.get(.dci(state: "live", endID: nil))
            XCTFail("不應把未知容器當成空持倉")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("data：預期為陣列"))
            XCTAssertTrue(error.localizedDescription.contains("list: 陣列"))
            XCTAssertFalse(error.localizedDescription.contains("private-account-name"))
            XCTAssertFalse(error.localizedDescription.contains("hidden"))
        }
    }

    func testDCIInvalidNumericFieldIsNotSilentlyDropped() async {
        let client = client(response: #"{"code":"0","data":[{"ordId":"1","productId":"test","state":"live","notionalSz":true}]}"#)
        do {
            let _: [DCIOrder] = try await client.get(.dci(state: "live", endID: nil))
            XCTFail("不得把無效本金當成缺值或零")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("notionalSz"))
        }
    }

    func testNonJSONDiagnosticDoesNotIncludeResponseBody() async {
        let client = client(response: "<html>PRIVATE-SERVER-MESSAGE</html>")
        do {
            let _: [DCIOrder] = try await client.get(.dci(state: "initial", endID: nil))
            XCTFail("應辨識非 JSON 回應")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("回應不是有效的 JSON"))
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE-SERVER-MESSAGE"))
        }
    }

    func testHTTPAuthenticationErrorPreservesOKXCode() async {
        let client = client(response: #"{"code":"50105","msg":"private-detail"}"#, status: 401)
        do {
            let _: [DCIOrder] = try await client.get(.dci(state: "initial", endID: nil))
            XCTFail("應保留 OKX 的權限錯誤碼")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("50105"))
            XCTAssertFalse(error.localizedDescription.contains("private-detail"))
        }
    }

    func testDCIUnfilteredPaginationPreservesOlderActiveAndUnknownOrders() async throws {
        let client = client(response: "")
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertFalse(query.contains { $0.name == "state" })
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "100")
            let cursor = query.first { $0.name == "endId" }?.value
            recorder.append(cursor ?? "first")
            let orders: [[String: String]]
            if cursor == nil {
                orders = (101...200).reversed().map { ["ordId": "\($0)", "productId": "BTC-USDT-261225-90000-C", "state": "settled"] }
            } else {
                XCTAssertEqual(cursor, "101")
                orders = [
                    ["ordId": "100", "productId": "BTC-USDT-261225-90000-C", "state": "live"],
                    ["ordId": "99", "productId": "BTC-USDT-261225-90000-C", "state": "new_state"],
                    ["ordId": "200", "productId": "BTC-USDT-261225-90000-C", "state": "live"]
                ]
            }
            return (200, try JSONSerialization.data(withJSONObject: ["code": "0", "data": orders]))
        }
        let report = try await client.dciOrderReport()
        XCTAssertEqual(report.orders.count, 102)
        XCTAssertEqual(report.activeOrders.map(\.ordId), ["100"])
        XCTAssertEqual(report.unrecognizedOrders.map(\.ordId), ["99"])
        XCTAssertEqual(report.closedOrders.count, 100)
        XCTAssertEqual(report.pageCount, 2)
        XCTAssertEqual(recorder.values, ["first", "101"])
        XCTAssertNil(report.emptyMessage)
    }

    func testEmptyDCIResponseDoesNotClaimAccountHasNoHoldings() async throws {
        let client = client(response: #"{"code":"0","data":[]}"#)
        let report = try await client.dciOrderReport()
        XCTAssertEqual(report.orders.count, 0)
        XCTAssertEqual(report.pageCount, 1)
        XCTAssertTrue(report.emptyMessage!.contains("API 未回傳"))
        XCTAssertTrue(report.emptyMessage!.contains("尚無法確認實際持倉"))
    }

    func testDCIUnrecognizedStatesRemainVisibleAndSeparateFromClosed() async throws {
        let client = client(response: #"{"code":"0","data":[{"ordId":"1","productId":"test","state":"new_state"},{"ordId":"2","productId":"test","state":1},{"ordId":"3","productId":"test","state":"settled"}]}"#)
        let report = try await client.dciOrderReport()
        XCTAssertTrue(report.activeOrders.isEmpty)
        XCTAssertEqual(Set(report.unrecognizedOrders.map(\.state)), Set(["new_state", "1"]))
        XCTAssertEqual(report.closedOrders.map(\.ordId), ["3"])
        XCTAssertTrue(report.emptyMessage!.contains("尚未識別狀態"))
        let closedOnly = DCIReport(orders: report.closedOrders, pageCount: 1)
        XCTAssertTrue(closedOnly.emptyMessage!.contains("不代表 OKX App 中一定沒有"))
    }

    func testDCIRepeatedCursorFailsInsteadOfReportingIncompleteHoldings() async throws {
        let client = client(response: "")
        MockURLProtocol.handler = { _ in
            let orders = (1...100).reversed().map { ["ordId": "\($0)", "productId": "test", "state": "live"] }
            return (200, try JSONSerialization.data(withJSONObject: ["code": "0", "data": orders]))
        }
        do {
            _ = try await client.dciOrderReport()
            XCTFail("重複游標不得當成完整結果")
        } catch OKXError.pagination {} catch { XCTFail("非預期錯誤：\(error)") }
    }

    func testDCILaterPageErrorDoesNotReturnPartialReport() async throws {
        let client = client(response: "")
        MockURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.contains(where: { $0.name == "endId" }) {
                return (200, Data(#"{"code":"50011","data":[]}"#.utf8))
            }
            let orders = (1...100).reversed().map { ["ordId": "\($0)", "productId": "test", "state": "live"] }
            return (200, try JSONSerialization.data(withJSONObject: ["code": "0", "data": orders]))
        }
        do {
            _ = try await client.dciOrderReport()
            XCTFail("後續分頁錯誤不得回傳部分持倉")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("50011"))
        }
    }

}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
