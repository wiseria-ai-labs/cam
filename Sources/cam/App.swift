import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, ["list", "switch", "tokens"].contains(cmd) else {
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

/// 两个 Agent 的每日存档合并（账号 id 空间不重叠；同号出现在两边时相加）
func mergedDaily(_ a: [String: [String: Int]], _ b: [String: [String: Int]]) -> [String: [String: Int]] {
    var out = a
    for (day, m) in b { for (id, n) in m { out[day, default: [:]][id, default: 0] += n } }
    return out
}

/// 终端用法：`cam list` / `cam switch <名称|id 前缀>` / `cam tokens`
func cli(_ args: [String]) async throws {
    let store = Store()
    let kimi = KimiStore(home: NSHomeDirectory() + "/.kimi-code")
    let (cl, cr) = try await store.rows()
    let (kl, kr) = try await kimi.rows()
    let rows = cr + kr
    if args[0] == "tokens" {
        async let cd = store.dailyTokens()
        async let kd = kimi.dailyTokens()
        let daily = mergedDaily(await cd, await kd)
        let ids = Set(daily.values.flatMap(\.keys)).sorted()
        for (title, n) in [("今天", 1), ("7 天", 7), ("30 天", 30), ("一年", 365)] {
            print("\(title)  合计 \(tokenText(Store.total(daily, days: n)))")
            for id in ids {
                let t = Store.total(daily, days: n, account: id)
                if t > 0 { print("  \(id.isEmpty ? "未归属" : rows.first { $0.id == id }?.name ?? id)  \(tokenText(t))") }
            }
        }
        return
    }
    if args[0] == "list" {
        for r in rows {
            print("\(r.id == (r.agent == "kimi" ? kl : cl) ? "*" : " ") \(r.agent)  \(r.name)  \(r.summary)  [\(r.id.prefix(8))]")
        }
        return
    }
    guard args.count > 1, let r = rows.first(where: { $0.name == args[1] || $0.id.hasPrefix(args[1]) }) else {
        throw CAMError("找不到账号：\(args.dropFirst().first ?? "")")
    }
    if r.agent == "kimi" {
        try await kimi.switchTo(r.id)
        print("已切换到 \(r.name)，正在运行的 kimi 会话几分钟内自动生效")
    } else {
        try await store.switchTo(r.id)
        print("已切换到 \(r.name)，正在运行的 claude 会话需重启后生效")
    }
}

enum ConfirmKind { case switchTo, delete }
struct Confirm: Equatable { let id: String; let kind: ConfirmKind }

@MainActor
final class Model: ObservableObject {
    @Published var rows: [Store.Row] = []
    @Published var live: String?
    @Published var kimiLive: String?
    /// 正在登录的 Agent，只有它的「添加账号」行显示进度
    @Published var loginAgent: String?
    /// kimi 设备码登录的授权链接提示（浏览器没自动打开时手动用）
    @Published var loginHint: String?
    /// 非 nil 时禁用所有操作，顺带把 Keychain 读写串行化
    @Published var busy: String?
    @Published var error: String?
    @Published var updated: Date?
    /// 每日 token 合计（含本地存档，最长一年）
    @Published var daily: [String: [String: Int]] = [:]
    /// 账号行里原地展开的切换/删除确认（不用系统弹窗：菜单栏面板弹 alert 会自己收起）
    @Published var confirming: Confirm?
    /// 可取消的操作（目前只有登录）；只取消操作本身，之后的刷新照常进行
    @Published private(set) var cancellable: Task<Void, Error>?
    let claude = Store()
    let kimi = KimiStore(home: NSHomeDirectory() + "/.kimi-code")

    func liveId(_ agent: String) -> String? { agent == "kimi" ? kimiLive : live }

    /// 某个 Agent 的账号：当前账号置顶，其余按名称
    func sorted(_ agent: String) -> [Store.Row] {
        rows.filter { $0.agent == agent }.sorted { ($0.id == liveId(agent) ? 0 : 1, $0.name) < ($1.id == liveId(agent) ? 0 : 1, $1.name) }
    }

    /// "" 是 CAM 开始记录前的用量；已删除的账号显示 id 前缀
    func name(_ id: String) -> String { id.isEmpty ? "未归属" : rows.first { $0.id == id }?.name ?? String(id.prefix(8)) }
    /// 按名称顺序固定配色（rows 已排序），切换、筛选都不变色
    // ponytail: 超过 8 个账号会重复用色，真有那么多账号再把多出的归成「其他」
    func color(_ id: String) -> Color { rows.firstIndex { $0.id == id }.map { palette[$0 % palette.count] } ?? .gray }
    func tokens(days n: Int, account: String? = nil) -> Int { Store.total(daily, days: n, account: account) }

    func run(_ label: String, cancellable: Bool = false, _ op: @escaping () async throws -> Void = {}) {
        guard busy == nil else { return }
        busy = label
        error = nil
        Task {
            let task = Task { try await op() }
            if cancellable { self.cancellable = task }
            do { try await task.value } catch is CancellationError {} catch { self.error = error.localizedDescription }
            self.cancellable = nil
            (self.loginAgent, self.loginHint) = (nil, nil)
            do {
                var live: String?, kimiLive: String?, all: [Store.Row] = [], errs: [String] = []
                // 一个 Agent 的账号库坏了不影响另一个
                do { let (l, r) = try await claude.rows(); (live, all) = (l, r) }
                catch { errs.append("Claude：\(error.localizedDescription)") }
                do { let (l, r) = try await kimi.rows(); kimiLive = l; all.append(contentsOf: r) }
                catch { errs.append("Kimi：\(error.localizedDescription)") }
                // 切换后新账号移到第一行：ForEach 按 id 认行，位置变化自动做成移动动画
                withAnimation(.snappy(duration: 0.4)) { (self.live, self.kimiLive, self.rows, confirming) = (live, kimiLive, all, nil) }
                // 只追加不清空：上面切换/登录的报错要留着给用户看
                if !errs.isEmpty { error = ([error].compactMap { $0 } + errs).joined(separator: "；") }
                updated = Date()
                async let cd = claude.dailyTokens()
                async let kd = kimi.dailyTokens()
                daily = mergedDaily(await cd, await kd)
            }
            busy = nil
        }
    }

    func ask(_ id: String, _ kind: ConfirmKind) { withAnimation(.snappy(duration: 0.2)) { confirming = Confirm(id: id, kind: kind) } }
    func cancel() { withAnimation(.snappy(duration: 0.2)) { confirming = nil } }
    func confirm() {
        guard let c = confirming, let row = rows.first(where: { $0.id == c.id }) else { return }
        let isKimi = row.agent == "kimi"
        run(c.kind == .delete ? "删除中…" : "切换中…") {
            if c.kind == .delete {
                if isKimi { try self.kimi.remove(c.id) } else { try self.claude.remove(c.id) }
            } else if isKimi {
                try await self.kimi.switchTo(c.id)
            } else {
                try await self.claude.switchTo(c.id)
            }
        }
    }

    /// 浏览器登录加账号；kimi 的设备码链接提示走 loginHint
    func add(_ agent: String) {
        guard busy == nil else { return }
        loginAgent = agent
        let isKimi = agent == "kimi"
        run("等待浏览器登录…", cancellable: true) {
            if isKimi {
                _ = try await self.kimi.addViaLogin { url, code in
                    Task { @MainActor in self.loginHint = code.isEmpty ? url : "\(url)（码 \(code)）" }
                }
            } else {
                _ = try await self.claude.addViaLogin()
            }
        }
    }
}

/// 不用 MenuBarExtra：它的窗口显示后不会跟着内容变高（加载完账号后被截断）；
/// NSPopover 会跟随 preferredContentSize 自动调整
@MainActor
final class StatusBar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    let model: Model

    init(model: Model) {
        self.model = model
        super.init()
        let host = NSHostingController(rootView: Panel(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .applicationDefined  // 收起时机由下面的全局监听决定（登录期间要保持打开）
        item.button?.image = Self.icon
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model.run("刷新中…")  // 启动即加载，首次打开就是完整高度
        // 面板没打开时也定时刷新，打开就是新数据；正在确认时跳过，免得刷新把确认条收起
        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in if model.confirming == nil { model.run("刷新中…") } }
        }
        timer.tolerance = 30
        // 盯住切换前就在跑的 claude 进程，退出时间记得越准，旧账号的用量算得越准
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in if model.busy == nil { model.claude.reapProcs() } }
        }
        // accessory app 的 .transient 不一定能收到失焦，所以自己监听面板外的点击。
        // 全局监听只收到发给其他 app 的事件，面板内和菜单栏图标的点击不会进来。
        // 等待浏览器登录时不收起，用户要去浏览器里点，面板留着显示登录状态
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown, model.cancellable == nil else { return }
                self.popover.performClose(nil)
                model.cancel()
            }
        }
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
        if NSApp.currentEvent?.type == .rightMouseUp { return showMenu() }
        guard !popover.isShown else { return popover.performClose(nil) }
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // macOS 14 的 activate() 是协作式的，前台 app 不让就不生效，面板不是 key window，
        // 第一下点击只用来激活窗口、点不到账号行；回车/Esc 也要 key window 才响应
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// 右键菜单：面板没有底栏，退出放在这里
    func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(withTitle: "刷新用量", action: #selector(refresh), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 CAM", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.button?.performClick(nil)  // 设了 menu 的状态栏按钮被点时弹出菜单，位置由系统摆
        item.menu = nil
    }

    @objc func refresh() { model.run("刷新中…") }

    @objc func quit() {
        model.cancellable?.cancel()  // 同步结束登录进程，否则退出后成孤儿
        NSApp.terminate(nil)
    }
}

