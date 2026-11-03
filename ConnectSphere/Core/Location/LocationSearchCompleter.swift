import MapKit
import Observation

/// Thin `MKLocalSearchCompleter` wrapper for place autocomplete — the meeting
/// proposal's location field and the Marketplace location picker. Text-based
/// place/address search only, which needs no location permission.
@Observable
final class LocationSearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []

    private let completer: MKLocalSearchCompleter = {
        let c = MKLocalSearchCompleter()
        c.resultTypes = [.address, .pointOfInterest]
        return c
    }()

    override init() {
        super.init()
        completer.delegate = self
    }

    /// Updates the search query — matching results arrive asynchronously via
    /// `completerDidUpdateResults`. Clears immediately for an empty/whitespace
    /// fragment rather than waiting on the completer.
    func search(_ fragment: String) {
        guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }
        completer.queryFragment = fragment
    }

    /// Clears the results list (e.g. after a suggestion is picked, or the field loses focus).
    func clear() {
        results = []
        completer.queryFragment = ""
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}
