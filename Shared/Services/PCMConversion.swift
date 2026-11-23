import AVFoundation

/// Converts each microphone buffer once. A converter may request input repeatedly
/// to fill its output capacity; repeated requests must not replay the buffer.
enum PCMConversion {
    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> Data? {
        // Calculate output frame count based on sample rate ratio
        let inputSampleRate = buffer.format.sampleRate
        let outputSampleRate = 16000.0
        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        var suppliedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard !suppliedInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil else { return nil }

        // Extract float32 samples as Data
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0,
              let channelData = outputBuffer.floatChannelData else { return nil }

        let byteCount = frameLength * MemoryLayout<Float>.stride
        let data = Data(bytes: channelData[0], count: byteCount)

        return data
    }
}
