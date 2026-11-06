import MapKit
import SwiftUI

/// Sell / Edit listing: where the item is, picked on a map. Search for a
/// place or use the phone's location. Done hands back the pinned place.
struct ListingLocationPicker: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let onDone: (PickedPlace) -> Void
    @State private var viewModel: LocationPickerViewModel
    @State private var camera: MapCameraPosition
    @State private var isSearching = false

    init(place: PickedPlace?, onDone: @escaping (PickedPlace) -> Void) {
        self.onDone = onDone
        _viewModel = State(initialValue: LocationPickerViewModel(place: place))
        _camera = State(initialValue: place.map(Self.camera) ?? .automatic)
    }

    nonisolated private static func camera(_ place: PickedPlace) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.suggestions, id: \.self) { suggestion in
                        Button {
                            Task<Void, Never>(name: nil) { await viewModel.pick(suggestion) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .scaledFont(13)
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                }
                            }
                        }
                    }
                }
                if let place = viewModel.place, viewModel.suggestions.isEmpty {
                    Section {
                        Map(position: $camera) {
                            Marker(place.name, coordinate: place.coordinate)
                                .tint(themeManager.theme.primary)
                        }
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                        Label(place.name, systemImage: "mappin.and.ellipse")
                    }
                }
                Section {
                    Button {
                        Task<Void, Never>(name: nil) { await viewModel.useCurrentLocation() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "location.fill")
                            Text("Use my current location", bundle: bundle)
                            Spacer()
                            if viewModel.isLocating { ProgressView() }
                        }
                        .foregroundColor(themeManager.theme.primary)
                    }
                    .disabled(viewModel.isLocating)
                } footer: {
                    if let error = viewModel.errorMessage { Text(error).foregroundColor(.red) }
                }
            }
            .searchable(text: $viewModel.query, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: bundle.loc("Search places"))
            .onChange(of: viewModel.place) { _, new in
                // Close the search once a place is pinned, so Done shows.
                isSearching = false
                if let new { withAnimation { camera = Self.camera(new) } }
            }
            .tint(themeManager.theme.primary)
            .navigationTitle(Text("Choose location", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Done")) {
                        if let place = viewModel.place { onDone(place) }
                        dismiss()
                    }
                    .disabled(viewModel.place == nil)
                }
            }
        }
    }
}

/// The Location row in the Sell and Edit forms: the chosen place, or a prompt
/// to choose one, with a button to clear it.
struct ListingLocationRow: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @Binding var place: PickedPlace?
    @State private var showPicker = false

    var body: some View {
        HStack(spacing: 10) {
            Button { showPicker = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundColor(themeManager.theme.primary)
                    Text(place?.name ?? bundle.loc("Choose location"))
                        .foregroundColor(place == nil ? AppColors.textTertiary(colorScheme) : AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if place != nil {
                Button { place = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear location", bundle: bundle))
            }
        }
        .sheet(isPresented: $showPicker) {
            ListingLocationPicker(place: place) { place = $0 }
                .environment(themeManager)
        }
    }
}

/// The listing page's small map with a pin; tapping it opens Apple Maps.
struct ListingMapPreview: View {
    let latitude: Double
    let longitude: Double
    let name: String

    private var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)),
            interactionModes: []) {
            Marker(name, coordinate: coordinate)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            item.name = name
            item.openInMaps()
        }
        .accessibilityElement()
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(.isButton)
    }
}
