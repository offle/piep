import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PiepDataArchive: Codable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let sessions: [Session]

    struct Session: Codable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date?
        let latitude: Double?
        let longitude: Double?
        let locationName: String?
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
        let observations: [Observation]
    }

    struct Observation: Codable {
        let id: UUID
        let scientificName: String
        let germanName: String
        let bestConfidence: Float
        let firstDetectedAt: Date
        let lastDetectedAt: Date
        let detectionCount: Int
        let statusRawValue: String
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }
}

struct PiepArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .xml] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
enum SessionDataArchiveService {
    static func makeArchive(modelContext: ModelContext) throws -> PiepDataArchive {
        let sessions = try modelContext.fetch(FetchDescriptor<BirdSession>())
        return PiepDataArchive(
            version: PiepDataArchive.currentVersion,
            exportedAt: Date(),
            sessions: sessions.map { session in
                PiepDataArchive.Session(
                    id: session.id,
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    latitude: session.latitude,
                    longitude: session.longitude,
                    locationName: session.locationName,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt,
                    deletedAt: session.deletedAt,
                    observations: session.observations.map { observation in
                        PiepDataArchive.Observation(
                            id: observation.id,
                            scientificName: observation.scientificName,
                            germanName: observation.germanName,
                            bestConfidence: observation.bestConfidence,
                            firstDetectedAt: observation.firstDetectedAt,
                            lastDetectedAt: observation.lastDetectedAt,
                            detectionCount: observation.detectionCount,
                            statusRawValue: observation.statusRawValue,
                            createdAt: observation.createdAt,
                            updatedAt: observation.updatedAt,
                            deletedAt: observation.deletedAt
                        )
                    }
                )
            }
        )
    }

    static func encode(_ archive: PiepDataArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> PiepDataArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(PiepDataArchive.self, from: data)
        guard archive.version <= PiepDataArchive.currentVersion else {
            throw ArchiveError.unsupportedVersion(archive.version)
        }
        return archive
    }

    static func csvData(from archive: PiepDataArchive) -> Data {
        var rows = ["session_id,start,ende,ort,breitengrad,laengengrad,art_deutsch,art_wissenschaftlich,genauigkeit,anzahl"]
        let formatter = ISO8601DateFormatter()
        for session in archive.sessions where session.deletedAt == nil {
            for observation in session.observations where observation.deletedAt == nil {
                let values: [String] = [
                    session.id.uuidString,
                    formatter.string(from: session.startedAt),
                    session.endedAt.map { formatter.string(from: $0) } ?? "",
                    session.locationName ?? "",
                    session.latitude.map { String($0) } ?? "",
                    session.longitude.map { String($0) } ?? "",
                    observation.germanName,
                    observation.scientificName,
                    String(format: "%.4f", observation.bestConfidence),
                    String(observation.detectionCount),
                ]
                rows.append(values.map { csvField($0) }.joined(separator: ","))
            }
        }
        return Data(rows.joined(separator: "\n").utf8)
    }

