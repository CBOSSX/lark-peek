# Lark Peek

Lark Peek 是飞书桌面端的按需只读消息预览器。

把鼠标停在飞书左侧任意会话行上，按住 `Option`（也可以继续使用 `Control + Option + P`）。Lark Peek 会读取鼠标下方的会话名称，通过 `lark-cli` 定位对应 `chat_id`，先拉取该会话最近 20 条消息，并在会话旁边显示悬浮窗口；滚动到顶部时按页加载更早消息。松开 `Option` 后，临时预览会立即关闭。

它不是第二个飞书收件箱：没有会话目录、关注、归档、稍后处理、全量刷新或“去飞书处理”按钮。

## 只读边界

应用只编译进四类结构化命令：

- `lark-cli auth status --json --verify`
- `lark-cli im +chat-list --as user --types p2p,group --sort active_time ...`
- `lark-cli im +chat-search --as user --query ...`
- `lark-cli im +chat-messages-list --as user --chat-id ... --no-reactions ...`

没有 Shell 字符串拼接、任意 API 分发器或飞书写操作。附件和表情详情默认不下载，消息正文不落盘。同名会话的人工选择只保存哈希后的界面指纹到 `chat_id` 映射。

## 权限

- macOS 辅助功能：首次启动会主动请求，用于读取鼠标所在的飞书会话行，不执行点击。
- lark-cli 用户授权：需要 `im:chat:read` 与 `im:message:readonly` 等当前 CLI 提示的只读权限。

## 构建

要求 macOS 14+、Swift 6、`lark-cli`，以及该 CLI 所需的 Node.js 运行时。

```bash
./Scripts/setup-local-signing.sh  # 每台 Mac 只需一次
./Scripts/test.sh
./Scripts/build-app.sh
open "dist/Lark Peek.app"
```

### 稳定签名

`./Scripts/setup-local-signing.sh` 会在登录钥匙串创建一个有效期 10 年、只用于代码签名的 `Lark Peek Local Code Signing` 本机证书。首次配置时 macOS 会要求 Touch ID 或登录密码来修改证书信任设置。

之后 `./Scripts/build-app.sh` 始终使用这个身份，并且在证书缺失时直接失败，不会回退到会让辅助功能授权失效的 ad-hoc 临时签名。可以这样检查：

```bash
security find-identity -v -p codesigning
codesign -dr - "dist/Lark Peek.app"
codesign --verify --deep --strict "dist/Lark Peek.app"
```

如果已经有 Apple Development 或 Developer ID 证书，也可以指定它：

```bash
LARK_PEEK_CODESIGN_IDENTITY="Apple Development: Your Name (...)" ./Scripts/build-app.sh
```

无飞书请求的视觉预览：

```bash
"dist/Lark Peek.app/Contents/MacOS/LarkPeek" --preview-fixtures
```

Finder 启动时不会依赖终端 PATH。应用会自动查找 Homebrew、nvm、fnm、Volta、mise、asdf、npm、pnpm、Bun 和常见用户目录中的 `lark-cli` / Node.js；也可以从菜单栏手动选择 CLI。

## 交互

- 悬停飞书会话行，按住 `⌥`：临时预览；松开后关闭。
- `⌃⌥P`：保留原有的预览或切换预览目标快捷键。
- 滚动到消息顶部：加载更早一页，并保持当前阅读位置。
- `Esc`：关闭浮窗。
- 点击浮窗外：关闭浮窗。
- 同名会话：选择一次候选项，之后复用匿名映射。

读取链路没有调用标记已读接口，但“历史消息读取永远不会产生服务端已读回执”并不是开放平台的正式长期保证。发布前仍应使用测试账号覆盖单聊、群聊、@、话题、附件以及飞书在线/离线场景。
