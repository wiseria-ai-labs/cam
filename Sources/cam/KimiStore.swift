import Darwin
import Foundation

/// Kimi Code 登录态 = ~/.kimi-code/credentials/kimi-code.json 一个文件（access token 15 分钟、refresh token 30 天滚动）。
/// 换号 = 在与 CLI 相同的跨进程锁（~/.kimi-code/oauth/kimi-code 的 .lock 目录）下原子替换该文件；
/// CLI 每次取 token 前都重读文件，运行中的会话几分钟内自动换到新账号，不需要 claude 那样的进程表。
/// 额度/刷新/me 的端点与参数照搬 CLI 2.1.1 的实现，不是公开 API，升级后要重新核对。
struct KimiStore {
    /// KIMI_CODE_HOME，测试指向临时目录
    var home: String
    /// 本 app 自己的记录文件目录（timeline/daily 存档）
    var appSupport: String = NSHomeDirectory() + "/Library/Application Support/cam"
    /// 本 app 的 Kimi 账号库：一个 Keychain 条目，存 [userId: {credential, profile}]
    var vaultService = "CAMKimiAccounts"
    /// 全部网络走这里，测试注入假响应
    var fetcher: (URLRequest) async throws -> (status: Int, data: Data) = KimiStore.urlSessionFetch

    static let clientId = "17e5f671-d194-4dfb-9706-5516cb48c098"

    struct RegionProfile { let oauthHost, baseUrl: String }
    static func profile(_ region: String) -> RegionProfile {
        region == "global"
            ? RegionProfile(oauthHost: "https://auth.kimi.ai", baseUrl: "https://api.kimi.ai/coding/v1")
            : RegionProfile(oauthHost: "https://auth.kimi.com", baseUrl: "https://api.kimi.com/coding/v1")
    }

    var credPath: String { home + "/credentials/kimi-code.json" }
    var lockPath: String { home + "/oauth/kimi-code" }  // CLI 锁的 sentinel；锁目录是它的 .lock

    func appFile(_ name: String) -> String { appSupport + "/" + name }
    var timelinePath: String { appFile("kimi-timeline.json") }
    var dailyPath: String { appFile("kimi-daily.json") }

