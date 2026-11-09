import Foundation

enum APIRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case global, us, europe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .global: "全球站"
        case .us: "美國 / 澳洲"
        case .europe: "歐洲經濟區"
        }
    }
    var host: String {
        switch self {
        case .global: "openapi.okx.com"
        case .us: "us.okx.com"
        case .europe: "eea.okx.com"
        }
    }
}

struct Credentials: Codable, Equatable, Sendable {
    var apiKey = ""
    var secretKey = ""
    var passphrase = ""
    var region: APIRegion = .global
    var isValid: Bool {
        [apiKey, secretKey, passphrase].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }
}

struct AssetValuation: Decodable, Sendable {
    let totalBal: String
    let details: Details

    struct Details: Decodable, Sendable {
        let funding: String?
        let trading: String?
        let earn: String?
        let classic: String?

        private enum CodingKeys: String, CodingKey { case funding, trading, earn, classic }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            funding = try values.optionalNumericText(forKey: .funding)
            trading = try values.optionalNumericText(forKey: .trading)
            earn = try values.optionalNumericText(forKey: .earn)
            classic = try values.optionalNumericText(forKey: .classic)
        }
    }

    private enum CodingKeys: String, CodingKey { case totalBal, details }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        totalBal = try values.numericText(forKey: .totalBal)
        guard let amount = Numbers.decimal(totalBal), !amount.isNaN else {
            throw DecodingError.dataCorruptedError(forKey: .totalBal, in: values, debugDescription: "總資產必須為有效數值。")
        }
        details = try values.decode(Details.self, forKey: .details)
    }
}

struct TradingBalance: Decodable, Sendable {
    let totalEq: String?
    let details: [CoinBalance]
}

struct CoinBalance: Decodable, Identifiable, Sendable {
    let ccy: String
    let cashBal: String?
    let eq: String?
    let eqUsd: String?
    let availBal: String?
    let frozenBal: String?
    let liab: String?
    var id: String { ccy }
}

struct FundingBalance: Decodable, Identifiable, Sendable {
    let ccy: String
    let bal: String
    let availBal: String?
    let frozenBal: String?
    var usdValue: String?
    var id: String { ccy }
}

struct ContractInstrument: Decodable, Sendable {
    let instId: String
    let ctType: String?
    let ctVal: String?
    let ctValCcy: String?
}

struct Position: Decodable, Identifiable, Sendable {
    let posId: String
    let instId: String
    let instType: String
    let pos: String
    let posSide: String
    let mgnMode: String?
    let ccy: String?
    let avgPx: String?
    let markPx: String?
    let liqPx: String?
    let lever: String?
    let upl: String?
    let uplRatio: String?
    let notionalUsd: String?
    let deltaBS: String?
    let gammaBS: String?
    let thetaBS: String?
    let vegaBS: String?
    var contract: ContractInstrument?
    var id: String { "\(posId)-\(instId)-\(posSide)" }
    static func sortedByNotional(_ positions: [Position]) -> [Position] {
        func magnitude(_ position: Position) -> Decimal? {
            guard let value = Numbers.decimal(position.notionalUsd), !value.isNaN else { return nil }
            return abs(value)
        }
        return positions.sorted {
            switch (magnitude($0), magnitude($1)) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id < $1.id
            }
        }
    }
    var isOpen: Bool { Numbers.decimal(pos).map { $0 != 0 } ?? true }
    var isShort: Bool { posSide == "short" || (posSide == "net" && (Numbers.decimal(pos) ?? 0) < 0) }
    var direction: String { isShort ? "空單" : "多單" }
    var option: OptionContract? { OptionContract(instId) }
    var baseCurrency: String { String(instId.split(separator: "-").first ?? "") }
    var baseQuantity: Decimal? {
        guard instType == "SWAP", let contract, contract.instId == instId,
              let quantity = Numbers.decimal(pos), !quantity.isNaN,
              let faceValue = Numbers.decimal(contract.ctVal), !faceValue.isNaN, faceValue > 0 else { return nil }
        let amount: Decimal
        // ctVal 已是每張面值；線性合約以標的幣計價，反向合約以 USD 計價。
        switch contract.ctType {
        case "linear":
            guard contract.ctValCcy == baseCurrency else { return nil }
            amount = quantity * faceValue
        case "inverse":
            guard contract.ctValCcy == "USD", let price = Numbers.decimal(markPx), !price.isNaN, price > 0 else { return nil }
            amount = quantity * faceValue / price
        default: return nil
        }
        return amount.isNaN ? nil : amount
    }
    var quantityText: String {
        guard instType == "SWAP" else { return "\(Numbers.format(pos)) 張" }
        guard let baseQuantity else { return "暫無換算資料" }
        return "\(Numbers.format(NSDecimalNumber(decimal: baseQuantity).stringValue)) \(baseCurrency)"
    }
    var priceCurrency: String {
        if instType == "OPTION" { return ccy ?? "" }
        let parts = instId.split(separator: "-")
        return parts.count > 1 ? String(parts[1]) : ""
    }
}

