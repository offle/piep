//
//  AudioBuffer.swift
//  piep
//
//  Created by Ole on 02.06.26.
//

import Foundation

/// Thread-safe ring buffer for accumulating audio samples from the
/// AVAudioEngine tap callback (audio render thread) and reading
/// them on the main thread for inference dispatch.
final class AudioBuffer: @unchecked Sendable {

    private var samples: [Float] = []
    private let lock = NSLock()
    private let maxSamples: Int

    /// - Parameter maxSamples: Maximum samples to keep (default: 2× chunk = 288,000).
    init(maxSamples: Int = 288_000) {
        self.maxSamples = maxSamples
        samples.reserveCapacity(maxSamples)
    }

    /// Append new samples from the audio tap (called on audio thread).
    func append(_ newSamples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: newSamples)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Extract the most recent `size` samples if available.
    /// Returns `nil` if not enough samples have been accumulated.
    func extractChunk(size: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard samples.count >= size else { return nil }
        let startIndex = samples.count - size
        return Array(samples[startIndex..<samples.count])
    }

    /// Clear all accumulated samples.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }

    /// Current number of accumulated samples.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }
}
