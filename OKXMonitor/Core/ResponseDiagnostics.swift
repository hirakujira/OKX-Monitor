import Foundation
import CoreFoundation

enum ResponseDiagnostics {
    static func describe(_ error: DecodingError, data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "回應不是有效的 JSON。"
        }
        let path: [CodingKey]
        let issue: String
        switch error {
        case .keyNotFound(let key, let context):
            path = context.codingPath + [key]
            issue = "缺少必要欄位"
        case .typeMismatch(let type, let context):
            path = context.codingPath
            issue = "預期為\(expectedType(type))，實際為\(shape(value(at: path, in: root)))"
        case .valueNotFound(_, let context):
            path = context.codingPath
            issue = "必要欄位為 null"
        case .dataCorrupted(let context):
            path = context.codingPath
            issue = "欄位內容無法解析"
        @unknown default:
            return "JSON 格式不符預期。"
        }
        // 只顯示程式已知的欄位路徑與型別；不輸出原始回應、數值或 decoder 的 debugDescription。
        let knownKeys: Set<String> = ["code", "data", "ts", "totalEq", "details", "ccy", "cashBal", "eq", "eqUsd",
            "availBal", "frozenBal", "liab", "bal", "posId", "instId", "instType", "pos", "posSide", "mgnMode",
            "avgPx", "markPx", "liqPx", "lever", "upl", "uplRatio", "notionalUsd", "deltaBS", "gammaBS", "thetaBS",
            "vegaBS", "ordId", "productId", "state", "notionalSz", "notionalCcy", "quoteCcy", "strike",
            "annualizedYield", "expTime", "yieldSz", "yieldCcy", "totalBal", "funding", "trading", "earn", "classic",
            "ctType", "ctVal", "ctValCcy", "settleTime", "settledTime", "interestAccrualTime", "redeemStartTime", "cTime", "absYield", "baseCcy", "idxPx"]
        var location = ""
        for key in path {
            if let index = key.intValue { location += "[\(index)]" }
            else {
                location += (location.isEmpty ? "" : ".") + (knownKeys.contains(key.stringValue) ? key.stringValue : "欄位")
            }
        }
        return "\(location.isEmpty ? "根節點" : location)：\(issue)。"
    }

    private static func expectedType(_ type: Any.Type) -> String {
        if type == String.self { return "字串" }
        if type == Int.self || type == Decimal.self || type == Double.self { return "數字" }
        if String(reflecting: type).hasPrefix("Swift.Array<") { return "陣列" }
        return "物件"
    }

    private static func value(at path: [CodingKey], in root: Any) -> Any? {
        var value: Any? = root
        for key in path {
            if let index = key.intValue, let array = value as? [Any], array.indices.contains(index) {
                value = array[index]
            } else { value = (value as? [String: Any])?[key.stringValue] }
        }
        return value
    }

    private static func shape(_ value: Any?) -> String {
        guard let value else { return "缺少欄位" }
        if value is NSNull { return "null" }
        if value is String { return "字串" }
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? "布林值" : "數字" }
        if value is [Any] { return "陣列" }
        if let object = value as? [String: Any] {
            let containers = ["data", "list", "orders", "items", "rows", "result"].compactMap { key -> String? in
                guard let nested = object[key] else { return nil }
                // 僅描述一層已知容器，避免印出任意伺服器欄位或深層資料。
                let type = nested is [Any] ? "陣列" : nested is [String: Any] ? "物件" : "其他型別"
                return "\(key): \(type)"
            }
            return "物件" + (containers.isEmpty ? "" : "（\(containers.joined(separator: "、"))）")
        }
        return "未知型別"
    }
}
