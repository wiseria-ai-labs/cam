import Foundation
import Testing
@testable import cam

/// 假 JWT：只编码 payload，签名是假的（KimiStore 只解码不验签）
func fakeJWT(_ payload: JSON) -> String {
    func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let header = b64(Data(#"{"alg":"ES256","typ":"JWT"}"#.utf8))
    let body = b64(try! JSONSerialization.data(withJSONObject: payload))
    return "\(header).\(body).sig"
}

func fakeKimiCred(_ userId: String, region: String = "cn", expiresIn: Int = 3600, refresh: String? = nil) -> JSON {
    ["access_token": fakeJWT(["user_id": userId, "region": region, "exp": Int(Date().timeIntervalSince1970) + expiresIn]),
     "refresh_token": refresh ?? "r-\(userId)",
     "expires_at": Int(Date().timeIntervalSince1970) + expiresIn,
     "expires_in": 900, "scope": "kimi-code", "token_type": "Bearer"]
}

/// 切换往返：轮换的 token 存回账号库、锁目录释放
@Test func kimiSwitchKeepsRotatedTokens() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir + "/credentials", withIntermediateDirectories: true)
    var k = KimiStore(home: dir, appSupport: dir + "/app", vaultService: "cam-test-\(UUID().uuidString)")
    k.fetcher = { _ in throw CAMError("不走网络") }
    defer {
        try? FileManager.default.removeItem(atPath: dir)
        _ = try? Store.security(["delete-generic-password", "-a", Store.keychainUser, "-s", k.vaultService])
    }
    func setLive(_ cred: JSON) throws {
        let data = try JSONSerialization.data(withJSONObject: cred)
        FileManager.default.createFile(atPath: k.credPath, contents: data, attributes: [.posixPermissions: 0o600])
    }
    func live() throws -> String? { try k.readCredential()?["access_token"] as? String }
    func stored(_ id: String) throws -> String? { (try k.vault()[id]?["credential"] as? JSON)?["access_token"] as? String }

    try setLive(fakeKimiCred("uA"))
    #expect(try k.syncLive() == "uA")
    #expect(try stored("uA") != nil)

    let credB = fakeKimiCred("uB")
    var vault = try k.vault()
    vault["uB"] = ["credential": credB, "profile": ["region": "cn"]]
    try k.saveVault(vault)

    let credA2 = fakeKimiCred("uA", refresh: "r-uA2")
    try setLive(credA2)  // CLI 刷新轮换了 A 的 token
    try await k.switchTo("uB")
    #expect(try stored("uA") == credA2["access_token"] as? String)
    #expect(try live() == credB["access_token"] as? String)
    #expect(try FileManager.default.attributesOfItem(atPath: k.credPath)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/oauth").filter { $0.hasSuffix(".lock") }.isEmpty)

    let credB2 = fakeKimiCred("uB", refresh: "r-uB2")
    try setLive(credB2)
    try await k.switchTo("uA")
    #expect(try stored("uB") == credB2["access_token"] as? String)
    #expect(try live() == credA2["access_token"] as? String)
}

/// 非当前账号过期由本 app 刷新：轮换的 refresh_token 写回账号库；失效时报「重新登录」
@Test func kimiUsageRefreshesStaleVaultToken() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir + "/credentials", withIntermediateDirectories: true)
    let refreshed = fakeKimiCred("uB", expiresIn: 3600, refresh: "r-uB2")
    var k = KimiStore(home: dir, appSupport: dir + "/app", vaultService: "cam-test-\(UUID().uuidString)")
    var refreshedToken = false
    k.fetcher = { req in
        if req.url!.path.hasSuffix("/api/oauth/token") {
            refreshedToken = true
            return (200, try! JSONSerialization.data(withJSONObject: ["access_token": refreshed["access_token"]!, "refresh_token": "r-uB2", "expires_in": 900, "scope": "kimi-code", "token_type": "Bearer"]))
        }
        let body: JSON = ["usages": ["limit_5h": ["used_ratio": 0.5, "reset_time": "2026-10-04T01:00:00Z"],
                                     "limit_7d": ["used_ratio": "0.25", "reset_time": "2026-10-09T01:00:00Z"]],
                          "booster_wallet": ["status": "STATUS_DISABLED"]]
        return (200, try! JSONSerialization.data(withJSONObject: body))
    }
    defer {
        try? FileManager.default.removeItem(atPath: dir)
        _ = try? Store.security(["delete-generic-password", "-a", Store.keychainUser, "-s", k.vaultService])
    }
    try k.saveVault(["uB": ["credential": fakeKimiCred("uB", expiresIn: -100),  // 已过期
                            "profile": ["nickname": "测试乙", "level": "Plus", "region": "cn"]]])

    let row = try await k.usage("uB", isLive: false)
    #expect(refreshedToken)
    #expect(try k.vault()["uB"]?["credential"] as? JSON? != nil)
    #expect((try k.vault()["uB"]?["credential"] as? JSON)?["refresh_token"] as? String == "r-uB2")
    #expect(row.name == "测试乙" && row.plan == "Plus" && row.agent == "kimi")
    #expect(row.h5?.pct == 50)
    #expect(row.d7?.pct == 25)
    #expect(row.h5?.reset != nil && row.d7?.reset != nil)

    // refresh 返回 invalid_grant → 报「重新登录」
    k.fetcher = { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
    await #expect(throws: CAMError.self) { _ = try await k.usage("uB", isLive: false) }
}

