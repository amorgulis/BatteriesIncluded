import Foundation

/// Collector outputs before normalization, suitable for transport and deterministic replay.
struct CollectorCapture: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let name: String
        let snapshot: CollectorSnapshot
    }

    let schemaVersion: Int
    let capturedAt: Date
    let appVersion: String
    let osVersion: String
    let collectors: [Entry]

    init(capturedAt: Date, collectors: [Entry]) {
        schemaVersion = 1
        self.capturedAt = capturedAt
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        appVersion = "\(version) (\(build))"
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.collectors = collectors
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func load(path: String) throws -> CollectorCapture {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let capture = try decoder.decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard capture.schemaVersion == 1 else { throw CaptureError.unsupportedVersion(capture.schemaVersion) }
        return capture
    }

    private enum CaptureError: LocalizedError {
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): "Unsupported collector snapshot version: \(version)."
            }
        }
    }
}
