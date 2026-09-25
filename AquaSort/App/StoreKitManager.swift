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

    /// One receipt entry, reduced to the two fields the entitlement rule needs.
    struct EntitlementEntry: Equatable {
        let productID: String
        let revocationDate: Date?
    }

    /// One-time Export Pack; unlocking WAV audio export. Project-file export stays free.
    ///
    /// This must be the identifier the product actually carries in App Store Connect. That app's
    /// live product is `exportunlock`, and an in-app purchase identifier cannot be renamed once the
    /// product exists, so the code side is the side that conforms. It was previously
    /// `com.bytepocket.studio.export`, which no live product answered to — `Product.products(for:)`
    /// came back empty and the pack was unbuyable while the local StoreKit config, which the same
    /// string also satisfies, kept it looking healthy in Xcode.
    let unlockProductID = "exportunlock"
    var status: PurchaseStatus = .loading
    /// Receipt-backed entitlement. Only a signed, verified, non-revoked transaction
    /// for the Export Pack sets this true — a successful product fetch never does.
    private(set) var hasReceiptEntitlement = false

    /// Products this process has seen a signed, unrevoked transaction for.
    ///
    /// This is a floor under the receipt, not a replacement for it. `purchase()`
    /// returns only after the user has been charged, and `Transaction.currentEntitlements`
    /// can lag that moment by a beat — so a re-read is the wrong thing to gate on.
    /// Doing so returned `false` from a successful purchase, left the paywall up, and
    /// left a paying user tapping UNLOCK again. A refund still lowers the floor,
    /// because a revocation arrives as a signed transaction of its own.
    private var sessionVerifiedGrants: Set<String> = []

    /// The pure half of the entitlement rule, split out so it is testable without a
    /// live store: the Export Pack is owned when at least one receipt entry is for the
    /// product and has not been revoked. Refunds and Family Sharing removals set a
    /// revocation date, which clears the claim.
    nonisolated static func isOwned(productID: String, in entries: [EntitlementEntry]) -> Bool {
        entries.contains { $0.productID == productID && $0.revocationDate == nil }
    }

    /// Folds a signed transaction into the in-session floor: an unrevoked transaction
    /// raises it, a revocation lowers it.
    private func record(_ transaction: Transaction) {
        if transaction.revocationDate == nil {
            sessionVerifiedGrants.insert(transaction.productID)
        } else {
            sessionVerifiedGrants.remove(transaction.productID)
        }
    }

    /// Entitlement updates for the life of the process: purchases made here,
    /// restores from other devices, and revocations (refunds, Family Sharing
    /// removal) all arrive as signed transactions on this stream.
    private var updatesTask: Task<Void, Never>?

    private func startTransactionObserverIfNeeded() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                guard let self else { return }
                // Record the grant before acknowledging the transaction, so a
                // crash in between cannot leave a paid transaction acknowledged
                // but ungranted.
                self.record(transaction)
                let relevant = transaction.productID == self.unlockProductID
                await transaction.finish()
                guard relevant else { continue }
                await self.syncEntitlement()
                await self.load()
            }
        }
    }

    /// Re-derives the entitlement from the in-session grant floor plus every current
    /// signed receipt entry. A revoked transaction (refund / Family Sharing removal)
    /// fails the check and lowers the floor with it.
    func syncEntitlement() async {
        var entries: [EntitlementEntry] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            entries.append(EntitlementEntry(productID: transaction.productID, revocationDate: transaction.revocationDate))
        }
        if entries.contains(where: { $0.productID == unlockProductID && $0.revocationDate != nil }) {
            sessionVerifiedGrants.remove(unlockProductID)
        }
        hasReceiptEntitlement = sessionVerifiedGrants.contains(unlockProductID)
            || Self.isOwned(productID: unlockProductID, in: entries)
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
                // Grant from the signed transaction in hand. The user has already been
                // charged by this point, so this must not wait on — or be undone by — a
                // receipt re-read that can lag the purchase behind it.
                record(transaction)
                await transaction.finish()
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
        } catch {
            // A cancelled Apple ID prompt is not a failed entitlement check: fall
            // through and reconcile against whatever the receipt already holds.
        }
        await syncEntitlement()
        if hasReceiptEntitlement { status = .purchased }
        return hasReceiptEntitlement
    }

    /// Synchronous gate for export UI. True only when the receipt currently
    /// backs the Export Pack entitlement.
    var canExport: Bool {
        hasReceiptEntitlement
    }
}