/// 加油包开启且有余额时挂在 plan 上
@Test func kimiBoosterNote() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir + "/credentials", withIntermediateDirectories: true)
    var k = KimiStore(home: dir, appSupport: dir + "/app", vaultService: "cam-test-\(UUID().uuidString)")
    let wallet: JSON = ["status": "STATUS_ENABLED", "balance": ["amountLeft": 2_500_000, "amount": 25_000_000]]
    k.fetcher = { _ in
        let body: JSON = ["usages": ["limit_month_total": ["used_ratio": 1.2, "reset_time": "2026-11-01T00:00:00Z"]],
                          "booster_wallet": wallet]
        return (200, try! JSONSerialization.data(withJSONObject: body))
    }
    defer {
        try? FileManager.default.removeItem(atPath: dir)
        _ = try? Store.security(["delete-generic-password", "-a", Store.keychainUser, "-s", k.vaultService])
    }
    try k.saveVault(["uC": ["credential": fakeKimiCred("uC"), "profile": ["nickname": "丙", "region": "cn"]]])

    let row = try await k.usage("uC", isLive: false)
    #expect(row.d7?.pct == 120)  // 月度窗口落在第二列
    #expect(row.plan == "加油包 ¥0.03")  // 2_500_000 定点数 → 2.5 分，四舍五入到 3 分
    #expect(KimiStore.boosterNote(["status": "STATUS_DISABLED"]) == nil)
}

/// 去重（同文件重复行、fork 复制到新目录）、子 agent 单独计、按时间线归属
@Test func kimiTokenUsageDedupesAndAttributes() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    let s1 = dir + "/sessions/wd_x_1/s1/agents/main", s2 = dir + "/sessions/wd_x_1/s2/agents/main"
    let s3 = dir + "/sessions/wd_x_1/s1/agents/agent-0"
    for p in [s1, s2, s3] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let k = KimiStore(home: dir, appSupport: dir + "/app", vaultService: "cam-test-\(UUID().uuidString)")
    let now = Date().timeIntervalSince1970
    func rec(_ agent: String, ago: Double, input: Int, output: Int = 0) -> String {
        #"{"type":"usage.record","agentId":"\#(agent)","usage":{"inputOther":\#(input),"output":\#(output),"inputCacheRead":0,"inputCacheCreation":0},"time":\#(Int((now - ago) * 1000))}"#
    }
    let dup = rec("main", ago: 7200, input: 10)
    let fresh = rec("main", ago: 300, input: 1, output: 5)
    let sub = rec("agent-0", ago: 300, input: 3)
    FileManager.default.createFile(atPath: s1 + "/wire.jsonl", contents: Data([dup, dup, fresh].joined(separator: "\n").utf8))
    FileManager.default.createFile(atPath: s2 + "/wire.jsonl", contents: Data([dup].joined(separator: "\n").utf8))  // fork 复制
    FileManager.default.createFile(atPath: s3 + "/wire.jsonl", contents: Data([sub].joined(separator: "\n").utf8))
    k.save(k.timelinePath, [[now - 3600, "uA"], [now - 600, "uB"]])

    let uses = await k.tokenUsage(days: 30).sorted { $0.time < $1.time }
    #expect(uses.map(\.tokens) == [10, 3, 6])
    #expect(uses.map(\.account) == [nil, "uB", "uB"])  // 最早一条早于 timeline 起点，未归属
}

/// 每日存档：新算的少于存档不覆盖；归属变化照常覆盖
@Test func kimiDailyTokensKeepsArchive() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    let s = dir + "/sessions/wd_x_1/s1/agents/main"
    try FileManager.default.createDirectory(atPath: s, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let k = KimiStore(home: dir, appSupport: dir + "/app", vaultService: "cam-test-\(UUID().uuidString)")
    let today = Store.day(Date()), old = "2020-01-01"
    k.save(k.dailyPath, [old: ["uA": 5], today: ["": 100]])
    let rec = #"{"type":"usage.record","agentId":"main","usage":{"inputOther":7,"output":0,"inputCacheRead":0,"inputCacheCreation":0},"time":\#(Int(Date().timeIntervalSince1970 * 1000))}"#
    FileManager.default.createFile(atPath: s + "/wire.jsonl", contents: Data(rec.utf8))

    var daily = await k.dailyTokens()
    #expect(daily[old] == ["uA": 5])
    #expect(daily[today] == ["": 100])  // 新算的 7 < 存档 100，不覆盖

    k.save(k.dailyPath, [today: ["": 7]])
    k.save(k.timelinePath, [[Date().timeIntervalSince1970 - 60, "uB"]])
    daily = await k.dailyTokens()
    #expect(daily[today] == ["uB": 7])
}

/// 持锁期间锁目录 mtime 持续刷新，CLI 不会把慢操作中的锁当成过期锁
@Test func kimiLockHeartbeat() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let k = KimiStore(home: dir, appSupport: dir + "/app", vaultService: "cam-test-\(UUID().uuidString)")
    let lock = k.lockPath + ".lock"
    let age: Double = try await k.withLock {
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let mtime = try FileManager.default.attributesOfItem(atPath: lock)[.modificationDate] as! Date
        return Date().timeIntervalSince(mtime)
    }
    #expect(age < 1.5)
    #expect(!FileManager.default.fileExists(atPath: lock))
}
