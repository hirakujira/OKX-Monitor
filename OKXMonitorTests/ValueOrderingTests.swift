import XCTest
import Foundation
@testable import OKXMonitorCore

final class ValueOrderingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testTradingUsesNumericUSDValueAndPlacesMissingLast() throws {
        let coins = try decode([CoinBalance].self, #"[{"ccy":"A","eqUsd":"9"},{"ccy":"B","eqUsd":"100"},{"ccy":"C","eqUsd":"9.000000001"},{"ccy":"D","eqUsd":"-2"},{"ccy":"E"},{"ccy":"F","eqUsd":"0"},{"ccy":"G","eqUsd":"9"}]"#)
        XCTAssertEqual(BalanceValuation.sortedTrading(coins).map(\.ccy), ["B", "C", "A", "G", "F", "D", "E"])
    }

    func testFundingValuesDifferentCurrenciesAndDoesNotAssumeStablecoinPeg() throws {
        let coins = try decode([FundingBalance].self, #"[{"ccy":"USDT","bal":"100"},{"ccy":"BTC","bal":"0.01"},{"ccy":"USD","bal":"100"},{"ccy":"UNKNOWN","bal":"999999"},{"ccy":"ZERO","bal":"0"},{"ccy":"TINY","bal":"0.00000001"}]"#)
        let prices = [USDIndexPrice(instId: "BTC-USD", idxPx: "75000"),
                      USDIndexPrice(instId: "USDT-USD", idxPx: "0.998"),
                      USDIndexPrice(instId: "UNKNOWN-USDT", idxPx: "2"),
                      USDIndexPrice(instId: "TINY-USD", idxPx: "0.001")]
        let valued = BalanceValuation.sortedFunding(BalanceValuation.funding(coins, prices: prices))
        XCTAssertEqual(valued.map(\.ccy), ["BTC", "USD", "USDT", "TINY", "ZERO", "UNKNOWN"])
        XCTAssertEqual(valued.map(\.usdValue), ["750", "100", "99.8", "0.00000000001", "0", nil])
    }

    func testInvalidIndexPricesDoNotBecomeZeroValuations() throws {
        let coins = try decode([FundingBalance].self, #"[{"ccy":"A","bal":"1"},{"ccy":"B","bal":"1"},{"ccy":"C","bal":"1"}]"#)
        let prices = [USDIndexPrice(instId: "A-USD", idxPx: "0"),
                      USDIndexPrice(instId: "B-USD", idxPx: "-1"),
                      USDIndexPrice(instId: "C-USD", idxPx: "invalid")]
        XCTAssertTrue(BalanceValuation.funding(coins, prices: prices).allSatisfy { $0.usdValue == nil })
    }

    func testPositionsSortAbsoluteNotionalForLongsShortsAndOptions() throws {
        let positions = try decode([Position].self, #"[{"posId":"1","instId":"BTC-USDT-SWAP","instType":"SWAP","pos":"1","posSide":"long","notionalUsd":"9"},{"posId":"2","instId":"ETH-USDT-SWAP","instType":"SWAP","pos":"-1","posSide":"net","notionalUsd":"-100"},{"posId":"3","instId":"BTC-USD-261225-90000-C","instType":"OPTION","pos":"1","posSide":"long","notionalUsd":"50"},{"posId":"4","instId":"X-USDT-SWAP","instType":"SWAP","pos":"1","posSide":"short"},{"posId":"5","instId":"Y-USDT-SWAP","instType":"SWAP","pos":"1","posSide":"long","notionalUsd":"0"},{"posId":"6","instId":"Z-USDT-SWAP","instType":"SWAP","pos":"1","posSide":"long","notionalUsd":"9.000000001"}]"#)
        XCTAssertEqual(Position.sortedByNotional(positions).map(\.posId), ["2", "3", "6", "1", "5", "4"])
    }

    func testUSDIndexBatchRequestHasNoCredentials() throws {
        let request = try OKXClient(credentials: Credentials()).request(.usdIndexPrices)
        XCTAssertEqual(request.url?.absoluteString, "https://openapi.okx.com/api/v5/market/index-tickers?quoteCcy=USD")
        for header in ["OK-ACCESS-KEY", "OK-ACCESS-SIGN", "OK-ACCESS-PASSPHRASE", "OK-ACCESS-TIMESTAMP"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header))
        }
    }
}
