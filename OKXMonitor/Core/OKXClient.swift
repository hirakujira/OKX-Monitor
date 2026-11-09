import Foundation
import CryptoKit

enum OKXError: LocalizedError {
    case invalidCredentials, invalidResponse, http(Int), api(String), pagination
    case responseFormat(endpoint: String, detail: String)
    var isRateLimited: Bool {
        switch self {
        case .api("50011"), .http(429): true
        default: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "請填入 API Key、Secret Key 與 Passphrase。"
        case .invalidResponse: "OKX 回應格式不符預期，請稍後重試。"
        case .responseFormat(let endpoint, let detail): "\(endpoint)回應無法解析。\n\(detail)\n請提供此訊息以協助排查；不需提高金鑰權限。"
        case .http(let status): "連線失敗（HTTP \(status)），請確認網路及 API 地區。"
        case .pagination: "雙幣贏分頁未能完整讀取，請重新整理。"
        case .api(let code):
            switch code {
            case "50101": "API Key 環境不符，請使用正式帳戶的金鑰。（\(code)）"
            case "50102": "時間驗證失敗，請重試並確認手機開啟自動日期與時間。（\(code)）"
            case "50105": "Passphrase 不正確。（\(code)）"
            case "50111", "50119": "API Key 無效或地區不符，請確認金鑰與 API 地區。（\(code)）"
            case "50113": "簽章驗證失敗，請確認 Secret Key。（\(code)）"
            case "50110": "目前網路 IP 不在 API Key 的允許清單內。（\(code)）"
            case "50120": "此金鑰沒有查詢權限，請確認已啟用 Read。（\(code)）"
            case "50011": "查詢太頻繁，請稍後重新整理。（\(code)）"
            default: "OKX 無法提供這項資料（代碼 \(code)）。請確認此帳戶的產品資格、地區及金鑰權限。"
            }
        }
    }
}

struct APIEnvelope<T: Decodable>: Decodable {
    let data: [T]?
}

private struct APIStatus: Decodable {
    let code: String
    private enum CodingKeys: String, CodingKey { case code }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .code) {
            code = text
        } else {
            code = String(try container.decode(Int.self, forKey: .code))
        }
    }
}
private struct ServerTime: Decodable { let ts: String }

enum Endpoint {
    case time, valuation, trading, funding, usdIndexPrices, swapInstruments, positions(String?), dci(state: String?, endID: String?)
    var diagnosticName: String {
        switch self {
        case .time: "時間同步"
        case .valuation: "總資產"
        case .trading: "交易帳戶"
        case .funding: "資金帳戶"
        case .usdIndexPrices: "美元估值"
        case .positions: "持倉"
        case .swapInstruments: "永續合約規格"
        case .dci(let state, _):
            "雙幣贏" + (state.map { DCIOrder.activeStates.contains($0) ? "（\($0)）" : "" } ?? "（不限定狀態）")
        }
    }
    var path: String {
        switch self {
        case .time: "/api/v5/public/time"
        case .valuation: "/api/v5/asset/asset-valuation"
        case .trading: "/api/v5/account/balance"
        case .funding: "/api/v5/asset/balances"
        case .usdIndexPrices: "/api/v5/market/index-tickers"
        case .positions: "/api/v5/account/positions"
        case .swapInstruments: "/api/v5/public/instruments"
        case .dci: "/api/v5/finance/sfp/dcd/order-history"
        }
    }
    var query: [URLQueryItem] {
        switch self {
        case .valuation: [URLQueryItem(name: "ccy", value: "USD")]
        case .usdIndexPrices: [URLQueryItem(name: "quoteCcy", value: "USD")]
        case .positions(let type): type.map { [URLQueryItem(name: "instType", value: $0)] } ?? []
        case .swapInstruments: [URLQueryItem(name: "instType", value: "SWAP")]
        case .dci(let state, let endID):
            (state.map { [URLQueryItem(name: "state", value: $0)] } ?? [])
            + [URLQueryItem(name: "limit", value: "100")]
            + (endID.map { [URLQueryItem(name: "endId", value: $0)] } ?? [])
        default: []
        }
    }
}

struct OKXClient {
    let credentials: Credentials
    let session: URLSession
    let clockOffset: TimeInterval

