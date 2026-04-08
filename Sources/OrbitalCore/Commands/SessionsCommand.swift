import ArgumentParser
import Foundation

public struct SessionsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: L10n.Sessions.abstract
    )

    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.Sessions.toolHelp))
    public var tool: String = "claude"

    public init() {}

    public func run() throws {
        guard let t = Tool(rawValue: tool) else {
            throw ValidationError(L10n.Sessions.unknownTool(tool))
        }

        let projectKey = Self.projectKey(for: FileManager.default.currentDirectoryPath)
        let store = EnvironmentStore.default

        // Collect session files from shared dir and all env dirs
        var sessionFiles: [URL] = []

        // Shared sessions
        let sharedProjectDir = store.sharedSessionDir(tool: t)
            .appendingPathComponent(projectKey)
        sessionFiles.append(contentsOf: Self.jsonlFiles(in: sharedProjectDir))

        // Per-env sessions (for isolated or un-migrated envs)
        for name in (try? store.listNames()) ?? [] {
            let envProjectDir = store.toolConfigDir(tool: t, environment: name)
                .appendingPathComponent("projects")
                .appendingPathComponent(projectKey)
            // Skip if it's a symlink (already covered by shared)
            var isDir: ObjCBool = false
            let projectsDir = store.toolConfigDir(tool: t, environment: name)
                .appendingPathComponent("projects")
            if let _ = try? FileManager.default.destinationOfSymbolicLink(atPath: projectsDir.path) {
                continue
            }
            if FileManager.default.fileExists(atPath: envProjectDir.path, isDirectory: &isDir), isDir.boolValue {
                sessionFiles.append(contentsOf: Self.jsonlFiles(in: envProjectDir))
            }
        }

        // Deduplicate by session ID
        var seen = Set<String>()
        sessionFiles = sessionFiles.filter { url in
            let id = url.deletingPathExtension().lastPathComponent
            return seen.insert(id).inserted
        }

        if sessionFiles.isEmpty {
            print(L10n.Sessions.noSessions)
            return
        }

        // Parse and sort by last timestamp
        var entries: [(id: String, firstMessage: String, lastTime: String, userCount: Int)] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .short
        displayFormatter.timeStyle = .short

        for file in sessionFiles {
            let id = file.deletingPathExtension().lastPathComponent
            guard let data = try? String(contentsOf: file, encoding: .utf8) else { continue }

            var firstUser: String?
            var lastTimestamp: Date?
            var userCount = 0

            for line in data.components(separatedBy: .newlines) where !line.isEmpty {
                guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }

                let type = d["type"] as? String

                // Extract timestamps
                if let ts = d["timestamp"] as? String, let date = isoFormatter.date(from: ts) {
                    if lastTimestamp == nil || date > lastTimestamp! { lastTimestamp = date }
                }
                if let snap = d["snapshot"] as? [String: Any],
                   let ts = snap["timestamp"] as? String,
                   let date = isoFormatter.date(from: ts) {
                    if lastTimestamp == nil || date > lastTimestamp! { lastTimestamp = date }
                }

                // Count user messages and extract first one as title
                if type == "user" {
                    userCount += 1
                    if firstUser == nil {
                        firstUser = Self.extractUserText(from: d)
                    }
                }
            }

            let title = firstUser ?? "(empty)"
            let timeStr = lastTimestamp.map { displayFormatter.string(from: $0) } ?? "?"

            entries.append((id: id, firstMessage: title, lastTime: timeStr, userCount: userCount))
        }

        // Sort by last time descending (most recent first)
        entries.sort { $0.lastTime > $1.lastTime }

        // Print
        print(L10n.Sessions.header)
        print(String(repeating: "-", count: 78))
        for e in entries {
            let idShort = String(e.id.prefix(8))
            let title = String(e.firstMessage.prefix(36))
            let msgs = "\(e.userCount) msgs"
            print("\(idShort)  \(title.padding(toLength: 38, withPad: " ", startingAt: 0))\(msgs.padding(toLength: 12, withPad: " ", startingAt: 0))\(e.lastTime)")
        }
    }

    // MARK: - Helpers

    /// Convert a directory path to Claude's project key format
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
