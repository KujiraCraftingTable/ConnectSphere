import Foundation
import Observation

/// "Deal history": your confirmed sales and purchases, kept 3 years so either
/// side can look a deal up or save a copy (Law 19/2023 Art. 39.3h).
@MainActor
@Observable
final class DealHistoryViewModel {
    private(set) var deals: [Deal] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    private let mode: AppMode
    private let repository = MarketplaceRepository()

    init(mode: AppMode) {
        self.mode = mode
    }

    func load(token: String) async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            deals = try await repository.deals(mode: mode, token: token)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// "150.000 ₫ × 2", or just "× 2" when the price wasn't recorded.
    static func amount(_ deal: Deal) -> String {
        guard let price = deal.itemPrice else { return "× \(deal.quantity)" }
        return "\(ListingPrice.grouped(price)) ₫ × \(deal.quantity)"
    }

    /// Every deal as plain text, one line each, to save or print from the share sheet.
    var exportText: String {
        let bundle = Bundle.app
        let lines = deals.map { d in
            let date = d.confirmedAt.formatted(date: .numeric, time: .omitted)
            let who = d.role == .sold
                ? String(format: bundle.loc("Sold to @%@"), d.otherUsername)
                : String(format: bundle.loc("Bought from @%@"), d.otherUsername)
            return "\(date) · \(who) · \(d.itemTitle) · \(Self.amount(d))"
        }
        return ([bundle.loc("ConnectSphere deal history")] + lines).joined(separator: "\n")
    }
}
