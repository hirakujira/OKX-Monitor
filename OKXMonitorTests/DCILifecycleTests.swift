import XCTest
import Foundation
@testable import OKXMonitorCore

final class DCILifecycleTests: XCTestCase {
    private let start = 1_700_000_000_000.0
    private let expiry = 1_700_086_400_000.0

    private func order(_ fields: [String: Any]) throws -> DCIOrder {
        let base: [String: Any] = ["ordId": "example", "productId": "BTC-USDT-231115-40000-C", "state": "LIVE"]
        let data = try JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new })
        return try JSONDecoder().decode(DCIOrder.self, from: data)
    }

    private func date(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }

    func testObservedResponseShapeShowsExpiryAndTransitionsWithoutAnotherResponse() throws {
        let value = try order(["redeemStartTime": start, "settleTime": expiry, "settledTime": ""])
        XCTAssertNil(value.expTime)
        XCTAssertEqual(value.expirationTime, "1700086400000")
        XCTAssertEqual(value.accrualStartTime, "1700000000000")
        XCTAssertEqual(value.stateTitle(at: date(start - 1)), "待生息")
        XCTAssertEqual(value.stateTitle(at: date(start)), "賺幣中")
        XCTAssertEqual(value.stateTitle(at: date(expiry - 1)), "賺幣中")
        XCTAssertEqual(value.stateTitle(at: date(expiry)), "待結算")
        XCTAssertEqual(value.state, "LIVE")
        XCTAssertTrue(value.isActive)
    }

    func testExplicitExpiryAndAccrualTimeTakePrecedence() throws {
        let value = try order(["interestAccrualTime": String(Int(start)), "redeemStartTime": start + 3600000,
                               "expTime": String(Int(expiry)), "settleTime": expiry + 3600000, "settledTime": ""])
        XCTAssertEqual(value.expirationTime, "1700086400000")
        XCTAssertEqual(value.stateTitle(at: date(start)), "賺幣中")
    }

    func testSubscriptionTimestampPreservesAPITimeWithoutAdjustingSeconds() throws {
        for raw: Any in ["1699998278000", 1_699_998_278_000] {
            let value = try order(["cTime": raw, "interestAccrualTime": start])
            XCTAssertEqual(value.cTime, "1699998278000")
            XCTAssertEqual(value.accrualStartTime, "1700000000000")
        }
        let missing = try order([:])
        XCTAssertNil(missing.cTime)
        XCTAssertNil(missing.accrualStartTime)
    }

    func testPeriodYieldRateAndEstimatedAmountAreDistinctFromAnnualizedRate() throws {
        let value = try order(["notionalSz": "0.22", "notionalCcy": "BTC", "absYield": "0.0103",
                               "annualizedYield": "2.5145", "yieldSz": "", "baseCcy": "BTC", "quoteCcy": "USDT", "strike": "178"])
        XCTAssertEqual(Numbers.percent(value.absYield), "1.03%")
        XCTAssertEqual(Numbers.percent(value.annualizedYield), "251.45%")
        XCTAssertEqual(value.estimatedYield, "0.002266")
        XCTAssertEqual(value.yieldEstimates.map(\.text), ["0.002266 BTC", "0.403348 USDT"])
        XCTAssertEqual(value.yieldEstimates.map(\.condition), ["到期價 < 178 USDT", "到期價 ≥ 178 USDT"])
        XCTAssertEqual(value.yieldText, "—")
    }

    func testReportedYieldIncludingZeroOverridesEstimateAndUsesReportedCurrency() throws {
        for (reported, expected) in [("0", "0 USDT"), ("1.23", "1.23 USDT")] {
            let value = try order(["notionalSz": "0.22", "notionalCcy": "BTC", "absYield": 0.0103,
                                   "yieldSz": reported, "yieldCcy": "USDT"])
            XCTAssertTrue(value.hasReportedYield)
            XCTAssertTrue(value.yieldEstimates.isEmpty)
            XCTAssertEqual(value.yieldText, expected)
        }
    }

    func testMissingRateOrClosedOrderDoesNotInventIncome() throws {
        for fields: [String: Any] in [["notionalSz": "0.22", "notionalCcy": "BTC"],
                                      ["absYield": "0.0103", "notionalCcy": "BTC"],
                                      ["notionalSz": "0.22", "absYield": "0.0103"],
                                      ["state": "REJECTED", "notionalSz": "0.22", "absYield": "0.0103", "notionalCcy": "BTC"]] {
            let value = try order(fields)
            XCTAssertEqual(value.yieldText, "—")
            XCTAssertTrue(value.yieldEstimates.isEmpty)
        }
    }

    func testBuyLowEstimatesDivideByTargetPriceForConvertedCurrency() throws {
        let value = try order(["productId": "BTC-USDT-231115-40000-P", "notionalSz": "5000",
                               "notionalCcy": "USDT", "baseCcy": "BTC", "quoteCcy": "USDT",
                               "strike": "40000", "absYield": "0.01"])
        XCTAssertEqual(value.yieldEstimates.map(\.text), ["50 USDT", "0.00125 BTC"])
        XCTAssertEqual(value.yieldEstimates.map(\.condition), ["到期價 > 40,000 USDT", "到期價 ≤ 40,000 USDT"])
    }

    func testYieldScenariosRequireValidStrikeAndMatchingInvestmentCurrency() throws {
        for fields: [String: Any] in [["strike": "0"], ["strike": ""], ["notionalCcy": "USDT"],
                                      ["state": "REJECTED"], ["baseCcy": ""]] {
            let inputs: [String: Any] = ["notionalSz": "1", "notionalCcy": "BTC", "baseCcy": "BTC",
                                         "quoteCcy": "USDT", "strike": "40000", "absYield": "0.01"]
            let value = try order(inputs.merging(fields) { _, new in new })
            XCTAssertTrue(value.yieldEstimates.isEmpty)
        }
    }

    func testDocumentedActualSettlementTimeIsNotUsedAsExpiry() throws {
        let value = try order(["settleTime": expiry, "redeemStartTime": start])
        XCTAssertNil(value.expirationTime)
        XCTAssertEqual(value.stateTitle(at: date(start)), "賺幣中")
    }

    func testEmptyOrInvalidExpiryFallsBackOnlyForObservedShape() throws {
        for raw in ["", "0", "invalid", "NaN"] {
            let value = try order(["expTime": raw, "settleTime": expiry, "settledTime": NSNull()])
            XCTAssertEqual(value.expirationTime, "1700086400000")
        }
        let missing = try order(["expTime": NSNull(), "settleTime": "", "settledTime": "", "redeemStartTime": "0"])
        XCTAssertNil(missing.expirationTime)
        XCTAssertEqual(missing.stateTitle(at: date(start)), "持有中")
    }

    func testServerTerminalAndRedemptionStatesOverrideTimeBasedPhase() throws {
        for (state, title) in [("SETTLED", "已結算"), ("REDEEMED", "已贖回"), ("REJECTED", "未成立"),
                               ("PENDING_REDEEM", "贖回中"), ("PENDING_SETTLE", "待結算"), ("INITIAL", "處理中")] {
            let value = try order(["state": state, "interestAccrualTime": start, "expTime": expiry])
            XCTAssertEqual(value.stateTitle(at: date(start - 1)), title)
            XCTAssertEqual(value.stateTitle(at: date(expiry + 1)), title)
        }
    }
}
