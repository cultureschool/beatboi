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
                    // Seeded before the first load, so the entitlement the fixture plants is
                    // folded in by the same reconcile that reads a real receipt.
                    storeKit.seedEntitlementForUITestIfNeeded()
                    await storeKit.load()
                    // The persisted flag speeds up first paint; the receipt is the
                    // source of truth and reconciles it both directions.
                    if await storeKit.isPurchased() {
                        store.setUnlocked(true)
                    } else {
                        store.setUnlocked(false)
                    }
                }
        }
    }
}

struct BeatboiRootView: View {
    @Environment(GameStore.self) private var store

    var body: some View {
        EditorView()
            .font(.custom("Futura-Medium", size: 14))
            .preferredColorScheme(.dark)
    }
}
