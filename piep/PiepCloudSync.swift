//
//  PiepCloudSync.swift
//  piep
//
//  Created by Codex on 18.06.26.
//

import CloudKit
import Foundation
import SwiftData

@Observable
@MainActor
final class PiepCloudSyncManager {

    static let shared = PiepCloudSyncManager()

    private(set) var statusText = "Nicht synchronisiert"
    private(set) var accountText = "unbekannt"
    private(set) var remoteSessionCount: Int?
    private(set) var remoteVisibleSessionCount: Int?
    private(set) var remoteObservationCount: Int?
    private(set) var remoteVisibleObservationCount: Int?
    private(set) var remoteSpeciesCount: Int?
    private(set) var remoteVisibleSpeciesCount: Int?
    private(set) var lastSyncDate: Date?
    private(set) var lastErrorMessage: String?
    private(set) var pendingSessionUploadCount = 0
    private(set) var pendingObservationUploadCount = 0
    private(set) var lastUploadIssue: String?
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
        lastUploadIssue = nil
        statusText = "Synchronisiere..."

        do {
            let accountStatus = try await container.accountStatus()
            accountText = Self.accountText(for: accountStatus)
            guard accountStatus == .available else {
                throw PiepCloudSyncError.accountUnavailable(accountStatus)
            }

            try await ensureZoneExists()
            let remoteSnapshot = try await fetchRemoteSnapshot()
            updateRemoteCounts(from: remoteSnapshot)
            try merge(remoteSnapshot: remoteSnapshot, modelContext: modelContext)
            try await uploadLocalChanges(modelContext: modelContext)
            try modelContext.save()

            let verifiedSnapshot = try await fetchRemoteSnapshot()
            try merge(remoteSnapshot: verifiedSnapshot, modelContext: modelContext)
            try modelContext.save()
            updateRemoteCounts(
                from: verifiedSnapshot,
                minimum: try localSyncCounts(modelContext: modelContext)
            )

            lastSyncDate = Date()
            statusText = "Zuletzt synchronisiert \(Self.timeFormatter.string(from: lastSyncDate!))"
        } catch {
            lastErrorMessage = error.localizedDescription
            statusText = "Sync fehlgeschlagen"
        }

