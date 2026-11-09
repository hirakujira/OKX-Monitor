import SwiftUI

@main
struct OKXMonitorApp: App {
    @StateObject private var store = MonitorStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(.mint)
                .preferredColorScheme(.dark)
                .overlay {
                    if scenePhase != .active {
                        ZStack {
                            Color(.systemBackground).ignoresSafeArea()
                            Label("OKX Monitor", systemImage: "lock.shield")
                                .font(.title2.bold())
                        }
                    }
                }
                .task(id: "\(scenePhase)-\(store.generation)-\(store.selectedTab.scope.rawValue)") {
                    guard scenePhase == .active else { store.cancelRefresh(); return }
                    while !Task.isCancelled {
                        await store.refresh()
                        do { try await Task.sleep(for: .seconds(5)) }
                        catch { return }
                    }
                }
        }
    }
}
