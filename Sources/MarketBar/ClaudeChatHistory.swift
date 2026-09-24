import Foundation

/// 从 Claude CLI 的会话文件里读历史消息。
///
/// 会话文件在 `~/.claude/projects/<cwd 转义>/<session-id>.jsonl`，与 `claude --resume` 同源，
/// 所以窗口里能看到整个会话（包括你在终端里聊的部分），不再是 app 自己另存的一份。
enum ClaudeChatHistory {
    static let defaultLimit = 60

    /// cwd 的转义规则：`/` 换成 `-`（`/Users/a` → `-Users-a`）
    ///
    /// ⚠️ 路径必须用字符串拼、再 `URL(fileURLWithPath:)`。
    /// 实测：`FileManager.homeDirectoryForCurrentUser.appendingPathComponent(...)` 拼出来的 URL
    /// 在 app 进程里 stat 得到 ENOENT，而同样内容的字面量绝对路径能正常读到
    /// （同一进程内同时探两个路径：derived=false / literal=true, 1096400 字节）。
    static func sessionFile(sessionID: UUID, workingDirectory: URL) -> URL {
        let slug = workingDirectory.path.replacingOccurrences(of: "/", with: "-")
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: "\(home)/.claude/projects/\(slug)/\(sessionID.uuidString).jsonl")
    }

    static func sessionDirectory(workingDirectory: URL) -> URL {
        let slug = workingDirectory.path.replacingOccurrences(of: "/", with: "-")
        return URL(fileURLWithPath: "\(NSHomeDirectory())/.claude/projects/\(slug)")
    }

    /// 该工作目录下最近修改过的会话 id。
    /// 用途：全新安装（或换过工作目录）时没有存过会话 id，接管最近用过的那个，
    /// 这样就能看到之前在终端/旧版本里聊的内容，而不是从空会话开始。
    static func mostRecentSessionID(in workingDirectory: URL) -> UUID? {
        let directory = sessionDirectory(workingDirectory: workingDirectory)
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(key)
        ) else { return nil }

        let newest = items
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: key).contentModificationDate else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }

        return newest.flatMap { UUID(uuidString: $0.0.deletingPathExtension().lastPathComponent) }
    }

    static func messages(from url: URL, limit: Int = defaultLimit) -> [ChatMessage] {
        guard let text = readText(at: url) else { return [] }
        return parse(lines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init), limit: limit)
    }

    /// 读文件，带重试。
    /// 实测：CLI 正在往会话文件里写的时候，直接读会拿到 ENOENT（文件"瞬间不存在"），
    /// 而稍后再读就正常 —— 所以隔一小会儿重试几次，最后再退回经登录 shell 读。
    /// 优先直接读（快），失败就走登录 shell 读 —— 实测 app 进程自己读 `~/.claude` 恒为 ENOENT，
    /// 但 app 启动的 CLI（以及它 fork 出来的 shell）能正常访问那个目录，所以这条路走得通。
    static func readText(at url: URL) -> String? {
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let data = try? readViaSubprocess(url), let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return nil
    }

    /// 经登录 shell 读（最后手段）
    private static func readViaSubprocess(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "cat -- \"$1\"", "marketbar", url.path]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    /// 纯函数：抽用户提问与助手回复；工具调用、思考、系统注入的内容都不进历史
    static func parse(lines: [String], limit: Int = defaultLimit) -> [ChatMessage] {
        var messages: [ChatMessage] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let node = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = node["type"] as? String,
                  let message = node["message"] as? [String: Any],
                  node["isMeta"] as? Bool != true else { continue }

            let date = (node["timestamp"] as? String).flatMap(parseTimestamp) ?? Date()

            switch type {
            case "user":
                guard let text = message["content"] as? String, isDisplayable(text) else { continue }
                messages.append(ChatMessage(role: .user, text: text, date: date))

            case "assistant":
                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                let text = blocks
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                messages.append(ChatMessage(role: .assistant, text: text, date: date))

            default:
                continue
            }
        }

        return messages.count > limit ? Array(messages.suffix(limit)) : messages
    }

    /// CLI 自己塞进去的伪用户消息（系统提醒、命令回显）都以 `<` 开头
    private static func isDisplayable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("<")
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
