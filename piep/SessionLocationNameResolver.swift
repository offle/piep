//
//  SessionLocationNameResolver.swift
//  piep
//
//  Created by Codex on 06.06.26.
//

import CoreLocation
import Foundation
import MapKit

enum SessionLocationNameResolver {

    nonisolated static func resolve(
        latitude: Double,
        longitude: Double
    ) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)

        guard let request = MKReverseGeocodingRequest(location: location),
              let mapItem = try? await mapItems(for: request).first
        else {
            return nil
        }

        let placemark = mapItem.placemark
        let city = firstNonEmpty([
            placemark.locality,
            placemark.subAdministrativeArea,
            placemark.name,
        ])
        let region = firstNonEmpty([
            placemark.administrativeArea,
            placemark.subAdministrativeArea,
        ])
        let country = firstNonEmpty([
            placemark.country,
            placemark.isoCountryCode,
        ])

        return joinedUnique([city, region, country])
    }

    nonisolated private static func mapItems(
        for request: MKReverseGeocodingRequest
    ) async throws -> [MKMapItem] {
        try await withCheckedThrowingContinuation { continuation in
            request.getMapItems { mapItems, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: mapItems ?? [])
                }
            }
        }
    }

    nonisolated private static func firstNonEmpty(_ values: [String?]) -> String? {
        values
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .first
    }

    nonisolated private static func joinedUnique(_ values: [String?]) -> String? {
        var seen = Set<String>()
        let parts = values.compactMap { value -> String? in
            guard let value else { return nil }
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { return nil }
            return value
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }
}
