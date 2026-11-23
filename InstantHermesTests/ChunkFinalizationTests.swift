import Foundation
import Testing
@testable import InstantHermes

private actor UploadProbe: AudioUploadClient {
    var events: [String] = []
    var finalAudio = Data()
    var finalSequence = -1
    private var uploadGate: CheckedContinuation<Void, Never>?
    private var started = false

    func uploadChunk(recordingID: UUID, sequence: Int, data: Data) async throws {
        events.append("upload-start")
        started = true
        await withCheckedContinuation { uploadGate = $0 }
        events.append("upload-end")
    }
    func submit(recordingID: UUID, deliveryTarget: String?, finalAudio: Data, finalSequence: Int) async throws {
        events.append("finalize")
        self.finalAudio = finalAudio
        self.finalSequence = finalSequence
    }
    func releaseUpload() { uploadGate?.resume(); uploadGate = nil }
    func isUploading() -> Bool { started }
}

@MainActor
struct ChunkFinalizationTests {
    @Test func finalChunkIsCombinedWithSubmit() async throws {
        let probe = UploadProbe()
        let batcher = ChunkBatcher(recordingID: UUID(), sttClient: probe, errorFlag: UploadErrorFlag())
        let tail = Data(repeating: 1, count: 400)
        await batcher.add(tail)
        try await batcher.finalize(deliveryTarget: nil)
        #expect(await probe.events == ["finalize"])
        #expect(await probe.finalAudio == tail)
        #expect(await probe.finalSequence == 0)
    }

    @Test func waitsForEarlierUploadThenFinalizesWithoutUploadingTailSeparately() async throws {
        let probe = UploadProbe()
        let batcher = ChunkBatcher(recordingID: UUID(), sttClient: probe, errorFlag: UploadErrorFlag())
        await batcher.add(Data(repeating: 0, count: 65536))
        let deadline = Date().addingTimeInterval(2)
        while !(await probe.isUploading()) && Date() < deadline { await Task.yield() }
        #expect(await probe.isUploading())
        let tail = Data(repeating: 2, count: 400)
        await batcher.add(tail)
        #expect(await batcher.waitForUploads(timeout: 0) == false)
        let finalize = Task { try await batcher.finalize(deliveryTarget: "matrix") }
        await probe.releaseUpload()
        try await finalize.value
        #expect(await probe.events == ["upload-start", "upload-end", "finalize"])
        #expect(await probe.finalSequence == 1)
        #expect(await probe.finalAudio == tail)
    }

    @Test func failedUploadNeverFinalizes() async throws {
        let probe = UploadProbe()
        let errors = UploadErrorFlag()
        let batcher = ChunkBatcher(recordingID: UUID(), sttClient: probe, errorFlag: errors)
        errors.set(URLError(.cannotConnectToHost))
        do {
            try await batcher.finalize(deliveryTarget: nil)
            Issue.record("Accepted despite upload failure")
        } catch { }
        #expect(await probe.events.isEmpty)
    }
}
