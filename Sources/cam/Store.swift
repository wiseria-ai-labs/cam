import CryptoKit
import Foundation

typealias JSON = [String: Any]

struct CAMError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Claude Code 登录态 = Keychain 凭据（claudeAiOauth + mcpOAuth）+ .claude.json 的 oauthAccount。
/// 命名规则与读写方式照搬 CLI 2.1.287 的实现，CLI 升级后需重新核对。
struct Store {
    /// nil = 默认登录态；非 nil 等同于 CLI 的 CLAUDE_CONFIG_DIR
    var configDir: String?
    /// 本 app 的账号库：一个 Keychain 条目，存 [accountUuid: {oauthAccount, claudeAiOauth}]
    /// 项目已更名为 cam，但条目名保持不变，否则已存的账号会丢
    var vaultService = "ClaudeAccountManager"
    /// access token → 账号 uuid；测试里替换掉网络
    var whoami: (String) async -> String? = Store.profileUUID

    struct Window { let pct: Double; let reset: Date? }

    struct Row: Identifiable {
        let id, name, plan: String
        var agent = "claude"
        var h5, d7: Window?
        var error: String?

        var summary: String {
            if let error { return "\(plan) · \(error)" }
            let fmt = { (w: Window?) in w.map { "\(Int($0.pct))%" } ?? "–" }
            return "\(plan) · 5h \(fmt(h5)) · 7d \(fmt(d7))"
        }
    }

