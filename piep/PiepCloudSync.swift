//
//  PiepCloudSync.swift
//  piep
//
//  Created by Codex on 17.06.26.
//

import CloudKit
import Foundation
import SwiftData

@Observable
@MainActor
final class PiepCloudSyncManager {

    static let shared = PiepCloudSyncManager()

    private(set) var statusText = "Nicht synchronisiert"
    private(set) var lastSyncDate: Date?
    private(set) var lastErrorMessage: String?
    private(set) var isSyncing = false

    private let container = CKContainer(identifier: "iCloud.org.offlepoffle1.piep")
    private let zoneID = CKRecordZone.ID(
        zoneName: "Piep",
        ownerName: CKCurrentUserDefaultName
    )

    private init() {}

    func syncIfEnabled(modelContext: ModelContext) {
        guard AppSettings.iCloudSyncEnabled else {
            statusText = "iCloud Sync ist deaktiviert"
            return
        }

        Task {
            await sync(modelContext: modelContext)
        }
    }

    func sync(modelContext: ModelContext) async {
        guard !isSyncing else { return }
        guard AppSettings.iCloudSyncEnabled else {
            statusText = "iCloud Sync ist deaktiviert"
            return
        }

        isSyncing = true
        lastErrorMessage = nil
        statusText = "Synchronisiere..."

        do {
            try await ensureAccountAvailable()
            try await ensureZoneExists()
            let remoteSnapshot = try await fetchRemoteSnapshot()
            try merge(remoteSnapshot: remoteSnapshot, modelContext: modelContext)
            try await uploadLocalChanges(modelContext: modelContext)
            lastSyncDate = Date()
            statusText = "Zuletzt synchronisiert \(Self.timeFormatter.string(from: lastSyncDate!))"
            try? modelContext.save()
        } catch {
            lastErrorMessage = error.localizedDescription
            statusText = "Sync fehlgeschlagen"
        }

        isSyncing = false
    }

    private func ensureAccountAvailable() async throws {
        let status = try await container.accountStatus()
        guard status == .available else {
            throw PiepCloudSyncError.accountUnavailable(status)
        }
    }

    private func ensureZoneExists() async throws {
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneID: zoneID)

        do {
            _ = try await database.save(zone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(zone)
        } catch let error as CKError where error.code == .partialFailure {
            return
        }
    }

    private func fetchRemoteSnapshot() async throws -> RemoteSnapshot {
        let sessions = try await fetchRecords(
            type: CloudRecordType.session.rawValue
        )
        let observations = try await fetchRecords(
            type: CloudRecordType.observation.rawValue
        )

        return RemoteSnapshot(
            sessions: sessions.compactMap(CloudSession.init(record:)),
            observations: observations.compactMap(CloudObservation.init(record:))
        )
    }

    private func fetchRecords(type: String) async throws -> [CKRecord] {
        let database = container.privateCloudDatabase
        let query = CKQuery(
            recordType: type,
            predicate: NSPredicate(value: true)
        )

        var allRecords: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        let firstResult = try await database.records(
            matching: query,
            inZoneWith: zoneID
        )
        allRecords.append(contentsOf: firstResult.matchResults.compactMap {
            try? $0.1.get()
        })
        cursor = firstResult.queryCursor

        while let currentCursor = cursor {
            let result = try await database.records(continuingMatchFrom: currentCursor)
            allRecords.append(contentsOf: result.matchResults.compactMap {
                try? $0.1.get()
            })
            cursor = result.queryCursor
        }

        return allRecords
    }

