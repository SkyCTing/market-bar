import Foundation

// MARK: - 调用参数

/// 构造 `claude` CLI 的调用参数。纯函数，便于单测。
enum ClaudeChatInvocation {
    /// ⚠️ 这里是「用户自己的完整 CLI」这条产品决策的落点：
    /// 刻意**不**传 `--tools` / `--strict-mcp-config` / `--setting-sources` / `--system-prompt`，
    /// 让用户的工具、MCP、记忆和默认模型全部生效（有测试锁住这条）。
    ///
    /// `--permission-mode bypassPermissions` 是用户明确要求的：聊天窗里的会话不弹权限询问。
    /// 代价是它**不再征求同意就能执行命令/改文件** —— 这是刻意的取舍，改动这里前先想清楚。
    static func arguments(prompt: String, sessionID: UUID, isResume: Bool) -> [String] {
        var arguments = ["-p", prompt]
        arguments += isResume
            ? ["--resume", sessionID.uuidString]
            : ["--session-id", sessionID.uuidString]
        // 用 stream-json 而不是 json：只有这样才拿得到思考过程，而且能逐块推送（边想边显示）。
        // `--verbose` 是 print 模式下用 stream-json 的硬性要求，去掉会直接报错。
        arguments += [
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "bypassPermissions",
        ]
        return arguments
    }

    /// 通过登录 shell 启动：用户的 PATH 配在 `~/.zshrc`（**交互式**才加载），
    /// 所以必须是 `-lic`（交互式登录 shell），`-lc` 会找不到 claude。
    ///
    /// 用位置参数把真实命令原样传进去，避免任何引号拼接问题；
    /// 先 `cd` 是因为 `.zshrc` 里可能自己 cd 到别处（很常见），
    /// 而 cwd 决定这个会话落在 `~/.claude/projects/<slug>/` 的哪个目录。
    static let shellCommand = "builtin cd -- \"$1\" || exit $?; exec \"${@:2}\""
    static let shellArgumentZero = "marketbar"

    static func spec(
        prompt: String,
        sessionID: UUID,
        isResume: Bool,
        claudePath: URL,
        workingDirectory: URL
    ) -> ClaudeProcessSpec {
        ClaudeProcessSpec(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [ "-lic", shellCommand, shellArgumentZero, workingDirectory.path, claudePath.path ]
                + arguments(prompt: prompt, sessionID: sessionID, isResume: isResume),
            workingDirectory: workingDirectory
        )
    }

    /// 探测 claude 路径用的登录 shell 命令
    static let pathProbeCommand = "command -v -- claude"
    static func pathProbeSpec() -> ClaudeProcessSpec {
        ClaudeProcessSpec(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lic", pathProbeCommand, shellArgumentZero],
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory())
        )
    }
}

/// 一次子进程调用的完整描述。把 `Process` 关在 runner 内部，外面只见到这个 Sendable 结构，
/// 测试里就能用 `/bin/echo` 替代真实 CLI。
struct ClaudeProcessSpec: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var workingDirectory: URL
}

// MARK: - 输出与错误

struct ClaudeProcessOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var stderrTail: String {
        let text = String(decoding: stderr, as: UTF8.self)
        return text.split(separator: "\n").suffix(8).joined(separator: "\n")
    }
}

enum ClaudeChatError: Error, Equatable {
    case launchFailed(String)
    case timeout(seconds: Int)
    case cancelled
    /// 存的会话 id 在服务端不存在（`--resume` 一个不存在的 id）
    case sessionNotFound
    case commandFailed(status: Int32, stderrTail: String)
    case invalidResponse(String)
    case executableNotFound

    var message: String {
        switch self {
        case .launchFailed(let detail):
            return "启动 claude 失败：\(detail)"
        case .timeout(let seconds):
            return "响应超时（\(seconds) 秒），已中止"
        case .cancelled:
            return "已取消"
        case .sessionNotFound:
            return "会话已失效，已开新会话"
        case .commandFailed(let status, let tail):
            return "claude 退出码 \(status)" + (tail.isEmpty ? "" : "：\n\(tail)")
        case .invalidResponse(let detail):
            return "无法解析 claude 的输出：\(detail)"
        case .executableNotFound:
            return "找不到 claude 命令，请用下面的「选择 claude 路径…」指定"
        }
    }
}

// MARK: - 进程执行

