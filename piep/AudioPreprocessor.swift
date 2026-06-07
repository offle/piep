//
//  AudioPreprocessor.swift
//  piep
//
//  Created by Codex on 05.06.26.
//

import Accelerate
import Foundation

struct AudioPreprocessingSettings: Equatable, Sendable {
    let isBandpassEnabled: Bool
    let highpassCutoffHz: Float
    let lowpassCutoffHz: Float
    let isBandEnergyGateEnabled: Bool
    let minimumBandRMS: Float
}

struct AudioAnalysisProfile: Sendable {
    let label: String
    let settings: AudioPreprocessingSettings
}

struct AudioPreprocessingMetrics: Sendable {
    let inputRMS: Float
    let bandRMS: Float
    let skippedByBandEnergyGate: Bool
}

struct AudioPreprocessingResult: Sendable {
    let samples: [Float]
    let shouldAnalyze: Bool
    let metrics: AudioPreprocessingMetrics
}

enum AudioPreprocessor {

    nonisolated static let sampleRate: Float = 48_000

    nonisolated static func process(
        _ samples: [Float],
        settings: AudioPreprocessingSettings
    ) -> AudioPreprocessingResult {
        let inputRMS = rms(samples)
        let bandpassedSamples = settings.isBandpassEnabled
            ? bandpass(samples, settings: settings)
            : samples
        let bandRMS = rms(bandpassedSamples)
        let shouldAnalyze =
            !settings.isBandEnergyGateEnabled
            || bandRMS >= max(settings.minimumBandRMS, 0)

        guard shouldAnalyze else {
            return AudioPreprocessingResult(
                samples: bandpassedSamples,
                shouldAnalyze: false,
                metrics: AudioPreprocessingMetrics(
                    inputRMS: inputRMS,
                    bandRMS: bandRMS,
                    skippedByBandEnergyGate: true
                )
            )
        }

        return AudioPreprocessingResult(
            samples: bandpassedSamples,
            shouldAnalyze: true,
            metrics: AudioPreprocessingMetrics(
                inputRMS: inputRMS,
                bandRMS: bandRMS,
                skippedByBandEnergyGate: false
            )
        )
    }

    nonisolated private static func bandpass(
        _ samples: [Float],
        settings: AudioPreprocessingSettings
    ) -> [Float] {
        let highpassCutoff = clamp(
            settings.highpassCutoffHz,
            min: 20,
            max: sampleRate / 2 - 1
        )
        let lowpassCutoff = clamp(
            settings.lowpassCutoffHz,
            min: highpassCutoff + 100,
            max: sampleRate / 2 - 1
        )

        let highpassed = highpass(samples, cutoffHz: highpassCutoff)
        return lowpass(highpassed, cutoffHz: lowpassCutoff)
    }

    nonisolated private static func highpass(_ samples: [Float], cutoffHz: Float) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let dt = 1 / sampleRate
        let rc = 1 / (2 * Float.pi * cutoffHz)
        let alpha = rc / (rc + dt)
        var output = [Float](repeating: 0, count: samples.count)
        var previousOutput: Float = 0
        var previousInput = samples[0]

        for index in samples.indices {
            let currentInput = samples[index]
            let currentOutput = alpha
                * (previousOutput + currentInput - previousInput)
            output[index] = currentOutput
            previousOutput = currentOutput
            previousInput = currentInput
        }

        return output
    }

    nonisolated private static func lowpass(_ samples: [Float], cutoffHz: Float) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let dt = 1 / sampleRate
        let rc = 1 / (2 * Float.pi * cutoffHz)
        let alpha = dt / (rc + dt)
        var output = [Float](repeating: 0, count: samples.count)
        var previousOutput = samples[0]

        for index in samples.indices {
            previousOutput += alpha * (samples[index] - previousOutput)
            output[index] = previousOutput
        }

        return output
    }

    nonisolated private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            vDSP_rmsqv(baseAddress, 1, &value, vDSP_Length(buffer.count))
        }
        return value
    }

    nonisolated private static func clamp(_ value: Float, min lower: Float, max upper: Float) -> Float {
        Swift.max(lower, Swift.min(value, upper))
    }
}