    func load(_ path: String) -> Any? { FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    func save(_ path: String, _ obj: Any) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: try? JSONSerialization.data(withJSONObject: obj))
    }

    // MARK: 凭据读写

    func readCredential(_ path: String? = nil) throws -> JSON? {
        guard let data = FileManager.default.contents(atPath: path ?? credPath) else { return nil }
        guard let credential = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw CAMError("凭据文件不是 JSON：\(path ?? credPath)")
        }
        // CLI 刷新失败会把 token 写成空串（墓碑），等同未登录
        return (credential["access_token"] as? String)?.isEmpty == false ? credential : nil
    }

    /// 原子替换并保持 0600；调用方需已持有锁或确定没有并发
    func writeCredential(_ credential: JSON) throws {
        let tmp = credPath + ".cam-tmp"
        let data = try JSONSerialization.data(withJSONObject: credential, options: [.withoutEscapingSlashes])
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp, credPath) == 0 else { throw CAMError("写入 \(credPath) 失败") }
    }

    /// 与 CLI 相同的 proper-lockfile 协议：mkdir 抢 .lock 目录（原子），stale 5s 强抢，最长等 60s
    func withLock<T>(_ body: () async throws -> T) async throws -> T {
        let dir = lockPath + ".lock"
        let parent = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lockPath, contents: Data())  // CLI 也先确保 sentinel 存在
        let deadline = Date().addingTimeInterval(60)
        while true {
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
                break
            } catch {
                let age = ((try? FileManager.default.attributesOfItem(atPath: dir))?[.modificationDate] as? Date)
                    .map { Date().timeIntervalSince($0) } ?? .infinity
                if age > 5 { try? FileManager.default.removeItem(atPath: dir); continue }
                guard Date() < deadline else { throw CAMError("等待 Kimi 凭据锁超时") }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        // 同 proper-lockfile 的 update：持锁期间每 2s 刷新 mtime，否则持锁超过 5s（如慢速 refresh）会被 CLI 当成过期锁抢走
        let beat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir)
            }
        }
        defer { beat.cancel(); try? FileManager.default.removeItem(atPath: dir) }
        return try await body()
    }

    // MARK: token 识别与续期

    /// JWT 只解码不验签：拿 user_id / region，零网络
    static func jwtPayload(_ token: String) -> JSON? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var body = String(parts[1])
        while body.count % 4 != 0 { body.append("=") }
        guard let data = Data(base64Encoded: body) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSON
    }

    static func accountId(_ credential: JSON) -> String? {
        guard let token = credential["access_token"] as? String else { return nil }
        return jwtPayload(token)?["user_id"] as? String
    }

    /// region 取值跟 CLI 的 region 标记文件一致：cn / global
    static func region(_ credential: JSON) -> String {
        guard let token = credential["access_token"] as? String else { return "cn" }
        return jwtPayload(token)?["region"] as? String == "global" ? "global" : "cn"
    }

    /// 账号自己的 region（JWT 里的最准；老数据退回 cn）
    static func entryRegion(_ entry: JSON, credential: JSON) -> String {
        (entry["profile"] as? JSON)?["region"] as? String ?? Self.region(credential)
    }

    /// 照搬 CLI：剩余有效期 < max(300s, 有效期×0.5) 就该刷
    static func stale(_ credential: JSON) -> Bool {
        let expiresIn = credential["expires_in"] as? Double ?? 900
        return (credential["expires_at"] as? Double ?? 0) - Date().timeIntervalSince1970 < max(300, expiresIn * 0.5)
    }

    /// POST {oauthHost}/api/oauth/token；服务器每次都轮换 refresh_token，响应必须整体写回
    static func refresh(_ credential: JSON, region: String, fetcher: (URLRequest) async throws -> (status: Int, data: Data)) async throws -> JSON {
        guard let refreshToken = credential["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw CAMError("该账号没有 refresh token，需要重新登录")
        }
        var req = URLRequest(url: URL(string: profile(region).oauthHost + "/api/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in deviceHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = "client_id=\(clientId)&grant_type=refresh_token&refresh_token=\(refreshToken)".data(using: .utf8)
        let (status, data) = try await fetcher(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { throw CAMError("刷新 token 失败：HTTP \(status)") }
        if status == 401 || status == 403 || obj["error"] as? String == "invalid_grant" {
            throw CAMError("登录已失效，需要重新登录该账号")
        }
        guard status == 200, let access = obj["access_token"] as? String, !access.isEmpty,
              let refresh = obj["refresh_token"] as? String, !refresh.isEmpty,
              let expiresIn = (obj["expires_in"] as? Double).map(Int.init) ?? (obj["expires_in"] as? String).flatMap(Int.init), expiresIn > 0 else {
            throw CAMError("刷新 token 响应不完整：HTTP \(status)")
        }
        return ["access_token": access, "refresh_token": refresh,
                "expires_at": Int(Date().timeIntervalSince1970) + expiresIn,
                "expires_in": expiresIn,
                "scope": obj["scope"] as? String ?? credential["scope"] ?? "",
                "token_type": obj["token_type"] as? String ?? "Bearer"]
    }

    /// 当前登录的凭据，过期就在锁里续（与 CLI 同协议：拿锁后重读，可能刚被 CLI 刷过）
    func ensureFresh() async throws -> JSON {
        guard let current = try readCredential() else { throw CAMError("Kimi Code 未登录") }
        guard Self.stale(current) else { return current }
        return try await withLock {
            guard let latest = try readCredential() else { throw CAMError("Kimi Code 未登录") }
            if !Self.stale(latest) { return latest }
            let refreshed = try await Self.refresh(latest, region: Self.region(latest), fetcher: fetcher)
            try writeCredential(refreshed)
            _ = try syncLive()
            return refreshed
        }
    }

    // MARK: 账号操作

    func vault() throws -> [String: JSON] { try Store.readItem(vaultService) as? [String: JSON] ?? [:] }
    func saveVault(_ vault: [String: JSON]) throws { try Store.writeItem(vaultService, vault) }

    /// 把凭据文件里当前的登录存回账号库，返回 userId；token 归属解 JWT 就知道，不用网络
    @discardableResult
    func syncLive() throws -> String? {
        guard let credential = try readCredential(), let id = Self.accountId(credential) else { return nil }
        var vault = try vault()
        var entry = vault[id] ?? [:]
        entry["credential"] = credential
        if entry["profile"] == nil { entry["profile"] = ["region": Self.region(credential)] }
        vault[id] = entry
        try saveVault(vault)
        return id
    }

    func switchTo(_ userId: String) async throws {
        _ = try syncLive()  // 先存回当前账号（CLI 可能刚刷新过）
        guard var entry = try vault()[userId] else { throw CAMError("账号不存在：\(userId)") }
        var credential = entry["credential"] as? JSON ?? [:]
        if Self.stale(credential) {  // 非当前账号由本 app 续期
            credential = try await Self.refresh(credential, region: Self.entryRegion(entry, credential: credential), fetcher: fetcher)
            entry["credential"] = credential
            var vault = try vault(); vault[userId] = entry; try saveVault(vault)
        }
        try await withLock {
            _ = try syncLive()  // 拿锁后重读：等锁期间 CLI 若刷新过旧账号，先把新 token 存回它名下
            try writeCredential(credential)
        }
        markLive(userId)
    }

    func remove(_ userId: String) throws {
        var vault = try vault()
        vault[userId] = nil
        try saveVault(vault)
    }

    /// 在隔离的临时 KIMI_CODE_HOME 里跑 `kimi login`（CLI 自己开浏览器），不影响当前登录。
    /// onHint 收到授权链接和验证码，浏览器没自动打开时给用户手动用
    func addViaLogin(onHint: @escaping (String, String) -> Void = { _, _ in }) async throws -> String {
        let dir = appSupport + "/login-kimi-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // 预置同一个 device_id：新凭据的设备绑定和本机一致；region 标记照搬本机，登录走到对的区
        if let dev = deviceId(create: false) {
            FileManager.default.createFile(atPath: dir + "/device_id", contents: Data(dev.utf8), attributes: [.posixPermissions: 0o600])
        }
        if let marker = try? String(contentsOfFile: home + "/region", encoding: .utf8) {
            try? marker.write(toFile: dir + "/region", atomically: true, encoding: .utf8)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["kimi", "login"]
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("KIMI") }
        env["KIMI_CODE_HOME"] = dir
        env["PATH"] = home + "/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            if let (url, code) = Self.deviceHint(text) { onHint(url, code) }
        }
        // 兜底超时；用户可随时取消（Task.cancel → 结束 kimi 进程）
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
        out.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        guard p.terminationStatus == 0 else { throw CAMError("登录未完成（kimi exit \(p.terminationStatus)）") }
        // 国际版（auth.kimi.ai）的凭据在 credentials/kimi-code-<hash>.json 这类独立槽位，CAM 只管默认槽位
        // ponytail: 只支持国内版；要支持国际版，credPath/lockPath 得按 config.toml 的 oauth key 推导，host 一起切
        let credDir = dir + "/credentials"
        guard let credential = try readCredential(credDir + "/kimi-code.json"),
              let userId = Self.accountId(credential) else {
            let scoped = (try? FileManager.default.contentsOfDirectory(atPath: credDir))?.contains { $0.hasPrefix("kimi-code-") } == true
            throw CAMError(scoped ? "暂不支持国际版账号" : "登录成功但没读到凭据：\(credDir)/kimi-code.json")
        }
        var vault = try vault()
        vault[userId] = ["credential": credential, "profile": ["region": Self.region(credential)]]
        try saveVault(vault)
        try? await enrichProfile(userId)
        return userId
    }

    /// 从登录输出里抠设备码授权链接（CLI 打印 "Opening browser ... https://...user_code=XXX"）
    static func deviceHint(_ text: String) -> (url: String, code: String)? {
        guard let r = text.range(of: "authorize_device"),
              let scheme = text[..<r.lowerBound].range(of: "https://", options: .backwards) else { return nil }
        let after = text[r.upperBound...]
        let end = after.firstIndex(where: \.isWhitespace) ?? after.endIndex
        let url = String(text[scheme.lowerBound..<end])
        guard let q = url.range(of: "user_code=") else { return (url, "") }
        let code = url[q.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return (url, String(code))
    }

    /// /me 补昵称和会员等级；失败不影响账号入库
    func enrichProfile(_ userId: String) async throws {
        var vault = try vault()
        guard var entry = vault[userId], var credential = entry["credential"] as? JSON else { return }
        var profile = entry["profile"] as? JSON ?? [:]
        guard profile["nickname"] == nil else { return }
        if Self.stale(credential) {
            credential = try await Self.refresh(credential, region: Self.entryRegion(entry, credential: credential), fetcher: fetcher)
            entry["credential"] = credential
        }
        let (status, data) = try await fetcher(Self.request(Self.profile(Self.entryRegion(entry, credential: credential)).baseUrl + "/me",
                                                             token: credential["access_token"] as? String ?? ""))
        guard status == 200, let me = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let nickname = me["nickname"] as? String else { return }
        profile["nickname"] = nickname
        if let level = me["user_level_name"] as? String { profile["level"] = level }
        if let region = me["region"] as? String { profile["region"] = region == "global" ? "global" : "cn" }
        entry["profile"] = profile
        vault[userId] = entry
        try saveVault(vault)
    }

    // MARK: 用量

    static func request(_ url: String, token: String) throws -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in deviceHeaders { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// 当前账号在 CLI 的锁里续期（CLI 每次用都重读文件，不会失效）；其它账号直接续期，轮换出的新 refresh_token 写回账号库
    func usage(_ userId: String, isLive: Bool) async throws -> Store.Row {
        var credential: JSON
        if isLive {
            credential = try await ensureFresh()
        } else {
            var vault = try vault()
            guard var entry = vault[userId] else { throw CAMError("账号不存在：\(userId)") }
            credential = entry["credential"] as? JSON ?? [:]
            if Self.stale(credential) {
                credential = try await Self.refresh(credential, region: Self.entryRegion(entry, credential: credential), fetcher: fetcher)
                entry["credential"] = credential
                vault[userId] = entry
                try saveVault(vault)
            }
        }
        // 昵称/等级只在第一次拉到时请求 /me
        let cur = try? vault()
        if (cur?[userId]?["profile"] as? JSON)?["nickname"] == nil { try? await enrichProfile(userId) }
        let entry = (try? vault())?[userId] ?? [:]
        let profile = entry["profile"] as? JSON ?? [:]
        let (status, data) = try await fetcher(Self.request(Self.profile(Self.entryRegion(entry, credential: credential)).baseUrl + "/usages",
                                                             token: credential["access_token"] as? String ?? ""))
        guard status == 200, let q = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw CAMError("HTTP \(status)：/usages")
        }
        let usages = q["usages"] as? JSON ?? [:]
        // 新套餐没有 7 天窗口，退回月度（total 是总账、code 是编程专项）
        let d7 = Self.window(usages["limit_7d"]) ?? Self.window(usages["limit_month_total"]) ?? Self.window(usages["limit_month_code"])
        let note = Self.boosterNote(q["booster_wallet"])
        let level = profile["level"] as? String ?? ""
        let plan = note.map { level.isEmpty ? $0 : "\(level) · \($0)" } ?? level
        var row = Store.Row(id: userId, name: profile["nickname"] as? String ?? String(userId.prefix(8)), plan: plan, agent: "kimi")
        row.h5 = Self.window(usages["limit_5h"])
        row.d7 = d7
        return row
    }

    func rows() async throws -> (live: String?, rows: [Store.Row]) {
        let live = try syncLive()
        if let live { markLive(live) }
        var out: [Store.Row] = []
        for (id, _) in try vault() {
            do { out.append(try await usage(id, isLive: id == live)) }
            catch {
                var row = Store.Row(id: id, name: String(id.prefix(8)), plan: "", agent: "kimi")
                row.error = error.localizedDescription
                out.append(row)
            }
        }
        return (live, out.sorted { $0.name < $1.name })
    }

    static func window(_ raw: Any?) -> Store.Window? {
        guard let e = raw as? JSON,
              let ratio = (e["used_ratio"] as? Double) ?? (e["used_ratio"] as? String).flatMap(Double.init) else { return nil }
        let reset = (e["reset_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Store.Window(pct: ratio * 100, reset: reset)
    }

    /// 加油包：开启且有剩余才提示；定点数换算照搬 CLI（四舍五入到分）
    static func boosterNote(_ raw: Any?) -> String? {
        guard let w = raw as? JSON, w["status"] as? String == "STATUS_ENABLED",
              let balance = w["balance"] as? JSON,
              let left = intValue(balance["amountLeft"]), left > 0 else { return nil }
        let cents = Int((Double(left) / 1_000_000).rounded())
        return String(format: "加油包 ¥%.2f", Double(cents) / 100)
    }

    static func intValue(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let s = v as? String, let n = Int(s) { return n }
        return nil
    }

    // MARK: Token 用量

    /// 当前账号的变化记录 [[秒, userId]]；wire.jsonl 里没有账号信息，只能按时间对上
    func timeline() -> [(t: Double, id: String)] {
        (load(timelinePath) as? [[Any]] ?? []).compactMap { e in (e.first as? Double).flatMap { t in (e.last as? String).map { (t, $0) } } }
    }

    func markLive(_ userId: String) {
        var list = timeline()
        guard list.last?.id != userId else { return }
        list.append((Date().timeIntervalSince1970, userId))
        save(timelinePath, list.map { [$0.t, $0.id] })
    }

    struct KimiTokenUse {
        let time: Date
        let session: String
        var account: String?
        let tokens: Int
    }

    /// 扫 sessions 下所有 agent 的 wire.jsonl 里的 usage.record（每次模型请求一行：输入/输出/缓存读写 token 数）。
    /// fork 会话会整段复制 wire.jsonl 到新目录，去重 key 不带 session；归属按 timeline
    func tokenUsage(days: Int) async -> [KimiTokenUse] {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let sinceMs = since.timeIntervalSince1970 * 1000
        let marks = timeline()
        let files = FileManager.default.enumerator(at: URL(fileURLWithPath: home + "/sessions"),
                                                   includingPropertiesForKeys: [.contentModificationDateKey])?.allObjects as? [URL] ?? []
        var seen = Set<String>(), out: [KimiTokenUse] = []
        for url in files where url.lastPathComponent == "wire.jsonl" && url.path.contains("/agents/") {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mtime >= since else { continue }
            if KimiStore.parsed[url.path]?.mtime != mtime, let data = try? Data(contentsOf: url) {
                var lines: [(key: String, use: KimiTokenUse)] = []
                let needle = Data("\"usage.record\"".utf8)
                for line in data.split(separator: 10) where line.range(of: needle) != nil {
                    guard let e = try? JSONSerialization.jsonObject(with: line) as? JSON,
                          e["type"] as? String == "usage.record",
                          let t = e["time"] as? Double, t >= sinceMs,
                          let u = e["usage"] as? JSON else { continue }
                    let tokens = ["inputOther", "output", "inputCacheRead", "inputCacheCreation"].reduce(0) { $0 + (u[$1] as? Int ?? 0) }
                    let agentId = e["agentId"] as? String ?? ""
                    let key = "\(agentId)|\(Int(t))|\(tokens)"  // 同毫秒同总量视为同一条
                    let session = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                    lines.append((key, KimiTokenUse(time: Date(timeIntervalSince1970: t / 1000), session: session, account: nil, tokens: tokens)))
                }
                KimiStore.parsed[url.path] = (mtime, lines)
            }
            for (key, var use) in KimiStore.parsed[url.path]?.lines ?? [] where use.time >= since && seen.insert(key).inserted {
                use.account = marks.last { $0.t <= use.time.timeIntervalSince1970 }?.id
                out.append(use)
            }
        }
        return out
    }

    /// 解析过的日志按 (路径, 修改时间) 缓存，定时刷新时只重扫还在写的会话
    nonisolated(unsafe) static var parsed: [String: (mtime: Date, lines: [(key: String, use: KimiTokenUse)])] = [:]

    /// 每日 token 合计 [日期: [userId（"" = 未归属）: tokens]]；合并进本地存档，热力图才能画满一年
    func dailyTokens() async -> [String: [String: Int]] {
        var fresh: [String: [String: Int]] = [:]
        for u in await tokenUsage(days: 366) { fresh[Store.day(u.time), default: [:]][u.account ?? "", default: 0] += u.tokens }
        var archive = load(dailyPath) as? [String: [String: Int]] ?? [:]
        let partial = Store.day(Date().addingTimeInterval(-366 * 86400))
        // 会话被删掉一部分时新算的会偏少，只在不少于存档时覆盖
        for (day, m) in fresh where day > partial && m.values.reduce(0, +) >= archive[day]?.values.reduce(0, +) ?? 0 { archive[day] = m }
        save(dailyPath, archive)
        return archive
    }

    // MARK: 设备头

    /// CLI 请求带的设备头；服务器未必强制校验，照抄最稳
    static var deviceHeaders: [String: String] {
        ["X-Msh-Platform": "macos",
         "X-Msh-Version": "cam",
         "X-Msh-Device-Name": ProcessInfo.processInfo.hostName,
         "X-Msh-Device-Model": sysString("hw.model"),
         "X-Msh-Os-Version": sysString("kern.osrelease"),
         "X-Msh-Device-Id": KimiStore(home: NSHomeDirectory() + "/.kimi-code").deviceId(create: false) ?? ""]
    }

    static func sysString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    /// ~/.kimi-code/device_id，登录预置和请求头共用；create 时才生成
    func deviceId(create: Bool) -> String? {
        let path = home + "/device_id"
        if let text = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        guard create else { return nil }
        let id = UUID().uuidString
        FileManager.default.createFile(atPath: path, contents: Data(id.utf8), attributes: [.posixPermissions: 0o600])
        return id
    }

    static func urlSessionFetch(_ req: URLRequest) async throws -> (status: Int, data: Data) {
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