/// 进程退出码：让「先记录后等待」和「先等待后记录」两种时序都成立。
///
/// 不用裸的 `withCheckedContinuation`：`run()` 抛错时 continuation 永远不会被 resume，
/// 会卡住等待方。
final class ExitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func record(_ value: Int32) {
        lock.lock()
        status = value
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: value) }
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// `NSLock` 保护的字节缓冲（`readabilityHandler` 在别的线程上跑）
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 把 stdout 的字节流切成一行行实时回调出去（stream-json 是 NDJSON，一行一个事件）。
/// 注意 onLine 在锁外调用：避免重入死锁，调用方要自己保证线程安全。
final class LockedLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        pending.append(chunk)

        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        lock.unlock()

        for line in lines { onLine(line) }
    }

    /// 进程结束时把最后没有换行符的残行也吐出去
    func flush() {
        lock.lock()
        let remainder = pending
        pending = Data()
        lock.unlock()

        if !remainder.isEmpty, let line = String(data: remainder, encoding: .utf8), !line.isEmpty {
            onLine(line)
        }
    }
}

enum ClaudeProcessRunner {
    /// 跑一个子进程并收集 stdout/stderr。
    ///
    /// 两条管道**必须并发持续读**：macOS 管道缓冲区只有 64KB，子进程写满而没人读就会永远阻塞在
    /// write 上，`terminationHandler` 也不会触发。所以用 `readabilityHandler` 而不是「退出后再读」。
    static func run(
        _ spec: ClaudeProcessSpec,
        timeout: TimeInterval,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ClaudeProcessOutput {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectory
        // 不接 /dev/null 的话，claude CLI 会等 3 秒才继续（"no stdin data received in 3s"）
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ClaudeChatError.launchFailed(error.localizedDescription)
        }

        let stdout = LockedData()
        let stderr = LockedData()
        let drains = DispatchGroup()
        let lineBuffer = onLine.map { LockedLineBuffer(onLine: $0) }

        // run() 之后立刻装（中间没有 await），此时子进程就算已经写完，数据也在管道里等着被读
        for (handle, buffer) in [
            (stdoutPipe.fileHandleForReading, stdout),
            (stderrPipe.fileHandleForReading, stderr),
        ] {
            let isStdout = (handle === stdoutPipe.fileHandleForReading)
            drains.enter()
            handle.readabilityHandler = { readable in
                let chunk = readable.availableData
                if chunk.isEmpty {
                    readable.readabilityHandler = nil
                    if isStdout { lineBuffer?.flush() }
                    drains.leave()
                } else {
                    buffer.append(chunk)
                    if isStdout { lineBuffer?.append(chunk) }
                }
            }
        }

        var failure: ClaudeChatError?
        do {
            try await waitForExit(process, timeout: timeout)
        } catch let error as ClaudeChatError {
            failure = error
        } catch {
            failure = .cancelled
        }

        if failure != nil {
            await terminate(process)
        }

        // 不管成功失败都要等两条管道读到 EOF，否则会丢掉最后一截 stdout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drains.notify(queue: .global()) { continuation.resume() }
        }

        if let failure { throw failure }
        return ClaudeProcessOutput(status: process.terminationStatus, stdout: stdout.value, stderr: stderr.value)
    }

    /// 每 50ms 轮询一次：比 continuation + 超时竞速简单得多，也能被 `Task` 取消直接打断
    private static func waitForExit(_ process: Process, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled { throw ClaudeChatError.cancelled }
            if Date() >= deadline { throw ClaudeChatError.timeout(seconds: Int(timeout)) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// SIGTERM 后给一段宽限期，仍然活着就 SIGKILL。
    /// 因为命令行是 `exec` 的，进程 id 就是 claude 本身，不会留下孤儿 shell。
    private static func terminate(_ process: Process) async {
        guard process.isRunning else { return }

        process.terminate()
        let deadline = Date().addingTimeInterval(ClaudeChatTiming.terminateGracePeriod)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

// MARK: - 输出解析

struct ClaudeChatUsage: Decodable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    /// 这一次请求总共处理了多少 token（含缓存命中部分，那同样是走过模型的上下文）
    var totalTokens: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0)
            + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
    }
}

