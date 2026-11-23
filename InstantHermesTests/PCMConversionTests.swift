import AVFoundation
import Testing
@testable import InstantHermes

struct PCMConversionTests {
    @Test(arguments: [16000.0, 44100.0, 48000.0])
    func preservesTenSecondsOfAudio(sampleRate: Double) throws {
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: 1, interleaved: false))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let count = Int(sampleRate * 10 / 1024)
        var bytes = 0
        for _ in 0..<count {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1024))
            buffer.frameLength = 1024
            for i in 0..<1024 { buffer.floatChannelData![0][i] = Float(i % 100) / 100 }
            bytes += try #require(PCMConversion.convert(buffer, using: converter)).count
        }
        let inputDuration = Double(count * 1024) / sampleRate
        let outputDuration = Double(bytes) / (16000 * 4)
        // Allow converter priming latency, but never duplicated input.
        #expect(abs(outputDuration - inputDuration) < 0.02)
    }
}
