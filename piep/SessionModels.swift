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
    var id: UUID
    var scientificName: String
    var germanName: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date?
    var syncRecordName: String?
    var lastSyncedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \BirdSpeciesImage.species)
    var images: [BirdSpeciesImage]

    @Relationship(deleteRule: .nullify, inverse: \SessionSpeciesObservation.species)
    var observations: [SessionSpeciesObservation]

    init(scientificName: String, germanName: String) {
        self.id = UUID()
        self.scientificName = scientificName
        self.germanName = germanName
        self.createdAt = Date()
        self.updatedAt = Date()
        self.deletedAt = nil
        self.syncRecordName = nil
        self.lastSyncedAt = nil
        self.images = []
        self.observations = []
    }

    var relevantObservations: [SessionSpeciesObservation] {
        observations.filter {
            !$0.isDeleted && $0.status != .discarded && !$0.isExcludedHumanSound
        }
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

    func markUpdated(at date: Date = Date()) {
        updatedAt = date
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
    var id: UUID
    var title: String
    var author: String
    var license: String
    var sourceURLString: String
    var fileName: String
    var createdAt: Date
    var updatedAt: Date = Date()
    var deletedAt: Date?
    var species: BirdSpecies?

    init(
        title: String,
        author: String,
        license: String,
        sourceURL: URL,
        fileName: String,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.license = license
        self.sourceURLString = sourceURL.absoluteString
        self.fileName = fileName
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
    }

    var sourceURL: URL? {
        URL(string: sourceURLString)
    }
}

@Model
final class BirdSession {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var latitude: Double?
    var longitude: Double?
    var locationName: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date?
    var syncRecordName: String?
    var lastSyncedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \SessionSpeciesObservation.session)
    var observations: [SessionSpeciesObservation]

    init(
        startedAt: Date = Date(),
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil
    ) {
        let createdAt = Date()
        self.id = UUID()
        self.startedAt = startedAt
        self.endedAt = nil
        self.latitude = latitude
        self.longitude = longitude
        self.locationName = locationName
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
        self.syncRecordName = nil
        self.lastSyncedAt = nil
        self.observations = []
    }

    var isDeleted: Bool {
        deletedAt != nil
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
        observations.filter {
            !$0.isDeleted && $0.status != .discarded && !$0.isExcludedHumanSound
        }
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

    func markUpdated(at date: Date = Date()) {
        updatedAt = date
    }

    func markDeleted(at date: Date = Date()) {
        deletedAt = date
        updatedAt = date
        for observation in observations {
            observation.markDeleted(at: date)
        }
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
    var id: UUID
    var sessionID: UUID?
    var speciesID: UUID?
    var scientificNameSnapshot: String = ""
    var germanNameSnapshot: String = ""
    var bestConfidence: Float
    var firstDetectedAt: Date
    var lastDetectedAt: Date
    var detectionCount: Int
    var statusRawValue: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date?
    var syncRecordName: String?
    var lastSyncedAt: Date?
    var session: BirdSession?
    var species: BirdSpecies?

    init(
        species: BirdSpecies,
        confidence: Float,
        detectedAt: Date = Date(),
        status: DetectionReviewStatus = .confirmed
    ) {
        self.id = UUID()
        self.sessionID = nil
        self.speciesID = species.id
        self.scientificNameSnapshot = species.scientificName
        self.germanNameSnapshot = species.germanName
        self.bestConfidence = confidence
        self.firstDetectedAt = detectedAt
        self.lastDetectedAt = detectedAt
        self.detectionCount = 1
        self.statusRawValue = status.rawValue
        self.createdAt = detectedAt
        self.updatedAt = detectedAt
        self.deletedAt = nil
        self.syncRecordName = nil
        self.lastSyncedAt = nil
        self.species = species
    }

    var scientificName: String {
        if !scientificNameSnapshot.isEmpty {
            return scientificNameSnapshot
        }

        return species?.scientificName ?? "Unbekannte Art"
    }

    var germanName: String {
        if !germanNameSnapshot.isEmpty {
            return germanNameSnapshot
        }

        return species?.germanName ?? "Unbekannt"
    }

    var status: DetectionReviewStatus {
        get {
            DetectionReviewStatus(rawValue: statusRawValue) ?? .pending
        }
        set {
            statusRawValue = newValue.rawValue
            markUpdated()
        }
    }

    var isDeleted: Bool {
        deletedAt != nil || session?.isDeleted == true
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
        updatedAt = detectedAt
        return didIncrementCount
    }

    func attach(to session: BirdSession) {
        self.session = session
        self.sessionID = session.id
    }

    func markUpdated(at date: Date = Date()) {
        updatedAt = date
    }

    func markDeleted(at date: Date = Date()) {
        deletedAt = date
        updatedAt = date
        statusRawValue = DetectionReviewStatus.discarded.rawValue
    }
}

typealias SessionBirdDetection = SessionSpeciesObservation

@MainActor
enum LocalDataMigration {
    private static let modelVersionKey = "localDataModelVersion"
    private static let currentModelVersion = 2

    static func runIfNeeded(modelContext: ModelContext) {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: modelVersionKey) < currentModelVersion else {
            return
        }

        migrateSessionDerivedIdentity(modelContext: modelContext)
        defaults.set(currentModelVersion, forKey: modelVersionKey)
    }

    private static func migrateSessionDerivedIdentity(
        modelContext: ModelContext
    ) {
        let sessionDescriptor = FetchDescriptor<BirdSession>()
        let sessions = (try? modelContext.fetch(sessionDescriptor)) ?? []
        var didChange = false

        for session in sessions {
            if session.createdAt > session.startedAt {
                session.createdAt = session.startedAt
                didChange = true
            }
            if session.updatedAt < session.startedAt {
                session.updatedAt = session.endedAt ?? session.startedAt
                didChange = true
            }

            for observation in session.observations {
                if observation.sessionID != session.id {
                    observation.sessionID = session.id
                    didChange = true
                }

                if let species = observation.species {
                    if observation.speciesID != species.id {
                        observation.speciesID = species.id
                        didChange = true
                    }
                    if observation.scientificNameSnapshot.isEmpty {
                        observation.scientificNameSnapshot = species.scientificName
                        didChange = true
                    }
                    if observation.germanNameSnapshot.isEmpty {
                        observation.germanNameSnapshot = species.germanName
                        didChange = true
                    }
                }

                if observation.createdAt > observation.firstDetectedAt {
                    observation.createdAt = observation.firstDetectedAt
                    didChange = true
                }
                if observation.updatedAt < observation.lastDetectedAt {
                    observation.updatedAt = observation.lastDetectedAt
                    didChange = true
                }
            }
        }

        if didChange {
            try? modelContext.save()
        }
    }
}
