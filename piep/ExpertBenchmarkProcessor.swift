//
//  ExpertBenchmarkProcessor.swift
//  piep
//
//  Created by Codex on 06.06.26.
//

import Foundation

struct ExpertBenchmarkDetectionResult: Identifiable, Equatable, Sendable {
    var id: String { scientificName }
    let scientificName: String
    let germanName: String
    let maxConfidence: Float
    let averageConfidence: Float
    let hitWindowCount: Int
    let analyzedWindowCount: Int
    let firstHitStartSeconds: Double
    let lastHitStartSeconds: Double

    nonisolated var hitRate: Double {
        guard analyzedWindowCount > 0 else { return 0 }
        return Double(hitWindowCount) / Double(analyzedWindowCount)
    }
}

struct ExpertBenchmarkSummary: Sendable {
    let recordingDuration: TimeInterval
    let processedWindowCount: Int
    let skippedWindowCount: Int
    let preprocessingSummaries: [ExpertBenchmarkPreprocessingSummary]
    let profileResults: [ExpertBenchmarkProfileResult]
    let results: [ExpertBenchmarkDetectionResult]
}

struct ExpertBenchmarkPreprocessingSummary: Identifiable, Equatable, Sendable {
    var id: String { profileLabel }
    let profileLabel: String
    let windowCount: Int
    let skippedWindowCount: Int
    let averageInputRMS: Float
    let averageBandRMS: Float
}

struct ExpertBenchmarkProfileResult: Identifiable, Equatable, Sendable {
    var id: String { profileLabel }
    let profileLabel: String
    let settings: AudioPreprocessingSettings
    let analyzedWindowCount: Int
    let skippedWindowCount: Int
    let averageInputRMS: Float
    let averageBandRMS: Float
    let results: [ExpertBenchmarkDetectionResult]
}

enum ExpertBenchmarkProcessor {

    nonisolated static let sampleRate = 48_000
    nonisolated static let hopSamples = 48_000

    nonisolated static func process(
        samples: [Float],
        profiles: [AudioAnalysisProfile],
        confidenceThreshold: Float,
        classify: ([Float]) -> [BirdDetection]
    ) -> ExpertBenchmarkSummary {
        let analyzedWindows = analysisWindows(from: samples)
        var skippedWindowCount = 0
        var aggregates: [String: DetectionAggregate] = [:]
        var profileAggregates: [String: [String: DetectionAggregate]] = [:]
        var preprocessingAggregates: [String: PreprocessingAggregate] = [:]

        for window in analyzedWindows {
            var analyzedProfileCount = 0
            var windowDetections: [BirdDetection] = []

            for profile in profiles {
                let preprocessingResult = AudioPreprocessor.process(
                    window.samples,
                    settings: profile.settings
                )
                preprocessingAggregates[profile.label, default: PreprocessingAggregate(
                    profileLabel: profile.label
                )].record(preprocessingResult.metrics)

                guard preprocessingResult.shouldAnalyze else {
                    continue
                }

                analyzedProfileCount += 1
                let profileDetections = classify(preprocessingResult.samples)
                windowDetections.append(contentsOf: profileDetections)

                let profileThresholdDetections = mergedDetectionsByBestConfidence(profileDetections)
                    .filter { $0.confidence >= confidenceThreshold }
                for detection in profileThresholdDetections {
                    profileAggregates[profile.label, default: [:]][detection.scientificName, default: DetectionAggregate(
                        scientificName: detection.scientificName,
                        germanName: detection.germanName
                    )].record(
                        confidence: detection.confidence,
                        windowStartSeconds: window.startSeconds
                    )
                }
            }

            guard analyzedProfileCount > 0 else {
                skippedWindowCount += 1
                continue
            }

            let detections = mergedDetectionsByBestConfidence(windowDetections)
                .filter { $0.confidence >= confidenceThreshold }

            for detection in detections {
                aggregates[detection.scientificName, default: DetectionAggregate(
                    scientificName: detection.scientificName,
                    germanName: detection.germanName
                )].record(
                    confidence: detection.confidence,
                    windowStartSeconds: window.startSeconds
                )
            }
        }

        let analyzedWindowCount = max(0, analyzedWindows.count - skippedWindowCount)
        let preprocessingSummaries = preprocessingAggregates.values
            .map(\.summary)
            .sorted { $0.profileLabel < $1.profileLabel }
        let results = aggregates.values
            .map { $0.result(analyzedWindowCount: analyzedWindowCount) }
            .sorted {
                if $0.maxConfidence == $1.maxConfidence {
                    return $0.hitRate > $1.hitRate
                }
                return $0.maxConfidence > $1.maxConfidence
            }
        let summariesByLabel = Dictionary(
            uniqueKeysWithValues: preprocessingSummaries.map { ($0.profileLabel, $0) }
        )
        var profileResults: [ExpertBenchmarkProfileResult] = []
        for profile in profiles {
            guard let summary = summariesByLabel[profile.label] else {
                continue
            }
            let analyzedProfileWindowCount = max(
                0,
                summary.windowCount - summary.skippedWindowCount
            )
            let results = (profileAggregates[summary.profileLabel] ?? [:]).values
                .map { $0.result(analyzedWindowCount: analyzedProfileWindowCount) }
                .sorted {
                    if $0.maxConfidence == $1.maxConfidence {
                        return $0.hitRate > $1.hitRate
                    }
                    return $0.maxConfidence > $1.maxConfidence
                }

            profileResults.append(ExpertBenchmarkProfileResult(
                profileLabel: summary.profileLabel,
                settings: profile.settings,
                analyzedWindowCount: analyzedProfileWindowCount,
                skippedWindowCount: summary.skippedWindowCount,
                averageInputRMS: summary.averageInputRMS,
                averageBandRMS: summary.averageBandRMS,
                results: results
            ))
        }

        return ExpertBenchmarkSummary(
            recordingDuration: Double(samples.count) / Double(sampleRate),
            processedWindowCount: analyzedWindowCount,
            skippedWindowCount: skippedWindowCount,
            preprocessingSummaries: preprocessingSummaries,
            profileResults: profileResults,
            results: results
        )
    }

