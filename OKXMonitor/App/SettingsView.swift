import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Credentials()
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(store.credentials == nil ? "尚未設定帳戶" : "已儲存一組金鑰", systemImage: "lock.shield")
                }
                Section {
                    SecureField("API Key", text: $draft.apiKey).accessibilityIdentifier("apiKey")
                    SecureField("Secret Key", text: $draft.secretKey).accessibilityIdentifier("secretKey")
                    SecureField("Passphrase", text: $draft.passphrase).accessibilityIdentifier("passphrase")
                } header: { Text("\(store.credentials == nil ? "" : "更換")API 金鑰") } footer: {
                    Text("Passphrase 為 API 密語。更換金鑰時需重填三項。")
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                Section {
                    Picker("API 地區", selection: $draft.region) {
                        ForEach(APIRegion.allCases) { region in Text(region.title).tag(region) }
                    }
                    Text(draft.region.host).font(.caption.monospaced()).foregroundStyle(.secondary)
                } footer: { Text("依帳戶註冊地區選擇；僅支援正式帳戶。") }
                Section("權限與儲存") {
                    Text("使用 Read 權限，僅供查詢。")
                    Text("金鑰儲存於本機 Keychain，不同步至 iCloud。")
                }.font(.footnote)
                if let error { Section { ErrorNote(message: error) } }
                Section {
                    Button("儲存並讀取帳戶") {
                        do {
                            draft.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.secretKey = draft.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            try store.save(draft)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!draft.isValid)
                    if store.isDemo {
                        Button("離開示範模式") { store.leaveDemo(); dismiss() }
                    }
                    if store.credentials != nil {
                        Button("移除此裝置的金鑰", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle("API 設定").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .onAppear { draft.region = store.credentials?.region ?? .global }
            .confirmationDialog("移除儲存在此裝置的 API 金鑰？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("移除金鑰及畫面資料", role: .destructive) {
                    do { try store.remove(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("不會刪除 OKX 帳戶或取消任何持倉。") }
        }
    }
}
