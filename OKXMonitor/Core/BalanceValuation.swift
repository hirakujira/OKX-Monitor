import Foundation

struct USDIndexPrice: Decodable, Sendable {
    let instId: String
    let idxPx: String?
}

enum BalanceValuation {
    static func funding(_ balances: [FundingBalance], prices: [USDIndexPrice]) -> [FundingBalance] {
        var usdPrices: [String: Decimal] = ["USD": 1]
        for price in prices where price.instId.hasSuffix("-USD") {
            guard let value = number(price.idxPx), value > 0 else { continue }
            usdPrices[String(price.instId.dropLast(4))] = value
        }
        return balances.map { balance in
            var balance = balance
            balance.usdValue = nil
            if let quantity = number(balance.bal) {
                if quantity == 0 {
                    balance.usdValue = "0"
                } else if let price = usdPrices[balance.ccy] {
                    let value = quantity * price
                    if !value.isNaN { balance.usdValue = NSDecimalNumber(decimal: value).stringValue }
                }
            }
            return balance
        }
    }

    static func sortedTrading(_ balances: [CoinBalance]) -> [CoinBalance] {
        balances.sorted { precedes($0.ccy, $0.eqUsd, $1.ccy, $1.eqUsd) }
    }

    static func sortedFunding(_ balances: [FundingBalance]) -> [FundingBalance] {
        balances.sorted { precedes($0.ccy, $0.usdValue, $1.ccy, $1.usdValue) }
    }

    private static func number(_ value: String?) -> Decimal? {
        guard let number = Numbers.decimal(value), !number.isNaN else { return nil }
        return number
    }

    private static func precedes(_ leftCurrency: String, _ leftValue: String?, _ rightCurrency: String, _ rightValue: String?) -> Bool {
        switch (number(leftValue), number(rightValue)) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return leftCurrency < rightCurrency
        }
    }
}
