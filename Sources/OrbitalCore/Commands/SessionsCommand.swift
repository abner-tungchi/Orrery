import ArgumentParser
import Foundation

public struct SessionsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: L10n.Sessions.abstract
    )

    public init() {}

    public func run() throws {
        let projectKey = Self.projectKey(for: FileManager.default.currentDirectoryPath)
        let store = EnvironmentStore.default

        var allEntries: [(tool: String, id: String, firstMessage: String, lastTime: Date?, userCount: Int)] = []

        for tool in Tool.allCases {
            let files = Self.collectSessionFiles(tool: tool, projectKey: projectKey, store: store)
            for file in files {
                if let entry = Self.parseSession(file: file, tool: tool.rawValue) {
                    allEntries.append(entry)
                }
            }
        }

        if allEntries.isEmpty {
            print(L10n.Sessions.noSessions)
            return
        }

        // Group by tool, sort each group by last time descending
        let grouped = Dictionary(grouping: allEntries, by: { $0.tool })
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .short
        displayFormatter.timeStyle = .short

        for tool in Tool.allCases {
            guard var entries = grouped[tool.rawValue], !entries.isEmpty else { continue }
            entries.sort { ($0.lastTime ?? .distantPast) > ($1.lastTime ?? .distantPast) }

            print("")
            print("  \(tool.rawValue)")
            print("  \(String(repeating: "-", count: 76))")
            print("  \(L10n.Sessions.header)")
            for e in entries {
                let idShort = String(e.id.prefix(8))
                let title = String(e.firstMessage.prefix(36))
                let msgs = "\(e.userCount) msgs"
                let timeStr = e.lastTime.map { displayFormatter.string(from: $0) } ?? "?"
                print("  \(idShort)  \(title.padding(toLength: 38, withPad: " ", startingAt: 0))\(msgs.padding(toLength: 12, withPad: " ", startingAt: 0))\(timeStr)")
            }
        }
        print("")
    }

    // MARK: - Helpers

    static func collectSessionFiles(tool: Tool, projectKey: String, store: EnvironmentStore) -> [URL] {
        var files: [URL] = []
        var seen = Set<String>()

        // Shared sessions
        let sharedProjectDir = store.sharedSessionDir(tool: tool)
            .appendingPathComponent(projectKey)
        files.append(contentsOf: jsonlFiles(in: sharedProjectDir))

        // Per-env sessions (isolated or un-migrated)
        for name in (try? store.listNames()) ?? [] {
            let projectsDir = store.toolConfigDir(tool: tool, environment: name)
                .appendingPathComponent("projects")
            // Skip symlinked dirs (already covered by shared)
            if let _ = try? FileManager.default.destinationOfSymbolicLink(atPath: projectsDir.path) {
                continue
            }
            let envProjectDir = projectsDir.appendingPathComponent(projectKey)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: envProjectDir.path, isDirectory: &isDir), isDir.boolValue {
                files.append(contentsOf: jsonlFiles(in: envProjectDir))
            }
        }

        // Deduplicate by session ID
        return files.filter { url in
            let id = url.deletingPathExtension().lastPathComponent
            return seen.insert(id).inserted
        }
    }

    static func parseSession(file: URL, tool: String) -> (tool: String, id: String, firstMessage: String, lastTime: Date?, userCount: Int)? {
        let id = file.deletingPathExtension().lastPathComponent
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var firstUser: String?
        var lastTimestamp: Date?
        var userCount = 0

        for line in data.components(separatedBy: .newlines) where !line.isEmpty {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }

            let type = d["type"] as? String

            if let ts = d["timestamp"] as? String, let date = isoFormatter.date(from: ts) {
                if lastTimestamp == nil || date > lastTimestamp! { lastTimestamp = date }
            }
            if let snap = d["snapshot"] as? [String: Any],
               let ts = snap["timestamp"] as? String,
               let date = isoFormatter.date(from: ts) {
                if lastTimestamp == nil || date > lastTimestamp! { lastTimestamp = date }
            }

            if type == "user" {
                userCount += 1
                if firstUser == nil {
                    firstUser = extractUserText(from: d)
                }
            }
        }

        let title = firstUser ?? "(empty)"
        return (tool: tool, id: id, firstMessage: title, lastTime: lastTimestamp, userCount: userCount)
    }

    static func projectKey(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    static func jsonlFiles(in dir: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.filter { $0.pathExtension == "jsonl" }
    }

    static func extractUserText(from dict: [String: Any]) -> String? {
        guard let msg = dict["message"] as? [String: Any] else { return nil }
        let content = msg["content"]
        if let text = content as? String {
            return String(text.prefix(80))
        }
        if let arr = content as? [[String: Any]] {
            for item in arr {
                if item["type"] as? String == "text", let text = item["text"] as? String {
                    return String(text.prefix(80))
                }
            }
        }
        return nil
    }
}
