import Foundation

/// Mono 16-bit PCM WAV written straight to its final location.
///
/// The header is refreshed about once a second, and `repair(at:)` can rebuild it from the file size,
/// so a crash or power loss costs at most the last moment of audio rather than the whole recording.
public final class WAVFileWriter {
    public static let headerSize = 44

    public let url: URL
    public private(set) var frameCount: Int64 = 0

    private let sampleRate: Int
    private let handle: FileHandle
    private var framesSinceCheckpoint = 0
    private var isClosed = false

    public init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate

        let header = Self.header(sampleRate: sampleRate, dataBytes: 0)
        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            throw WAVFileError.cannotCreate(url.path)
        }

        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    public func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard !samples.isEmpty else { return }

        try handle.write(contentsOf: Data(buffer: samples))
        frameCount += Int64(samples.count)
        framesSinceCheckpoint += samples.count

        if framesSinceCheckpoint >= sampleRate {
            try checkpoint()
        }
    }

    /// Finalizes the header, flushes to disk, and closes the file.
    public func finish() throws {
        guard !isClosed else { return }

        try checkpoint()
        try handle.close()
        isClosed = true
    }

    /// Closes the file without finalizing it. The caller decides whether to delete it.
    public func abandon() {
        guard !isClosed else { return }

        try? handle.close()
        isClosed = true
    }

    private func checkpoint() throws {
        framesSinceCheckpoint = 0

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: frameCount * 2))
        try handle.seekToEnd()
        try handle.synchronize()
    }

    /// Rebuilds the header of an interrupted recording from its size on disk and returns the frame count.
    @discardableResult
    public static func repair(at url: URL) throws -> Int64 {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let existingHeader = try handle.read(upToCount: headerSize) ?? Data()
        guard
            existingHeader.count == headerSize,
            existingHeader.prefix(4) == Data("RIFF".utf8),
            existingHeader[36..<40] == Data("data".utf8)
        else {
            throw WAVFileError.unrecognizedFormat(url.path)
        }

        let sampleRate = existingHeader[24..<28].enumerated().reduce(0) { result, byte in
            result | Int(byte.element) << (8 * byte.offset)
        }

        var dataBytes = Int64(try handle.seekToEnd()) - Int64(headerSize)
        if dataBytes % 2 != 0 {
            dataBytes -= 1
            try handle.truncate(atOffset: UInt64(Int64(headerSize) + dataBytes))
        }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(sampleRate: sampleRate, dataBytes: dataBytes))
        try handle.synchronize()
        return dataBytes / 2
    }

    private static func header(sampleRate: Int, dataBytes: Int64) -> Data {
        // RIFF sizes are 32-bit; ~37 hours at 16 kHz, far beyond any dictation.
        let dataSize = UInt32(clamping: dataBytes)
        let riffSize = UInt32(clamping: dataBytes + Int64(headerSize) - 8)
        let bytesPerFrame: UInt16 = 2

        var data = Data(capacity: headerSize)
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(riffSize)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate) * UInt32(bytesPerFrame))
        data.appendLittleEndian(bytesPerFrame)
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataSize)
        return data
    }
}

public enum WAVFileError: LocalizedError {
    case cannotCreate(String)
    case unrecognizedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreate(let path):
            return "Couldn't create the recording file at \(path)."
        case .unrecognizedFormat(let path):
            return "\(path) isn't a recording this app can repair."
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
