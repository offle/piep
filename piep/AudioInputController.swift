//
//  AudioInputController.swift
//  piep
//
//  Created by Codex on 05.06.26.
//

import Accelerate
import AVFoundation
import Foundation

struct AudioInputStats: Sendable {
    let level: Float
    let bufferedSamples: Int
    let tapCount: Int
}

final class AudioInputController: @unchecked Sendable {

    private var audioEngine: AVAudioEngine?
    private let audioBuffer = AudioBuffer()
    private let statsLock = NSLock()
    private var tapCount = 0
    private var onStats: ((AudioInputStats) -> Void)?

    var bufferedSampleCount: Int {
        audioBuffer.count
    }

    func start(onStats: @escaping (AudioInputStats) -> Void) throws -> String {
        stop()
        self.onStats = onStats

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [
                .allowAirPlay,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .defaultToSpeaker,
            ]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        let formatDescription = String(
            format: "%.0f Hz, %d Kanal%@",
            hwFormat.sampleRate,
            Int(hwFormat.channelCount),
            hwFormat.channelCount == 1 ? "" : "e"
        )

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioInputError.unableToCreateTargetFormat
        }

        let needsConversion =
            hwFormat.sampleRate != 48_000 || hwFormat.channelCount != 1
        let converter: AVAudioConverter? =
            needsConversion
            ? AVAudioConverter(from: hwFormat, to: targetFormat) : nil

        inputNode.installTap(
            onBus: 0,
            bufferSize: 8192,
            format: hwFormat
        ) { [weak self] pcmBuffer, _ in
            self?.handleAudioTap(
                pcmBuffer,
                converter: converter,
                targetFormat: targetFormat
            )
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine

        return formatDescription
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioBuffer.clear()

        statsLock.lock()
        tapCount = 0
        statsLock.unlock()

        onStats = nil
    }

    func extractChunk(size: Int) -> [Float]? {
        audioBuffer.extractChunk(size: size)
    }

    private func handleAudioTap(
        _ pcmBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) {
        if let converter {
            let ratio = 48_000.0 / converter.inputFormat.sampleRate
            let capacity = AVAudioFrameCount(
                Double(pcmBuffer.frameLength) * ratio
            )
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(capacity, 1)
            ) else { return }

            var error: NSError?
            var consumed = false
            converter.convert(to: converted, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return pcmBuffer
            }

            guard error == nil, let data = converted.floatChannelData else {
                return
            }

            appendAndReport(
                UnsafeBufferPointer(
                    start: data[0],
                    count: Int(converted.frameLength)
                )
            )
        } else {
            guard let data = pcmBuffer.floatChannelData else { return }
            appendAndReport(
                UnsafeBufferPointer(
                    start: data[0],
                    count: Int(pcmBuffer.frameLength)
                )
            )
        }
    }

    private func appendAndReport(_ samples: UnsafeBufferPointer<Float>) {
        guard let baseAddress = samples.baseAddress, samples.count > 0 else {
            return
        }

        audioBuffer.append(samples)

        var rms: Float = 0
        vDSP_rmsqv(baseAddress, 1, &rms, vDSP_Length(samples.count))

        let currentTapCount = nextTapCount()
        onStats?(
            AudioInputStats(
                level: rms,
                bufferedSamples: audioBuffer.count,
                tapCount: currentTapCount
            )
        )
    }

    private func nextTapCount() -> Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        tapCount += 1
        return tapCount
    }
}

enum AudioInputError: LocalizedError {
    case unableToCreateTargetFormat

    var errorDescription: String? {
        switch self {
        case .unableToCreateTargetFormat:
            return "Audio-Format konnte nicht erstellt werden"
        }
    }
}