    init(credentials: Credentials, session: URLSession = OKXClient.makeSession(), clockOffset: TimeInterval = 0) {
        self.credentials = credentials
        self.session = session
        self.clockOffset = clockOffset
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    static func signature(timestamp: String, requestPath: String, secret: String) -> String {
        let message = Data((timestamp + "GET" + requestPath).utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))).base64EncodedString()
    }

    func request(_ endpoint: Endpoint, date: Date = Date()) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = credentials.region.host
        components.path = endpoint.path
        if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
        guard let url = components.url else { throw OKXError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch endpoint {
        case .time, .swapInstruments, .usdIndexPrices: return request
        default: break
        }
        guard credentials.isValid else { throw OKXError.invalidCredentials }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date.addingTimeInterval(clockOffset))
        let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "OK-ACCESS-KEY")
        request.setValue(credentials.passphrase, forHTTPHeaderField: "OK-ACCESS-PASSPHRASE")
        request.setValue(timestamp, forHTTPHeaderField: "OK-ACCESS-TIMESTAMP")
        request.setValue(Self.signature(timestamp: timestamp, requestPath: path, secret: credentials.secretKey), forHTTPHeaderField: "OK-ACCESS-SIGN")
        return request
    }

    func get<T: Decodable>(_ endpoint: Endpoint) async throws -> [T] {
        let (data, response) = try await session.data(for: request(endpoint))
        guard let response = response as? HTTPURLResponse else { throw OKXError.invalidResponse }
        let decoder = JSONDecoder()
        // OKX 的驗證錯誤也可能搭配 HTTP 401；保留錯誤碼，才能與格式問題區分。
        let status = try? decoder.decode(APIStatus.self, from: data)
        if let status, status.code != "0" { throw OKXError.api(status.code) }
        guard (200..<300).contains(response.statusCode) else { throw OKXError.http(response.statusCode) }
        do {
            if status == nil { _ = try decoder.decode(APIStatus.self, from: data) }
            let envelope = try decoder.decode(APIEnvelope<T>.self, from: data)
            guard let values = envelope.data else {
                throw OKXError.responseFormat(endpoint: endpoint.diagnosticName, detail: "HTTP \(response.statusCode) · data 缺少或為 null，預期為陣列。")
            }
            return values
        } catch let error as DecodingError {
            throw OKXError.responseFormat(endpoint: endpoint.diagnosticName,
                detail: "HTTP \(response.statusCode) · " + ResponseDiagnostics.describe(error, data: data))
        }
    }

    func synchronized() async throws -> OKXClient {
        let before = Date()
        let time: [ServerTime] = try await get(.time)
        guard let raw = time.first?.ts, let milliseconds = Double(raw), milliseconds > 0 else { throw OKXError.invalidResponse }
        let midpoint = before.timeIntervalSince1970 + Date().timeIntervalSince(before) / 2
        return OKXClient(credentials: credentials, session: session, clockOffset: milliseconds / 1000 - midpoint)
    }

    func dciOrderReport() async throws -> DCIReport {
        var orders: [String: DCIOrder] = [:]
        var pageCount = 0
        var cursor: String?
        var seenCursors = Set<String>()
        while true {
            // 不用已知狀態限制遠端查詢，避免尚未識別的狀態在查詢階段就被排除。
            if pageCount > 0 { try await Task.sleep(for: .milliseconds(1100)) }
            try Task.checkCancellation()
            let page: [DCIOrder] = try await get(.dci(state: nil, endID: cursor))
            pageCount += 1
            for order in page where orders[order.id] == nil { orders[order.id] = order }
            if page.count < 100 { break }
            guard let next = page.last?.ordId, !next.isEmpty, seenCursors.insert(next).inserted else {
                throw OKXError.pagination
            }
            cursor = next
        }
        let sorted = orders.values.sorted { (Double($0.expirationTime ?? "") ?? .infinity) < (Double($1.expirationTime ?? "") ?? .infinity) }
        return DCIReport(orders: sorted, pageCount: pageCount)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // 私密簽章標頭只送至設定中的官方主機，不跟隨重新導向。
        completionHandler(nil)
    }
}
