import CoreLocation
import MapKit
import Observation

/// A place picked on the map: what buyers read, and where its pin goes.
nonisolated struct PickedPlace: Equatable {
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Where a listing's item is — a searched place, or the phone's current
/// location (which asks for permission the first time).
@MainActor
@Observable
final class LocationPickerViewModel {
    var query = "" {
        didSet { completer.search(query) }
    }
    private(set) var place: PickedPlace?
    private(set) var isLocating = false
    var errorMessage: String?

    let completer = LocationSearchCompleter()

    init(place: PickedPlace?) { self.place = place }

    var suggestions: [MKLocalSearchCompletion] { completer.results }

    /// Turns a suggestion into a pinned place.
    func pick(_ suggestion: MKLocalSearchCompletion) async {
        errorMessage = nil
        do {
            let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion)).start()
            guard let item = response.mapItems.first else { return }
            let name = [suggestion.title, suggestion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
            let coordinate = item.placemark.coordinate
            place = PickedPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
            query = ""
            completer.clear()
        } catch {
            errorMessage = Bundle.app.loc("Couldn't find that place")
        }
    }

    /// The phone's location, named by its district and city.
    func useCurrentLocation() async {
        errorMessage = nil
        isLocating = true
        defer { isLocating = false }
        // Holding the session asks for "while using" permission when needed.
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                    errorMessage = Bundle.app.loc("Location access is off. Turn it on in Settings to use your current location.")
                    return
                }
                guard let location = update.location else { continue }
                let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first
                let name = [mark?.subLocality ?? mark?.name, mark?.subAdministrativeArea, mark?.locality ?? mark?.administrativeArea]
                    .compactMap { $0 }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    .joined(separator: ", ")
                place = PickedPlace(name: name.isEmpty ? Bundle.app.loc("Current location") : name,
                                    latitude: location.coordinate.latitude,
                                    longitude: location.coordinate.longitude)
                return
            }
        } catch {
            errorMessage = Bundle.app.loc("Couldn't get your location")
        }
    }
}