    var credService: String {
        guard let configDir else { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + hash.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    var configPath: String { (configDir ?? NSHomeDirectory()) + "/.claude.json" }

    // MARK: 账号操作

    /// 把当前登录（token 可能已被 CLI 轮换）存回账号库，返回当前账号 uuid
    @discardableResult
    func syncLive() async throws -> String? {
        guard let oauth = try Store.readItem(credService)?["claudeAiOauth"] as? JSON,
              let token = oauth["accessToken"] as? String else { return nil }
        let account = try readConfig()["oauthAccount"] as? JSON
        let configUUID = account?["accountUuid"] as? String
        // 以 token 实际归属为准：运行中的会话可能在切换后把旧账号刷新出的 token 写回 Keychain
        guard let uuid = await whoami(token) ?? configUUID else { return nil }
        var vault = try vault()
        var entry = vault[uuid] ?? [:]
        entry["claudeAiOauth"] = oauth
        if configUUID == uuid { entry["oauthAccount"] = account }
        guard let fixed = entry["oauthAccount"] else { return nil }  // 没有账号资料的 token 不入库
        vault[uuid] = entry
        try saveVault(vault)
        if configUUID != uuid {
            var config = try readConfig()
            config["oauthAccount"] = fixed
            try writeConfig(config)
        }
        return uuid
    }

    func switchTo(_ uuid: String) async throws {
        let old = try await syncLive()  // 先存回当前账号最新的 token，否则存档里的 refresh token 会失效
        guard let target = try vault()[uuid] else { throw CAMError("账号不存在：\(uuid)") }
        var creds = try Store.readItem(credService) ?? [:]
        creds["claudeAiOauth"] = target["claudeAiOauth"]  // mcpOAuth 等其它字段原样保留
        try Store.writeItem(credService, creds)
        var config = try readConfig()
        config["oauthAccount"] = target["oauthAccount"]
        try writeConfig(config)
        markLive(uuid)
        if let old, old != uuid { markOldProcs(old) }
    }

    func remove(_ uuid: String) throws {
        var vault = try vault()
        vault[uuid] = nil
        try saveVault(vault)
    }

    /// 在隔离的临时 CLAUDE_CONFIG_DIR 里跑 `claude auth login`，不影响当前登录
    func addViaLogin() async throws -> String {
        let dir = NSHomeDirectory() + "/Library/Application Support/cam/login-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = Store(configDir: dir, vaultService: vaultService)
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            _ = try? Store.security(["delete-generic-password", "-a", Store.keychainUser, "-s", tmp.credService])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "auth", "login"]
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
        env["CLAUDE_CONFIG_DIR"] = dir
        env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // 兜底超时；用户可随时取消（Task.cancel → 结束 claude 进程）
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { if p.isRunning { p.terminate() } }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                p.terminationHandler = { _ in c.resume() }
                do { try p.run() } catch { c.resume(throwing: error) }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        try Task.checkCancellation()
        guard p.terminationStatus == 0 else { throw CAMError("登录未完成（claude exit \(p.terminationStatus)）") }
        guard let oauth = try Store.readItem(tmp.credService)?["claudeAiOauth"] as? JSON,
              let account = try tmp.readConfig()["oauthAccount"] as? JSON,
              let uuid = account["accountUuid"] as? String else {
            throw CAMError("登录成功但没读到凭据：\(tmp.credService)")
        }
        var vault = try vault()
        vault[uuid] = ["claudeAiOauth": oauth, "oauthAccount": account]
        try saveVault(vault)
        return uuid
    }

    // MARK: 用量

    /// 当前账号只读 Keychain、刷新交给 CLI（否则 CLI 手里的 refresh token 会失效）；其它账号由本 app 刷新
    func usage(_ uuid: String, isLive: Bool) async throws -> JSON {
        var oauth: JSON
        if isLive {
            oauth = try Store.readItem(credService)?["claudeAiOauth"] as? JSON ?? [:]
        } else {
            var vault = try vault()
            oauth = vault[uuid]?["claudeAiOauth"] as? JSON ?? [:]
            if (oauth["expiresAt"] as? Double ?? 0) < Date().timeIntervalSince1970 * 1000 + 60_000 {
                oauth = try await Store.refresh(oauth)
                vault[uuid]?["claudeAiOauth"] = oauth
                try saveVault(vault)
            }
        }
        return try await Store.api("/api/oauth/usage", token: oauth["accessToken"] as? String ?? "")
    }

    func rows() async throws -> (live: String?, rows: [Row]) {
        let live = try await syncLive()
        if let live { markLive(live) }
        var rows: [Row] = []
        for (uuid, entry) in try vault() {
            let oauth = entry["claudeAiOauth"] as? JSON
            let email = (entry["oauthAccount"] as? JSON)?["emailAddress"] as? String ?? uuid
            var row = Row(id: uuid, name: email, plan: Store.plan(oauth))
            do {
                let usage = try await self.usage(uuid, isLive: uuid == live)
                row.h5 = Store.window(usage["five_hour"])
                row.d7 = Store.window(usage["seven_day"])
            } catch { row.error = error.localizedDescription }
            rows.append(row)
        }
        return (live, rows.sorted { $0.name < $1.name })
    }

    // MARK: Token 用量

    /// 一次 API 响应的 token 数（输入 + 输出 + 缓存读写）；account = 写这条日志的进程所用的账号，CAM 开始记录前的为 nil
    struct TokenUse {
        let time: Date
        let session: String
        var account: String?
        let tokens: Int
    }

    var claudeDir: String { configDir ?? NSHomeDirectory() + "/.claude" }

    /// 本 app 自己的记录文件；跟着 configDir 走，测试里落在临时目录
    func camFile(_ name: String) -> String {
        configDir.map { "\($0)/cam-\(name)" } ?? NSHomeDirectory() + "/Library/Application Support/cam/\(name)"
    }
    func load(_ path: String) -> Any? { FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    func save(_ path: String, _ obj: Any) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: try? JSONSerialization.data(withJSONObject: obj))
    }

    /// 当前账号的变化记录 [[秒, uuid]]：会话日志里没有账号信息，只能按时间对上
    var timelinePath: String { camFile("timeline.json") }

    func timeline() -> [(t: Double, id: String)] {
        (load(timelinePath) as? [[Any]] ?? []).compactMap { e in (e.first as? Double).flatMap { t in (e.last as? String).map { (t, $0) } } }
    }

    // ponytail: 只在切换和定时刷新（5 分钟）时记录，终端里 /login 换号最多晚 5 分钟才记上，也不记旧进程
    func markLive(_ uuid: String) {
        var list = timeline()
        guard list.last?.id != uuid else { return }
        list.append((Date().timeIntervalSince1970, uuid))
        save(timelinePath, list.map { [$0.t, $0.id] })
    }

