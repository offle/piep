//
//  ExpertBenchmarkViewModel.swift
//  piep
//
//  Created by Codex on 06.06.26.
//

import AVFoundation
import Foundation

enum ExpertBenchmarkState: Equatable {
    case idle
    case loadingModel
    case recording
    case ready
    case processing
    case finished
    case failed(String)
}

@Observable
@MainActor
final class ExpertBenchmarkViewModel {

    var state: ExpertBenchmarkState = .idle
    var recordingDuration: TimeInterval = 0
    var audioLevel: Float = 0
    var audioFormat = AppLocalization.text("Audio noch nicht gestartet")
    var processedWindowCount = 0
    var skippedWindowCount = 0
    var processingDuration: TimeInterval?
    var preprocessingSummaries: [ExpertBenchmarkPreprocessingSummary] = []
    var profileResults: [ExpertBenchmarkProfileResult] = []
    var results: [ExpertBenchmarkDetectionResult] = []
    var statusText = AppLocalization.text("Noch keine Benchmark-Aufnahme")

    private var classifier: BirdNETClassifier?
    private let recorder = BenchmarkAudioRecorder()
    private let locationManager = LocationManager()
    private var recordedSamples: [Float] = []
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?

    var hasRecording: Bool {
        recordedSamples.count >= BirdNETClassifier.chunkSamples
    }

    var canProcess: Bool {
        hasRecording && state != .recording && state != .processing
    }

    var canRecord: Bool {
        state != .recording && state != .processing
    }

    var recordingProgress: Double {
        min(recordingDuration / BenchmarkAudioRecorder.maximumDuration, 1)
    }