    static func geoJSONData(from archive: PiepDataArchive) throws -> Data {
        let features: [[String: Any]] = archive.sessions.compactMap { session in
            guard session.deletedAt == nil,
                  let latitude = session.latitude,
                  let longitude = session.longitude
            else { return nil }
            let species = session.observations
                .filter { $0.deletedAt == nil }
                .map { $0.scientificName }
                .sorted()
            return [
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [longitude, latitude]],
                "properties": [
                    "sessionID": session.id.uuidString,
                    "startedAt": ISO8601DateFormatter().string(from: session.startedAt),
                    "location": session.locationName ?? "",
                    "species": species,
                ],
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["type": "FeatureCollection", "features": features],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func gpxData(from archive: PiepDataArchive) -> Data {
        let points = archive.sessions.compactMap { session -> String? in
            guard session.deletedAt == nil,
                  let latitude = session.latitude,
                  let longitude = session.longitude
            else { return nil }
            let species = session.observations
                .filter { $0.deletedAt == nil }
                .map(\.germanName)
                .sorted()
                .joined(separator: ", ")
            return """
              <wpt lat="\(latitude)" lon="\(longitude)">
                <time>\(ISO8601DateFormatter().string(from: session.startedAt))</time>
                <name>\(xmlEscaped(session.locationName ?? "Fundort"))</name>
                <desc>\(xmlEscaped(species))</desc>
              </wpt>
            """
        }.joined(separator: "\n")
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="piep" xmlns="http://www.topografix.com/GPX/1/1">
        \(points)
        </gpx>
        """.utf8)
    }

    @discardableResult
    static func importArchive(
        _ archive: PiepDataArchive,
        modelContext: ModelContext
    ) throws -> ImportResult {
        let localSessions = try modelContext.fetch(FetchDescriptor<BirdSession>())
        let localObservations = try modelContext.fetch(FetchDescriptor<SessionSpeciesObservation>())
        let localSpecies = try modelContext.fetch(FetchDescriptor<BirdSpecies>())
        var sessionsByID = Dictionary(uniqueKeysWithValues: localSessions.map { ($0.id, $0) })
        var observationsByID = Dictionary(uniqueKeysWithValues: localObservations.map { ($0.id, $0) })
        var speciesByName = Dictionary(uniqueKeysWithValues: localSpecies.map { ($0.scientificName, $0) })
        var importedSessions = 0
        var importedObservations = 0

        for archivedSession in archive.sessions {
            let session: BirdSession
            if let existing = sessionsByID[archivedSession.id] {
                session = existing
                if archivedSession.updatedAt >= existing.updatedAt {
                    apply(archivedSession, to: existing)
                }
            } else {
                session = BirdSession(startedAt: archivedSession.startedAt)
                session.id = archivedSession.id
                apply(archivedSession, to: session)
                modelContext.insert(session)
                sessionsByID[session.id] = session
                importedSessions += 1
            }

            for archivedObservation in archivedSession.observations {
                let species = species(
                    scientificName: archivedObservation.scientificName,
                    germanName: archivedObservation.germanName,
                    speciesByName: &speciesByName,
                    modelContext: modelContext
                )

                if let existing = observationsByID[archivedObservation.id] {
                    guard archivedObservation.updatedAt >= existing.updatedAt else { continue }
                    apply(archivedObservation, to: existing, species: species, session: session)
                } else {
                    let observation = SessionSpeciesObservation(
                        species: species,
                        confidence: archivedObservation.bestConfidence,
                        detectedAt: archivedObservation.firstDetectedAt,
                        status: DetectionReviewStatus(rawValue: archivedObservation.statusRawValue) ?? .confirmed
                    )
                    observation.id = archivedObservation.id
                    apply(archivedObservation, to: observation, species: species, session: session)
                    session.observations.append(observation)
                    modelContext.insert(observation)
                    observationsByID[observation.id] = observation
                    importedObservations += 1
                }
            }
        }

        try modelContext.save()
        cleanupOrphanedBirdSpecies(in: modelContext)
        return ImportResult(sessions: importedSessions, observations: importedObservations)
    }

    private static func apply(_ source: PiepDataArchive.Session, to target: BirdSession) {
        target.startedAt = source.startedAt
        target.endedAt = source.endedAt
        target.latitude = source.latitude
        target.longitude = source.longitude
        target.locationName = source.locationName
        target.createdAt = source.createdAt
        target.updatedAt = source.updatedAt
        target.deletedAt = source.deletedAt
        target.lastSyncedAt = nil
    }

    private static func apply(
        _ source: PiepDataArchive.Observation,
        to target: SessionSpeciesObservation,
        species: BirdSpecies,
        session: BirdSession
    ) {
        target.species = species
        target.speciesID = species.id
        target.scientificNameSnapshot = source.scientificName
        target.germanNameSnapshot = source.germanName
        target.bestConfidence = source.bestConfidence
        target.firstDetectedAt = source.firstDetectedAt
        target.lastDetectedAt = source.lastDetectedAt
        target.detectionCount = source.detectionCount
        target.statusRawValue = source.statusRawValue
        target.createdAt = source.createdAt
        target.updatedAt = source.updatedAt
        target.deletedAt = source.deletedAt
        target.lastSyncedAt = nil
        target.attach(to: session)
    }

    private static func species(
        scientificName: String,
        germanName: String,
        speciesByName: inout [String: BirdSpecies],
        modelContext: ModelContext
    ) -> BirdSpecies {
        if let species = speciesByName[scientificName] {
            return species
        }
        let species = BirdSpecies(scientificName: scientificName, germanName: germanName)
        modelContext.insert(species)
        speciesByName[scientificName] = species
        return species
    }

    struct ImportResult {
        let sessions: Int
        let observations: Int
    }

    enum ArchiveError: LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(version):
                return "Dieses Backup verwendet die noch nicht unterstützte Version \(version)."
            }
        }
    }

    private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum PiepExportKind: String, CaseIterable {
    case backup
    case csv
    case geoJSON
    case gpx

    var contentType: UTType {
        switch self {
        case .backup, .geoJSON: return .json
        case .csv: return .commaSeparatedText
        case .gpx: return .xml
        }
    }

    var fileSuffix: String {
        switch self {
        case .backup: return "backup.json"
        case .csv: return "sessions.csv"
        case .geoJSON: return "fundorte.geojson"
        case .gpx: return "fundorte.gpx"
        }
    }
}

enum PiepConflictResolver {
    static func remoteWins(localUpdatedAt: Date, remoteUpdatedAt: Date) -> Bool {
        remoteUpdatedAt >= localUpdatedAt
    }

    static func mergedDeletion(local: Date?, remote: Date?) -> Date? {
        [local, remote].compactMap { $0 }.max()
    }
}
