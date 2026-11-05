import Foundation

public struct SystemSound: Hashable, Sendable, Identifiable {
    public let displayName: String
    public let url: URL

    public var id: URL { url }

    public init(displayName: String, url: URL) {
        self.displayName = displayName
        self.url = url
    }
}

public enum SoundLibrary {
    private static let acceptedExtensions: Set<String> = ["aiff", "aif", "caf", "wav", "m4a"]

    private static let scanRoots: [URL] = [
        URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/Audio/UISounds", isDirectory: true),
    ]

    public static func discover() -> [SystemSound] {
        var seen: Set<String> = []
        var sounds: [SystemSound] = []

        for root in scanRoots {
            let files = enumerateSoundFiles(under: root)
            for (url, relativePath) in files {
                let displayName = makeDisplayName(relativePath: relativePath)
                guard !seen.contains(displayName) else { continue }
                seen.insert(displayName)
                sounds.append(SystemSound(displayName: displayName, url: url))
            }
        }

        sounds.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return sounds
    }

    public static func findByDisplayName(_ name: String, in library: [SystemSound]) -> SystemSound? {
        library.first { $0.displayName == name }
    }

    private static func enumerateSoundFiles(under root: URL) -> [(url: URL, relative: String)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        var results: [(URL, String)] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard acceptedExtensions.contains(ext) else { continue }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            results.append((url, relative))
        }
        return results
    }

    private static func makeDisplayName(relativePath: String) -> String {
        let url = URL(fileURLWithPath: relativePath)
        let stem = url.deletingPathExtension().lastPathComponent
        let parentPath = url.deletingLastPathComponent().path
        if parentPath.isEmpty || parentPath == "." || parentPath == "/" {
            return stem
        }
        let parent = URL(fileURLWithPath: parentPath).lastPathComponent
        return parent.isEmpty ? stem : "\(parent)/\(stem)"
    }
}