    func loadModel() {
        guard classifier == nil else { return }
        state = .loadingModel
        statusText = AppLocalization.text("Benchmark-Modell wird geladen")

        Task.detached {
            let cachedSample = Self.loadCachedSample()
            let loadedClassifier = BirdNETClassifier()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.classifier = loadedClassifier
                if self.recordedSamples.isEmpty, !cachedSample.isEmpty {
                    self.recordedSamples = cachedSample
                    self.recordingDuration =
                        Double(cachedSample.count) / BenchmarkAudioRecorder.sampleRate
                    self.audioFormat = AppLocalization.text("Letztes Sample, 48 kHz, mono")
                }
                self.state = self.recordedSamples.isEmpty ? .idle : .ready
                self.statusText = AppLocalization.text(
                    self.recordedSamples.isEmpty
                        ? "Bereit für Benchmark-Aufnahme"
                        : "Aufnahme bereit"
                )
            }
        }
    }

    func startRecording() {
        guard canRecord else { return }
        guard classifier != nil else {
            loadModel()
            return
        }

        locationManager.requestLocation()
        results = []
        processedWindowCount = 0
        skippedWindowCount = 0
        preprocessingSummaries = []
        profileResults = []
        processingDuration = nil
        recordedSamples = []
        recordingDuration = 0
        audioLevel = 0
        recordingStartedAt = Date()

        do {
            audioFormat = try recorder.start(
                onStats: { [weak self] stats in
                    Task { @MainActor in
                        self?.audioLevel = stats.level
                        self?.recordingDuration =
                            Double(stats.recordedSamples)
                            / BenchmarkAudioRecorder.sampleRate
                    }
                },
                onReachedLimit: { [weak self] in
                    Task { @MainActor in
                        self?.stopRecording()
                    }
                }
            )
            state = .recording
            statusText = AppLocalization.text("Benchmark-Aufnahme läuft")
            startRecordingTimer()
        } catch {
            state = .failed("Mikrofon-Fehler: \(error.localizedDescription)")
            statusText = AppLocalization.text("Benchmark-Aufnahme fehlgeschlagen")
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordedSamples = recorder.stop()
        recordingDuration =
            Double(recordedSamples.count) / BenchmarkAudioRecorder.sampleRate
        audioLevel = 0

        if recordedSamples.count < BirdNETClassifier.chunkSamples {
            state = .idle
            statusText = AppLocalization.text("Aufnahme zu kurz: mindestens 3 Sekunden")
        } else {
            Self.saveCachedSample(recordedSamples)
            state = .ready
            statusText = AppLocalization.text("Aufnahme bereit für Benchmark")
        }
    }

    func clearRecording() {
        if state == .recording {
            _ = recorder.stop()
        }
        recordingTimer?.invalidate()
        recordingTimer = nil
        recorder.clear()
        recordedSamples = []
        results = []
        processedWindowCount = 0
        skippedWindowCount = 0
        preprocessingSummaries = []
        profileResults = []
        processingDuration = nil
        recordingDuration = 0
        audioLevel = 0
        state = classifier == nil ? .loadingModel : .idle
        statusText = AppLocalization.text(
            classifier == nil ? "Benchmark-Modell wird geladen" : "Noch keine Benchmark-Aufnahme"
        )
    }

    func importSample(from url: URL) {
        guard state != .recording && state != .processing else { return }

        state = .processing
        statusText = AppLocalization.text("Sample wird geladen")
        results = []
        processedWindowCount = 0
        skippedWindowCount = 0
        preprocessingSummaries = []
        profileResults = []
        processingDuration = nil

        Task.detached {
            do {
                let samples = try AudioSampleLoader.loadMono48k(
                    from: url,
                    maximumDuration: BenchmarkAudioRecorder.maximumDuration
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.recordedSamples = samples
                    self.recordingDuration =
                        Double(samples.count) / BenchmarkAudioRecorder.sampleRate
                    self.audioLevel = 0
                    self.audioFormat = AppLocalization.text("Datei, 48 kHz, mono")

                    if samples.count < BirdNETClassifier.chunkSamples {
                        self.state = self.classifier == nil ? .loadingModel : .idle
                        self.statusText = AppLocalization.text("Datei zu kurz: mindestens 3 Sekunden")
                    } else {
                        Self.saveCachedSample(samples)
                        self.state = self.classifier == nil ? .loadingModel : .ready
                        self.statusText = AppLocalization.text("Datei-Sample bereit für Benchmark")
                        if self.classifier == nil {
                            self.loadModel()
                        }
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.state = .failed("Datei-Fehler: \(error.localizedDescription)")
                    self.statusText = AppLocalization.text("Datei konnte nicht geladen werden")
                }
            }
        }
    }

    func processRecording() {
        guard canProcess else { return }
        guard let classifier else {
            loadModel()
            return
        }

        let samples = recordedSamples
        let profiles = AppSettings.audioAnalysisProfiles
        let threshold = AppSettings.confidenceThreshold
        let latitude = locationManager.latitude
        let longitude = locationManager.longitude

        state = .processing
        statusText = AppLocalization.text("Benchmark wird durchprozessiert")
        processedWindowCount = 0
        skippedWindowCount = 0
        preprocessingSummaries = []
        profileResults = []
        processingDuration = nil
        results = []

        Task.detached {
            let startedAt = Date()
            classifier.clearLocationFilter()
            if let latitude, let longitude {
                classifier.updateLocationFilter(
                    latitude: latitude,
                    longitude: longitude
                )
            }

            let summary = ExpertBenchmarkProcessor.process(
                samples: samples,
                profiles: profiles,
                confidenceThreshold: threshold
            ) { chunk in
                classifier.classify(
                    audioSamples: chunk,
                    minimumConfidence: 0.001
                )
            }
            let duration = Date().timeIntervalSince(startedAt)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.processedWindowCount = summary.processedWindowCount
                self.skippedWindowCount = summary.skippedWindowCount
                self.preprocessingSummaries = summary.preprocessingSummaries
                self.profileResults = summary.profileResults
                self.processingDuration = duration
                self.results = summary.results
                self.state = .finished
                self.statusText = summary.results.isEmpty
                    ? "Benchmark fertig: keine Treffer ueber Threshold"
                    : "Benchmark fertig: \(summary.results.count) technische Treffer"
            }
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                if let recordingStartedAt = self.recordingStartedAt {
                    self.recordingDuration = min(
                        Date().timeIntervalSince(recordingStartedAt),
                        BenchmarkAudioRecorder.maximumDuration
                    )
                }
                if self.recordingDuration >= BenchmarkAudioRecorder.maximumDuration {
                    self.stopRecording()
                }
            }
        }
    }

    private nonisolated static func saveCachedSample(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        do {
            try data.write(to: cachedSampleURL, options: .atomic)
        } catch {
            print("[Benchmark] Could not cache sample: \(error.localizedDescription)")
        }
    }

    private nonisolated static func loadCachedSample() -> [Float] {
        do {
            let data = try Data(contentsOf: cachedSampleURL)
            let floatSize = MemoryLayout<Float>.stride
            guard data.count >= BirdNETClassifier.chunkSamples * floatSize else {
                return []
            }

            let sampleCount = data.count / floatSize
            return data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: Float.self).baseAddress else {
                    return []
                }

                return Array(UnsafeBufferPointer(
                    start: baseAddress,
                    count: min(sampleCount, BenchmarkAudioRecorder.maximumSamples)
                ))
            }
        } catch {
            return []
        }
    }

    private nonisolated static var cachedSampleURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("LastExpertBenchmarkSample.f32")
    }

}
