//
//  BenchmarkAudioRecorder.swift
//  piep
//
//  Created by Codex on 06.06.26.
//

import Accelerate
import AVFoundation
import Foundation

struct BenchmarkAudioRecorderStats: Sendable {
    let level: Float
    let recordedSamples: Int
    let tapCount: Int
}

final class BenchmarkAudioRecorder: @unchecked Sendable {

    static let maximumDuration: TimeInterval = 30
    static let sampleRate: Double = 48_000
    static let maximumSamples = Int(maximumDuration * sampleRate)

    private var audioEngine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var tapCount = 0
    private var onStats: ((BenchmarkAudioRecorderStats) -> Void)?
    private var onReachedLimit: (() -> Void)?
    private var hasReportedLimit = false

    var recordedSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func start(
        onStats: @escaping (BenchmarkAudioRecorderStats) -> Void,
        onReachedLimit: @escaping () -> Void
    ) throws -> String {
        stop()
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Self.maximumSamples)
        tapCount = 0
        hasReportedLimit = false
        lock.unlock()

        self.onStats = onStats
        self.onReachedLimit = onReachedLimit

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
        try session.setPreferredSampleRate(Self.sampleRate)
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
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioInputError.unableToCreateTargetFormat
        }

        let needsConversion =
            hwFormat.sampleRate != Self.sampleRate || hwFormat.channelCount != 1
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

    @discardableResult
    func stop() -> [Float] {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        onStats = nil
        onReachedLimit = nil

        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func clear() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        tapCount = 0
        hasReportedLimit = false
        lock.unlock()
    }

    private func handleAudioTap(
        _ pcmBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) {
        if let converter {
            let ratio = Self.sampleRate / converter.inputFormat.sampleRate
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

    private func appendAndReport(_ incomingSamples: UnsafeBufferPointer<Float>) {
        guard let baseAddress = incomingSamples.baseAddress,
              incomingSamples.count > 0
        else {
            return
        }

        var rms: Float = 0
        vDSP_rmsqv(baseAddress, 1, &rms, vDSP_Length(incomingSamples.count))

        let stats: BenchmarkAudioRecorderStats
        let reachedLimit: Bool

        lock.lock()
        let remainingCapacity = Self.maximumSamples - samples.count
        if remainingCapacity > 0 {
            let acceptedCount = min(remainingCapacity, incomingSamples.count)
            samples.append(contentsOf: UnsafeBufferPointer(
                start: baseAddress,
                count: acceptedCount
            ))
        }
        tapCount += 1
        reachedLimit = samples.count >= Self.maximumSamples && !hasReportedLimit
        if reachedLimit {
            hasReportedLimit = true
        }
        stats = BenchmarkAudioRecorderStats(
            level: rms,
            recordedSamples: samples.count,
            tapCount: tapCount
        )
        lock.unlock()

        onStats?(stats)
        if reachedLimit {
            onReachedLimit?()
        }
    }
}