// MARK: 面板

/// 侧栏里的 Agent。Claude Code 与 Kimi Code 已接入，Codex 占位
struct Agent: Identifiable {
    let id, name, short: String
    let logo: NSImage
    /// nil = 跟随文字颜色（黑白 logo）
    var tint: Color?
    var soon = false

    static let all = [
        Agent(id: "claude", name: "Claude Code", short: "Claude", logo: svg(claudeLogo), tint: dyn(0xD97757, 0xD97757)),
        Agent(id: "codex", name: "Codex", short: "Codex", logo: svg(openAILogo), soon: true),
        Agent(id: "kimi", name: "Kimi Code", short: "Kimi", logo: svg(kimiLogo), tint: dyn(0x2D6CDF, 0x5B8DEF)),
    ]

    /// 品牌 logo 来自 simple-icons（CC0）：24×24 单色路径，做成模板图再着色
    static func svg(_ path: String) -> NSImage {
        let image = NSImage(data: Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="\#(path)"/></svg>"#.utf8))!
        image.isTemplate = true
        return image
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    /// nil = 全部 Agent
    @State private var agent: String?
    /// KPI 和热力图只看这个账号；"" = 未归属
    @State private var focus: String?

    var body: some View {
        let shown = Agent.all.filter { !$0.soon && (agent == nil || $0.id == agent) }
        let soon = Agent.all.filter(\.soon)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CAM").font(.system(size: 14, weight: .bold))
                Spacer()
                Text(model.busy == "刷新中…" ? "刷新中…" : model.updated.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                Button { model.run("刷新中…") } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.busy != nil).help("刷新用量")
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .top, spacing: 12) {
                Rail(model: model, agent: $agent)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Kpi(label: "今天", value: model.tokens(days: 1, account: focus))
                        Kpi(label: "近 7 天", value: model.tokens(days: 7, account: focus))
                        Kpi(label: "近 30 天", value: model.tokens(days: 30, account: focus))
                    }
                    UsagePanel(model: model, focus: $focus, title: focus.map(model.name) ?? Agent.all.first { $0.id == agent }?.name ?? "全部 Agent")
                        .zIndex(1)  // 热力图的悬停提示会盖到下面的账号表上
                    ForEach(shown) { AccountTable(agent: $0, model: model, showTitle: agent == nil) }
                    if agent == nil && !soon.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(soon) { AgentLogo(agent: $0, size: 14) }
                            Text("\(soon.map(\.name).joined(separator: "、")) 即将支持").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 10).frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 580)
        .contentShape(Rectangle())
        .onTapGesture { model.cancel() }  // 点空白处取消确认
        .task { model.run("刷新中…") }
    }
}

