@preconcurrency import AVFoundation
import Foundation
import VoiceAudio
import VoiceTranscription

// Runs recordings through the real transcription engine and microphone health check, printing one
// JSON object per file. Use it to measure a change against real audio before shipping it.
//
//     swift run vt-eval <file listing one WAV path per line>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: vt-eval <file listing one WAV path per line>\n".utf8))
    exit(2)
}

func worstHealth(of path: String) throws -> InputHealth {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: true)
    guard
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1)))
    else {
        return .good
    }

    if file.length > 0 {
        try file.read(into: buffer)
    }

    var monitor = SignalMonitor()
    var worst = InputHealth.good

    if let channel = buffer.int16ChannelData?[0] {
        if let health = monitor.process(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))) {
            worst = max(worst, health)
        }
    }

    return max(worst, monitor.health)
}

/// What the in-recording speech check would conclude a given number of seconds in.
func wouldHearSpeech(in path: String, atSeconds seconds: Int) async throws -> Bool? {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: true)
    let frames = AVAudioFrameCount(seconds * 16_000)

    guard
        file.length >= AVAudioFramePosition(frames),
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
    else {
        return nil
    }

    try file.read(into: buffer, frameCount: frames)

    guard let channel = buffer.int16ChannelData?[0] else { return nil }

    let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("vt-eval-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: prefix) }

    let writer = try WAVFileWriter(url: prefix, sampleRate: 16_000)
    try writer.append(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    try writer.finish()

    return try await engine.containsSpeech(audioFile: prefix)
}

let engine = ParakeetTranscriptionEngine()
try await engine.prepare()

let paths = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    .split(separator: "\n")
    .map(String.init)

for path in paths {
    let started = Date()
    var output: [String: Any] = ["file": (path as NSString).lastPathComponent]

    do {
        let result = try await engine.transcribe(audioFile: URL(fileURLWithPath: path))
        output["text"] = result.text
        output["recovered"] = result.recoveredWordCount
        output["removed"] = result.removedWordCount
        output["health"] = try worstHealth(of: path).rawValue

        // The two checks a recording gets before any warning.
        for seconds in [12, 20] {
            if let heard = try await wouldHearSpeech(in: path, atSeconds: seconds) {
                output["heardAt\(seconds)s"] = heard
            }
        }
    } catch {
        output["error"] = error.localizedDescription
    }

    output["seconds"] = Date().timeIntervalSince(started)

    let data = try JSONSerialization.data(withJSONObject: output)
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}
