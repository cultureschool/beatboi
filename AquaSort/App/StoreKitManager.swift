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

    /// One-time optional FX cartridge; the four-channel core remains free.
    let unlockProductID = "com.bytepocket.studio.unlock"
    var status: PurchaseStatus = .loading

    func load() async {
        status = .loading
        do {
            let products = try await Product.products(for: [unlockProductID])
            guard let product = products.first else {
                status = .failed("Product unavailable")
                return
            }
            status = await isPurchased() ? .purchased : .available(product)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func isPurchased() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == unlockProductID {
                return true
            }
        }
        return false
    }

    func purchase() async -> Bool {
        guard case .available(let product) = status else { return false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return false }
                await transaction.finish()
                status = .purchased
                return true
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
            let owned = await isPurchased()
            if owned { status = .purchased }
            return owned
        } catch {
            return false
        }
    }
}