struct AgentLogo: View {
    let agent: Agent
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: agent.logo).renderingMode(.template).resizable().frame(width: size, height: size)
            .foregroundStyle(agent.tint ?? .primary)
            .accessibilityLabel(agent.name)
    }
}

/// 左侧 Agent 导轨：Agent 多了只是导轨变长
struct Rail: View {
    @ObservedObject var model: Model
    @Binding var agent: String?

    var body: some View {
        VStack(spacing: 8) {
            RailItem(label: "全部", selected: agent == nil) { agent = nil } icon: {
                Text("Σ").font(.system(size: 17, weight: .semibold))
            }
            .help("全部 Agent")
            ForEach(Agent.all) { a in
                RailItem(label: a.soon ? "即将" : a.short, selected: agent == a.id, count: a.soon ? 0 : model.sorted(a.id).count) { agent = a.id } icon: {
                    AgentLogo(agent: a, size: 22)
                }
                .disabled(a.soon).opacity(a.soon ? 0.45 : 1)
                .help(a.soon ? "\(a.name) 即将支持" : a.name)
            }
        }
        .frame(width: 52)
    }
}

struct RailItem<Icon: View>: View {
    let label: String
    let selected: Bool
    var count = 0
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(spacing: 3) {
            Button(action: action) {
                icon()
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
                    .overlay(alignment: .bottomTrailing) {
                        if count > 0 {
                            Text("\(count)").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(nsColor: .windowBackgroundColor))
                                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15).background(Capsule().fill(Color.secondary))
                                .offset(x: 4, y: 4)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

struct Kpi: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(tokenText(value)).font(.system(size: 17, weight: .bold))
            Text("tokens").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
    }
}

// MARK: Token 用量

func tokenText(_ n: Int) -> String { n == 0 ? "0" : n.formatted(.number.notation(.compactName).precision(.significantDigits(3))) }

/// 浅色/深色各一套的颜色
func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    func ns(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light) })
}

