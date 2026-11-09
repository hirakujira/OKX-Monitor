import SwiftUI

extension MonitorTab {
    var icon: String {
        switch self {
        case .balances: "wallet.bifold"
        case .perpetuals: "chart.line.uptrend.xyaxis"
        case .dci: "arrow.left.arrow.right.circle"
        case .options: "chart.xyaxis.line"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: MonitorStore
    @State private var showSettings = false

    var body: some View {
        Group {
            if store.hasAccount {
                TabView(selection: $store.selectedTab) {
                    ForEach(MonitorTab.allCases) { item in
                        NavigationStack {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 18) {
                                    if store.isDemo {
                                        Text("示範資料").font(.caption).foregroundStyle(.mint)
                                    }
                                    switch item {
                                    case .balances: balances
                                    case .perpetuals: positions(store.perpetuals)
                                    case .dci: dualInvestment
                                    case .options: positions(store.options)
                                    }
                                }
                                .padding()
                                .frame(maxWidth: 680)
                                .frame(maxWidth: .infinity)
                            }
                            .background(Color(.systemGroupedBackground))
                            .refreshable { await store.refresh(force: true) }
                            .navigationTitle(item.rawValue)
                            .toolbar {
                                ToolbarItemGroup(placement: .topBarTrailing) {
                                    if store.isRefreshing { ProgressView().accessibilityLabel("更新中") }
                                    else {
                                        Button { Task { await store.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                                            .accessibilityLabel("重新整理").disabled(store.isDemo)
                                    }
                                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                                        .accessibilityLabel("API 設定")
                                }
                            }
                        }
                        .tabItem { Label(item.rawValue, systemImage: item.icon) }.tag(item)
                    }
                }
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 48)).foregroundStyle(.mint).padding(.top, 35)
                            Text("查看 OKX 帳戶")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                            Text("資產、永續合約、雙幣贏與期權。")
                                .foregroundStyle(.secondary)
                            if let error = store.storageError { ErrorNote(message: error) }
                            Button("設定 API 金鑰") { showSettings = true }
                                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                            Button("先看示範畫面") { store.showDemo() }
                                .frame(maxWidth: .infinity)
                            Text("使用 Read 權限金鑰，僅儲存於此裝置。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.padding(28).frame(maxWidth: 600).frame(maxWidth: .infinity)
                    }
                    .navigationTitle("OKX Monitor").navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var balances: some View {
        VStack(alignment: .leading, spacing: 18) {
            ResourceStatus(resource: store.valuation, loading: store.isRefreshing)
            if let valuation = store.valuation.value {
                VStack(alignment: .leading, spacing: 14) {
                    Text("總資產（USD）").foregroundStyle(.secondary)
                    Text("$\(Numbers.format(valuation.totalBal, places: 2))")
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6)
                    Divider()
                    Metric(label: "資金帳戶", value: "$\(Numbers.format(valuation.details.funding, places: 2))")
                    Metric(label: "交易帳戶", value: "$\(Numbers.format(valuation.details.trading, places: 2))")
                    Metric(label: "賺幣", value: "$\(Numbers.format(valuation.details.earn, places: 2))")
                    if let classic = Numbers.decimal(valuation.details.classic), classic != 0 {
                        Metric(label: "經典帳戶", value: "$\(Numbers.format(valuation.details.classic, places: 2))")
                    }
                }.card()
            }
            sectionTitle("交易帳戶", count: store.trading.value?.details.count)
            ResourceStatus(resource: store.trading, loading: store.isRefreshing)
            if let account = store.trading.value {
                if account.details.isEmpty { EmptyNote(text: "無餘額") }
                ForEach(BalanceValuation.sortedTrading(account.details)) { coin in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(coin.ccy).font(.title3.bold())
                            Spacer()
                            Text("≈ $\(Numbers.format(coin.eqUsd, places: 2))").foregroundStyle(.secondary)
                        }
                        Metric(label: "現金餘額", value: Numbers.format(coin.cashBal))
                        Metric(label: "權益（含浮動損益）", value: Numbers.format(coin.eq))
                        let equity = Numbers.decimal(coin.eq)
                        let available = Numbers.decimal(coin.availBal)
                        if equity == nil || available == nil || equity != available {
                            Metric(label: "可用餘額", value: Numbers.format(coin.availBal))
                        }
                        if Numbers.decimal(coin.frozenBal) != 0 {
                            Metric(label: "凍結", value: Numbers.format(coin.frozenBal))
                        }
                        if let liability = Numbers.decimal(coin.liab), liability != 0 {
                            Metric(label: "負債", value: Numbers.format(coin.liab))
                        }
                    }.card()
                }
            }
            sectionTitle("資金帳戶", count: store.funding.value?.count)
            ResourceStatus(resource: store.funding, loading: store.isRefreshing)
            if let coins = store.funding.value {
                if coins.isEmpty { EmptyNote(text: "無餘額") }
                ForEach(BalanceValuation.sortedFunding(coins)) { coin in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(coin.ccy).font(.title3.bold())
                            Spacer()
                            Text(coin.usdValue.map { "≈ $\(Numbers.format($0, places: 2))" } ?? "USD —")
                                .foregroundStyle(.secondary)
                        }
                        Metric(label: "餘額", value: Numbers.format(coin.bal))
                        Metric(label: "可用", value: Numbers.format(coin.availBal))
                        if Numbers.decimal(coin.frozenBal) != 0 {
                            Metric(label: "凍結", value: Numbers.format(coin.frozenBal))
                        }
                    }.card()
                }
            }
        }
    }

    private func positions(_ resource: Resource<[Position]>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("持倉", count: resource.value?.count)
            ResourceStatus(resource: resource, loading: store.isRefreshing)
            if let items = resource.value {
                if items.isEmpty { EmptyNote(text: "無持倉") }
                ForEach(Position.sortedByNotional(items)) { position in PositionCard(position: position) }
            }
        }
    }

    private var dualInvestment: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("進行中", count: store.dci.value?.activeOrders.count)
            ResourceStatus(resource: store.dci, loading: store.isRefreshing, staleAfter: 300)
            if let report = store.dci.value {
                if report.activeOrders.isEmpty && report.unrecognizedOrders.isEmpty {
                    EmptyNote(text: report.orders.isEmpty ? "API 未回傳訂單" : "API 未回傳進行中的訂單")
                }
                ForEach(report.activeOrders) { order in dciCard(order) }
                if !report.unrecognizedOrders.isEmpty {
                    sectionTitle("狀態待確認", count: report.unrecognizedOrders.count)
                    ForEach(report.unrecognizedOrders) { order in dciCard(order) }
                }
                if !report.closedOrders.isEmpty {
                    DisclosureGroup("已結束（\(report.closedOrders.count)）") {
                        LazyVStack(spacing: 14) {
                            ForEach(report.closedOrders.reversed()) { order in dciCard(order) }
                        }.padding(.top, 12)
                    }
                }
                Text("共 \(report.orders.count) 筆 · \(report.pageCount) 頁 · 已結束 \(report.closedOrders.count) 筆")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func dciCard(_ order: DCIOrder) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(order.baseCcy ?? order.notionalCcy ?? "") · \(order.strategy)").font(.title3.bold())
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(order.needsReview ? "待確認：\(order.state)" : order.stateTitle(at: context.date))
                        .foregroundStyle(order.needsReview ? .orange : .mint).font(.subheadline)
                }
            }
            Text(order.productId).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Metric(label: "投入本金", value: "\(Numbers.format(order.notionalSz)) \(order.notionalCcy ?? "")")
            Metric(label: "目標價", value: "\(Numbers.format(order.strike)) \(order.quoteCcy ?? "")")
            Metric(label: "年化收益率", value: Numbers.percent(order.annualizedYield))
            Metric(label: "本期收益率", value: Numbers.percent(order.absYield))
            if order.hasReportedYield || order.isClosed {
                Metric(label: "收益", value: order.yieldText)
            }
            Metric(label: "到期時間", value: Numbers.date(order.expirationTime))
            DisclosureGroup("詳細資料") {
                VStack(alignment: .leading, spacing: 14) {
                    if !order.hasReportedYield && !order.isClosed {
                        if order.yieldEstimates.isEmpty {
                            Metric(label: "預估到期收益", value: "—")
                        } else {
                            Text("預估到期收益").font(.caption).foregroundStyle(.secondary)
                            ForEach(order.yieldEstimates) { estimate in
                                Metric(label: estimate.condition, value: estimate.text)
                            }
                        }
                    }
                    Metric(label: "申購時間", value: Numbers.date(order.cTime, includeSeconds: true))
                    Metric(label: "生息時間", value: Numbers.date(order.accrualStartTime, includeSeconds: true))
                    Text("訂單 \(order.ordId)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.top, 12)
            }.font(.subheadline)
        }.card()
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let count { Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }
}

