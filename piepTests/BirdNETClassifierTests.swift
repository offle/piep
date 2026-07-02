import AVFoundation
import SwiftData
import XCTest
@testable import piep

final class BirdNETClassifierTests: XCTestCase {

    private static let classifier = BirdNETClassifier()
    private static let fanoClassifier: BirdNETClassifier = {
        let classifier = BirdNETClassifier()
        classifier.updateLocationFilter(latitude: 55.42, longitude: 8.38)
        return classifier
    }()

    func testBirdNameLocalizationUsesSelectedLanguage() {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: AppSettings.appLanguageKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: AppSettings.appLanguageKey)
            } else {
                defaults.removeObject(forKey: AppSettings.appLanguageKey)
            }
        }

        defaults.set("en", forKey: AppSettings.appLanguageKey)
        XCTAssertEqual(
            BirdNameLocalization.commonName(
                scientificName: "Turdus merula",
                fallback: "Amsel"
            ),
            "Eurasian Blackbird"
        )

        defaults.set("de", forKey: AppSettings.appLanguageKey)
        XCTAssertEqual(
            BirdNameLocalization.commonName(
                scientificName: "Turdus merula",
                fallback: "Amsel"
            ),
            "Amsel"
        )
    }

    func testEnglishLocalizationCoversListeningStatus() {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: AppSettings.appLanguageKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: AppSettings.appLanguageKey)
            } else {
                defaults.removeObject(forKey: AppSettings.appLanguageKey)
            }
        }

        defaults.set("en", forKey: AppSettings.appLanguageKey)

        XCTAssertEqual(AppLocalization.text("Zuhören"), "Listen")
        XCTAssertEqual(AppLocalization.text("Höre zu"), "Listening")
        XCTAssertEqual(AppLocalization.text("Bereit"), "Ready")
        XCTAssertEqual(AppLocalization.text("Startet eine neue Session"), "Starts a new session")
        XCTAssertEqual(AppLocalization.text("%lld Arten", 3), "3 species")
    }

    func testCommonBlackbirdSampleFindsAmsel() throws {
        let detections = try bestDetections(
            forResource: "turdus_merula_xc125792",
            expectedScientificName: "Turdus merula",
            classifier: Self.classifier
        )

        XCTAssertTrue(
            detections.contains { $0.scientificName == "Turdus merula" },
            "Expected Turdus merula in top detections, got: \(Self.describe(detections))"
        )
    }

    func testGreatTitSampleFindsKohlmeise() throws {
        let detections = try bestDetections(
            forResource: "parus_major_xc129643",
            expectedScientificName: "Parus major",
            classifier: Self.classifier
        )

        XCTAssertTrue(
            detections.contains { $0.scientificName == "Parus major" },
            "Expected Parus major in top detections, got: \(Self.describe(detections))"
        )
    }

    func testSilenceDoesNotProduceUiThresholdDetections() {
        let silence = [Float](repeating: 0, count: BirdNETClassifier.chunkSamples)

        let detections = Self.classifier.classify(audioSamples: silence)

        XCTAssertTrue(
            detections.isEmpty,
            "Silence should not produce UI-threshold detections, got: \(Self.describe(detections))"
        )
    }

    func testFanoLocationFilterCommonBlackbirdSampleFindsAmsel() throws {
        let detections = try bestDetections(
            forResource: "turdus_merula_xc125792",
            expectedScientificName: "Turdus merula",
            classifier: Self.fanoClassifier
        )

        XCTAssertTrue(
            detections.contains { $0.scientificName == "Turdus merula" },
            "Expected Turdus merula with Fanø filter, got: \(Self.describe(detections))"
        )
    }

    func testFanoLocationFilterGreatTitSampleFindsKohlmeise() throws {
        let detections = try bestDetections(
            forResource: "parus_major_xc129643",
            expectedScientificName: "Parus major",
            classifier: Self.fanoClassifier
        )

        XCTAssertTrue(
            detections.contains { $0.scientificName == "Parus major" },
            "Expected Parus major with Fanø filter, got: \(Self.describe(detections))"
        )
    }

    func testExpertBenchmarkUsesLiveWindowStride() {
        let samples = [Float](
            repeating: 0.1,
            count: BirdNETClassifier.chunkSamples + ExpertBenchmarkProcessor.hopSamples * 2
        )

        let windows = ExpertBenchmarkProcessor.analysisWindows(from: samples)

        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.map(\.startSeconds), [0, 1, 2])
        XCTAssertTrue(windows.allSatisfy { $0.samples.count == BirdNETClassifier.chunkSamples })
    }

    func testWatchRecordingUsesOverlappingWindowsAndAllProfiles() {
        let samples = [Float](
            repeating: 0.1,
            count: BirdNETClassifier.chunkSamples + ExpertBenchmarkProcessor.hopSamples
        )
        let settings = AudioPreprocessingSettings(
            isBandpassEnabled: false,
            highpassCutoffHz: 0,
            lowpassCutoffHz: 24_000,
            isBandEnergyGateEnabled: false,
            minimumBandRMS: 0
        )
        let profiles = [
            AudioAnalysisProfile(label: "P1", settings: settings),
            AudioAnalysisProfile(label: "P2", settings: settings),
        ]
        var classificationCount = 0

        let windows = WatchRecordingAnalyzer.analyze(
            samples: samples,
            profiles: profiles,
            confidenceThreshold: 0.2
        ) { _ in
            classificationCount += 1
            return [
                BirdDetection(
                    scientificName: "Turdus merula",
                    germanName: "Amsel",
                    confidence: 0.75
                ),
                BirdDetection(
                    scientificName: "Human vocal",
                    germanName: "Mensch Stimme",
                    confidence: 0.99
                ),
            ]
        }

        XCTAssertEqual(windows.map(\.startSeconds), [0, 1])
        XCTAssertEqual(classificationCount, 4)
        XCTAssertTrue(windows.allSatisfy { window in
            window.detections.map(\.scientificName) == ["Turdus merula"]
        })
    }

    func testExpertBenchmarkAggregatesTechnicalResults() {
        let samples = [Float](
            repeating: 0.1,
            count: BirdNETClassifier.chunkSamples + ExpertBenchmarkProcessor.hopSamples
        )
        var invocation = 0

        let summary = ExpertBenchmarkProcessor.process(
            samples: samples,
            profiles: [
                AudioAnalysisProfile(
                    label: "Profil 1",
                    settings: AudioPreprocessingSettings(
                        isBandpassEnabled: false,
                        highpassCutoffHz: 200,
                        lowpassCutoffHz: 10_000,
                        isBandEnergyGateEnabled: false,
                        minimumBandRMS: 0.0008
                    )
                ),
            ],
            confidenceThreshold: 0.3
        ) { _ in
            defer { invocation += 1 }
            return [
                BirdDetection(
                    scientificName: "Turdus merula",
                    germanName: "Amsel",
                    confidence: invocation == 0 ? 0.4 : 0.8
                ),
                BirdDetection(
                    scientificName: "Parus major",
                    germanName: "Kohlmeise",
                    confidence: 0.2
                ),
            ]
        }

        XCTAssertEqual(summary.processedWindowCount, 2)
        XCTAssertEqual(summary.skippedWindowCount, 0)
        XCTAssertEqual(summary.results.count, 1)
        XCTAssertEqual(summary.results.first?.scientificName, "Turdus merula")
        XCTAssertEqual(summary.results.first?.hitWindowCount, 2)
        XCTAssertEqual(summary.results.first?.maxConfidence, 0.8)
        XCTAssertEqual(
            try XCTUnwrap(summary.results.first?.averageConfidence),
            0.6,
            accuracy: 0.0001
        )
    }

    func testExpertBenchmarkProcessesThreeProfilesPerWindow() throws {
        let samples = [Float](
            repeating: 0.1,
            count: BirdNETClassifier.chunkSamples
        )
        var invocationCount = 0

        let summary = ExpertBenchmarkProcessor.process(
            samples: samples,
            profiles: [
                AudioAnalysisProfile(label: "Profil 1", settings: Self.testPreprocessingSettings),
                AudioAnalysisProfile(label: "Profil 2", settings: Self.testPreprocessingSettings),
                AudioAnalysisProfile(label: "Profil 3", settings: Self.testPreprocessingSettings),
            ],
            confidenceThreshold: 0.3
        ) { _ in
            invocationCount += 1
            return [
                BirdDetection(
                    scientificName: "Turdus merula",
                    germanName: "Amsel",
                    confidence: Float(invocationCount) / 10
                ),
            ]
        }

        XCTAssertEqual(invocationCount, 3)
        XCTAssertEqual(summary.processedWindowCount, 1)
        XCTAssertEqual(summary.results.count, 1)
        XCTAssertEqual(summary.results.first?.hitWindowCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(summary.results.first?.maxConfidence),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(summary.profileResults.count, 3)
        XCTAssertEqual(summary.profileResults.map(\.profileLabel), [
            "Profil 1",
            "Profil 2",
            "Profil 3",
        ])
        XCTAssertEqual(summary.profileResults[0].results.count, 0)
        XCTAssertEqual(summary.profileResults[1].results.count, 0)
        XCTAssertEqual(summary.profileResults[2].results.first?.scientificName, "Turdus merula")
        XCTAssertEqual(
            try XCTUnwrap(summary.profileResults[2].results.first?.maxConfidence),
            0.3,
            accuracy: 0.0001
        )
    }

    func testSessionDetectionCountsOncePerCooldownWindow() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let species = BirdSpecies(
            scientificName: "Turdus merula",
            germanName: "Amsel"
        )
        let observation = SessionSpeciesObservation(
            species: species,
            confidence: 0.6,
            detectedAt: startedAt
        )

        XCTAssertFalse(observation.merge(
            confidence: 0.7,
            detectedAt: startedAt.addingTimeInterval(5),
            countCooldown: 10
        ))
        XCTAssertEqual(observation.detectionCount, 1)

        XCTAssertTrue(observation.merge(
            confidence: 0.8,
            detectedAt: startedAt.addingTimeInterval(10),
            countCooldown: 10
        ))
        XCTAssertEqual(observation.detectionCount, 2)

        XCTAssertFalse(observation.merge(
            confidence: 0.75,
            detectedAt: startedAt.addingTimeInterval(15),
            countCooldown: 10
        ))
        XCTAssertEqual(observation.detectionCount, 2)

        XCTAssertTrue(observation.merge(
            confidence: 0.9,
            detectedAt: startedAt.addingTimeInterval(20),
            countCooldown: 10
        ))
        XCTAssertEqual(observation.detectionCount, 3)
        XCTAssertEqual(observation.bestConfidence, 0.9)
    }

    @MainActor
    func testBackupRoundTripPreservesSessionIdentityAndDeletion() throws {
        let source = try makeInMemoryContainer()
        let sourceContext = source.mainContext
        let species = BirdSpecies(scientificName: "Turdus merula", germanName: "Amsel")
        let session = BirdSession(
            startedAt: Date(timeIntervalSince1970: 1_000),
            latitude: 55.42,
            longitude: 8.38,
            locationName: "Fanø"
        )
        session.endedAt = Date(timeIntervalSince1970: 1_180)
        let observation = SessionSpeciesObservation(
            species: species,
            confidence: 0.82,
            detectedAt: Date(timeIntervalSince1970: 1_010)
        )
        observation.attach(to: session)
        session.observations.append(observation)
        sourceContext.insert(species)
        sourceContext.insert(session)
        sourceContext.insert(observation)
        try sourceContext.save()

        let data = try SessionDataArchiveService.encode(
            SessionDataArchiveService.makeArchive(modelContext: sourceContext)
        )
        let decoded = try SessionDataArchiveService.decode(data)
        let destination = try makeInMemoryContainer()
        let result = try SessionDataArchiveService.importArchive(
            decoded,
            modelContext: destination.mainContext
        )

        XCTAssertEqual(result.sessions, 1)
        XCTAssertEqual(result.observations, 1)
        let restoredSessions = try destination.mainContext.fetch(FetchDescriptor<BirdSession>())
        let restored = try XCTUnwrap(restoredSessions.first)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.locationName, "Fanø")
        XCTAssertEqual(restored.reviewedDetections.first?.id, observation.id)
        XCTAssertEqual(restored.reviewedDetections.first?.scientificName, "Turdus merula")

        let secondImport = try SessionDataArchiveService.importArchive(
            decoded,
            modelContext: destination.mainContext
        )
        XCTAssertEqual(secondImport.sessions, 0)
        XCTAssertEqual(secondImport.observations, 0)
        XCTAssertEqual(try destination.mainContext.fetch(FetchDescriptor<BirdSession>()).count, 1)
    }

    func testConflictResolverKeepsNewestUpdateAndDeletion() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)

        XCTAssertTrue(PiepConflictResolver.remoteWins(localUpdatedAt: older, remoteUpdatedAt: newer))
        XCTAssertFalse(PiepConflictResolver.remoteWins(localUpdatedAt: newer, remoteUpdatedAt: older))
        XCTAssertEqual(PiepConflictResolver.mergedDeletion(local: older, remote: newer), newer)
        XCTAssertEqual(PiepConflictResolver.mergedDeletion(local: newer, remote: nil), newer)
    }

    @MainActor
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            BirdSpecies.self,
            BirdSpeciesImage.self,
            BirdSession.self,
            SessionSpeciesObservation.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static var testPreprocessingSettings: AudioPreprocessingSettings {
        AudioPreprocessingSettings(
            isBandpassEnabled: false,
            highpassCutoffHz: 200,
            lowpassCutoffHz: 10_000,
            isBandEnergyGateEnabled: false,
            minimumBandRMS: 0.0008
        )
    }

    private func bestDetections(
        forResource resourceName: String,
        expectedScientificName: String,
        classifier: BirdNETClassifier
    ) throws -> [BirdDetection] {
        let samples = try Self.loadMono48kSamples(resourceName: resourceName)

        var bestWindowDetections: [BirdDetection] = []
        var bestExpectedConfidence: Float = 0

        for chunk in Self.analysisChunks(from: samples, maxChunks: 20) {
            let detections = classifier.classify(
                audioSamples: chunk,
                minimumConfidence: 0.001
            )

            let expectedConfidence =
                detections.first { $0.scientificName == expectedScientificName }?.confidence ?? 0

            if expectedConfidence > bestExpectedConfidence {
                bestExpectedConfidence = expectedConfidence
                bestWindowDetections = detections
            } else if bestWindowDetections.isEmpty {
                bestWindowDetections = detections
            }
        }

        print("[BirdNETTests] \(resourceName): \(Self.describe(bestWindowDetections))")
        return bestWindowDetections
    }

    private static func analysisChunks(
        from samples: [Float],
        maxChunks: Int
    ) -> [[Float]] {
        let chunkSize = BirdNETClassifier.chunkSamples
        guard samples.count >= chunkSize else { return [] }

        let hopSize = chunkSize
        var chunks: [[Float]] = []
        var start = 0

        while start + chunkSize <= samples.count && chunks.count < maxChunks {
            chunks.append(Array(samples[start..<(start + chunkSize)]))
            start += hopSize
        }

        return chunks
    }

    private static func loadMono48kSamples(resourceName: String) throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle(for: BirdNETClassifierTests.self).url(
                forResource: resourceName,
                withExtension: "mp3"
            )
        )

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        try file.read(into: buffer)

        let sourceFrameCount = Int(buffer.frameLength)
        let sourceChannels = Int(format.channelCount)
        let channelData = try XCTUnwrap(buffer.floatChannelData)

        var mono = [Float](repeating: 0, count: sourceFrameCount)
        for frame in 0..<sourceFrameCount {
            var sample: Float = 0
            for channel in 0..<sourceChannels {
                sample += channelData[channel][frame]
            }
            mono[frame] = sample / Float(sourceChannels)
        }

        return resampleLinear(
            mono,
            sourceSampleRate: format.sampleRate,
            targetSampleRate: 48_000
        )
    }

    private static func resampleLinear(
        _ samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard sourceSampleRate != targetSampleRate else { return samples }

        let targetCount = Int(
            (Double(samples.count) * targetSampleRate / sourceSampleRate).rounded()
        )
        let scale = sourceSampleRate / targetSampleRate
        var resampled = [Float](repeating: 0, count: targetCount)

        for index in 0..<targetCount {
            let sourcePosition = Double(index) * scale
            let lower = Int(sourcePosition)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            resampled[index] = samples[lower] * (1 - fraction) + samples[upper] * fraction
        }

        return resampled
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let squareSum = samples.reduce(Float(0)) { partialResult, sample in
            partialResult + sample * sample
        }
        return sqrt(squareSum / Float(samples.count))
    }

    private static func describe(_ detections: [BirdDetection]) -> String {
        detections
            .prefix(10)
            .map {
                "\($0.scientificName) / \($0.germanName): " +
                String(format: "%.4f", $0.confidence)
            }
            .joined(separator: ", ")
    }
}