    /// 切换后还在跑的 claude 进程：[{pid, start, account, sessions, from, end}]。
    /// 鉴权跟着进程走：没重启的进程继续用旧账号，重启后（哪怕续接同一个会话）才用新账号
    var procsPath: String { camFile("procs.json") }
    func procs() -> [JSON] { load(procsPath) as? [JSON] ?? [] }
    /// 进程结束 31 天后就不会再影响统计（新数据只来自 30 天内的日志），清掉
    func saveProcs(_ list: [JSON]) { save(procsPath, list.filter { ($0["end"] as? Double ?? .infinity) > Date().timeIntervalSince1970 - 31 * 86400 }) }

    /// 正在运行的 claude 进程：CLI 在 <claudeDir>/sessions/<pid>.json 里记着 pid、启动时间和当前 sessionId，退出时删掉
    func liveSessions() -> [(pid: Int, start: Double, session: String)] {
        let dir = claudeDir + "/sessions"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name in
            guard name.hasSuffix(".json"), let data = FileManager.default.contents(atPath: dir + "/" + name),
                  let s = try? JSONSerialization.jsonObject(with: data) as? JSON,
                  let pid = s["pid"] as? Int, let start = s["startedAt"] as? Double, let session = s["sessionId"] as? String,
                  kill(pid_t(pid), 0) == 0 else { return nil }  // 进程崩溃时文件可能残留
            return (pid, start, session)
        }
    }

    /// 切换账号时记下还在跑的进程，它们之后的用量仍算旧账号。之前切换时已记过的进程保持原账号
    func markOldProcs(_ account: String) {
        var list = procs()
        let now = Date().timeIntervalSince1970
        for s in liveSessions() where !list.contains(where: { $0["pid"] as? Int == s.pid && $0["start"] as? Double == s.start }) {
            list.append(["pid": s.pid, "start": s.start, "account": account, "sessions": [s.session], "from": now])
        }
        saveProcs(list)
    }

    /// App 每隔几秒调一次：退出的旧进程记下结束时间；还在跑的补上新 sessionId（进程内 /resume、/clear 会换会话）
    // ponytail: 只有 App 开着时才检查；`cam switch` 后没开 App，旧进程的结束时间会记晚，多算给旧账号
    func reapProcs() {
        var list = procs(), changed = false
        guard list.contains(where: { $0["end"] == nil }) else { return }
        let live = liveSessions()
        for i in list.indices where list[i]["end"] == nil {
            if let s = live.first(where: { $0.pid == list[i]["pid"] as? Int && $0.start == list[i]["start"] as? Double }) {
                var ids = list[i]["sessions"] as? [String] ?? []
                if !ids.contains(s.session) { ids.append(s.session); list[i]["sessions"] = ids; changed = true }
            } else {
                list[i]["end"] = Date().timeIntervalSince1970
                changed = true
            }
        }
        if changed { saveProcs(list) }
    }

    /// 扫 <claudeDir>/projects 下的会话日志（含子 agent）。同一响应按内容块重复记多行、续接的会话会复制历史，所以按 message id 去重。
    /// 归属：会话属于某个旧进程、且在它运行期间 → 旧进程的账号；否则按当时在用的账号
    func tokenUsage(days: Int) async -> [TokenUse] {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let sinceText = ISO8601DateFormatter().string(from: since)  // 日志时间都是 UTC「Z」，先比字符串筛掉旧行
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let marks = timeline()
        let olds = procs().map { p in
            (account: p["account"] as? String, sessions: Set(p["sessions"] as? [String] ?? []),
             from: p["from"] as? Double ?? .infinity, end: p["end"] as? Double ?? .infinity)
        }
        let key = Data("\"usage\"".utf8)
        let files = FileManager.default.enumerator(at: URL(fileURLWithPath: claudeDir + "/projects"),
                                                   includingPropertiesForKeys: [.contentModificationDateKey])?.allObjects as? [URL] ?? []
        var seen = Set<String>(), out: [TokenUse] = []
        for url in files where url.pathExtension == "jsonl" {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mtime >= since else { continue }
            if Store.parsed[url.path]?.mtime != mtime, let data = try? Data(contentsOf: url) {
                var lines: [(id: String, use: TokenUse)] = []
                for line in data.split(separator: 10) where line.range(of: key) != nil {
                    guard let e = try? JSONSerialization.jsonObject(with: line) as? JSON,
                          let ts = e["timestamp"] as? String, ts >= sinceText, let time = iso.date(from: ts),
                          let m = e["message"] as? JSON, let u = m["usage"] as? JSON else { continue }
                    lines.append(("\(m["id"] ?? e["uuid"] ?? ts)|\(e["requestId"] ?? "")",
                                  TokenUse(time: time, session: e["sessionId"] as? String ?? "", account: nil,
                                           tokens: ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                                               .reduce(0) { $0 + (u[$1] as? Int ?? 0) })))
                }
                Store.parsed[url.path] = (mtime, lines)
            }
            for (id, var use) in Store.parsed[url.path]?.lines ?? [] where use.time >= since && seen.insert(id).inserted {
                let t = use.time.timeIntervalSince1970
                use.account = olds.first { $0.sessions.contains(use.session) && $0.from <= t && t < $0.end }?.account
                    ?? marks.last { $0.t <= t }?.id
                out.append(use)
            }
        }
        return out
    }

    /// 解析过的日志按 (路径, 修改时间) 缓存，定时刷新时只重扫还在写的会话
    // ponytail: 不加锁，调用方（Model.run 的 busy / CLI）本来就是串行的；缓存只增不减，App 常驻几个月才需要清理
    nonisolated(unsafe) static var parsed: [String: (mtime: Date, lines: [(id: String, use: TokenUse)])] = [:]

    /// 每日 token 合计 [日期 yyyy-MM-dd: [账号 uuid（"" = 未归属）: tokens]]。
    /// CLI 默认 30 天后删会话日志，所以结果合并进本地存档，热力图才能画满一年
    var dailyPath: String { camFile("daily.json") }

    func dailyTokens() async -> [String: [String: Int]] {
        var fresh: [String: [String: Int]] = [:]
        for u in await tokenUsage(days: 366) { fresh[Store.day(u.time), default: [:]][u.account ?? "", default: 0] += u.tokens }
        var archive = load(dailyPath) as? [String: [String: Int]] ?? [:]
        let partial = Store.day(Date().addingTimeInterval(-366 * 86400))  // 最早那天只扫到一部分，不覆盖
        // 日志被 CLI 清掉一部分时新算的会偏少，只在不少于存档时覆盖；换归属不改变当天合计，照常覆盖
        for (day, m) in fresh where day > partial && m.values.reduce(0, +) >= archive[day]?.values.reduce(0, +) ?? 0 { archive[day] = m }
        save(dailyPath, archive)
        return archive
    }

    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// 最近 n 天（含今天）的合计；account 为 nil 时算所有账号
    static func total(_ daily: [String: [String: Int]], days n: Int, account: String? = nil) -> Int {
        (0..<n).reduce(0) { sum, i in
            let m = daily[day(Calendar.current.date(byAdding: .day, value: -i, to: Date())!)] ?? [:]
            return sum + (account.map { m[$0] ?? 0 } ?? m.values.reduce(0, +))
        }
    }

    /// "max" + "default_claude_max_5x" → "Max 5x"
    static func plan(_ oauth: JSON?) -> String {
        let type = (oauth?["subscriptionType"] as? String ?? "?").capitalized
        let tier = oauth?["rateLimitTier"] as? String ?? ""
        guard let r = tier.range(of: #"\d+x$"#, options: .regularExpression) else { return type }
        return "\(type) \(tier[r])"
    }

    static func window(_ raw: Any?) -> Window? {
        guard let w = raw as? JSON, let pct = w["utilization"] as? Double else { return nil }
        let reset = (w["resets_at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
        }
        return Window(pct: pct, reset: reset)
    }

    // MARK: 网络

    static func refresh(_ oauth: JSON) async throws -> JSON {
        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": oauth["refreshToken"] as? String ?? "",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": (oauth["scopes"] as? [String] ?? []).joined(separator: " "),
        ])
        let res = try await fetch(req)
        guard let access = res["access_token"] as? String, let expiresIn = res["expires_in"] as? Double else {
            throw CAMError("刷新 token 失败，需要重新登录该账号")
        }
        let now = Date().timeIntervalSince1970 * 1000
        var out = oauth
        out["accessToken"] = access
        out["refreshToken"] = res["refresh_token"] ?? oauth["refreshToken"]
        out["expiresAt"] = Int64(now + expiresIn * 1000)
        if let ttl = res["refresh_token_expires_in"] as? Double { out["refreshTokenExpiresAt"] = Int64(now + ttl * 1000) }
        return out
    }

    static func api(_ path: String, token: String) async throws -> JSON {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return try await fetch(req)
    }

    static func fetch(_ req: URLRequest) async throws -> JSON {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw CAMError("HTTP \(code)：\(req.url?.path ?? "")")
        }
        return obj
    }

    static func profileUUID(_ token: String) async -> String? {
        ((try? await api("/api/oauth/profile", token: token))?["account"] as? JSON)?["uuid"] as? String
    }

    // MARK: 存储

    func vault() throws -> [String: JSON] { try Store.readItem(vaultService) as? [String: JSON] ?? [:] }
    func saveVault(_ vault: [String: JSON]) throws { try Store.writeItem(vaultService, vault) }

    func readConfig() throws -> JSON {
        guard let data = FileManager.default.contents(atPath: configPath) else { return [:] }
        guard let config = try JSONSerialization.jsonObject(with: data) as? JSON else { throw CAMError("\(configPath) 不是 JSON 对象") }
        return config
    }

    /// 原子替换并保持 0600（文件里可能有 MCP server 的 env 密钥）
    func writeConfig(_ config: JSON) throws {
        let tmp = configPath + ".cam-tmp"
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes])
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp, configPath) == 0 else { throw CAMError("写入 \(configPath) 失败") }
    }

    /// 与 CLI 相同：$USER 不合法时用 claude-code-user
    static let keychainUser: String = {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return user.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil ? user : "claude-code-user"
    }()

    // 走 /usr/bin/security 而不是 SecItem API：CLI 建的条目 ACL 信任的是 security，这样读写不弹授权框
    static func readItem(_ service: String) throws -> JSON? {
        let r = try security(["find-generic-password", "-a", keychainUser, "-s", service, "-w"])
        if r.status == 44 { return nil }  // errSecItemNotFound
        var text = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("{") {  // 值含非 ASCII 时 security -w 输出 hex
            let u = Array(text.utf8)
            let bytes = stride(from: 0, to: u.count - 1, by: 2).compactMap { UInt8(String(decoding: u[$0...$0 + 1], as: UTF8.self), radix: 16) }
            text = String(decoding: bytes, as: UTF8.self)
        }
        guard r.status == 0, let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON else {
            throw CAMError("读取 Keychain 失败：\(service)（security exit \(r.status)）")
        }
        return obj
    }

    /// 照搬 CLI：hex 编码后走 `security -i` 的 stdin，不进 argv；超过 stdin 行长上限才退回 argv
    static func writeItem(_ service: String, _ obj: Any) throws {
        let hex = try JSONSerialization.data(withJSONObject: obj).map { String(format: "%02x", $0) }.joined()
        // 结尾必须有换行，否则 security -i 不执行且照样 exit 0
        let cmd = "add-generic-password -U -a \"\(keychainUser)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let r = cmd.utf8.count <= 4032
            ? try security(["-i"], stdin: cmd)
            : try security(["add-generic-password", "-U", "-a", keychainUser, "-s", service, "-X", hex])
        guard r.status == 0 else { throw CAMError("写入 Keychain 失败：\(service)（security exit \(r.status)）") }
    }

    @discardableResult
    static func security(_ args: [String], stdin: String? = nil) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try p.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