/// 账号配色：dataviz 默认色板，这个顺序相邻两色对色觉障碍也分得开
let palette = [dyn(0x2A78D6, 0x3987E5), dyn(0xEB6834, 0xD95926), dyn(0x1BAF7A, 0x199E70), dyn(0xEDA100, 0xC98500),
               dyn(0xE87BA4, 0xD55181), dyn(0x008300, 0x008300), dyn(0x4A3AA7, 0x9085E9), dyn(0xE34948, 0xE66767)]
/// 热力图：单色（蓝）顺序色阶，0 档贴近底色
let heatRamp = [Color.primary.opacity(0.07), dyn(0xB7D3F6, 0x104281), dyn(0x6DA7EC, 0x1C5CAB), dyn(0x2A78D6, 0x3987E5), dyn(0x184F95, 0x86B6EF)]

/// 热力图 + 账号图例（点图例只看这个账号）
struct UsagePanel: View {
    @ObservedObject var model: Model
    @Binding var focus: String?
    let title: String

    var body: some View {
        let year = Dictionary(uniqueKeysWithValues: Set(model.daily.values.flatMap(\.keys)).map { ($0, model.tokens(days: 365, account: $0)) })
            .filter { $0.value > 0 }
        let total = max(year.values.reduce(0, +), 1)
        let ids = year.keys.sorted { (year[$0]!, $0) > (year[$1]!, $1) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(title) · 近一年").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                HStack(spacing: 3) {
                    Text("少")
                    ForEach(heatRamp.indices, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(heatRamp[$0]).frame(width: 9, height: 9) }
                    Text("多")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Heatmap(model: model, focus: focus)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    Button { focus = focus == id ? nil : id } label: {
                        HStack(spacing: 5) {
                            Circle().fill(model.color(id)).frame(width: 7, height: 7)
                            Text(model.name(id).split(separator: "@").first.map(String.init) ?? "").lineLimit(1)
                            Text("\(Int((Double(year[id]!) / Double(total) * 100).rounded()))%").fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.system(size: 11)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(focus == id ? 0.08 : 0)))
                        .opacity(focus == nil || focus == id ? 1 : 0.45)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(focus == id ? "显示全部账号" : "只看 \(model.name(id))")
                }
            }
            if year[""] != nil {
                Text("按各 Agent 开始记录时的账号归属统计；CAM 开始记录前的用量计为「未归属」")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }
}

