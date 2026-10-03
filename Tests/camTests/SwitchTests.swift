import Foundation
import Testing
@testable import cam

/// 用临时 CLAUDE_CONFIG_DIR + 临时账号库跑真实 Keychain，不碰当前登录
@Test func switchKeepsRotatedTokensAndMcpOAuth() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var s = Store(configDir: dir, vaultService: "cam-test-\(UUID().uuidString)")
    s.whoami = { _ in nil }  // 不走网络，按 .claude.json 认人
    defer {
        try? FileManager.default.removeItem(atPath: dir)
        for svc in [s.credService, s.vaultService] { _ = try? Store.security(["delete-generic-password", "-a", Store.keychainUser, "-s", svc]) }
    }

    func oauth(_ t: String) -> JSON { ["accessToken": t, "refreshToken": "r-" + t, "expiresAt": 1] }
    func setLive(_ t: String) throws { try Store.writeItem(s.credService, ["claudeAiOauth": oauth(t), "mcpOAuth": ["srv": ["clientId": "c"]]]) }
    func live() throws -> String? { (try Store.readItem(s.credService)?["claudeAiOauth"] as? JSON)?["accessToken"] as? String }
    func stored(_ uuid: String) throws -> String? { (try s.vault()[uuid]?["claudeAiOauth"] as? JSON)?["accessToken"] as? String }
    func configAccount() throws -> String? { (try s.readConfig()["oauthAccount"] as? JSON)?["accountUuid"] as? String }
    func mcpKept() throws -> Bool { ((try Store.readItem(s.credService)?["mcpOAuth"] as? JSON)?["srv"] as? JSON)?["clientId"] as? String == "c" }

    // 非 ASCII 走 security -w 的 hex 输出分支；长字段让账号库超过 4032 走 argv 分支
    let acctA: JSON = ["accountUuid": "A", "emailAddress": "a@x", "displayName": "张三" + String(repeating: "x", count: 3000)]
    let acctB: JSON = ["accountUuid": "B", "emailAddress": "b@x"]
    try setLive("A1")
    try s.writeConfig(["oauthAccount": acctA, "projects": ["keep": 1]])

    #expect(try await s.syncLive() == "A")
    #expect(try stored("A") == "A1")
    #expect((try s.vault()["A"]?["oauthAccount"] as? JSON)?["displayName"] as? String == acctA["displayName"] as? String)

    var vault = try s.vault()
    vault["B"] = ["claudeAiOauth": oauth("B1"), "oauthAccount": acctB]
    try s.saveVault(vault)

    try setLive("A2")  // CLI 刷新轮换了 A 的 token
    try await s.switchTo("B")
    #expect(try stored("A") == "A2")
    #expect(try live() == "B1")
    #expect(try configAccount() == "B")
    #expect(try mcpKept())
    #expect((try s.readConfig()["projects"] as? JSON)?["keep"] as? Int == 1)
    #expect(try FileManager.default.attributesOfItem(atPath: s.configPath)[.posixPermissions] as? Int == 0o600)

    try setLive("B2")
    try await s.switchTo("A")
    #expect(try stored("B") == "B2")
    #expect(try live() == "A2")
    #expect(try configAccount() == "A")
    #expect(try mcpKept())

    // 切到 B 后，运行中的会话把 A 刷新出的 A3 写回了 Keychain：应存到 A 名下并修正 .claude.json
    try await s.switchTo("B")
    try setLive("A3")
    s.whoami = { $0.hasPrefix("A") ? "A" : "B" }
    #expect(try await s.syncLive() == "A")
    #expect(try stored("A") == "A3")
    #expect(try stored("B") == "B2")
    #expect(try configAccount() == "A")
}