    private func merge(
        remoteSnapshot: RemoteSnapshot,
        modelContext: ModelContext
    ) throws {
        let localSessions = try modelContext.fetch(FetchDescriptor<BirdSession>())
        let localObservations = try modelContext.fetch(
            FetchDescriptor<SessionSpeciesObservation>()
        )
        let localSpecies = try modelContext.fetch(FetchDescriptor<BirdSpecies>())
        var sessionsByID = Dictionary(uniqueKeysWithValues: localSessions.map { ($0.id, $0) })
        var observationsByID = Dictionary(uniqueKeysWithValues: localObservations.map { ($0.id, $0) })
        var speciesByScientificName = Dictionary(
            uniqueKeysWithValues: localSpecies.map { ($0.scientificName, $0) }
        )

        for remoteSession in remoteSnapshot.sessions {
            if let local = sessionsByID[remoteSession.id] {
                merge(remoteSession, into: local)
            } else {
                let session = BirdSession(
                    startedAt: remoteSession.startedAt,
                    latitude: remoteSession.latitude,
                    longitude: remoteSession.longitude,
                    locationName: remoteSession.locationName
                )
                session.id = remoteSession.id
                apply(remoteSession, to: session)
                modelContext.insert(session)
                sessionsByID[session.id] = session
            }
        }

        for remoteObservation in remoteSnapshot.observations {
            guard let session = sessionsByID[remoteObservation.sessionID] else {
                continue
            }

            let species = species(
                scientificName: remoteObservation.scientificName,
                germanName: remoteObservation.germanName,
                speciesByScientificName: &speciesByScientificName,
                modelContext: modelContext
            )

            if let local = observationsByID[remoteObservation.id] {
                merge(remoteObservation, into: local, session: session, species: species)
            } else if let duplicate = session.observations.first(where: {
                !$0.isDeleted && $0.scientificName == remoteObservation.scientificName
            }) {
                merge(remoteObservation, into: duplicate, session: session, species: species)
                observationsByID[remoteObservation.id] = duplicate
            } else {
                let observation = SessionSpeciesObservation(
                    species: species,
                    confidence: remoteObservation.bestConfidence,
                    detectedAt: remoteObservation.firstDetectedAt,
                    status: remoteObservation.status
                )
                observation.id = remoteObservation.id
                observation.attach(to: session)
                apply(remoteObservation, to: observation, species: species)
                session.observations.append(observation)
                observationsByID[observation.id] = observation
            }
        }

        try modelContext.save()
    }

    private func merge(_ remote: CloudSession, into local: BirdSession) {
        guard remote.updatedAt >= local.updatedAt else { return }
        apply(remote, to: local)
    }

    private func apply(_ remote: CloudSession, to local: BirdSession) {
        local.startedAt = remote.startedAt
        local.endedAt = remote.endedAt
        local.latitude = remote.latitude
        local.longitude = remote.longitude
        local.locationName = remote.locationName
        local.createdAt = min(local.createdAt, remote.createdAt)
        local.updatedAt = remote.updatedAt
        local.deletedAt = newest(local.deletedAt, remote.deletedAt)
        local.syncRecordName = remote.recordName
        local.lastSyncedAt = Date()
    }

    private func merge(
        _ remote: CloudObservation,
        into local: SessionSpeciesObservation,
        session: BirdSession,
        species: BirdSpecies
    ) {
        if remote.deletedAt != nil || remote.updatedAt >= local.updatedAt {
            apply(remote, to: local, species: species)
            local.attach(to: session)
            return
        }

        local.bestConfidence = max(local.bestConfidence, remote.bestConfidence)
        local.firstDetectedAt = min(local.firstDetectedAt, remote.firstDetectedAt)
        local.lastDetectedAt = max(local.lastDetectedAt, remote.lastDetectedAt)
        local.detectionCount = max(local.detectionCount, remote.detectionCount)
        local.lastSyncedAt = Date()
    }

