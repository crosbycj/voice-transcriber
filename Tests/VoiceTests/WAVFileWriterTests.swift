import AVFoundation
import Foundation
import Testing
@testable import VoiceAudio

@Suite struct WAVFileWriterTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wav-test-\(UUID().uuidString).wav")
    }

    private func write(_ samples: [Int16], to writer: WAVFileWriter) throws {
        try samples.withUnsafeBufferPointer { try writer.append($0) }
    }

    @Test func finishedFileReadsBackExactly() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = (0..<20_000).map { Int16(truncatingIfNeeded: $0 * 7) }
        let writer = try WAVFileWriter(url: url, sampleRate: 16_000)
        try write(samples, to: writer)
        try writer.finish()

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.length == 20_000)
        #expect(file.fileFormat.sampleRate == 16_000)

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 20_000))
        try file.read(into: buffer)
        let readBack = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: 20_000))
        #expect(readBack == samples)
    }

    @Test func fileIsReadableMidRecordingAfterFirstCheckpoint() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVFileWriter(url: url, sampleRate: 16_000)
        try write([Int16](repeating: 5, count: 16_000), to: writer)

        // Never finished, as if the app died here.
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 16_000)
    }

    @Test func repairRecoversAudioWrittenAfterTheLastCheckpoint() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVFileWriter(url: url, sampleRate: 16_000)
        try write([Int16](repeating: 5, count: 16_000 + 4_000), to: writer)
        writer.abandon()

        #expect(try WAVFileWriter.repair(at: url) == 20_000)
        #expect(try AVAudioFile(forReading: url).length == 20_000)
    }

    @Test func repairHandlesATornFinalSample() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVFileWriter(url: url, sampleRate: 16_000)
        try write([1, 2, 3], to: writer)
        writer.abandon()

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7F]))
        try handle.close()

        #expect(try WAVFileWriter.repair(at: url) == 3)
    }

    @Test func repairRefusesFilesItDidNotWrite() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(repeating: 1, count: 500).write(to: url)
        #expect(throws: WAVFileError.self) { try WAVFileWriter.repair(at: url) }
    }
}
