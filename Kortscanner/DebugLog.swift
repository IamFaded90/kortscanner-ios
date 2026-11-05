import Foundation
import Combine
import UIKit
import OSLog

@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var lines: [String] = []
    private let logger = Logger(subsystem: "dk.iamfaded90.kortscanner", category: "app")
    private let maximumBytes = 512 * 1024
    private let fileURL: URL

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        fileURL = directory.appendingPathComponent("kortscanner.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previous = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            lines = Array(previous.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(1000))
        } catch {
            lines = ["Kunne ikke åbne logfil: \(error.localizedDescription)"]
        }
    }

    func startSession() {
        let bundleInfo = Bundle.main.infoDictionary ?? [:]
        info("App åbnet. Version \(bundleInfo["CFBundleShortVersionString"] ?? "?") (\(bundleInfo["CFBundleVersion"] ?? "?")). iOS \(UIDevice.current.systemVersion)")
    }

    func info(_ message: String) { append("INFO", message) }
    func error(_ message: String) { append("ERROR", message) }

    private func append(_ level: String, _ message: String) {
        // Never pass OCR text, account names, card images or credentials to this logger.
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)"
        lines.append(line)
        if lines.count > 1000 { lines.removeFirst(lines.count - 1000) }
        logger.log("\(line, privacy: .public)")
        do {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? NSNumber, size.intValue > maximumBytes {
                try Data(lines.suffix(500).joined(separator: "\n").appending("\n").utf8)
                    .write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
            } else {
                try Data((line + "\n").utf8).write(to: fileURL, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
        } catch {
            logger.error("Kunne ikke gemme fejllog.")
        }
    }

    func export() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kortscanner-fejllog.txt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func clear() {
        do {
            try Data().write(to: fileURL, options: .atomic)
            lines = []
            info("Log ryddet")
        } catch { self.error("Kunne ikke rydde loggen") }
    }
}