    private func apply(
        _ remote: CloudObservation,
        to local: SessionSpeciesObservation,
        species: BirdSpecies
    ) {
        local.species = species
        local.speciesID = species.id
        local.scientificNameSnapshot = remote.scientificName
        local.germanNameSnapshot = remote.germanName
        local.bestConfidence = remote.bestConfidence
        local.firstDetectedAt = remote.firstDetectedAt
        local.lastDetectedAt = remote.lastDetectedAt
        local.detectionCount = remote.detectionCount
        local.statusRawValue = remote.status.rawValue
        local.createdAt = min(local.createdAt, remote.createdAt)
        local.updatedAt = remote.updatedAt
        local.deletedAt = newest(local.deletedAt, remote.deletedAt)
        local.syncRecordName = remote.recordName
        local.lastSyncedAt = Date()
    }

    private func uploadLocalChanges(modelContext: ModelContext) async throws {
        let sessions = try modelContext.fetch(FetchDescriptor<BirdSession>())
        let observations = try modelContext.fetch(
            FetchDescriptor<SessionSpeciesObservation>()
        )

        var recordsToSave: [CKRecord] = []
        recordsToSave.append(contentsOf: sessions.filter(needsUpload).map(sessionRecord))
        recordsToSave.append(contentsOf: observations.filter(needsUpload).compactMap {
            observationRecord($0)
        })

        guard !recordsToSave.isEmpty else { return }

        let database = container.privateCloudDatabase
        let result = try await database.modifyRecords(
            saving: recordsToSave,
            deleting: []
        )
        let now = Date()
        let savedIDs = Set(result.saveResults.compactMap { try? $0.value.get().recordID.recordName })

        for session in sessions {
            if savedIDs.contains(recordName(forSessionID: session.id)) {
                session.syncRecordName = recordName(forSessionID: session.id)
                session.lastSyncedAt = now
            }
        }

        for observation in observations {
            if savedIDs.contains(recordName(forObservationID: observation.id)) {
                observation.syncRecordName = recordName(forObservationID: observation.id)
                observation.lastSyncedAt = now
            }
        }
    }

    private func needsUpload(_ session: BirdSession) -> Bool {
        guard let lastSyncedAt = session.lastSyncedAt else { return true }
        return session.updatedAt > lastSyncedAt
    }

    private func needsUpload(_ observation: SessionSpeciesObservation) -> Bool {
        guard observation.sessionID != nil || observation.session?.id != nil else {
            return false
        }
        guard let lastSyncedAt = observation.lastSyncedAt else { return true }
        return observation.updatedAt > lastSyncedAt
    }

    private func sessionRecord(_ session: BirdSession) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: recordName(forSessionID: session.id),
            zoneID: zoneID
        )
        let record = CKRecord(recordType: CloudRecordType.session.rawValue, recordID: recordID)
        record["id"] = session.id.uuidString
        record["startedAt"] = session.startedAt
        record["endedAt"] = session.endedAt
        record["latitude"] = session.latitude
        record["longitude"] = session.longitude
        record["locationName"] = session.locationName
        record["createdAt"] = session.createdAt
        record["updatedAt"] = session.updatedAt
        record["deletedAt"] = session.deletedAt
        return record
    }

    private func observationRecord(
        _ observation: SessionSpeciesObservation
    ) -> CKRecord? {
        guard let sessionID = observation.sessionID ?? observation.session?.id else {
            return nil
        }

        let recordID = CKRecord.ID(
            recordName: recordName(forObservationID: observation.id),
            zoneID: zoneID
        )
        let record = CKRecord(recordType: CloudRecordType.observation.rawValue, recordID: recordID)
        record["id"] = observation.id.uuidString
        record["sessionID"] = sessionID.uuidString
        record["scientificName"] = observation.scientificName
        record["germanName"] = observation.germanName
        record["bestConfidence"] = Double(observation.bestConfidence)
        record["firstDetectedAt"] = observation.firstDetectedAt
        record["lastDetectedAt"] = observation.lastDetectedAt
        record["detectionCount"] = observation.detectionCount
        record["status"] = observation.status.rawValue
        record["createdAt"] = observation.createdAt
        record["updatedAt"] = observation.updatedAt
        record["deletedAt"] = observation.deletedAt
        return record
    }

    private func species(
        scientificName: String,
        germanName: String,
        speciesByScientificName: inout [String: BirdSpecies],
        modelContext: ModelContext
    ) -> BirdSpecies {
        if let existing = speciesByScientificName[scientificName] {
            if existing.germanName != germanName {
                existing.germanName = germanName
                existing.markUpdated()
            }
            return existing
        }

        let created = BirdSpecies(
            scientificName: scientificName,
            germanName: germanName
        )
        modelContext.insert(created)
        speciesByScientificName[scientificName] = created
        return created
    }

    private func recordName(forSessionID id: UUID) -> String {
        "session_\(id.uuidString)"
    }

    private func recordName(forObservationID id: UUID) -> String {
        "observation_\(id.uuidString)"
    }

    private func newest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return max(lhs, rhs)
        case let (.some(lhs), .none):
            return lhs
        case let (.none, .some(rhs)):
            return rhs
        case (.none, .none):
            return nil
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private enum CloudRecordType: String {
    case session = "PiepSession"
    case observation = "PiepObservation"
}