struct ClaudeChatResponse: Decodable, Equatable, Sendable {
    var result: String?
    var sessionID: String?
    var isError: Bool?
    /// CLI 会返回成本，但界面上只展示 token 数，不展示钱
    var totalCostUSD: Double?
    var usage: ClaudeChatUsage?

    enum CodingKeys: String, CodingKey {
        case result
        case sessionID = "session_id"
        case isError = "is_error"
        case totalCostUSD = "total_cost_usd"
        case usage
    }
}

// MARK: - 流式事件解析

/// stream-json 的一行（NDJSON）。只关心三类：思考/正文增量、会话 id、最终 result。
enum ClaudeChatEvent: Equatable {
    case sessionID(String)
    case thinkingDelta(String)
    case textDelta(String)
    case finished(ClaudeChatResult)
}

struct ClaudeChatResult: Equatable, Sendable {
    var text: String?
    var sessionID: String?
    var isError: Bool?
    var usage: ClaudeChatUsage?
}

/// 逐行喂进来、吐事件。有状态，但纯逻辑（可单测，不碰进程）。
struct ClaudeChatStreamParser {
    private var blockTypes: [Int: String] = [:]
    private var sawDelta = false

    var didReceiveDeltas: Bool { sawDelta }

    /// 返回这一行里解析出的事件（一行可能没有事件，比如 system/init 或无关噪音）
    mutating func consume(line: String) -> [ClaudeChatEvent] {
        guard let data = line.data(using: .utf8),
              let node = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = node["type"] as? String else { return [] }

        switch type {
        case "system":
            if let sessionID = node["session_id"] as? String, node["subtype"] as? String == "init" {
                return [.sessionID(sessionID)]
            }
            return []

        case "stream_event":
            guard let event = node["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { return [] }
            let index = event["index"] as? Int ?? 0

            switch eventType {
            case "content_block_start":
                // 记住每个块是思考还是正文：后面的增量只有 index，没有类型
                if let block = event["content_block"] as? [String: Any],
                   let blockType = block["type"] as? String {
                    blockTypes[index] = blockType
                }
                return []
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { return [] }
                switch deltaType {
                case "thinking_delta":
                    guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
                    sawDelta = true
                    return [.thinkingDelta(text)]
                case "text_delta":
                    guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                    sawDelta = true
                    return [.textDelta(text)]
                default:
                    return []   // signature_delta 之类
                }
            default:
                return []
            }

        case "result":
            let usage = (node["usage"] as? [String: Any]).flatMap { payload -> ClaudeChatUsage? in
                guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
                return try? JSONDecoder().decode(ClaudeChatUsage.self, from: data)
            }
            return [.finished(ClaudeChatResult(
                text: node["result"] as? String,
                sessionID: node["session_id"] as? String,
                isError: node["is_error"] as? Bool,
                usage: usage
            ))]

        default:
            return []
        }
    }
}

enum ClaudeChatParser {
    /// 容错解析：登录 shell 每次都会跑用户的 `.zshrc`，任何 echo/banner 都可能排在 JSON 前面，
    /// 所以依次尝试「整体解码 → 逐行从尾部试 → 截取首个 { 到末个 }」。
    static func parse(_ data: Data) throws -> ClaudeChatResponse {
        guard !data.isEmpty else { throw ClaudeChatError.invalidResponse("输出为空") }

        let decoder = JSONDecoder()
        if let response = try? decoder.decode(ClaudeChatResponse.self, from: data) {
            return response
        }

        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            if let lineData = line.data(using: .utf8),
               let response = try? decoder.decode(ClaudeChatResponse.self, from: lineData) {
                return response
            }
        }

        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end,
           let response = try? decoder.decode(ClaudeChatResponse.self, from: Data(text[start...end].utf8)) {
            return response
        }

        throw ClaudeChatError.invalidResponse(String(text.suffix(200)))
    }


/// 会话不存在时的报错文案。实测 `--resume` 不存在的 id 会退出码 1 并在 stderr 打印这句；
    /// 文案可能随版本变化，所以留多个候选，改动集中在这一处。
    static let brokenSessionMarkers = [
        "No conversation found",
        "no conversation found",
        "session not found",
    ]

    static func indicatesBrokenSession(_ output: ClaudeProcessOutput) -> Bool {
        let text = String(decoding: output.stderr, as: UTF8.self)
        return brokenSessionMarkers.contains { text.contains($0) }
    }
}

// MARK: - 会话状态