/// 近 53 周每日用量：一列一周（周一在上），4 档按非零值的四分位分
struct Heatmap: View {
    @ObservedObject var model: Model
    let focus: String?
    @State private var hover: Int?

    static let weeks = 53, cell: CGFloat = 6.8, gap: CGFloat = 1.6, left: CGFloat = 16, top: CGFloat = 13
    static let step = cell + gap, width = left + CGFloat(weeks) * step - gap

    var body: some View {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        let weekday = (cal.component(.weekday, from: today) + 5) % 7  // 周一 = 0
        let start = cal.date(byAdding: .day, value: -weekday - (Self.weeks - 1) * 7, to: today)!
        let days = (0...(Self.weeks - 1) * 7 + weekday).map { cal.date(byAdding: .day, value: $0, to: start)! }
        let values = days.map { d in model.daily[Store.day(d)].map { m in focus.map { m[$0] ?? 0 } ?? m.values.reduce(0, +) } ?? 0 }
        let nonzero = values.filter { $0 > 0 }.sorted()
        let cuts = [0.25, 0.5, 0.75].map { nonzero.isEmpty ? 0 : nonzero[Int($0 * Double(nonzero.count - 1))] }
        Canvas { ctx, _ in
            var lastMonth = 0, lastX = -99.0
            for w in 0..<Self.weeks {
                let month = cal.component(.month, from: days[w * 7]), x = Self.left + CGFloat(w) * Self.step
                guard month != lastMonth else { continue }
                lastMonth = month
                if x - lastX > 26 && w < Self.weeks - 1 {
                    ctx.draw(Text("\(month)月").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: x, y: 0), anchor: .topLeading)
                    lastX = x
                }
            }
            for (k, label) in ["一", "三", "五"].enumerated() {
                ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: 0, y: Self.top + CGFloat(k * 2) * Self.step + Self.cell / 2), anchor: .leading)
            }
            for i in days.indices {
                let rect = CGRect(x: Self.left + CGFloat(i / 7) * Self.step, y: Self.top + CGFloat(i % 7) * Self.step, width: Self.cell, height: Self.cell)
                let v = values[i], level = v <= 0 ? 0 : (cuts.firstIndex { v <= $0 } ?? 3) + 1
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(heatRamp[level]))
                if i == hover { ctx.stroke(Path(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 2), with: .color(.primary), lineWidth: 1) }
            }
        }
        .frame(width: Self.width, height: Self.top + 7 * Self.step - Self.gap)
        .onContinuousHover { phase in
            guard case .active(let p) = phase, p.x >= Self.left, p.y >= Self.top else { hover = nil; return }
            let row = Int((p.y - Self.top) / Self.step), i = Int((p.x - Self.left) / Self.step) * 7 + row
            hover = row < 7 && days.indices.contains(i) ? i : nil
        }
        .overlay(alignment: .topLeading) {
            if let i = hover {
                DayTip(model: model, date: days[i], focus: focus)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in -min(Self.left + CGFloat(i / 7) * Self.step + 10, Self.width - d.width) }
                    .alignmentGuide(.top) { _ in -(Self.top + CGFloat(i % 7 + 1) * Self.step + 4) }
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("近一年每日 token 热力图")
    }
}

/// 热力图悬停提示：当天合计 + 各账号明细
struct DayTip: View {
    let model: Model
    let date: Date
    let focus: String?

