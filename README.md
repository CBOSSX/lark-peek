# Lark Peek

Lark Peek 是飞书桌面端的按需只读消息预览器。

把鼠标停在飞书左侧任意会话行上，长按 `Option`（也可以使用 `Control + Option + P`）。Lark Peek 会读取鼠标下方的会话名称，通过 `lark-cli` 定位对应 `chat_id`，先拉取该会话最近 20 条消息，并在会话旁边显示悬浮窗口；滚动到顶部时按页加载更早消息。松开 `Option` 后，临时预览会立即关闭。

它不是第二个飞书收件箱：没有会话目录、关注、归档、稍后处理、全量刷新或“去飞书处理”按钮。

## 只读边界

应用只编译进八类结构化命令：

- `lark-cli auth status --json --verify`
- `lark-cli im +chat-list --as user --types p2p,group --sort active_time ...`
- `lark-cli im +chat-search --as user --query ...`
- `lark-cli im +messages-search --as user --query ...`
- `lark-cli im chats get --as user --chat-id ...`
- `lark-cli im +chat-messages-list --as user --chat-id ... --no-reactions ...`
- `lark-cli im +threads-messages-list --as user --thread ... --no-reactions ...`
- `lark-cli im +messages-resources-download --as user --message-id ... --file-key img_... --type image ...`

没有 Shell 字符串拼接、任意 API 分发器或飞书写操作。只按需下载消息中的图片，不会顺带下载文件、音视频或表情详情；图片经临时文件读入内存后立即删除，消息正文不落盘。同名会话的人工选择只保存哈希后的界面指纹到 `chat_id` 映射。

消息正文支持常用 Markdown（含列表、引用、标题与代码块）和 `<p>` / `<br>` 段落；可识别的互动卡片会提取标题与正文，以只读卡片样式展示。群聊名片会通过只读群信息接口补充群名。复杂卡片按钮不会执行。

## 权限

- macOS 辅助功能：首次启动会主动请求，用于读取鼠标所在的飞书会话行，不执行点击。
- lark-cli 用户授权：需要 `im:chat:read` 与 `im:message:readonly` 等当前 CLI 提示的只读权限。

## 构建

要求 macOS 14+、Swift 6、Node.js 20+ 和 `lark-cli`。

先安装并登录飞书官方 CLI：

```bash
npx @larksuite/cli@latest install
lark-cli config init
lark-cli auth login
lark-cli auth status --json --verify
```

登录时仅授予 Lark Peek 所需的只读权限。至少需要会话和消息读取权限；如果 CLI 报告缺少 scope，请按照错误中的只读 scope 补充授权。

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

### 发布签名与公证

向普通用户分发 App 时，需要加入 Apple Developer Program，并在钥匙串中安装 `Developer ID Application` 证书。然后将公证凭证安全地保存到钥匙串；下面的命令会交互式询问 app-specific password，不要把密码直接写进命令或仓库：

```bash
xcrun notarytool store-credentials LarkPeekNotary \
  --apple-id "your-apple-id@example.com" \
  --team-id "YOURTEAMID"
```

完成一次性配置后，运行：

```bash
LARK_PEEK_CODESIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
  ./Scripts/notarize-app.sh
```

脚本会使用 hardened runtime 和安全时间戳签名，提交 Apple 公证，将 ticket staple 到 App，执行 Gatekeeper 验证，并生成可分发的 `dist/Lark-Peek.zip`。

无飞书请求的视觉预览：

```bash
"dist/Lark Peek.app/Contents/MacOS/LarkPeek" --preview-fixtures
```

Finder 启动时不会依赖终端 PATH。应用会自动查找 Homebrew、nvm、fnm、Volta、mise、asdf、npm、pnpm、Bun 和常见用户目录中的 `lark-cli` / Node.js；也可以从菜单栏手动选择 CLI。

如果菜单栏显示“未找到 lark-cli”，请先执行上面的安装命令，然后重新启动 Lark Peek；也可以使用菜单栏的“选择 lark-cli…”手动指定可执行文件。

## 交互

- 悬停飞书会话行后，长按 `⌥`：临时预览；松开后关闭。在飞书之外或非会话区域长按时不会弹窗。
- 悬停飞书会话行后，按 `⌃⌥P`：预览或切换预览目标。
- 滚动到消息顶部：加载更早一页，并保持当前阅读位置。
- `Esc`：关闭浮窗。
- 点击浮窗外：关闭浮窗。
- 同名会话：选择一次候选项，之后复用匿名映射。

读取链路没有调用标记已读接口，但“历史消息读取永远不会产生服务端已读回执”并不是开放平台的正式长期保证。发布前仍应使用测试账号覆盖单聊、群聊、@、话题、附件以及飞书在线/离线场景。

## 许可与声明

本项目采用 [MIT License](LICENSE)。Lark Peek 是独立的开源项目，不代表 Lark、飞书或其关联公司的官方产品或背书。
