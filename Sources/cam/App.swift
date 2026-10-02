import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, ["list", "switch"].contains(cmd) else {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.accessory)
                let bar = StatusBar(model: Model())
                withExtendedLifetime(bar) { NSApplication.shared.run() }
            }
            return
        }
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

/// 终端用法：`cam list` / `cam switch <邮箱|uuid 前缀>`
func cli(_ args: [String]) async throws {
    let store = Store()
    let (live, rows) = try await store.rows()
    if args[0] == "list" {
        for r in rows { print("\(r.id == live ? "*" : " ") \(r.email)  \(r.summary)  [\(r.id.prefix(8))]") }
        return
    }
    guard args.count > 1, let r = rows.first(where: { $0.email == args[1] || $0.id.hasPrefix(args[1]) }) else {
        throw CAMError("找不到账号：\(args.dropFirst().first ?? "")")
    }
    try await store.switchTo(r.id)
    print("已切换到 \(r.email)，正在运行的 claude 会话需重启后生效")
}

enum ConfirmKind { case switchTo, delete }
struct Confirm: Equatable { let id: String; let kind: ConfirmKind }

@MainActor
final class Model: ObservableObject {
    @Published var rows: [Store.Row] = []
    @Published var live: String?
    /// 非 nil 时禁用所有操作，顺带把 Keychain 读写串行化
    @Published var busy: String?
    @Published var error: String?
    @Published var updated: Date?
    /// 卡片内展开的切换/删除确认（不用系统弹窗：菜单栏面板弹 alert 会自己收起）
    @Published var confirming: Confirm?
    /// 可取消的操作（目前只有登录）；只取消操作本身，之后的刷新照常进行
    @Published private(set) var cancellable: Task<Void, Error>?
    let store = Store()

    /// 当前账号置顶，其余按邮箱
    var sorted: [Store.Row] { rows.sorted { ($0.id == live ? 0 : 1, $0.email) < ($1.id == live ? 0 : 1, $1.email) } }

    func run(_ label: String, cancellable: Bool = false, _ op: @escaping () async throws -> Void = {}) {
        guard busy == nil else { return }
        busy = label
        error = nil
        Task {
            let task = Task { try await op() }
            if cancellable { self.cancellable = task }
            do { try await task.value } catch is CancellationError {} catch { self.error = error.localizedDescription }
            self.cancellable = nil
            do {
                let (live, rows) = try await store.rows()
                withAnimation(.snappy(duration: 0.35)) { (self.live, self.rows, confirming) = (live, rows, nil) }
                updated = Date()
            } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }

    func ask(_ id: String, _ kind: ConfirmKind) { withAnimation(.snappy(duration: 0.25)) { confirming = Confirm(id: id, kind: kind) } }
    func cancel() { withAnimation(.snappy(duration: 0.2)) { confirming = nil } }
    func confirm() {
        guard let c = confirming else { return }
        let store = store
        run(c.kind == .delete ? "删除中…" : "切换中…") {
            if c.kind == .delete { try store.remove(c.id) } else { try await store.switchTo(c.id) }
        }
    }
}

/// 不用 MenuBarExtra：它的窗口显示后不会跟着内容变高（加载完账号后被截断）；
/// NSPopover 会跟随 preferredContentSize 自动调整
@MainActor
final class StatusBar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()