    var body: some View {
        let m = (model.daily[Store.day(date)] ?? [:]).filter { $0.value > 0 && (focus == nil || $0.key == focus) }
        let ids = m.keys.sorted { m[$0]! > m[$1]! }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(date.formatted(.dateTime.month().day().weekday(.abbreviated))).fontWeight(.semibold)
                Spacer(minLength: 16)
                Text(m.isEmpty ? "无用量" : tokenText(m.values.reduce(0, +))).fontWeight(.semibold).monospacedDigit()
            }
            ForEach(ids.prefix(5), id: \.self) { id in
                HStack(spacing: 6) {
                    Circle().fill(model.color(id)).frame(width: 7, height: 7)
                    Text(model.name(id)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(tokenText(m[id]!)).monospacedDigit()
                }
            }
            if ids.count > 5 { Text("还有 \(ids.count - 5) 个账号").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minWidth: 170)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

// MARK: 账号表

enum Col { static let window: CGFloat = 96, tokens: CGFloat = 72, spacing: CGFloat = 10 }

/// 一个 Agent 的账号：表头、账号行、添加账号行
struct AccountTable: View {
    let agent: Agent
    @ObservedObject var model: Model
    let showTitle: Bool

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: Col.spacing) {
                HStack(spacing: 6) {
                    if showTitle {
                        AgentLogo(agent: agent, size: 13)
                        Text(agent.name).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.primary)
                    } else {
                        Text("账号")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("5 小时").frame(width: Col.window, alignment: .leading)
                // kimi 新套餐没有 7 天窗口，该列显示月度额度
                Text(agent.id == "kimi" ? "7 天 / 月" : "7 天").frame(width: Col.window, alignment: .leading)
                Text("今日 / 30 天").frame(width: Col.tokens, alignment: .trailing)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.bottom, 2)
            ForEach(model.sorted(agent.id)) { AccountRow(row: $0, model: model) }
            if model.sorted(agent.id).isEmpty && model.busy == nil {
                Text(agent.id == "kimi"
                     ? "还没有账号：在终端登录 kimi 后点刷新，或点下面添加"
                     : "还没有账号：在终端登录 claude 后点刷新，或点下面添加")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            AddAccountRow(agent: agent, model: model)
        }
    }
}

/// 一行一个账号，高度固定：点击后确认内容在原地替换，面板不跳
struct AccountRow: View {
    let row: Store.Row
    @ObservedObject var model: Model
    @State private var hover = false

