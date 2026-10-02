import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, ["list", "switch"].contains(cmd) else { return CAMApp.main() }
        Task {
            do { try await cli(args) } catch {
                FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            exit(0)
        }
        dispatchMain()
    }
}

/// 终端用法：`ClaudeAccountManager list` / `ClaudeAccountManager switch <邮箱|uuid 前缀>`
func cli(_ args: [String]) async throws {
    let store = Store()
    let (live, rows) = try await store.rows()
    if args[0] == "list" {
        for r in rows { print("\(r.id == live ? "*" : " ") \(r.email)  \(r.detail)  [\(r.id.prefix(8))]") }
        return
    }
    guard args.count > 1, let r = rows.first(where: { $0.email == args[1] || $0.id.hasPrefix(args[1]) }) else {
        throw CAMError("找不到账号：\(args.dropFirst().first ?? "")")
    }
    try await store.switchTo(r.id)
    print("已切换到 \(r.email)，正在运行的 claude 会话需重启后生效")
}

@MainActor
final class Model: ObservableObject {
    @Published var rows: [Store.Row] = []
    @Published var live: String?
    /// 非 nil 时禁用所有操作，顺带把 Keychain 读写串行化
    @Published var busy: String?
    @Published var error: String?
    let store = Store()

    func run(_ label: String, _ op: @escaping () async throws -> Void = {}) {
        guard busy == nil else { return }
        busy = label
        error = nil
        Task {
            do { try await op() } catch { self.error = error.localizedDescription }
            do { (live, rows) = try await store.rows() } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }
}

struct CAMApp: App {
    @StateObject private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.accessory) }

    var body: some Scene {
        MenuBarExtra("Claude 账号", systemImage: "person.2.circle") {
            Panel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.rows) { row in
                let isLive = row.id == model.live
                HStack(alignment: .top) {
                    Image(systemName: isLive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isLive ? .green : .secondary)
                        .accessibilityLabel(isLive ? "当前账号" : "")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.email).fontWeight(.medium)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !isLive {
                        Button("切换") { model.run("切换中…") { try await model.store.switchTo(row.id) } }
                        Button { model.run("删除中…") { try model.store.remove(row.id) } } label: { Image(systemName: "trash") }
                            .accessibilityLabel("删除 \(row.email)")
                    }
                }
                .disabled(model.busy != nil)
            }
            if model.rows.isEmpty {
                Text("还没有账号：在终端登录 claude 后点刷新，或点「添加账号」").foregroundStyle(.secondary)
            }
            Divider()
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text(model.busy ?? "切换后，正在运行的 claude 会话需重启才生效").font(.caption).foregroundStyle(.secondary)
            HStack {
                Group {
                    Button("添加账号") { model.run("等待浏览器登录（5 分钟超时）…") { _ = try await model.store.addViaLogin() } }
                    Button("刷新") { model.run("刷新中…") }
                }
                .disabled(model.busy != nil)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 380)
        .task { model.run("刷新中…") }
    }
}