        isSyncing = false
    }

    private func ensureZoneExists() async throws {
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneID: zoneID)

        do {
            _ = try await database.save(zone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return
        } catch let error as CKError where error.code == .partialFailure {
            return
        }
    }

    private func updateRemoteCounts(
        from snapshot: RemoteSnapshot,
        minimum: CloudSyncCounts? = nil
    ) {
        let snapshotCounts = CloudSyncCounts(
            visibleSessions: snapshot.sessions.filter { $0.deletedAt == nil }.count,
            sessions: snapshot.sessions.count,
            visibleObservations: visibleObservations(in: snapshot).count,
            observations: snapshot.observations.count,
            visibleSpecies: Set(visibleObservations(in: snapshot).map(\.scientificName)).count,
            species: Set(snapshot.observations.map(\.scientificName)).count
        )

        remoteVisibleSessionCount = max(snapshotCounts.visibleSessions, minimum?.visibleSessions ?? 0)
        remoteSessionCount = max(snapshotCounts.sessions, minimum?.sessions ?? 0)
        remoteVisibleObservationCount = max(
            snapshotCounts.visibleObservations,
            minimum?.visibleObservations ?? 0
        )
        remoteObservationCount = max(snapshotCounts.observations, minimum?.observations ?? 0)
        remoteVisibleSpeciesCount = max(snapshotCounts.visibleSpecies, minimum?.visibleSpecies ?? 0)
        remoteSpeciesCount = max(snapshotCounts.species, minimum?.species ?? 0)
    }

    private func visibleObservations(in snapshot: RemoteSnapshot) -> [CloudObservation] {
        let visibleSessionIDs = Set(
            snapshot.sessions
                .filter { $0.deletedAt == nil }
                .map(\.id)
        )

        return snapshot.observations.filter {
            $0.deletedAt == nil
                && $0.status != .discarded
                && visibleSessionIDs.contains($0.sessionID)
                && !$0.scientificName.hasPrefix("Human ")
                && !$0.germanName.hasPrefix("Mensch ")
        }
    }

    private func fetchRemoteSnapshot() async throws -> RemoteSnapshot {
        let records = try await fetchAllRecordsInSyncZone()
        let sessions = records.filter { $0.recordType == CloudRecordType.session.rawValue }
        let observations = records.filter { $0.recordType == CloudRecordType.observation.rawValue }

        return RemoteSnapshot(
            sessions: sessions.compactMap(CloudSession.init(record:)),
            observations: observations.compactMap(CloudObservation.init(record:))
        )
    }

    private func fetchAllRecordsInSyncZone() async throws -> [CKRecord] {
        let database = container.privateCloudDatabase
        var allRecords: [CKRecord] = []
        var previousToken: CKServerChangeToken?
        var moreComing = true

        while moreComing {
            let result = try await fetchRecordZoneChanges(
                database: database,
                previousServerChangeToken: previousToken
            )
            allRecords.append(contentsOf: result.records)
            previousToken = result.serverChangeToken
            moreComing = result.moreComing
        }

        return allRecords
    }

    private func fetchRecordZoneChanges(
        database: CKDatabase,
        previousServerChangeToken: CKServerChangeToken?
    ) async throws -> ZoneChangeFetchResult {
        try await withCheckedThrowingContinuation { continuation in
            var records: [CKRecord] = []
            var zoneResult: Result<
                (serverChangeToken: CKServerChangeToken, clientChangeTokenData: Data?, moreComing: Bool),
                Error
            >?

            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: previousServerChangeToken
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )

            operation.recordWasChangedBlock = { _, recordResult in
                if let record = try? recordResult.get() {
                    records.append(record)
                }
            }

            operation.recordZoneFetchResultBlock = { _, fetchChangesResult in
                zoneResult = fetchChangesResult
            }

            operation.fetchRecordZoneChangesResultBlock = { operationResult in
                switch operationResult {
                case .success:
                    switch zoneResult {
                    case let .success(result):
                        continuation.resume(
                            returning: ZoneChangeFetchResult(
                                records: records,
                                serverChangeToken: result.serverChangeToken,
                                moreComing: result.moreComing
                            )
                        )
                    case let .failure(error):
                        if let ckError = error as? CKError,
                           ckError.code == .zoneNotFound || ckError.code == .unknownItem {
                            continuation.resume(
                                returning: ZoneChangeFetchResult(
                                    records: [],
                                    serverChangeToken: previousServerChangeToken,
                                    moreComing: false
                                )
                            )
                        } else {
                            continuation.resume(throwing: error)
                        }
                    case .none:
                        continuation.resume(
                            returning: ZoneChangeFetchResult(
                                records: records,
                                serverChangeToken: previousServerChangeToken,
                                moreComing: false
                            )
                        )
                    }
                case let .failure(error):
                    if let ckError = error as? CKError,
                       ckError.code == .zoneNotFound || ckError.code == .unknownItem {
                        continuation.resume(
                            returning: ZoneChangeFetchResult(
                                records: [],
                                serverChangeToken: previousServerChangeToken,
                                moreComing: false
                            )
                        )
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }

            database.add(operation)
        }
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
        guard PiepConflictResolver.remoteWins(
            localUpdatedAt: local.updatedAt,
            remoteUpdatedAt: remote.updatedAt
        ) else { return }
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
        local.deletedAt = PiepConflictResolver.mergedDeletion(
            local: local.deletedAt,
            remote: remote.deletedAt
        )
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
        local.deletedAt = PiepConflictResolver.mergedDeletion(
            local: local.deletedAt,
            remote: remote.deletedAt
        )
        local.syncRecordName = remote.recordName
        local.lastSyncedAt = Date()
    }

    private func uploadLocalChanges(modelContext: ModelContext) async throws {
        let sessions = try modelContext.fetch(FetchDescriptor<BirdSession>())
        let observations = try modelContext.fetch(
            FetchDescriptor<SessionSpeciesObservation>()
        )

        let dirtySessions = sessions.filter(needsUpload)
        let dirtyObservations = observations.filter(needsUpload)
        let syncDate = Date()
        var savedRecordNames = Set<String>()
        var saveErrors: [String] = []

        pendingSessionUploadCount = dirtySessions.count
        pendingObservationUploadCount = dirtyObservations.count
        lastUploadIssue = nil

        for session in dirtySessions {
            do {
                try await save(record: sessionRecord(session))
                savedRecordNames.insert(recordName(for: session.id))
            } catch {
                saveErrors.append(uploadErrorText(recordName: recordName(for: session.id), error: error))
            }
        }

        for observation in dirtyObservations {
            guard let record = observationRecord(observation) else {
                saveErrors.append("\(recordName(for: observation.id)): Session fehlt")
                continue
            }
            do {
                try await save(record: record)
                savedRecordNames.insert(recordName(for: observation.id))
            } catch {
                saveErrors.append(uploadErrorText(recordName: recordName(for: observation.id), error: error))
            }
        }

        for session in dirtySessions where savedRecordNames.contains(recordName(for: session.id)) {
            session.syncRecordName = recordName(for: session.id)
            session.lastSyncedAt = syncDate
        }

        for observation in dirtyObservations where savedRecordNames.contains(recordName(for: observation.id)) {
            observation.syncRecordName = recordName(for: observation.id)
            observation.lastSyncedAt = syncDate
        }

        try modelContext.save()

        pendingSessionUploadCount = dirtySessions.filter {
            !savedRecordNames.contains(recordName(for: $0.id))
        }.count
        pendingObservationUploadCount = dirtyObservations.filter {
            !savedRecordNames.contains(recordName(for: $0.id))
        }.count
        lastUploadIssue = saveErrors.first

        if !saveErrors.isEmpty {
            throw PiepCloudSyncError.partialUpload(saveErrors)
        }

        pendingSessionUploadCount = 0
        pendingObservationUploadCount = 0
        lastUploadIssue = nil
    }

    private func save(record: CKRecord) async throws {
        let database = container.privateCloudDatabase
        do {
            try await save(record: record, database: database)
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let serverRecord = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else {
                throw error
            }

            let localUpdatedAt = record["updatedAt"] as? Date ?? .distantPast
            let serverUpdatedAt = serverRecord["updatedAt"] as? Date ?? .distantPast
            guard !PiepConflictResolver.remoteWins(
                localUpdatedAt: localUpdatedAt,
                remoteUpdatedAt: serverUpdatedAt
            ) else {
                return
            }

            for key in record.allKeys() {
                serverRecord[key] = record[key]
            }
            try await save(record: serverRecord, database: database)
        }
    }

    private func save(record: CKRecord, database: CKDatabase) async throws {
        let result = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .changedKeys,
            atomically: false
        )
        if let saveResult = result.saveResults[record.recordID] {
            _ = try saveResult.get()
        }
    }

    private func uploadErrorText(recordName: String, error: Error) -> String {
        if let cloudError = error as? CKError {
            return "\(recordName): \(cloudError.code)"
        }
        return "\(recordName): \(error.localizedDescription)"
    }

    private func localSyncCounts(modelContext: ModelContext) throws -> CloudSyncCounts {
        let sessions = try modelContext.fetch(FetchDescriptor<BirdSession>())
        let observations = try modelContext.fetch(
            FetchDescriptor<SessionSpeciesObservation>()
        )
        let species = Set(observations.map(\.scientificName))
        let visibleObservations = observations.filter {
            !$0.isDeleted && $0.status != .discarded && !$0.isExcludedHumanSound
        }

        return CloudSyncCounts(
            visibleSessions: sessions.filter { !$0.isDeleted }.count,
            sessions: sessions.count,
            visibleObservations: visibleObservations.count,
            observations: observations.count,
            visibleSpecies: Set(visibleObservations.map(\.scientificName)).count,
            species: species.count
        )
    }

    private func needsUpload(_ session: BirdSession) -> Bool {
        guard let lastSyncedAt = session.lastSyncedAt else { return true }
        return session.updatedAt > lastSyncedAt
            || session.deletedAt.map { $0 > lastSyncedAt } == true
    }

    private func needsUpload(_ observation: SessionSpeciesObservation) -> Bool {
        guard let lastSyncedAt = observation.lastSyncedAt else { return true }
        return observation.updatedAt > lastSyncedAt
            || observation.deletedAt.map { $0 > lastSyncedAt } == true
    }

    private func sessionRecord(_ session: BirdSession) -> CKRecord {
        let record = CKRecord(
            recordType: CloudRecordType.session.rawValue,
            recordID: CKRecord.ID(recordName: recordName(for: session.id), zoneID: zoneID)
        )
        record["id"] = session.id.uuidString
        record["startedAt"] = safeDate(session.startedAt)
        setOptionalDate(session.endedAt, for: "endedAt", in: record)
        setFiniteDouble(session.latitude, for: "latitude", in: record)
        setFiniteDouble(session.longitude, for: "longitude", in: record)
        setOptionalString(session.locationName, for: "locationName", in: record, maxLength: 240)
        record["createdAt"] = safeDate(session.createdAt, fallback: session.startedAt)
        record["updatedAt"] = safeDate(session.updatedAt, fallback: session.endedAt ?? session.startedAt)
        setOptionalDate(session.deletedAt, for: "deletedAt", in: record)
        return record
    }

    private func observationRecord(
        _ observation: SessionSpeciesObservation
    ) -> CKRecord? {
        guard let sessionID = observation.sessionID ?? observation.session?.id else {
            return nil
        }

        let record = CKRecord(
            recordType: CloudRecordType.observation.rawValue,
            recordID: CKRecord.ID(recordName: recordName(for: observation.id), zoneID: zoneID)
        )
        record["id"] = observation.id.uuidString
        record["sessionID"] = sessionID.uuidString
        record["scientificName"] = sanitizedString(
            observation.scientificName,
            fallback: "Unbekannte Art",
            maxLength: 240
        )
        record["germanName"] = sanitizedString(
            observation.germanName,
            fallback: "Unbekannt",
            maxLength: 240
        )
        record["bestConfidence"] = sanitizedConfidence(observation.bestConfidence)
        record["firstDetectedAt"] = safeDate(observation.firstDetectedAt)
        record["lastDetectedAt"] = safeDate(
            observation.lastDetectedAt,
            fallback: observation.firstDetectedAt
        )
        record["detectionCount"] = max(0, observation.detectionCount)
        record["status"] = observation.status.rawValue
        record["createdAt"] = safeDate(observation.createdAt, fallback: observation.firstDetectedAt)
        record["updatedAt"] = safeDate(observation.updatedAt, fallback: observation.lastDetectedAt)
        setOptionalDate(observation.deletedAt, for: "deletedAt", in: record)
        return record
    }

    private func setOptionalDate(_ date: Date?, for key: String, in record: CKRecord) {
        guard let date else {
            record[key] = nil
            return
        }

        record[key] = safeDate(date)
    }

    private func setFiniteDouble(_ value: Double?, for key: String, in record: CKRecord) {
        guard let value, value.isFinite else {
            record[key] = nil
            return
        }

        record[key] = value
    }

    private func setOptionalString(
        _ value: String?,
        for key: String,
        in record: CKRecord,
        maxLength: Int
    ) {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleaned.isEmpty else {
            record[key] = nil
            return
        }

        record[key] = String(cleaned.prefix(maxLength))
    }

    private func sanitizedString(
        _ value: String,
        fallback: String,
        maxLength: Int
    ) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        return String(cleaned.prefix(maxLength))
    }

    private func sanitizedConfidence(_ value: Float) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(Double(value), 0), 1)
    }

    private func safeDate(_ date: Date, fallback: Date = Date()) -> Date {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return fallback }
        return date
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

        let species = BirdSpecies(scientificName: scientificName, germanName: germanName)
        modelContext.insert(species)
        speciesByScientificName[scientificName] = species
        return species
    }

    private func recordName(for id: UUID) -> String {
        id.uuidString
    }

    private static func accountText(for status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "verfügbar"
        case .couldNotDetermine:
            return "unklar"
        case .noAccount:
            return "kein Account"
        case .restricted:
            return "eingeschränkt"
        case .temporarilyUnavailable:
            return "temporär nicht verfügbar"
        @unknown default:
            return "unbekannt"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
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

private struct ZoneChangeFetchResult {
    let records: [CKRecord]
    let serverChangeToken: CKServerChangeToken?
    let moreComing: Bool
}

private struct CloudSyncCounts {
    let visibleSessions: Int
    let sessions: Int
    let visibleObservations: Int
    let observations: Int
    let visibleSpecies: Int
    let species: Int
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
              let startedAt = record["startedAt"] as? Date
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
        self.createdAt = record["createdAt"] as? Date ?? startedAt
        self.updatedAt = record["updatedAt"] as? Date ?? startedAt
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
              let confidence = record["bestConfidence"] as? Double,
              let firstDetectedAt = record["firstDetectedAt"] as? Date,
              let lastDetectedAt = record["lastDetectedAt"] as? Date
        else {
            return nil
        }

        self.recordName = record.recordID.recordName
        self.id = id
        self.sessionID = sessionID
        self.scientificName = scientificName
        self.germanName = germanName
        self.bestConfidence = Float(confidence)
        self.firstDetectedAt = firstDetectedAt
        self.lastDetectedAt = lastDetectedAt
        self.detectionCount = record["detectionCount"] as? Int ?? 1
        self.status = DetectionReviewStatus(
            rawValue: record["status"] as? String ?? DetectionReviewStatus.confirmed.rawValue
        ) ?? .confirmed
        self.createdAt = record["createdAt"] as? Date ?? firstDetectedAt
        self.updatedAt = record["updatedAt"] as? Date ?? lastDetectedAt
        self.deletedAt = record["deletedAt"] as? Date
    }
}

private enum PiepCloudSyncError: LocalizedError {
    case accountUnavailable(CKAccountStatus)
    case partialUpload([String])

    var errorDescription: String? {
        switch self {
        case let .accountUnavailable(status):
            return "iCloud ist nicht verfügbar: \(Self.accountText(for: status))"
        case let .partialUpload(errors):
            let firstError = errors.first ?? "Unbekannter Fehler"
            return "iCloud Upload unvollständig: \(firstError)"
        }
    }

    private static func accountText(for status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "verfügbar"
        case .couldNotDetermine:
            return "unklar"
        case .noAccount:
            return "kein Account"
        case .restricted:
            return "eingeschränkt"
        case .temporarilyUnavailable:
            return "temporär nicht verfügbar"
        @unknown default:
            return "unbekannt"
        }
    }
}
