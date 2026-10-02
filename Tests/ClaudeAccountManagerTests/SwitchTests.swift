import Foundation
import Testing
@testable import ClaudeAccountManager

/// 用临时 CLAUDE_CONFIG_DIR + 临时账号库跑真实 Keychain，不碰当前登录
@Test func switchKeepsRotatedTokensAndMcpOAuth() async throws {
    let dir = NSTemporaryDirectory() + "cam-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var s = Store(configDir: dir, vaultService: "ClaudeAccountManager-test-\(UUID().uuidString)")
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
