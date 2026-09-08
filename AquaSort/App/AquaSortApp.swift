import SwiftUI

@main
struct AquaSortApp: App {
    @State private var store = GameStore()
    @State private var storeKit = StoreKitManager()

    var body: some Scene {
        WindowGroup {
            BeatboiRootView()
                .environment(store)
                .environment(storeKit)
                .task {
                    await storeKit.load()
                    if await storeKit.isPurchased() {
                        store.setUnlocked(true)
                    }
                }
        }
    }
}

struct BeatboiRootView: View {
    @Environment(GameStore.self) private var store

    var body: some View {
        EditorView()
            .preferredColorScheme(.dark)
    }
}
