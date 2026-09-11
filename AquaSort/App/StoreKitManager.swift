import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class StoreKitManager {
    enum PurchaseStatus: Equatable {
        case loading
        case available(Product)
        case purchased
        case failed(String)
    }

    /// One-time Export Pack; unlocking MIDI and WAV export. Project-file export stays free.
    let unlockProductID = "com.bytepocket.studio.export"
    var status: PurchaseStatus = .loading
    /// Receipt-backed entitlement. Only a signed, verified, non-revoked transaction
    /// for the Export Pack sets this true — a successful product fetch never does.
    private(set) var hasReceiptEntitlement = false

    /// Entitlement updates for the life of the process: purchases made here,
    /// restores from other devices, and revocations (refunds, Family Sharing
    /// removal) all arrive as signed transactions on this stream.
    private var updatesTask: Task<Void, Never>?

    private func startTransactionObserverIfNeeded() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                guard let self, transaction.productID == self.unlockProductID else { continue }
                await self.syncEntitlement()
                await self.load()
            }
        }
    }

    /// Re-derives the entitlement from every current signed receipt entry.
    /// A revoked transaction (refund / Family Sharing removal) fails the check.
    func syncEntitlement() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productID == unlockProductID else { continue }
            if transaction.revocationDate == nil {
                owned = true
            }
        }
        hasReceiptEntitlement = owned
    }

    func load() async {
        startTransactionObserverIfNeeded()
        status = .loading
        // The receipt is checked first so a previously-purchased user stays
        // unlocked even if the product fetch below fails (offline, store outage).
        await syncEntitlement()
        if hasReceiptEntitlement {
            status = .purchased
            return
        }
        do {
            let products = try await Product.products(for: [unlockProductID])
            guard let product = products.first else {
                status = .failed("Product unavailable")
                return
            }
            status = .available(product)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func isPurchased() async -> Bool {
        await syncEntitlement()
        return hasReceiptEntitlement
    }

    func purchase() async -> Bool {
        guard case .available(let product) = status else { return false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return false }
                await transaction.finish()
                // Grant only after the signed transaction shows up in the receipt.
                await syncEntitlement()
                if hasReceiptEntitlement {
                    status = .purchased
                    return true
                }
                return false
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    func restore() async -> Bool {
        do {
            try await AppStore.sync()
            await syncEntitlement()
            if hasReceiptEntitlement { status = .purchased }
            return hasReceiptEntitlement
        } catch {
            return false
        }
    }

    /// Synchronous gate for export UI. True only when the receipt currently
    /// backs the Export Pack entitlement.
    var canExport: Bool {
        hasReceiptEntitlement
    }
}
