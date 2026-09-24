import Foundation

/// 聊天记录自己存一份。
///
/// 本来想直接读 Claude CLI 的会话文件（`~/.claude/projects/<cwd>/<id>.jsonl`，和 `claude --resume` 同源），
/// 但实测**这台机器上 GUI 进程读不到那个目录**：shell 工具和 swift 脚本都能读，
/// 而 app 进程（连它 fork 出来的 /bin/cat 也一样）读不到，`fileExists` 直接返回 false。
/// 所以改成 app 自己落盘，路径在自己的 Application Support 里，不受影响。
enum ChatTranscriptStore {
    static func fileURL(sessionID: UUID) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("MarketBar", isDirectory: true)
            .appendingPathComponent("chat-\(sessionID.uuidString).jsonl")
    }

    static func append(_ message: ChatMessage, sessionID: UUID) {
        let url = fileURL(sessionID: sessionID)
        guard let data = try? JSONEncoder().encode(message) else { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: url, options: .atomic)
        }
    }

    static func load(sessionID: UUID, limit: Int = 100) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL(sessionID: sessionID)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(lines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init), limit: limit)
    }

    /// 纯函数，便于单测：一行一条消息，坏行跳过
    static func parse(lines: [String], limit: Int = 100) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(ChatMessage.self, from: data) else { continue }
            messages.append(message)
        }
        return messages.count > limit ? Array(messages.suffix(limit)) : messages
    }

    /// 「新会话」时清掉当前会话的记录
    static func remove(sessionID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(sessionID: sessionID))
    }
}