struct ClaudeChatSessionState: Equatable, Sendable {
    private(set) var sessionID: UUID?

    init(sessionID: UUID? = nil) {
        self.sessionID = sessionID
    }

    /// 本次调用用哪个 id、要不要 `--resume`。
    /// 没有 id 时先落一个新的：即使这次请求失败，下次仍会带上同一个 id 去新建。
    mutating func begin() -> (id: UUID, isResume: Bool) {
        if let sessionID {
            return (sessionID, true)
        }
        let fresh = UUID()
        sessionID = fresh
        return (fresh, false)
    }

    /// 采纳服务端返回的 id（正常与本地一致，属于白送的保险）
    mutating func succeeded(returnedID: String?) {
        guard let returnedID, let parsed = UUID(uuidString: returnedID) else { return }
        sessionID = parsed
    }

    mutating func sessionBroke() {
        sessionID = nil
    }

    mutating func reset() {
        sessionID = nil
    }
}

// MARK: - 转写模型

struct ChatMessage: Equatable, Sendable, Codable {
    enum Role: String, Equatable, Sendable, Codable {
        case user
        case assistant
        case system
        case error
    }

    let role: Role
    let text: String
    let date: Date
    /// 本次请求处理的总 token 数（只展示 token，不展示钱）
    var tokens: Int?

    init(role: Role, text: String, date: Date = Date(), tokens: Int? = nil) {
        self.role = role
        self.text = text
        self.date = date
        self.tokens = tokens
    }
}

/// token 数的显示格式：带千分位 + 单位，例如 `33,435 tok`
enum ChatTokenFormat {
    static func text(_ tokens: Int?) -> String? {
        guard let tokens, tokens > 0 else { return nil }
        return "\(HoldingFormat.grouped(String(tokens))) tok"
    }
}

struct ChatTranscript: Equatable, Sendable {
    /// 上限：不裁剪的话 NSTextStorage 会随会话无限增长
    static let maximumMessages = 200

    private(set) var messages: [ChatMessage] = []

    mutating func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maximumMessages {
            messages.removeFirst(messages.count - Self.maximumMessages)
        }
    }

    mutating func removeAll() {
        messages.removeAll()
    }

    var isEmpty: Bool { messages.isEmpty }

    /// 纯文本形式（用于复制/测试）
    var plainText: String {
        messages.map(\.text).joined(separator: "\n\n")
    }
}

/// 后台线程喂行、主线程取快照的共享状态。
/// 不逐行往主线程跳：那会有乱序风险（增量文本一乱序就成乱码），这里用锁保证顺序。
final class LockedStreamState: @unchecked Sendable {
    struct Snapshot {
        var thinking: String
        var text: String
        var result: ClaudeChatResult?
        var sawDeltas: Bool
    }

    private let lock = NSLock()
    private var parser = ClaudeChatStreamParser()
    private var thinking = ""
    private var text = ""
    private var result: ClaudeChatResult?

    func consume(_ line: String) {
        let events = parser.consume(line: line)
        lock.lock()
        for event in events {
            switch event {
            case .thinkingDelta(let chunk): thinking += chunk
            case .textDelta(let chunk): text += chunk
            case .finished(let value): result = value
            case .sessionID: break   // result 事件里也带，够用
            }
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(thinking: thinking, text: text, result: result, sawDeltas: !text.isEmpty || !thinking.isEmpty)
    }
}

// MARK: - 时间参数

enum ClaudeChatTiming {
    /// 默认模型可能是 opus + 27k token 上下文，等几十秒是常态
    static let responseTimeout: TimeInterval = 300
    static let resolveTimeout: TimeInterval = 10
    /// 超过这么久才在标题栏显示「仍在处理…」
    static let progressHintDelay: TimeInterval = 8
    static let terminateGracePeriod: TimeInterval = 3
}

// MARK: - claude 路径解析

enum ClaudeExecutableResolver {
    /// 常见安装位置兜底（mise / npm / brew / bun / volta …）
    static let fallbackPaths = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "~/.bun/bin/claude",
        "~/.volta/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    /// 从 `command -v` 的输出里取可执行文件路径。纯函数。
    /// 交互式 shell 可能先打横幅，所以逐行找第一个存在的绝对路径。
    static func parse(_ output: String, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        for line in output.split(separator: "\n") {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("/"), isExecutable(candidate) else { continue }
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}