struct OptionContract: Sendable {
    let type: String
    let strike: String
    let expiry: String
    init?(_ instrument: String) {
        let parts = instrument.split(separator: "-")
        guard parts.count == 5, ["C", "P"].contains(parts[4]), parts[2].count == 6 else { return nil }
        type = parts[4] == "C" ? "買權 Call" : "賣權 Put"
        strike = String(parts[3])
        let date = String(parts[2])
        expiry = "20\(date.prefix(2))-\(date.dropFirst(2).prefix(2))-\(date.suffix(2))"
    }
}

struct DCIYieldEstimate: Identifiable, Sendable {
    let currency: String
    let amount: String
    let condition: String
    var id: String { currency }
    var text: String { "\(Numbers.format(amount)) \(currency)" }
}

struct DCIOrder: Decodable, Identifiable, Sendable {
    let ordId: String
    let productId: String
    let state: String
    let notionalSz: String?
    let notionalCcy: String?
    let baseCcy: String?
    let quoteCcy: String?
    let strike: String?
    let annualizedYield: String?
    let absYield: String?
    let cTime: String?
    let expTime: String?
    let settleTime: String?
    let interestAccrualTime: String?
    let redeemStartTime: String?
    private let hasSeparateSettlementTime: Bool
    let yieldSz: String?
    let yieldCcy: String?
    private enum CodingKeys: String, CodingKey {
        case ordId, productId, state, notionalSz, notionalCcy, quoteCcy, strike, annualizedYield, expTime, yieldSz, yieldCcy
        case settleTime, settledTime, interestAccrualTime, redeemStartTime, absYield, cTime, baseCcy
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ordId = try values.numericText(forKey: .ordId)
        productId = try values.decode(String.self, forKey: .productId)
        state = try values.numericText(forKey: .state)
        notionalSz = try values.optionalNumericText(forKey: .notionalSz)
        notionalCcy = try values.decodeIfPresent(String.self, forKey: .notionalCcy)
        baseCcy = try values.decodeIfPresent(String.self, forKey: .baseCcy)
        quoteCcy = try values.decodeIfPresent(String.self, forKey: .quoteCcy)
        strike = try values.optionalNumericText(forKey: .strike)
        annualizedYield = try values.optionalNumericText(forKey: .annualizedYield)
        absYield = try values.optionalNumericText(forKey: .absYield)
        cTime = try values.optionalNumericText(forKey: .cTime)
        expTime = try values.optionalNumericText(forKey: .expTime)
        settleTime = try values.optionalNumericText(forKey: .settleTime)
        interestAccrualTime = try values.optionalNumericText(forKey: .interestAccrualTime)
        redeemStartTime = try values.optionalNumericText(forKey: .redeemStartTime)
        hasSeparateSettlementTime = values.contains(.settledTime)
        yieldSz = try values.optionalNumericText(forKey: .yieldSz)
        yieldCcy = try values.decodeIfPresent(String.self, forKey: .yieldCcy)
    }
    var id: String { ordId }
    static let activeStates = ["initial", "live", "pending_settle", "pending_redeem"]
    // 實際 DCD 回應使用 LIVE 等大寫狀態，文件則使用小寫；保留原值供未知狀態排查。
    private var normalizedState: String { state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var isActive: Bool { Self.activeStates.contains(normalizedState) }
    var isClosed: Bool { ["settled", "redeemed", "rejected"].contains(normalizedState) }
    var needsReview: Bool { !isActive && !isClosed }
    var expirationTime: String? {
        if timestamp(expTime) != nil { return expTime }
        // 實機回應以 settleTime 表示預定結算，另有 settledTime 表示實際結算。
        // 文件版的 settleTime 是實際結算時間，沒有獨立欄位時不能當作到期日。
        if hasSeparateSettlementTime, timestamp(settleTime) != nil { return settleTime }
        return nil
    }
    var accrualStartTime: String? {
        if timestamp(interestAccrualTime) != nil { return interestAccrualTime }
        // OKX FAQ 說明提前贖回窗口從起息時間開始。
        return timestamp(redeemStartTime) != nil ? redeemStartTime : nil
    }
    var estimatedYield: String? {
        guard let principal = Numbers.decimal(notionalSz), !principal.isNaN, principal >= 0,
              let rate = Numbers.decimal(absYield), !rate.isNaN, rate >= 0 else { return nil }
        let amount = principal * rate
        return amount.isNaN ? nil : NSDecimalNumber(decimal: amount).stringValue
    }
    var hasReportedYield: Bool {
        guard let amount = Numbers.decimal(yieldSz) else { return false }
        return !amount.isNaN
    }
    var yieldText: String {
        if hasReportedYield { return "\(Numbers.format(yieldSz)) \(yieldCcy ?? "")" }
        return "—"
    }
    var yieldEstimates: [DCIYieldEstimate] {
        guard !isClosed, !hasReportedYield,
              let estimatedYield, let original = Numbers.decimal(estimatedYield),
              let strikeValue = Numbers.decimal(strike), !strikeValue.isNaN, strikeValue > 0,
              let base = baseCcy, !base.isEmpty, let quote = quoteCcy, !quote.isEmpty, base != quote else { return [] }
        let target = "\(Numbers.format(strike)) \(quote)"
        let converted: Decimal
        let originalCurrency: String
        let convertedCurrency: String
        let originalCondition: String
        let convertedCondition: String
        if productId.hasSuffix("-C"), notionalCcy == base {
            converted = original * strikeValue
            originalCurrency = base
            convertedCurrency = quote
            originalCondition = "到期價 < \(target)"
            convertedCondition = "到期價 ≥ \(target)"
        } else if productId.hasSuffix("-P"), notionalCcy == quote {
            converted = original / strikeValue
            originalCurrency = quote
            convertedCurrency = base
            originalCondition = "到期價 > \(target)"
            convertedCondition = "到期價 ≤ \(target)"
        } else { return [] }
        guard !converted.isNaN else { return [] }
        return [DCIYieldEstimate(currency: originalCurrency, amount: estimatedYield, condition: originalCondition),
                DCIYieldEstimate(currency: convertedCurrency, amount: NSDecimalNumber(decimal: converted).stringValue,
                                 condition: convertedCondition)]
    }
    private func timestamp(_ raw: String?) -> Date? {
        guard let raw, let milliseconds = Double(raw), milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
    var stateTitle: String { stateTitle(at: Date()) }
    func stateTitle(at date: Date) -> String {
        switch normalizedState {
        case "initial": return "處理中"
        case "live":
            if let expiry = timestamp(expirationTime), date >= expiry { return "待結算" }
            guard let start = timestamp(accrualStartTime) else { return "持有中" }
            return date < start ? "待生息" : "賺幣中"
        case "pending_settle": return "待結算"
        case "pending_redeem": return "贖回中"
        case "settled": return "已結算"
        case "redeemed": return "已贖回"
        case "rejected": return "未成立"
        default: return state
        }
    }
    var strategy: String {
        if productId.hasSuffix("-C") { return "高賣" }
        if productId.hasSuffix("-P") { return "低買" }
        return "雙幣贏"
    }
}

struct DCIReport: Sendable {
    let orders: [DCIOrder]
    let pageCount: Int
    var activeOrders: [DCIOrder] { orders.filter(\.isActive) }
    var unrecognizedOrders: [DCIOrder] { orders.filter(\.needsReview) }
    var closedOrders: [DCIOrder] { orders.filter(\.isClosed) }
    var emptyMessage: String? {
        guard activeOrders.isEmpty else { return nil }
        if orders.isEmpty {
            return "此 API 未回傳任何雙幣贏訂單，尚無法確認實際持倉。若 OKX App 中仍有訂單，可能是帳戶或訂單來源的查詢範圍不同。"
        }
        if !unrecognizedOrders.isEmpty {
            return "API 回傳了尚未識別狀態的訂單，請查看下方「狀態待確認」；這些訂單不會被當成已結束或直接隱藏。"
        }
        return "此 API 回傳的訂單均標示為已結束；這不代表 OKX App 中一定沒有其他持倉。可展開下方記錄核對。"
    }
}

private extension KeyedDecodingContainer {
    func numericText(forKey key: Key) throws -> String {
        if let text = try? decode(String.self, forKey: key) { return text }
        // 不經過 Double，避免長訂單編號與高精度金額被二進位浮點數改寫。
        let number = try decode(Decimal.self, forKey: key)
        return NSDecimalNumber(decimal: number).stringValue
    }

    func optionalNumericText(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try numericText(forKey: key)
    }
}

enum Numbers {
    static func decimal(_ raw: String?) -> Decimal? {
        guard let raw, !raw.isEmpty else { return nil }
        return Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
    }
    static func format(_ raw: String?, places: Int = 8, fixedDecimals: Bool = false) -> String {
        guard let value = decimal(raw) else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = places
        formatter.minimumFractionDigits = fixedDecimals ? places : 0
        if fixedDecimals { formatter.roundingMode = .halfUp }
        // 小額資產不能因畫面四捨五入而看起來等於零。
        if !fixedDecimals, value != 0, abs(value) < pow(Decimal(10), -places) { return raw ?? "—" }
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    static func percent(_ raw: String?) -> String {
        guard let value = decimal(raw) else { return "—" }
        return format(NSDecimalNumber(decimal: value * 100).stringValue, places: 2) + "%"
    }
    static func date(_ raw: String?, includeSeconds: Bool = false) -> String {
        guard let raw, let milliseconds = Double(raw), milliseconds.isFinite, milliseconds > 0 else { return "—" }
        return Date(timeIntervalSince1970: milliseconds / 1000)
            .formatted(date: .abbreviated, time: includeSeconds ? .standard : .shortened)
    }
}
