//
//  BirdNETClassifier.swift
//  piep
//
//  Created by Ole on 02.06.26.
//

import Foundation
import TensorFlowLite

// MARK: - Data Types

/// A single bird detection result.
struct BirdDetection: Identifiable, Equatable {
    let id = UUID()
    let scientificName: String
    let germanName: String
    let confidence: Float

    static func == (lhs: BirdDetection, rhs: BirdDetection) -> Bool {
        lhs.scientificName == rhs.scientificName
            && lhs.confidence == rhs.confidence
    }
}

// MARK: - BirdNET Classifier

/// Runs inference on both the audio-model and meta-model TFLite files.
///
/// - The **audio model** takes 3 seconds of raw 48 kHz mono audio (144,000 Float32 samples)
///   and outputs 6522 logits (one per species). The model has a built-in spectrogram layer,
///   so no external mel-spectrogram computation is required.
///
/// - The **meta model** takes a circular-encoded (sin/cos) representation of
///   latitude, longitude, and week-of-year and outputs 6522 occurrence probabilities.
///   These are used to filter/weight the audio predictions by geographic plausibility.
nonisolated final class BirdNETClassifier: @unchecked Sendable {

    // MARK: - Constants

    private static let sampleRate: Double = 48_000
    private static let chunkDuration: Double = 3.0
    static let chunkSamples: Int = 144_000  // sampleRate × chunkDuration
    private static let speciesCount: Int = 6_522
    private static let weeksPerYear: Double = 48.0

    /// Minimum audio-model confidence to consider a detection in the live UI.
    static let defaultConfidenceThreshold: Float = 0.1

    private static let excludedScientificNames: Set<String> = [
        "Human non-vocal",
        "Human vocal",
        "Human whistle",
    ]

    /// Minimum meta-model occurrence probability to keep a species in the filter.
    private static let occurrenceThreshold: Float = 0.03

    // MARK: - State

    private var audioInterpreter: Interpreter?
    private var metaInterpreter: Interpreter?
    private var labels: [(scientific: String, german: String)] = []

    /// Species occurrence mask from the meta model.
    /// Index i → probability that species i is present at the current location/week.
    /// `nil` means no location filter is active (all species considered).
    private var speciesFilter: [Float]?

    private let lock = NSLock()

    // MARK: - Initialization

    init() {
        loadLabels()
        loadAudioModel()
        loadMetaModel()
    }

    // MARK: - Label Loading

    private func loadLabels() {
        // Try directory variants — Xcode may bundle with or without subdirectory
        let path: String? =
            Bundle.main.path(forResource: "de", ofType: "txt", inDirectory: "BirdNET_v2/labels")
            ?? Bundle.main.path(forResource: "de", ofType: "txt", inDirectory: "labels")
            ?? Bundle.main.path(forResource: "de", ofType: "txt")

        guard let labelPath = path else {
            print("[BirdNET] ⚠️ de.txt not found in bundle")
            return
        }

        do {
            let content = try String(contentsOfFile: labelPath, encoding: .utf8)
            labels = content
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { line in
                    let parts = line.split(separator: "_", maxSplits: 1)
                    let scientific = String(parts[0])
                    let german = parts.count > 1 ? String(parts[1]) : scientific
                    return (scientific: scientific, german: german)
                }
            print("[BirdNET] ✅ Loaded \(labels.count) labels (DE)")
        } catch {
            print("[BirdNET] ⚠️ Failed to load labels: \(error)")
        }
    }

    // MARK: - Audio Model

    private func loadAudioModel() {
        let path: String? =
            Bundle.main.path(forResource: "audio-model", ofType: "tflite", inDirectory: "BirdNET_v2")
            ?? Bundle.main.path(forResource: "audio-model", ofType: "tflite")

        guard let modelPath = path else {
            print("[BirdNET] ⚠️ audio-model.tflite not found in bundle")
            return
        }

        do {
            var options = Interpreter.Options()
            options.threadCount = 2
            audioInterpreter = try Interpreter(modelPath: modelPath, options: options)
            try audioInterpreter?.allocateTensors()

            // Log tensor shapes for debugging
            if let input = try? audioInterpreter?.input(at: 0),
               let output = try? audioInterpreter?.output(at: 0)
            {
                print("[BirdNET] ✅ Audio model loaded — input: \(input.shape), output: \(output.shape)")
            }
        } catch {
            print("[BirdNET] ⚠️ Failed to load audio model: \(error)")
        }
    }

    // MARK: - Meta Model

    private func loadMetaModel() {
        let path: String? =
            Bundle.main.path(forResource: "meta-model", ofType: "tflite", inDirectory: "BirdNET_v2")
            ?? Bundle.main.path(forResource: "meta-model", ofType: "tflite")

        guard let modelPath = path else {
            print("[BirdNET] ⚠️ meta-model.tflite not found in bundle")
            return
        }

        do {
            metaInterpreter = try Interpreter(modelPath: modelPath)
            try metaInterpreter?.allocateTensors()

            if let input = try? metaInterpreter?.input(at: 0),
               let output = try? metaInterpreter?.output(at: 0)
            {
                print("[BirdNET] ✅ Meta model loaded — input: \(input.shape), output: \(output.shape)")
            }
        } catch {
            print("[BirdNET] ⚠️ Failed to load meta model: \(error)")
        }
    }

    // MARK: - Location Filter

    /// Update the species occurrence filter based on location and current date.
    /// Call this whenever the location changes or periodically.
    func updateLocationFilter(latitude: Double, longitude: Double) {
        guard let interpreter = metaInterpreter else {
            print("[BirdNET] Meta model not available — skipping location filter")
            return
        }

        // Calculate week of year (BirdNET uses 48 weeks)
        let calendar = Calendar.current
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let week = min(48, max(1, Int(ceil(Double(dayOfYear) / (365.25 / Self.weeksPerYear)))))

        // Circular embedding: sin/cos encoding for week, lat, lon
        let weekAngle = 2.0 * Double.pi * Double(week) / Self.weeksPerYear
        let latAngle  = 2.0 * Double.pi * (latitude + 90.0) / 180.0
        let lonAngle  = 2.0 * Double.pi * (longitude + 180.0) / 360.0

        // Check actual input shape
        guard let inputTensor = try? interpreter.input(at: 0) else { return }
        let inputSize = inputTensor.shape.dimensions.last ?? 6

        // Build input vector
        var inputFeatures: [Float32]
        if inputSize == 3 {
            inputFeatures = [
                Float32(latitude),
                Float32(longitude),
                Float32(week),
            ]
        } else if inputSize == 6 {
            inputFeatures = [
                Float32(sin(weekAngle)), Float32(cos(weekAngle)),
                Float32(sin(latAngle)),  Float32(cos(latAngle)),
                Float32(sin(lonAngle)),  Float32(cos(lonAngle)),
            ]
        } else if inputSize == 4 {
            // Some model versions use fewer features
            inputFeatures = [
                Float32(sin(weekAngle)), Float32(cos(weekAngle)),
                Float32(latitude / 90.0), Float32(longitude / 180.0),
            ]
        } else {
            // Fallback: fill with the standard encoding, padded
            inputFeatures = [Float32](repeating: 0, count: inputSize)
            if inputSize >= 2 {
                inputFeatures[0] = Float32(sin(weekAngle))
                inputFeatures[1] = Float32(cos(weekAngle))
            }
            if inputSize >= 4 {
                inputFeatures[2] = Float32(sin(latAngle))
                inputFeatures[3] = Float32(cos(latAngle))
            }
            if inputSize >= 6 {
                inputFeatures[4] = Float32(sin(lonAngle))
                inputFeatures[5] = Float32(cos(lonAngle))
            }
        }

        do {
            let inputData = inputFeatures.withUnsafeBufferPointer { buffer in
                Data(buffer: buffer)
            }
            try interpreter.copy(inputData, toInputAt: 0)
            try interpreter.invoke()

            let outputTensor = try interpreter.output(at: 0)
            let outputData = outputTensor.data
            let filter: [Float32] = outputData.withUnsafeBytes { rawBuffer in
                let ptr = rawBuffer.baseAddress!.assumingMemoryBound(to: Float32.self)
                return Array(UnsafeBufferPointer(start: ptr, count: outputData.count / MemoryLayout<Float32>.stride))
            }

            lock.lock()
            speciesFilter = filter
            lock.unlock()

            let activeSpecies = filter.filter { $0 >= Self.occurrenceThreshold }.count
            print("[BirdNET] 📍 Location filter updated: \(activeSpecies) species expected at (\(String(format: "%.2f", latitude)), \(String(format: "%.2f", longitude))), week \(week)")
        } catch {
            print("[BirdNET] ⚠️ Meta model inference failed: \(error)")
        }
    }

    /// Clear the location filter (consider all species).
    func clearLocationFilter() {
        lock.lock()
        speciesFilter = nil
        lock.unlock()
    }

    // MARK: - Audio Classification

    /// Classify a 3-second audio chunk. Must contain exactly 144,000 Float32 samples.
    /// Returns detected birds sorted by confidence (descending).
    func classify(
        audioSamples: [Float],
        minimumConfidence: Float = BirdNETClassifier.defaultConfidenceThreshold
    ) -> [BirdDetection] {
        guard let interpreter = audioInterpreter else {
            print("[BirdNET] Audio model not loaded")
            return []
        }
        guard audioSamples.count == Self.chunkSamples else {
            print("[BirdNET] ⚠️ Expected \(Self.chunkSamples) samples, got \(audioSamples.count)")
            return []
        }

        do {
            // Copy audio data to input tensor
            let inputData = audioSamples.withUnsafeBufferPointer { buffer in
                Data(buffer: buffer)
            }
            try interpreter.copy(inputData, toInputAt: 0)

            // Run inference
            try interpreter.invoke()

            // Read output logits
            let outputTensor = try interpreter.output(at: 0)
            let outputData = outputTensor.data
            let logits: [Float32] = outputData.withUnsafeBytes { rawBuffer in
                let ptr = rawBuffer.baseAddress!.assumingMemoryBound(to: Float32.self)
                return Array(UnsafeBufferPointer(start: ptr, count: outputData.count / MemoryLayout<Float32>.stride))
            }

            // Apply sigmoid to get probabilities
            let probabilities = logits.map { 1.0 / (1.0 + exp(-$0)) }

            // Get species filter snapshot
            lock.lock()
            let filter = speciesFilter
            lock.unlock()

            // Build detections
            var detections: [BirdDetection] = []
            let maxIndex = min(probabilities.count, labels.count)

            for i in 0..<maxIndex {
                let label = labels[i]
                guard !Self.excludedScientificNames.contains(label.scientific) else {
                    continue
                }

                var confidence = probabilities[i]

                // Apply location filter: multiply by occurrence probability
                if let filter, i < filter.count {
                    if filter[i] < Self.occurrenceThreshold {
                        continue  // Species not expected at this location
                    }
                    confidence *= filter[i]
                }

                if confidence >= minimumConfidence {
                    detections.append(BirdDetection(
                        scientificName: label.scientific,
                        germanName: label.german,
                        confidence: confidence
                    ))
                }
            }

            // Sort by confidence descending, limit to top 10
            detections.sort { $0.confidence > $1.confidence }
            if detections.count > 10 {
                detections = Array(detections.prefix(10))
            }

            return detections
        } catch {
            print("[BirdNET] ⚠️ Audio inference failed: \(error)")
            return []
        }
    }
}
