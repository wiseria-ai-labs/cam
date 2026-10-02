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
    var vaultService = "ClaudeAccountManager"
    /// access token → 账号 uuid；测试里替换掉网络
    var whoami: (String) async -> String? = Store.profileUUID

    struct Window { let pct: Double; let reset: Date? }

    struct Row: Identifiable {
        let id, email, plan: String
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
        try await syncLive()  // 先存回当前账号最新的 token，否则存档里的 refresh token 会失效
        guard let target = try vault()[uuid] else { throw CAMError("账号不存在：\(uuid)") }
        var creds = try Store.readItem(credService) ?? [:]
        creds["claudeAiOauth"] = target["claudeAiOauth"]  // mcpOAuth 等其它字段原样保留
        try Store.writeItem(credService, creds)
        var config = try readConfig()
        config["oauthAccount"] = target["oauthAccount"]
        try writeConfig(config)
    }

    func remove(_ uuid: String) throws {
        var vault = try vault()
        vault[uuid] = nil
        try saveVault(vault)
    }

    /// 在隔离的临时 CLAUDE_CONFIG_DIR 里跑 `claude auth login`，不影响当前登录
    func addViaLogin() async throws -> String {
        let dir = NSHomeDirectory() + "/Library/Application Support/ClaudeAccountManager/login-\(UUID().uuidString)"
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
        var rows: [Row] = []
        for (uuid, entry) in try vault() {
            let oauth = entry["claudeAiOauth"] as? JSON
            let email = (entry["oauthAccount"] as? JSON)?["emailAddress"] as? String ?? uuid
            var row = Row(id: uuid, email: email, plan: Store.plan(oauth))
            do {
                let usage = try await self.usage(uuid, isLive: uuid == live)
                row.h5 = Store.window(usage["five_hour"])
                row.d7 = Store.window(usage["seven_day"])
            } catch { row.error = error.localizedDescription }
            rows.append(row)
        }
        return (live, rows.sorted { $0.email < $1.email })
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
