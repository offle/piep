import Foundation
import UIKit
import WatchConnectivity

nonisolated struct WatchRecordingMetadata: Codable, Sendable {
    let recordingID: UUID
    let startedAt: Date
    let duration: TimeInterval
    let latitude: Double?
    let longitude: Double?
}

nonisolated struct PendingWatchRecording: Sendable {
    let audioURL: URL
    let metadataURL: URL
    let metadata: WatchRecordingMetadata
}

nonisolated enum WatchRecordingImportError: LocalizedError {
    case recordingTooShort

    var errorDescription: String? {
        switch self {
        case .recordingTooShort:
            return AppLocalization.text(
                "Die Watch-Aufnahme ist kürzer als drei Sekunden."
            )
        }
    }
}

final class WatchRecordingInbox: NSObject, WCSessionDelegate {

    static let shared = WatchRecordingInbox()
    static let didReceiveRecording = Notification.Name(
        "WatchRecordingInboxDidReceiveRecording"
    )
    static let didRequestSessionSnapshots = Notification.Name(
        "WatchRecordingInboxDidRequestSessionSnapshots"
    )

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        do {
            try Self.persist(file: file)
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: Self.didReceiveRecording,
                    object: nil
                )
            }
        } catch {
            print("[Watch] Could not persist recording: \(error.localizedDescription)")
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard message["requestSessionSnapshots"] as? Bool == true else {
            return
        }

        Task { @MainActor in
            NotificationCenter.default.post(
                name: Self.didRequestSessionSnapshots,
                object: nil
            )
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["requestSessionSnapshots"] as? Bool == true else {
            replyHandler([:])
            return
        }

        Task { @MainActor in
            NotificationCenter.default.post(
                name: Self.didRequestSessionSnapshots,
                object: nil
            )
            replyHandler(WatchSessionSnapshotSender.latestContext)
        }
    }

    nonisolated static func pendingRecordings() -> [PendingWatchRecording] {
        let directory = inboxDirectory
        let audioURLs = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "m4a" } ?? []

        return audioURLs.compactMap { audioURL in
            let metadataURL = audioURL.deletingPathExtension()
                .appendingPathExtension("json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(
                    WatchRecordingMetadata.self,
                    from: data
                  )
            else {
                try? FileManager.default.removeItem(at: audioURL)
                try? FileManager.default.removeItem(at: metadataURL)
                return nil
            }
            return PendingWatchRecording(
                audioURL: audioURL,
                metadataURL: metadataURL,
                metadata: metadata
            )
        }
        .sorted { $0.metadata.startedAt < $1.metadata.startedAt }
    }

    nonisolated static func remove(_ recording: PendingWatchRecording) {
        try? FileManager.default.removeItem(at: recording.audioURL)
        try? FileManager.default.removeItem(at: recording.metadataURL)
    }

    nonisolated private static func persist(file: WCSessionFile) throws {
        let metadata = try decodeMetadata(file.metadata)
        let directory = inboxDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let baseURL = directory.appendingPathComponent(
            metadata.recordingID.uuidString
        )
        let audioURL = baseURL.appendingPathExtension("m4a")
        let metadataURL = baseURL.appendingPathExtension("json")

        if FileManager.default.fileExists(atPath: audioURL.path) {
            try FileManager.default.removeItem(at: audioURL)
        }
        try FileManager.default.copyItem(at: file.fileURL, to: audioURL)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    nonisolated private static func decodeMetadata(
        _ values: [String: Any]?
    ) throws -> WatchRecordingMetadata {
        guard let values,
              let recordingIDString = values["recordingID"] as? String,
              let recordingID = UUID(uuidString: recordingIDString),
              let startedAtValue = values["startedAt"] as? Double,
              let duration = values["duration"] as? Double
        else {
            throw CocoaError(.coderReadCorrupt)
        }

        return WatchRecordingMetadata(
            recordingID: recordingID,
            startedAt: Date(timeIntervalSince1970: startedAtValue),
            duration: duration,
            latitude: values["latitude"] as? Double,
            longitude: values["longitude"] as? Double
        )
    }

    nonisolated private static var inboxDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base.appendingPathComponent("WatchRecordings", isDirectory: true)
    }
}

struct WatchSessionDetectionSnapshot {
    let commonName: String
    let scientificName: String
    let confidence: Float
    let count: Int
    let thumbnailData: Data?
}

struct WatchSessionSnapshot {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    let locationText: String
    let source: BirdSessionSource
    let analysisStatus: BirdSessionAnalysisStatus
    let detections: [WatchSessionDetectionSnapshot]
}

@MainActor
enum WatchSessionSnapshotSender {

    private(set) static var latestContext: [String: Any] = [
        "sessionSnapshots": [],
        "updatedAt": Date(timeIntervalSince1970: 0).timeIntervalSince1970,
    ]

    static func update(sessions: [BirdSession]) {
        let context = context(for: sessions)
        latestContext = context

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        do {
            try session.updateApplicationContext(context)
        } catch {
            print("[Watch] Could not update session snapshots: \(error.localizedDescription)")
        }
    }

    private static func context(for sessions: [BirdSession]) -> [String: Any] {
        let snapshots = sessions
            .filter { !$0.isDeleted }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(12)
            .map(dictionary)

        return [
            "sessionSnapshots": Array(snapshots),
            "updatedAt": Date().timeIntervalSince1970,
        ]
    }

    private static func dictionary(for session: BirdSession) -> [String: Any] {
        [
            "id": session.id.uuidString,
            "startedAt": session.startedAt.timeIntervalSince1970,
            "duration": session.duration,
            "locationText": session.locationDescription,
            "source": session.source.rawValue,
            "analysisStatus": session.effectiveAnalysisStatus.rawValue,
            "detections": session.reviewedDetections
                .sorted {
                    if $0.bestConfidence != $1.bestConfidence {
                        return $0.bestConfidence > $1.bestConfidence
                    }
                    return $0.germanName.localizedStandardCompare($1.germanName)
                        == .orderedAscending
                }
                .prefix(8)
                .map(detectionDictionary),
        ]
    }

    private static func detectionDictionary(
        for detection: SessionSpeciesObservation
    ) -> [String: Any] {
        var values: [String: Any] = [
            "commonName": detection.localizedCommonName,
            "scientificName": detection.scientificName,
            "confidence": Double(detection.bestConfidence),
            "count": detection.detectionCount,
        ]

        if let data = BirdImageStore.shared.thumbnailJPEGData(
            for: detection.scientificName,
            sideLength: 72
        ) {
            values["thumbnailData"] = data
        }

        return values
    }
}