    init(model: Model) {
        super.init()
        let host = NSHostingController(rootView: Panel(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        item.button?.image = Self.icon
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.run("刷新中…")  // 启动即加载，首次打开就是完整高度
    }

    /// 菜单栏图标，与 assets/menubar.svg 相同；内嵌在代码里，swift run 时也能用
    static let icon: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
          <path d="M20.86 13.56A9 9 0 1 1 17.79 5.11"/>
          <path d="M17.32 2.45L17.79 5.11L15.09 5.11"/>
          <path stroke-width="1.3" d="M12.00 10.10L12.00 7.10M12.95 10.35L14.45 7.76M13.65 11.05L16.24 9.55M13.90 12.00L16.90 12.00M13.65 12.95L16.24 14.45M12.95 13.65L14.45 16.24M12.00 13.90L12.00 16.90M11.05 13.65L9.55 16.24M10.35 12.95L7.76 14.45M10.10 12.00L7.10 12.00M10.35 11.05L7.76 9.55M11.05 10.35L9.55 7.76"/>
        </svg>
        """
        let image = NSImage(data: Data(svg.utf8))!
        image.isTemplate = true  // 跟随菜单栏深浅色
        image.accessibilityDescription = "CAM"
        return image
    }()

    @objc func toggle() {
        guard !popover.isShown else { return popover.performClose(nil) }
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()  // 让回车/Esc 快捷键生效
    }
}

// MARK: 面板

struct Panel: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CAM").font(.system(size: 14, weight: .bold))
                Spacer()
                Text(model.busy == "刷新中…" ? "刷新中…" : model.updated.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                Button { model.run("刷新中…") } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.busy != nil).help("刷新用量")
            }
            ForEach(model.sorted) { row in
                Card(row: row, model: model)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.95))))
            }
            if model.rows.isEmpty && model.busy == nil {
                Text("还没有账号：在终端登录 claude 后点刷新，或点「添加账号」").font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            VStack(spacing: 8) {
                Divider()
                HStack {
                    if let task = model.cancellable {
                        ProgressView().controlSize(.small)
                        Text("等待浏览器登录…").font(.caption)
                        Button("取消登录") { task.cancel() }.controlSize(.small)
                    } else {
                        Button {
                            model.run("等待浏览器登录…", cancellable: true) { _ = try await model.store.addViaLogin() }
                        } label: { Label("添加账号", systemImage: "plus") }
                        .disabled(model.busy != nil)
                    }
                    Spacer()
                    Button {
                        model.cancellable?.cancel()  // 同步结束 claude 登录进程，否则退出后成孤儿
                        NSApp.terminate(nil)
                    } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("退出")
                }
            }
        }
        .padding(14)
        .frame(width: 400)
        .contentShape(Rectangle())
        .onTapGesture { model.cancel() }  // 点空白处取消确认
        .task { model.run("刷新中…") }
    }
}

// MARK: 卡片

struct Card: View {
    let row: Store.Row
    @ObservedObject var model: Model
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isLive = row.id == model.live
        let kind = model.confirming?.id == row.id ? model.confirming?.kind : nil
        let hot = hover && kind == nil && model.busy == nil
        let accent: Color = kind == .delete ? .red : isLive ? .green : .accentColor
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(row.email).font(.system(size: isLive ? 14 : 13, weight: isLive ? .bold : .medium)).lineLimit(1)
                Badge(text: row.plan)
                Spacer()
                if isLive {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.green))
                }
            }
            if let error = row.error {
                Text("用量获取失败：\(error)").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    Metric(label: "5 小时", window: row.h5)
                    Metric(label: "7 天", window: row.d7)
                }
            }
            if let kind {
                ConfirmBar(kind: kind, model: model).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        // 当前账号：绿色渐变底 + 1.5pt 绿边 + 实心「使用中」胶囊；其他账号保持中性灰
        .background(RoundedRectangle(cornerRadius: 10).fill(isLive
            ? AnyShapeStyle(LinearGradient(colors: [Color.green.opacity(hot ? 0.2 : 0.16), Color.green.opacity(0.04)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(Color.primary.opacity(hot ? 0.065 : 0.035))))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(accent.opacity(isLive ? 0.7 : kind != nil ? 0.5 : hot ? 0.4 : 0), lineWidth: isLive ? 1.5 : 1))
        .overlay(alignment: .topTrailing) {
            if hot && !isLive {  // 当前账号删了也会在下次刷新时被重新导入，所以不给删
                Button { model.ask(row.id, .delete) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                }
                .buttonStyle(.plain).padding(5)
                .help("删除账号").accessibilityLabel("删除 \(row.email)")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .scaleEffect(hot && !reduceMotion ? 1.015 : 1)
        .shadow(color: .black.opacity(hot ? 0.14 : 0), radius: hot ? 10 : 0, y: hot ? 4 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hover = h }
            (h && !isLive ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onTapGesture { if !isLive && kind == nil && model.busy == nil { model.ask(row.id, .switchTo) } }
        .help(isLive ? "当前正在使用" : "点击切换到此账号")
        .accessibilityAddTraits(isLive ? [] : .isButton)
    }
}

struct ConfirmBar: View {
    let kind: ConfirmKind
    @ObservedObject var model: Model

    var body: some View {
        let isDelete = kind == .delete
        HStack(spacing: 8) {
            Image(systemName: isDelete ? "trash" : "arrow.left.arrow.right")
                .foregroundStyle(isDelete ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(isDelete ? "删除这个账号？" : "切换到这个账号？").font(.system(size: 12, weight: .semibold))
                Text(isDelete ? "移除保存的凭据，需重新登录才能加回" : "正在运行的 claude 会话需重启后生效")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") { model.cancel() }.keyboardShortcut(.cancelAction)
            Button {
                model.confirm()
            } label: {
                if model.busy != nil { ProgressView().controlSize(.mini).frame(width: 28) } else { Text(isDelete ? "删除" : "切换") }
            }
            .buttonStyle(.borderedProminent).tint(isDelete ? .red : .accentColor).keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .disabled(model.busy != nil)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill((isDelete ? Color.red : Color.accentColor).opacity(0.1)))
    }
}

// MARK: 小件

/// 5h/7d 用量配色：<70 绿、<90 橙、其余红
func level(_ pct: Double) -> Color { pct >= 90 ? .red : pct >= 70 ? .orange : .green }

struct Metric: View {
    let label: String
    let window: Store.Window?

    var body: some View {
        let pct = window?.pct ?? 0
        let reset = window?.reset.map { Calendar.current.isDateInToday($0)
            ? $0.formatted(.dateTime.hour().minute())
            : $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? "–"
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(window == nil ? "–" : "\(Int(pct))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(level(pct))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(level(pct)).frame(width: max(6, g.size.width * min(pct, 100) / 100))
                }
            }
            .frame(height: 6)
            Text(pct >= 100 ? "已用尽 · \(reset) 恢复" : "\(reset) 重置").font(.system(size: 10))
                .foregroundStyle(pct >= 100 ? Color.red : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.15))).foregroundStyle(Color.accentColor)
    }
}