struct PositionCard: View {
    let position: Position
    private static let longProfitColor = Color(.sRGB, red: 203 / 255.0, green: 252 / 255.0, blue: 84 / 255.0, opacity: 1)
    private static let shortLossColor = Color(.sRGB, red: 229 / 255.0, green: 85 / 255.0, blue: 169 / 255.0, opacity: 1)
    private static let liquidationColor = Color(.sRGB, red: 226 / 255.0, green: 111 / 255.0, blue: 49 / 255.0, opacity: 1)
    private var directionColor: Color { position.isShort ? Self.shortLossColor : Self.longProfitColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(position.instId).font(.headline).textSelection(.enabled)
            HStack(spacing: 10) {
                Text(position.direction).foregroundStyle(directionColor)
                Text(position.mgnMode == "isolated" ? "逐倉" : "全倉").foregroundStyle(.secondary)
                if let lever = position.lever, !lever.isEmpty { Text("\(Numbers.format(lever))×").foregroundStyle(.secondary) }
            }.font(.caption.bold())
            if let contract = position.option {
                Metric(label: "類型", value: contract.type)
                Metric(label: "到期日（UTC）", value: contract.expiry)
                Metric(label: "履約價", value: "\(Numbers.format(contract.strike)) USD")
            }
            Metric(label: "持倉數量", value: position.quantityText, valueColor: directionColor)
            Metric(label: "平均開倉價", value: "\(Numbers.format(position.avgPx)) \(position.priceCurrency)")
            Metric(label: "標記價格", value: "\(Numbers.format(position.markPx)) \(position.priceCurrency)")
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("未實現損益").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Numbers.format(position.upl)) \(position.ccy ?? "")").font(.headline.monospacedDigit())
                    Text(Numbers.percent(position.uplRatio)).font(.caption.monospacedDigit())
                }.foregroundStyle((Numbers.decimal(position.upl) ?? 0) < 0 ? Self.shortLossColor : Self.longProfitColor)
            }
            if position.instType == "SWAP" {
                Metric(label: "預估強平價", value: "\(Numbers.format(position.liqPx, places: 2, fixedDecimals: true)) \(position.priceCurrency)", valueColor: Self.liquidationColor)
                Metric(label: "名目價值（USD）", value: Numbers.format(position.notionalUsd, places: 2))
            } else {
                Text("Greeks · Black–Scholes（美元）").font(.caption).foregroundStyle(.secondary)
                Metric(label: "Delta / Gamma", value: "\(Numbers.format(position.deltaBS)) / \(Numbers.format(position.gammaBS))")
                Metric(label: "Theta / Vega", value: "\(Numbers.format(position.thetaBS)) / \(Numbers.format(position.vegaBS))")
            }
        }.card()
    }
}

struct Metric: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
                .foregroundStyle(valueColor)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.font(.subheadline)
    }
}

struct ResourceStatus<Value>: View {
    let resource: Resource<Value>
    let loading: Bool
    var staleAfter: TimeInterval = 90
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = resource.error {
                ErrorNote(message: (resource.value == nil ? "" : "更新失敗，以下為上次資料。\n") + error)
            }
            if let date = resource.updatedAt {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let stale = context.date.timeIntervalSince(date) > staleAfter
                    Text("\(stale ? "資料可能已過期 · " : "")更新於 \(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2).foregroundStyle(stale ? .orange : .secondary)
                }
            } else if resource.error == nil {
                HStack {
                    if loading { ProgressView() }
                    Text(loading ? "正在讀取…" : "等待更新").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ErrorNote: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            .padding().background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct EmptyNote: View {
    let text: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray").font(.largeTitle)
            Text(text).font(.subheadline)
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(32).card()
    }
}

extension View {
    func card() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
