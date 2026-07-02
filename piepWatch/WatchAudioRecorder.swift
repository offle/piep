import AVFoundation
import CoreLocation
import Foundation
import WatchConnectivity

@Observable
@MainActor
final class WatchAudioRecorder: NSObject,
    AVAudioRecorderDelegate,
    CLLocationManagerDelegate,
    WCSessionDelegate
{
    static let maximumDuration: TimeInterval = 180

    var isRecording = false
    var duration: TimeInterval = 0
    var statusText = String(localized: "Bereit")
    var queuedTransferCount = 0
    var sessions: [WatchSessionSummary] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingStartedAt: Date?
    private var recordingID: UUID?
    private var currentLatitude: Double?
    private var currentLongitude: Double?
    private let locationManager = CLLocationManager()

    var progress: Double {
        min(duration / Self.maximumDuration, 1)
    }

    var durationText: String {
        let elapsed = Int(duration)
        return String(format: "%d:%02d / 3:00", elapsed / 60, elapsed % 60)
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        Self.removeStaleOutboxFiles()
        queuedTransferCount = Self.pendingOutboxFileCount()
        activateConnectivity()
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            requestPermissionAndStart()
        }
    }

    private func requestPermissionAndStart() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecording()
        case .denied:
            statusText = String(localized: "Mikrofonzugriff verweigert")
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.startRecording()
                    } else {
                        self?.statusText = String(localized: "Mikrofonzugriff verweigert")
                    }
                }
            }
        @unknown default:
            statusText = String(localized: "Mikrofon nicht verfügbar")
        }
    }

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)

            requestLocation()
            let id = UUID()
            let url = Self.outboxDirectory
                .appendingPathComponent(id.uuidString)
                .appendingPathExtension("m4a")
            try FileManager.default.createDirectory(
                at: Self.outboxDirectory,
                withIntermediateDirectories: true
            )
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
            )
            recorder.delegate = self
            recorder.prepareToRecord()
            guard recorder.record(forDuration: Self.maximumDuration) else {
                throw CocoaError(.fileWriteUnknown)
            }

            self.recorder = recorder
            recordingID = id
            recordingStartedAt = Date()
            duration = 0
            isRecording = true
            statusText = String(localized: "Aufnahme läuft")
            startTimer()
        } catch {
            statusText = String(localized: "Aufnahme fehlgeschlagen")
            try? session.setActive(false)
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        recorder?.stop()
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            self.finishRecording(recorder: recorder, successfully: flag)
        }
    }

    private func finishRecording(
        recorder: AVAudioRecorder,
        successfully: Bool
    ) {
        timer?.invalidate()
        timer = nil
        isRecording = false
        duration = min(
            recordingStartedAt.map { Date().timeIntervalSince($0) }
                ?? recorder.currentTime,
            Self.maximumDuration
        )
        try? AVAudioSession.sharedInstance().setActive(false)

        guard successfully,
              duration >= 3,
              let recordingID,
              let recordingStartedAt
        else {
            try? FileManager.default.removeItem(at: recorder.url)
            statusText = duration < 3
                ? String(localized: "Mindestens 3 Sekunden aufnehmen")
                : String(localized: "Aufnahme fehlgeschlagen")
            return
        }

        var metadata: [String: Any] = [
            "recordingID": recordingID.uuidString,
            "startedAt": recordingStartedAt.timeIntervalSince1970,
            "duration": duration,
        ]
        if let currentLatitude, let currentLongitude {
            metadata["latitude"] = currentLatitude
            metadata["longitude"] = currentLongitude
        }

        WCSession.default.transferFile(recorder.url, metadata: metadata)
        queuedTransferCount += 1
        statusText = String(localized: "Übertragung vorgemerkt")
        self.recorder = nil
        self.recordingID = nil
        self.recordingStartedAt = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.duration = min(recorder.currentTime, Self.maximumDuration)
            }
        }
    }

    private func requestLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        default:
            break
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.currentLatitude = location.coordinate.latitude
            self.currentLongitude = location.coordinate.longitude
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {}

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        guard manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse
        else {
            return
        }
        manager.requestLocation()
    }

    private func activateConnectivity() {
        guard WCSession.isSupported() else {
            statusText = String(localized: "iPhone-Verbindung nicht verfügbar")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        sessions = Self.decodeSessionSummaries(
            from: session.receivedApplicationContext
        )
        requestSessionHistory()
    }

    func requestSessionHistory() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isReachable
        else {
            return
        }

        WCSession.default.sendMessage(
            ["requestSessionSnapshots": true],
            replyHandler: { [weak self] reply in
                let summaries = Self.decodeSessionSummaries(from: reply)
                Task { @MainActor in
                    self?.sessions = summaries
                }
            },
            errorHandler: nil
        )
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard let error else {
            Task { @MainActor in
                self.requestSessionHistory()
            }
            return
        }
        Task { @MainActor in
            self.statusText = String(
                format: String(localized: "Verbindung fehlgeschlagen: %@"),
                error.localizedDescription
            )
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.statusText = String(localized: "Übertragung ausstehend")
                print("[Watch] Transfer failed: \(error.localizedDescription)")
            } else {
                try? FileManager.default.removeItem(
                    at: fileTransfer.file.fileURL
                )
                self.queuedTransferCount = max(0, self.queuedTransferCount - 1)
                self.statusText = String(localized: "An das iPhone übertragen")
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let summaries = Self.decodeSessionSummaries(from: applicationContext)
        Task { @MainActor in
            self.sessions = summaries
        }
    }

    nonisolated private static func decodeSessionSummaries(
        from context: [String: Any]
    ) -> [WatchSessionSummary] {
        guard let values = context["sessionSnapshots"] as? [[String: Any]] else {
            return []
        }

        return values.compactMap { value in
            guard let idString = value["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let startedAtSeconds = value["startedAt"] as? Double,
                  let duration = value["duration"] as? Double,
                  let locationText = value["locationText"] as? String
            else {
                return nil
            }

            let detections = (value["detections"] as? [[String: Any]] ?? [])
                .compactMap(WatchSessionDetectionSummary.init(dictionary:))

            return WatchSessionSummary(
                id: id,
                startedAt: Date(timeIntervalSince1970: startedAtSeconds),
                duration: duration,
                locationText: locationText,
                sourceRawValue: value["source"] as? String ?? "iPhone",
                analysisStatusRawValue: value["analysisStatus"] as? String ?? "completed",
                detections: detections
            )
        }
    }

    nonisolated private static var outboxDirectory: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        return documents.appendingPathComponent("RecordingOutbox", isDirectory: true)
    }

    nonisolated private static func pendingOutboxFileCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(
            at: outboxDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .count
    }

    nonisolated private static func removeStaleOutboxFiles() {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: outboxDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)

        for url in urls where url.pathExtension == "m4a" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modifiedAt = values?.contentModificationDate,
                  modifiedAt < cutoff
            else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }
}

