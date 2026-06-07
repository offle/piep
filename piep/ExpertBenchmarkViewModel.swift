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
    var audioFormat = "Audio noch nicht gestartet"
    var processedWindowCount = 0
    var skippedWindowCount = 0
    var processingDuration: TimeInterval?
    var preprocessingSummaries: [ExpertBenchmarkPreprocessingSummary] = []
    var profileResults: [ExpertBenchmarkProfileResult] = []
    var results: [ExpertBenchmarkDetectionResult] = []
    var statusText = "Noch keine Benchmark-Aufnahme"

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
        statusText = "Benchmark-Modell wird geladen"

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
                    self.audioFormat = "Letztes Sample, 48 kHz, mono"
                }
                self.state = self.recordedSamples.isEmpty ? .idle : .ready
                self.statusText = self.recordedSamples.isEmpty
                    ? "Bereit für Benchmark-Aufnahme"
                    : "Aufnahme bereit"
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
            statusText = "Benchmark-Aufnahme läuft"
            startRecordingTimer()
        } catch {
            state = .failed("Mikrofon-Fehler: \(error.localizedDescription)")
            statusText = "Benchmark-Aufnahme fehlgeschlagen"
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
            statusText = "Aufnahme zu kurz: mindestens 3 Sekunden"
        } else {
            Self.saveCachedSample(recordedSamples)
            state = .ready
            statusText = "Aufnahme bereit für Benchmark"
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
        statusText = classifier == nil
            ? "Benchmark-Modell wird geladen"
            : "Noch keine Benchmark-Aufnahme"
    }

    func importSample(from url: URL) {
        guard state != .recording && state != .processing else { return }

        state = .processing
        statusText = "Sample wird geladen"
        results = []
        processedWindowCount = 0
        skippedWindowCount = 0
        preprocessingSummaries = []
        profileResults = []
        processingDuration = nil

        Task.detached {
            do {
                let samples = try Self.loadAudioSample(from: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.recordedSamples = samples
                    self.recordingDuration =
                        Double(samples.count) / BenchmarkAudioRecorder.sampleRate
                    self.audioLevel = 0
                    self.audioFormat = "Datei, 48 kHz, mono"

                    if samples.count < BirdNETClassifier.chunkSamples {
                        self.state = self.classifier == nil ? .loadingModel : .idle
                        self.statusText = "Datei zu kurz: mindestens 3 Sekunden"
                    } else {
                        Self.saveCachedSample(samples)
                        self.state = self.classifier == nil ? .loadingModel : .ready
                        self.statusText = "Datei-Sample bereit für Benchmark"
                        if self.classifier == nil {
                            self.loadModel()
                        }
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.state = .failed("Datei-Fehler: \(error.localizedDescription)")
                    self.statusText = "Datei konnte nicht geladen werden"
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
        statusText = "Benchmark wird durchprozessiert"
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


    private nonisolated static func loadAudioSample(from url: URL) throws -> [Float] {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let sourceFrameLimit = min(
            AVAudioFramePosition(
                BenchmarkAudioRecorder.maximumDuration * sourceFormat.sampleRate
            ),
            file.length
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceFrameLimit)
        ) else {
            throw AudioInputError.unableToCreateTargetFormat
        }

        try file.read(into: buffer, frameCount: AVAudioFrameCount(sourceFrameLimit))
        let sourceSamples = monoSamples(from: buffer)
        let resampled = resampleLinear(
            sourceSamples,
            sourceSampleRate: sourceFormat.sampleRate,
            targetSampleRate: BenchmarkAudioRecorder.sampleRate
        )

        return Array(resampled.prefix(BenchmarkAudioRecorder.maximumSamples))
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

    private nonisolated static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              let channelData = buffer.floatChannelData
        else {
            return []
        }

        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)

        for frame in 0..<frameCount {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += channelData[channel][frame]
            }
            mono[frame] = sample / Float(max(channelCount, 1))
        }

        return mono
    }

    private nonisolated static func resampleLinear(
        _ samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty, sourceSampleRate > 0, targetSampleRate > 0 else {
            return []
        }
        guard sourceSampleRate != targetSampleRate else {
            return samples
        }

        let ratio = targetSampleRate / sourceSampleRate
        let outputCount = max(1, Int(Double(samples.count) * ratio))
        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) / ratio
            let lowerIndex = Int(sourcePosition)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            return samples[lowerIndex] * (1 - fraction)
                + samples[upperIndex] * fraction
        }
    }
}
