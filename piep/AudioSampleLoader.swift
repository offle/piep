import AVFoundation
import Foundation

enum AudioSampleLoader {

    nonisolated static let targetSampleRate: Double = 48_000

    nonisolated static func loadMono48k(
        from url: URL,
        maximumDuration: TimeInterval
    ) throws -> [Float] {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let sourceFrameLimit = min(
            AVAudioFramePosition(maximumDuration * sourceFormat.sampleRate),
            file.length
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceFrameLimit)
        ) else {
            throw AudioInputError.unableToCreateTargetFormat
        }

        try file.read(
            into: buffer,
            frameCount: AVAudioFrameCount(sourceFrameLimit)
        )
        let sourceSamples = monoSamples(from: buffer)
        let resampled = resampleLinear(
            sourceSamples,
            sourceSampleRate: sourceFormat.sampleRate,
            targetSampleRate: targetSampleRate
        )
        let maximumSamples = Int(maximumDuration * targetSampleRate)
        return Array(resampled.prefix(maximumSamples))
    }

    nonisolated private static func monoSamples(
        from buffer: AVAudioPCMBuffer
    ) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else {
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

    nonisolated private static func resampleLinear(
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
            let lower = min(Int(sourcePosition), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            resampled[index] = samples[lower] * (1 - fraction)
                + samples[upper] * fraction
        }
        return resampled
    }
}