struct WatchSessionSummary: Identifiable, Hashable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    let locationText: String
    let sourceRawValue: String
    let analysisStatusRawValue: String
    let detections: [WatchSessionDetectionSummary]

    var isFromWatch: Bool {
        sourceRawValue == "watch"
    }

    var sourceLabel: String {
        switch sourceRawValue {
        case "watch":
            return "Watch"
        case "importedAudio":
            return "Datei"
        default:
            return "iPhone"
        }
    }

    var statusLabel: String {
        switch analysisStatusRawValue {
        case "analyzing":
            return "Analyse läuft"
        case "failed":
            return "Fehlgeschlagen"
        default:
            return "fertig"
        }
    }

    var dateText: String {
        Self.dateFormatter.string(from: startedAt)
    }

    var durationText: String {
        Self.durationFormatter.string(from: duration) ?? "0:00"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}

struct WatchSessionDetectionSummary: Identifiable, Hashable {
    var id: String { scientificName }
    let commonName: String
    let scientificName: String
    let confidence: Double
    let count: Int
    let thumbnailData: Data?

    init?(
        dictionary: [String: Any]
    ) {
        guard let commonName = dictionary["commonName"] as? String,
              let scientificName = dictionary["scientificName"] as? String
        else {
            return nil
        }

        self.commonName = commonName
        self.scientificName = scientificName
        self.confidence = dictionary["confidence"] as? Double ?? 0
        self.count = dictionary["count"] as? Int ?? 1
        self.thumbnailData = dictionary["thumbnailData"] as? Data
    }
}
