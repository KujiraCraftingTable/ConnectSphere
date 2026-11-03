import CoreLocation

/// Where the phone is, for Dating. A dating location only ever comes from
/// GPS — never a typed place — so nobody can pose as being somewhere else to
/// look at people there. Others only see the district and city.
@MainActor
struct DatingLocationProvider {
    enum Outcome {
        case place(PickedPlace)
        /// Location is off for the app (or the phone); Dating can't be used.
        case denied
        case failed
    }

    /// Whether iOS already said no, so the app can explain before asking again.
    var isDenied: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Asks for "While using the app" permission when needed, then reads one fix.
    func currentPlace() async -> Outcome {
        // Holding the session asks for "while using" permission when needed.
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                    return .denied
                }
                guard let location = update.location else { continue }
                return .place(await Self.named(location))
            }
        } catch {
            return .failed
        }
        return .failed
    }

    /// The local area and the city, e.g. "Bến Thành, Hồ Chí Minh" — never the
    /// street. Since Vietnam's 2025 reform a ward sits straight under its
    /// province, so the parts are read from most local to widest, and the
    /// first and last kept.
    private static func named(_ location: CLLocation) async -> PickedPlace {
        let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        let parts = [mark?.subLocality, mark?.subAdministrativeArea, mark?.locality, mark?.administrativeArea]
            .compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let name = (parts.count > 2 ? [parts[0], parts[parts.count - 1]] : parts).joined(separator: ", ")
        return PickedPlace(name: name.isEmpty ? Bundle.app.loc("Your area") : name,
                           latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    /// Kilometres between two places, to skip tiny moves.
    static func distanceKm(_ a: PickedPlace, _ b: (latitude: Double, longitude: Double)) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1000
    }
}
