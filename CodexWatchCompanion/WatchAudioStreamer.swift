import AVFoundation
import Foundation

protocol WatchAudioStreaming: AnyObject {
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    func start(onChunk: @escaping (AudioChunk) -> Void) throws
    func stop()
}

struct AudioChunk {
    let sampleRate: Double
    let channels: Int
    let encoding: String
    let data: Data
    let level: Double
}

enum AudioLevelMeter {
    static let floor = 0.04

    static func normalizedLevel(rms: Double, peak: Double) -> Double {
        let safeRMS = max(rms, 0.000_001)
        let safePeak = max(peak, 0.000_001)
        let rmsDecibels = 20 * log10(safeRMS)
        let peakDecibels = 20 * log10(safePeak)
        let rmsLevel = normalized(decibels: rmsDecibels, floor: -70, ceiling: -18)
        let peakLevel = normalized(decibels: peakDecibels, floor: -65, ceiling: -10) * 0.85
        let combined = max(rmsLevel, peakLevel)
        let compressed = pow(combined, 0.55)
        return min(1, max(floor, compressed))
    }

    private static func normalized(decibels: Double, floor: Double, ceiling: Double) -> Double {
        min(1, max(0, (decibels - floor) / (ceiling - floor)))
    }
}

final class WatchAudioStreamer: WatchAudioStreaming {
    private let engine = AVAudioEngine()
    private var isRunning = false

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(watchOS 10.0, *) {
            AVAudioApplication.requestRecordPermission { allowed in
                DispatchQueue.main.async {
                    completion(allowed)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                DispatchQueue.main.async {
                    completion(allowed)
                }
            }
        }
    }

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let channels = max(1, Int(format.channelCount))

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            var data = Data(capacity: frameCount * channels * MemoryLayout<Float>.size)
            var squareSum: Double = 0
            var peak: Double = 0
            var sampleCount = 0

            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    var sample = channelData[channel][frame]
                    squareSum += Double(sample * sample)
                    peak = max(peak, Double(abs(sample)))
                    sampleCount += 1
                    withUnsafeBytes(of: &sample) { bytes in
                        data.append(contentsOf: bytes)
                    }
                }
            }

            let rms = sampleCount > 0 ? sqrt(squareSum / Double(sampleCount)) : 0
            let level = AudioLevelMeter.normalizedLevel(rms: rms, peak: peak)

            onChunk(AudioChunk(
                sampleRate: format.sampleRate,
                channels: channels,
                encoding: "pcm-f32le",
                data: data,
                level: level
            ))
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
    }
}