private struct RemoteSnapshot {
    let sessions: [CloudSession]
    let observations: [CloudObservation]
}

private struct CloudSession {
    let recordName: String
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let latitude: Double?
    let longitude: Double?
    let locationName: String?
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    init?(record: CKRecord) {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let startedAt = record["startedAt"] as? Date,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date
        else {
            return nil
        }

        self.recordName = record.recordID.recordName
        self.id = id
        self.startedAt = startedAt
        self.endedAt = record["endedAt"] as? Date
        self.latitude = record["latitude"] as? Double
        self.longitude = record["longitude"] as? Double
        self.locationName = record["locationName"] as? String
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = record["deletedAt"] as? Date
    }
}

private struct CloudObservation {
    let recordName: String
    let id: UUID
    let sessionID: UUID
    let scientificName: String
    let germanName: String
    let bestConfidence: Float
    let firstDetectedAt: Date
    let lastDetectedAt: Date
    let detectionCount: Int
    let status: DetectionReviewStatus
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    init?(record: CKRecord) {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let sessionIDString = record["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString),
              let scientificName = record["scientificName"] as? String,
              let germanName = record["germanName"] as? String,
              let bestConfidence = record["bestConfidence"] as? Double,
              let firstDetectedAt = record["firstDetectedAt"] as? Date,
              let lastDetectedAt = record["lastDetectedAt"] as? Date,
              let detectionCount = record["detectionCount"] as? Int,
              let statusRawValue = record["status"] as? String,
              let status = DetectionReviewStatus(rawValue: statusRawValue),
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date
        else {
            return nil
        }

        self.recordName = record.recordID.recordName
        self.id = id
        self.sessionID = sessionID
        self.scientificName = scientificName
        self.germanName = germanName
        self.bestConfidence = Float(bestConfidence)
        self.firstDetectedAt = firstDetectedAt
        self.lastDetectedAt = lastDetectedAt
        self.detectionCount = detectionCount
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = record["deletedAt"] as? Date
    }
}

private enum PiepCloudSyncError: LocalizedError {
    case accountUnavailable(CKAccountStatus)

    var errorDescription: String? {
        switch self {
        case let .accountUnavailable(status):
            return "iCloud ist nicht verfügbar: \(status.localizedDescription)"
        }
    }
}

private extension CKAccountStatus {
    var localizedDescription: String {
        switch self {
        case .available:
            return "verfügbar"
        case .couldNotDetermine:
            return "Status unbekannt"
        case .noAccount:
            return "kein iCloud Account"
        case .restricted:
            return "eingeschränkt"
        case .temporarilyUnavailable:
            return "vorübergehend nicht verfügbar"
        @unknown default:
            return "unbekannt"
        }
    }
}