/// 登录中途取消：应立刻结束 claude 进程并清理临时目录（需本机装有 claude；用假 open 拦住浏览器）
@Test func cancelLoginStopsQuickly() async throws {
    let bin = NSTemporaryDirectory() + "cam-fakebin-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: bin) }
    FileManager.default.createFile(atPath: bin + "/open", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    setenv("PATH", bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)

    let loginDirs = { (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Application Support/cam"))?.filter { $0.hasPrefix("login-") } ?? [] }
    let before = loginDirs()
    let task = Task { try await Store(vaultService: "cam-test-\(UUID().uuidString)").addViaLogin() }
    try await Task.sleep(for: .seconds(3))
    let start = Date()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(loginDirs() == before)
}

/// 去重（同一响应多行、跨文件）、按时间筛选、按时间线归属账号
@Test func tokenUsageDedupesAndAttributes() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir + "/projects/p/s/subagents", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let s = Store(configDir: dir)
    let now = Date().timeIntervalSince1970
    FileManager.default.createFile(atPath: s.timelinePath, contents: Data("[[\(now - 3600), \"A\"]]".utf8))
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func line(_ id: String, ago: Double, input: Int = 0, output: Int = 0) -> String {
        #"{"type":"assistant","timestamp":"\#(iso.string(from: Date(timeIntervalSince1970: now - ago)))","requestId":"r\#(id)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":1}}}"#
    }
    let dup = line("m1", ago: 7200, input: 10)
    let main = [dup, dup, line("m2", ago: 1800, output: 5), line("old", ago: 40 * 86400, input: 99),
                #"{"type":"user","message":{"content":"\"usage\""}}"#].joined(separator: "\n")
    FileManager.default.createFile(atPath: dir + "/projects/p/s.jsonl", contents: Data(main.utf8))
    FileManager.default.createFile(atPath: dir + "/projects/p/s/subagents/a.jsonl", contents: Data(dup.utf8))

    let uses = await s.tokenUsage(days: 30).sorted { $0.time < $1.time }
    #expect(uses.count == 2)
    #expect(uses.map(\.account) == [nil, "A"])
    #expect(uses.map(\.tokens) == [11, 6])
}

/// 鉴权跟着进程走：切换前就在跑的进程算旧账号，进程退出、会话重启后算新账号
@Test func tokenUsageFollowsProcess() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir + "/projects/p", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: dir + "/sessions", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let s = Store(configDir: dir)

    // 记录与回收：本测试进程充当一个正在运行的 claude
    let pidFile = dir + "/sessions/\(getpid()).json"
    func session(_ id: String) { FileManager.default.createFile(atPath: pidFile, contents: Data(#"{"pid":\#(getpid()),"startedAt":1000,"sessionId":"\#(id)"}"#.utf8)) }
    session("S")
    s.markOldProcs("A")
    s.markOldProcs("B")  // 再切一次，已记过的进程不变
    session("S2")  // 进程内 /resume 换了会话
    s.reapProcs()
    #expect(s.procs().count == 1)
    #expect(s.procs().first?["account"] as? String == "A")
    #expect(s.procs().first?["sessions"] as? [String] == ["S", "S2"])
    #expect(s.procs().first?["end"] == nil)
    try FileManager.default.removeItem(atPath: pidFile)
    s.reapProcs()
    #expect(s.procs().first?["end"] as? Double != nil)

    // 归属：A 在用 → 切到 B；会话 S 的旧进程 [from, end) 期间仍算 A
    let now = Date().timeIntervalSince1970
    FileManager.default.createFile(atPath: s.timelinePath, contents: Data("[[\(now - 3600), \"A\"], [\(now - 1800), \"B\"]]".utf8))
    s.saveProcs([["pid": 1, "start": 0, "account": "A", "sessions": ["S"], "from": now - 1800, "end": now - 600]])
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func line(_ id: String, _ session: String, ago: Double) -> String {
        #"{"timestamp":"\#(iso.string(from: Date(timeIntervalSince1970: now - ago)))","sessionId":"\#(session)","message":{"id":"\#(id)","usage":{"output_tokens":1}}}"#
    }
    let lines = [line("1", "S", ago: 2400), line("2", "S", ago: 1200), line("3", "S", ago: 300), line("4", "T", ago: 1200)]
    FileManager.default.createFile(atPath: dir + "/projects/p/s.jsonl", contents: Data(lines.joined(separator: "\n").utf8))
    let uses = await s.tokenUsage(days: 1).sorted { ($0.time, $0.session) < ($1.time, $1.session) }
    #expect(uses.map(\.account) == ["A", "A", "B", "B"])  // 切换前 A、旧进程仍 A、会话 T 是新进程、重启后 B
}

/// 每日存档：日志清掉后旧日子保留；新算的少于存档时不覆盖；归属变化照常覆盖
@Test func dailyTokensKeepsArchive() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir + "/projects/p", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let s = Store(configDir: dir)
    let today = Store.day(Date()), old = "2020-01-01"
    s.save(s.dailyPath, [old: ["A": 5], today: ["": 100]])
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = #"{"timestamp":"\#(iso.string(from: Date()))","sessionId":"S","message":{"id":"m","usage":{"output_tokens":7}}}"#
    FileManager.default.createFile(atPath: dir + "/projects/p/s.jsonl", contents: Data(line.utf8))

    var daily = await s.dailyTokens()
    #expect(daily[old] == ["A": 5])
    #expect(daily[today] == ["": 100])  // 新算的 7 < 存档 100，不覆盖

    s.save(s.dailyPath, [today: ["": 7]])
    s.save(s.timelinePath, [[Date().timeIntervalSince1970 - 60, "B"]])
    daily = await s.dailyTokens()
    #expect(daily[today] == ["B": 7])  // 合计相同、归属变了，覆盖
    #expect(Store.total(daily, days: 1) == 7 && Store.total(daily, days: 1, account: "B") == 7)
}