    var body: some View {
        let isLive = row.id == model.liveId(row.agent)
        let kind = model.confirming?.id == row.id ? model.confirming?.kind : nil
        let tint: Color = kind == .delete ? .red : .accentColor
        ZStack {
            if let kind {
                AskRow(row: row, kind: kind, model: model).transition(.opacity)
            } else {
                HStack(spacing: Col.spacing) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(model.color(row.id)).frame(width: 7, height: 7)
                            Text(row.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        }
                        HStack(spacing: 6) {
                            Badge(text: row.plan.isEmpty ? " " : row.plan)
                            // 当前账号只用这行小字标出来，不加底色
                            if isLive { Label("使用中", systemImage: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green) }
                        }
                        .padding(.leading, 13)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let error = row.error {
                        Text("用量获取失败：\(error)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                            .frame(width: Col.window * 2 + Col.spacing, alignment: .leading).help(error)
                    } else {
                        WindowCell(window: row.h5).frame(width: Col.window)
                        WindowCell(window: row.d7).frame(width: Col.window)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(tokenText(model.tokens(days: 1, account: row.id))).font(.system(size: 12, weight: .semibold))
                        Text(tokenText(model.tokens(days: 30, account: row.id))).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .frame(width: Col.tokens, alignment: .trailing)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 8).fill(kind != nil ? tint.opacity(0.1)
            : hover && !isLive && model.busy == nil ? Color.primary.opacity(0.065) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(kind != nil ? 0.45 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hover = h }
            (h && !isLive && kind == nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onTapGesture { if !isLive && kind == nil && model.busy == nil { model.ask(row.id, .switchTo) } }
        .help(isLive ? "当前正在使用" : kind == nil ? "点击切换到此账号" : "")
        .accessibilityAddTraits(isLive ? [] : .isButton)
    }
}

/// 行内确认：切换（可转到删除）或删除
struct AskRow: View {
    let row: Store.Row
    let kind: ConfirmKind
    @ObservedObject var model: Model

    var body: some View {
        let isDelete = kind == .delete
        HStack(spacing: 8) {
            Image(systemName: isDelete ? "trash" : "arrow.left.arrow.right").foregroundStyle(isDelete ? Color.red : .accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(isDelete ? "删除" : "切换到") \(row.name)？").font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(isDelete ? "移除保存的凭据，需重新登录才能加回"
                             : row.agent == "kimi" ? "运行中的 kimi 会话几分钟内自动换到新账号"
                                                   : "正在运行的 claude 会话需重启后生效")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !isDelete {
                Button { model.ask(row.id, .delete) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red).help("删除这个账号").accessibilityLabel("删除 \(row.name)")
            }
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
    }
}

/// 添加账号：虚线按钮，登录中原地换成进度和「取消登录」，高度不变
struct AddAccountRow: View {
    let agent: Agent
    @ObservedObject var model: Model
    @State private var hover = false

    var body: some View {
        let hot = hover && model.cancellable == nil && model.busy == nil
        HStack(spacing: 6) {
            if let task = model.cancellable, model.loginAgent == agent.id {
                ProgressView().controlSize(.small)
                if agent.id == "kimi", let hint = model.loginHint {
                    // 浏览器没自动打开：把 CLI 打印的设备码链接给用户手动用
                    Text("浏览器没自动打开：\(hint)").foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                        .help(hint)
                } else {
                    Text("等待浏览器登录 \(agent.name)…").foregroundStyle(.primary)
                }
                Spacer()
                Button("取消登录") { task.cancel() }.controlSize(.small)
            } else {
                Image(systemName: "plus")
                Text("添加 \(agent.name) 账号")
                Spacer()
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(hot ? Color.accentColor : .secondary)
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(hot ? 0.06 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hot ? Color.accentColor : Color.primary.opacity(0.15),
                                                                style: StrokeStyle(lineWidth: 1, dash: model.cancellable == nil ? [3, 3] : [])))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            guard model.cancellable == nil, model.busy == nil else { return }
            model.add(agent.id)
        }
        .opacity(model.busy != nil && model.cancellable == nil ? 0.5 : 1)
        .padding(.top, 4)
    }
}

/// 一个额度窗口：百分比、进度条、重置时间（用尽时红色「几点恢复」）
struct WindowCell: View {
    let window: Store.Window?

    var body: some View {
        let pct = window?.pct ?? 0
        let reset = window?.reset.map { Calendar.current.isDateInToday($0)
            ? $0.formatted(.dateTime.hour().minute())
            : $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        VStack(alignment: .leading, spacing: 3) {
            Text(window == nil ? "–" : "\(Int(pct))%").font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(level(pct))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(level(pct)).frame(width: max(4, g.size.width * min(pct, 100) / 100))
                }
            }
            .frame(height: 4)
            Text(reset.map { pct >= 100 ? "\($0) 恢复" : "\($0) 重置" } ?? (window == nil ? "–" : "未开始"))
                .font(.system(size: 10)).monospacedDigit().lineLimit(1)
                .foregroundStyle(pct >= 100 ? Color.red : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 小件

/// 5h/7d 用量配色：<70 绿、<90 橙、其余红
func level(_ pct: Double) -> Color { pct >= 90 ? .red : pct >= 70 ? .orange : .green }

struct Badge: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.15))).foregroundStyle(Color.accentColor)
    }
}

// 品牌 logo 路径（simple-icons，CC0）
private let claudeLogo = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
private let openAILogo = "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"
private let kimiLogo = "M21.765.351C22.998.351 24 1.353 24 2.586S22.998 4.82 21.765 4.82h-1.974c-.15 0-.26-.12-.26-.26V2.586A2.237 2.237 0 0 1 21.765.35M9.41 13.388l8.447-8.377c.16-.16.07-.471-.14-.471h-4.55s-.1.02-.14.06l-9.099 9.029c-.14.14-.35.02-.35-.21V4.81c0-.15-.1-.27-.221-.27H.22c-.12 0-.22.12-.22.27v18.57c0 .15.1.27.22.27h3.137c.12 0 .22-.12.22-.27v-3.79c0-.08.03-.16.08-.21l2.826-2.796c.07-.07.16-.08.241-.03l7.546 5.551a8.9 8.9 0 0 0 4.018 1.493c.12.01.23-.11.23-.27V19.76c0-.14-.08-.25-.19-.26a5.8 5.8 0 0 1-2.355-.942l-6.533-4.73c-.14-.09-.15-.32-.03-.441"