    nonisolated static func analysisWindows(
        from samples: [Float]
    ) -> [(startSeconds: Double, samples: [Float])] {
        let chunkSamples = BirdNETClassifier.chunkSamples
        guard samples.count >= chunkSamples else { return [] }

        var windows: [(startSeconds: Double, samples: [Float])] = []
        var start = 0
        while start + chunkSamples <= samples.count {
            windows.append((
                startSeconds: Double(start) / Double(sampleRate),
                samples: Array(samples[start..<(start + chunkSamples)])
            ))
            start += hopSamples
        }
        return windows
    }

    nonisolated private static func mergedDetectionsByBestConfidence(
        _ detections: [BirdDetection]
    ) -> [BirdDetection] {
        var bestBySpecies: [String: BirdDetection] = [:]

        for detection in detections {
            if let existing = bestBySpecies[detection.scientificName],
               existing.confidence >= detection.confidence
            {
                continue
            }

            bestBySpecies[detection.scientificName] = detection
        }

        return bestBySpecies.values.sorted { $0.confidence > $1.confidence }
    }
}

private struct PreprocessingAggregate: Sendable {
    let profileLabel: String
    var windowCount = 0
    var skippedWindowCount = 0
    var inputRMSSum: Float = 0
    var bandRMSSum: Float = 0

    nonisolated mutating func record(_ metrics: AudioPreprocessingMetrics) {
        windowCount += 1
        if metrics.skippedByBandEnergyGate {
            skippedWindowCount += 1
        }
        inputRMSSum += metrics.inputRMS
        bandRMSSum += metrics.bandRMS
    }

    nonisolated var summary: ExpertBenchmarkPreprocessingSummary {
        ExpertBenchmarkPreprocessingSummary(
            profileLabel: profileLabel,
            windowCount: windowCount,
            skippedWindowCount: skippedWindowCount,
            averageInputRMS: average(inputRMSSum),
            averageBandRMS: average(bandRMSSum)
        )
    }

    nonisolated private func average(_ value: Float) -> Float {
        guard windowCount > 0 else { return 0 }
        return value / Float(windowCount)
    }
}

private struct DetectionAggregate: Sendable {
    let scientificName: String
    let germanName: String
    var maxConfidence: Float = 0
    var confidenceSum: Float = 0
    var hitWindowCount = 0
    var firstHitStartSeconds: Double?
    var lastHitStartSeconds: Double = 0

    nonisolated mutating func record(confidence: Float, windowStartSeconds: Double) {
        maxConfidence = max(maxConfidence, confidence)
        confidenceSum += confidence
        hitWindowCount += 1
        if firstHitStartSeconds == nil {
            firstHitStartSeconds = windowStartSeconds
        }
        lastHitStartSeconds = windowStartSeconds
    }

    nonisolated func result(analyzedWindowCount: Int) -> ExpertBenchmarkDetectionResult {
        ExpertBenchmarkDetectionResult(
            scientificName: scientificName,
            germanName: germanName,
            maxConfidence: maxConfidence,
            averageConfidence: hitWindowCount == 0
                ? 0 : confidenceSum / Float(hitWindowCount),
            hitWindowCount: hitWindowCount,
            analyzedWindowCount: analyzedWindowCount,
            firstHitStartSeconds: firstHitStartSeconds ?? 0,
            lastHitStartSeconds: lastHitStartSeconds
        )
    }
}
