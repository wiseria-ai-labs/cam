# CAM · Claude Account Manager

macOS 菜单栏小工具，用来在同一台机器上管理多个 Claude Code / Kimi Code 登录账号：一键切换、添加/删除账号、查看每个账号的 5 小时 / 7 天额度和 token 用量。

<p align="center"><img src="docs/panel.png" width="580"></p>

<sub>示意图为模拟数据。</sub>

> [!WARNING]
> 本项目为非官方工具，与 Anthropic 无关，使用风险自负。作者不对账号封禁、凭据丢失等任何问题负责，详见[免责声明](#免责声明--disclaimer)。

## 功能

- **Agent 侧栏**：左侧按 Agent 切换视图。目前支持 Claude Code 和 Kimi Code，Codex 即将支持。
- **账号表**：每个账号一行，显示套餐、5 小时与 7 天额度进度条和重置时间、今日 / 近 30 天 token；当前账号置顶，标「✓ 使用中」。
- **用量配色**：< 70% 绿、70–90% 橙、≥ 90% 红；额度用尽时显示「几点恢复」。
- **切换账号**：点击账号行，在行内确认（回车确认 / Esc 取消），切换后新账号移到第一行。
- **添加账号**：在浏览器里走官方 OAuth 登录，**不会影响当前已登录的账号**；登录中途可随时取消。
- **删除账号**：点击账号行，在确认条里点 🗑（当前账号不可删）。
- **自动导入**：终端里用 `claude` 正常登录的账号，打开面板时会自动收进账号库。
- **Token 用量**：顶部是今天 / 近 7 天 / 近 30 天合计，下面是近一年每日用量热力图（悬停看当天各账号明细，点图例只看某个账号）。Claude Code 的数据来自本机 `~/.claude/projects` 下的会话日志，按 claude 进程启动时的账号归属（切换后没重启的会话仍算旧账号）；Kimi Code 的数据来自 `~/.kimi-code/sessions` 下的会话日志；CAM 开始记录前的用量计为「未归属」。Claude Code 默认 30 天后删除日志，CAM 每天把汇总存到本地，热力图不受影响。
- **终端命令**：`cam list` / `cam switch` / `cam tokens`，方便脚本化。
- **退出**：右键菜单栏图标 → 「退出 CAM」。

## 安装

要求：macOS 14+，已安装 [Claude Code](https://code.claude.com) 和/或 [Kimi Code](https://www.kimi.com/code) CLI。

1. 从 [Releases](https://github.com/wiseria-ai-labs/cam/releases) 下载最新的 `CAM-x.y.z.dmg`。
2. 打开 DMG，把 `CAM.app` 拖进「应用程序」。
3. 双击打开即可。CAM 已用 Developer ID 签名并经 Apple 公证。

想开机自启，把 CAM 加到「系统设置 → 通用 → 登录项」。

### 从源码构建

需要 Xcode 15.3+（Swift 5.10+）。

```bash
git clone https://github.com/wiseria-ai-labs/cam.git && cd cam
swift run cam                  # 直接运行
scripts/release.sh 0.1.0       # 打包签名并公证 dist/CAM-0.1.0.dmg（IDENTITY 指定证书；NOTARY_PROFILE= 跳过公证）
```

## 用法

### 菜单栏

点击菜单栏图标打开面板。面板每 5 分钟在后台刷新一次，右上角 ↻ 可手动刷新。

| 操作 | 方式 |
|---|---|
| 切换账号 | 点击账号行 → 「切换」 |
| 添加账号 | 账号表底部「添加 Claude Code / Kimi Code 账号」→ 浏览器登录；可点「取消登录」中断 |
| 删除账号 | 点击账号行 → 🗑 → 「删除」 |
| 只看某个账号的用量 | 点热力图下的账号图例，再点一次恢复 |
| 取消确认 | 「取消」/ Esc / 点击面板空白处 |
| 刷新 / 退出 | 右键菜单栏图标 |

### 终端

```bash
# 装了 app 的话，命令行就是 /Applications/CAM.app/Contents/MacOS/cam
cam list                     # 列出账号与用量，* 为当前账号
cam switch work@company.com  # 按邮箱切换
cam switch 1a2b3c4d          # 或按 uuid 前缀切换
cam tokens                   # 今天 / 7 天 / 30 天 / 一年的 token 用量，按账号分
```

## 工作原理

Claude Code 的登录态由两部分组成，CAM 就是在管理这两处：

| 内容 | 位置 |
|---|---|
| OAuth 凭据（`claudeAiOauth`，同一条目里还有各 MCP server 的 `mcpOAuth`） | 登录钥匙串，条目 `Claude Code-credentials` |
| 账号资料（邮箱、组织等） | `~/.claude.json` 的 `oauthAccount` 字段 |

- **账号库**：所有账号的凭据和资料存在登录钥匙串的一个条目里（`ClaudeAccountManager`），不落盘成明文文件。
- **切换**：先把当前账号最新的凭据存回账号库（CLI 会轮换 refresh token，不存回的话旧存档会失效），再把目标账号写入 `claudeAiOauth` 和 `oauthAccount`。`mcpOAuth` 及 `.claude.json` 的其它字段原样保留。
- **添加**：在临时 `CLAUDE_CONFIG_DIR` 里运行 `claude auth login`，登录完成后把凭据导入账号库，再清理临时目录和钥匙串条目。
- **用量**：调用 `api.anthropic.com/api/oauth/usage`。非当前账号的 access token 过期时由 CAM 刷新；当前账号的 token 只读不刷新（交给 CLI，否则会让 CLI 手里的 refresh token 失效）。
- **防串号**：存回凭据前会用 token 查询它实际属于哪个账号，避免运行中的会话把旧账号 token 写回后被错存到新账号名下。

### Kimi Code

Kimi Code 的登录态是一个文件，CAM 管理的就是它：

| 内容 | 位置 |
|---|---|
| OAuth 凭据（access token 15 分钟、refresh token 30 天滚动） | `~/.kimi-code/credentials/kimi-code.json` |

- **账号库**：所有账号的凭据和资料存在登录钥匙串的 `CAMKimiAccounts` 条目里。
- **切换**：在 CLI 的跨进程文件锁下原子替换凭据文件。CLI 每次取 token 前都会重读文件，**运行中的 kimi 会话几分钟内自动换到新账号，不用重启**。
- **添加**：在隔离的临时目录里跑 `kimi login`（CLI 自己开浏览器），不影响当前登录。目前只支持国内版（kimi.com）账号，国际版（kimi.ai）暂不支持。
- **用量**：调用 `api.kimi.com/coding/v1/usages`（5 小时 / 7 天 / 月度额度、加油包余额）和 `/me`（昵称、会员等级）。新套餐没有 7 天窗口时显示月度额度。过期 token 由 CAM 自动续期（refresh token 每次轮换，新凭据写回账号库）。

## 注意事项

- **切换后正在运行的会话**：`claude` 会缓存旧凭据，**需要重启**才会用新账号；`kimi` 会在几分钟内自动换到新账号。
- **依赖两个 CLI 的内部实现。** Claude Code 的钥匙串条目命名、凭据结构、用量接口，以及 Kimi Code 的凭据文件、锁协议、刷新与用量端点都不是公开 API，分别对照 Claude Code 2.1.287 和 Kimi Code CLI 2.1.1 实现。CLI 升级后可能失效，届时需要按新版本重新核对。
- **长期不用的账号需要偶尔打开一下面板。** refresh token 有效期约 4 周（Kimi Code 30 天），CAM 只在查询用量时顺带续期；太久没打开，该账号就得重新登录。
- **仅支持 macOS。** Linux / Windows 上 Claude Code 把凭据存成明文文件、Kimi Code 的锁协议不同，CAM 目前没有适配。
- **钥匙串读写走 `/usr/bin/security`**，与 Claude Code 自身做法一致，因此不会弹授权框。凭据较长时会短暂出现在 `security` 进程的参数里（hex 编码），CLI 本身也是这样处理的。
- **账号库条目名为 `ClaudeAccountManager`** 是项目更名前的历史名字，为了保留已存账号没有改。
- 多账号轮换使用前，请自行确认符合 Anthropic 的使用条款，见下方免责声明。

## 开发

```bash
swift build
swift test   # 使用真实钥匙串里的临时条目，结束后自动清理；登录取消测试需要本机装有 claude
```

发版：`scripts/release.sh <版本号>` 生成 universal 的 `CAM.app` 并打成 DMG；设置 `NOTARY_PROFILE`（`xcrun notarytool store-credentials` 保存的配置名）时会自动公证并装订票据。

代码只有三个文件：`Sources/cam/Store.swift`（Claude Code 登录态、账号库、额度和 token 用量）、`Sources/cam/KimiStore.swift`（Kimi Code 的同套逻辑）和 `Sources/cam/App.swift`（共享的菜单栏界面与终端命令）。

已知限制：面板没有滚动（账号很多时会过长）；app 在登录过程中崩溃会留下 `claude auth login` / `kimi login` 进程。

## 免责声明 / Disclaimer

- 本项目是个人开发的非官方工具，**与 Anthropic 没有任何隶属、合作或背书关系**。「Claude」「Claude Code」是 Anthropic 的商标，「Kimi」「Kimi Code」是月之暗面（Moonshot AI）的商标。
- CAM 依赖 Claude Code 未公开的内部实现（钥匙串条目、配置文件结构、用量接口），这些随时可能变化，导致功能失效或行为异常。
- 使用多个账号、频繁切换账号，或以其它方式使用本工具，**是否符合 [Anthropic 的使用条款](https://www.anthropic.com/legal/consumer-terms)由使用者自行判断并承担责任**。
- **作者及贡献者不对使用本工具造成的任何后果负责**，包括但不限于：账号被限制或封禁、登录凭据丢失或失效、用量或费用异常、数据丢失。
- 本软件按「原样」提供，不附带任何形式的担保，详见 [MIT 许可证](LICENSE)。

*English:* This is an unofficial, community-built tool. It is **not affiliated with, endorsed by, or sponsored by Anthropic**; "Claude" and "Claude Code" are trademarks of Anthropic. CAM relies on undocumented internals of Claude Code that may change at any time. **You are solely responsible for ensuring your use complies with Anthropic's terms.** The authors and contributors accept **no liability** for any consequences of using this software, including but not limited to account restrictions or suspension, lost or invalidated credentials, unexpected usage or charges, or data loss. The software is provided "as is", without warranty of any kind (see [LICENSE](LICENSE)).

## License

[MIT](LICENSE)
