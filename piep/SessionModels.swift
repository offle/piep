//
//  SessionModels.swift
//  piep
//
//  Created by Codex on 03.06.26.
//

import Foundation
import SwiftData

enum DetectionReviewStatus: String, Codable, CaseIterable {
    case pending
    case confirmed
    case discarded

    var label: String {
        switch self {
        case .pending:
            return "gefunden"
        case .confirmed:
            return "gefunden"
        case .discarded:
            return "verworfen"
        }
    }
}

@Model
final class BirdSpecies {
    var id: UUID = UUID()
    var scientificName: String = ""
    var germanName: String = ""

    @Relationship(deleteRule: .nullify, inverse: \SessionSpeciesObservation.species)
    var observations: [SessionSpeciesObservation] = []

    init(scientificName: String, germanName: String) {
        self.id = UUID()
        self.scientificName = scientificName
        self.germanName = germanName
        self.observations = []
    }

    var relevantObservations: [SessionSpeciesObservation] {
        observations.filter { $0.status != .discarded && !$0.isExcludedHumanSound }
    }

    var firstObservedAt: Date? {
        relevantObservations
            .map(\.firstDetectedAt)
            .min()
    }

    var lastObservedAt: Date? {
        relevantObservations
            .map(\.lastDetectedAt)
            .max()
    }

    var firstObservationSessionID: UUID? {
        relevantObservations
            .min { $0.firstDetectedAt < $1.firstDetectedAt }?
            .session?.id
    }

    var uniqueSessionCount: Int {
        Set(relevantObservations.compactMap { $0.session?.id }).count
    }

    var isNewlyDiscovered: Bool {
        uniqueSessionCount <= 1
    }
}

@Model
final class BirdSpeciesImage {
    var id: UUID = UUID()
    var speciesScientificName: String = ""
    var title: String = ""
    var author: String = ""
    var license: String = ""
    var sourceURLString: String = ""
    var fileName: String = ""
    var createdAt: Date = Date()

    init(
        speciesScientificName: String,
        title: String,
        author: String,
        license: String,
        sourceURL: URL,
        fileName: String,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.speciesScientificName = speciesScientificName
        self.title = title
        self.author = author
        self.license = license
        self.sourceURLString = sourceURL.absoluteString
        self.fileName = fileName
        self.createdAt = createdAt
    }

    var sourceURL: URL? {
        URL(string: sourceURLString)
    }
}

@Model
final class BirdSession {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    var latitude: Double?
    var longitude: Double?
    var locationName: String?

    @Relationship(deleteRule: .cascade, inverse: \SessionSpeciesObservation.session)
    var observations: [SessionSpeciesObservation] = []

    init(
        startedAt: Date = Date(),
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil
    ) {
        self.id = UUID()
        self.startedAt = startedAt
        self.endedAt = nil
        self.latitude = latitude
        self.longitude = longitude
        self.locationName = locationName
        self.observations = []
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var locationDescription: String {
        if let locationName, !locationName.isEmpty {
            return locationName
        }

        if latitude != nil, longitude != nil {
            return "Ort wird ermittelt"
        }

        return "Ort unbekannt"
    }

    var coordinateDescription: String? {
        guard let latitude, let longitude else {
            return nil
        }

        let latitudeDirection = latitude >= 0 ? "N" : "S"
        let longitudeDirection = longitude >= 0 ? "E" : "W"
        return String(
            format: "%.2f %@, %.2f %@",
            abs(latitude),
            latitudeDirection,
            abs(longitude),
            longitudeDirection
        )
    }

    var displayTitle: String {
        locationDescription
    }

    var dateDescription: String {
        Self.dateFormatter.string(from: startedAt)
    }

    var reviewedDetections: [SessionSpeciesObservation] {
        observations.filter { $0.status != .discarded && !$0.isExcludedHumanSound }
    }

    var visibleDetections: [SessionSpeciesObservation] {
        reviewedDetections
    }

    var confirmedCount: Int {
        reviewedDetections.count
    }

    var detections: [SessionSpeciesObservation] {
        get { observations }
        set { observations = newValue }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

@Model
final class SessionSpeciesObservation {
    var id: UUID = UUID()
    var bestConfidence: Float = 0
    var firstDetectedAt: Date = Date()
    var lastDetectedAt: Date = Date()
    var detectionCount: Int = 0
    var statusRawValue: String = DetectionReviewStatus.confirmed.rawValue
    var session: BirdSession?
    var species: BirdSpecies?

    init(
        species: BirdSpecies,
        confidence: Float,
        detectedAt: Date = Date(),
        status: DetectionReviewStatus = .confirmed
    ) {
        self.id = UUID()
        self.bestConfidence = confidence
        self.firstDetectedAt = detectedAt
        self.lastDetectedAt = detectedAt
        self.detectionCount = 1
        self.statusRawValue = status.rawValue
        self.species = species
    }

    var scientificName: String {
        species?.scientificName ?? "Unbekannte Art"
    }

    var germanName: String {
        species?.germanName ?? "Unbekannt"
    }

    var status: DetectionReviewStatus {
        get {
            DetectionReviewStatus(rawValue: statusRawValue) ?? .pending
        }
        set {
            statusRawValue = newValue.rawValue
        }
    }

    var isExcludedHumanSound: Bool {
        scientificName.hasPrefix("Human ")
            || germanName.hasPrefix("Mensch ")
    }

    var isFirstObservationForSpecies: Bool {
        species?.firstObservationSessionID == session?.id
    }

    @discardableResult
    func merge(
        confidence: Float,
        detectedAt: Date = Date(),
        countCooldown: TimeInterval = 0
    ) -> Bool {
        bestConfidence = max(bestConfidence, confidence)
        let didIncrementCount: Bool
        if countCooldown > 0 {
            let elapsedSinceFirstDetection = max(
                0,
                detectedAt.timeIntervalSince(firstDetectedAt)
            )
            let detectionWindowIndex = Int(elapsedSinceFirstDetection / countCooldown)
            didIncrementCount = detectionWindowIndex + 1 > detectionCount
        } else {
            didIncrementCount = true
        }

        if didIncrementCount {
            detectionCount += 1
        }

        lastDetectedAt = detectedAt
        return didIncrementCount
    }
}

typealias SessionBirdDetection = SessionSpeciesObservation
