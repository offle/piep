//
//  LocationManager.swift
//  piep
//
//  Created by Ole on 02.06.26.
//

import CoreLocation

/// Manages device location for species range filtering.
/// Provides lat/lon to the BirdNET meta-model for improved accuracy.
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {

    var latitude: Double?
    var longitude: Double?
    var statusMessage: String = "Standort wird ermittelt…"

    var hasLocation: Bool { latitude != nil && longitude != nil }

    private let manager = CLLocationManager()
    private var locationRequestAttempts = 0
    private let maxLocationRequestAttempts = 5

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Request location — triggers authorization if needed.
    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            requestOneShotLocation(resetAttempts: true)
        case .denied, .restricted:
            statusMessage = "📍 Standort nicht erlaubt"
        @unknown default:
            break
        }
    }

    private func requestOneShotLocation(resetAttempts: Bool = false) {
        if resetAttempts {
            locationRequestAttempts = 0
        }

        locationRequestAttempts += 1
        statusMessage = manager.accuracyAuthorization == .reducedAccuracy
            ? "📍 Ungefährer Standort wird gesucht…"
            : "📍 Genauer Standort wird gesucht…"
        manager.requestLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        Task { @MainActor in
            self.locationRequestAttempts = 0
            self.latitude = lat
            self.longitude = lon
            self.statusMessage = String(
                format: "📍 %.2f°N, %.2f°E",
                lat, lon
            )
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        let nsError = error as NSError
        let code = CLError.Code(rawValue: nsError.code)
        Task { @MainActor in
            if code == .locationUnknown,
               self.locationRequestAttempts < self.maxLocationRequestAttempts
            {
                self.statusMessage = "📍 Standort wird gesucht…"
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.requestOneShotLocation()
                return
            }

            self.statusMessage = self.message(for: error)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.requestOneShotLocation(resetAttempts: true)
            case .denied, .restricted:
                self.statusMessage = "📍 Standort nicht erlaubt"
            default:
                break
            }
        }
    }

    private func message(for error: Error) -> String {
        let nsError = error as NSError
        guard let code = CLError.Code(rawValue: nsError.code) else {
            return "📍 Standort nicht verfügbar"
        }

        switch code {
        case .locationUnknown:
            return "📍 Standort noch nicht verfügbar"
        case .denied:
            return "📍 Standort nicht erlaubt"
        case .network:
            return "📍 Standortnetzwerk nicht verfügbar"
        default:
            return "📍 Standort nicht verfügbar"
        }
    }
}
