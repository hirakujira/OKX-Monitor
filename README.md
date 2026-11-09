# OKX Monitor

個人使用的 SwiftUI iPhone App，用來查看另一個 OKX 帳戶的資產與持倉。僅供查詢，無交易功能、後端服務或第三方套件。

## 功能

- **資產**：總資產及資金／交易／賺幣分類，各幣餘額依 USD 價值排序。
- **永續合約**：多空、幣數、損益與強平價，依名目價值排序。
- **雙幣贏**：訂單狀態、本金、收益率、到期時間與兩種結算情境的預估收益。
- **期權**：持倉、損益與 Greeks，依名目價值排序。

前景自動更新目前分頁，支援下拉重新整理；沒有金鑰也可使用示範模式。

## 安裝與設定

1. 使用 Xcode 27.2 或更新版本開啟 `OKXMonitor.xcodeproj`。
2. 在 **Signing & Capabilities** 選擇開發 Team，必要時修改 Bundle Identifier。
3. 連接 iPhone、啟用 Developer Mode，選擇 `OKXMonitor` scheme 並執行。最低支援 iOS 17。
4. 在 App「API 設定」輸入 **API Key、Secret Key、Passphrase** 與帳戶地區。

建議先使用 **Read** 權限的金鑰；雙幣贏可用性依帳戶與地區而定。若設定 IP 白名單，需包含手機的網路出口。金鑰僅儲存在此裝置的 Keychain，請求直接送至 OKX。

## 開發

核心邏輯位於 `OKXMonitor/Core`，SwiftUI 介面位於 `OKXMonitor/App`。

```sh
# 核心測試
swift test

# 模擬器建置
xcodebuild -project OKXMonitor.xcodeproj -scheme OKXMonitor \
  -sdk iphonesimulator -derivedDataPath /tmp/okx-monitor-build \
  CODE_SIGNING_ALLOWED=NO build
```

UI 測試可在 Xcode 執行，使用內建示範資料。
