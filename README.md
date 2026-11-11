# AI 用量 · 桌面小部件

一个桌面小部件，实时显示你各个 AI 订阅的**剩余用量 / 余额**。支持 **Windows** 和 **macOS**。
A small desktop widget (Windows & macOS) that shows how much of your Claude, ChatGPT (Codex) and DeepSeek quota is left.

- **Claude**：5 小时 / 每周额度剩余百分比和重置时间（与 claude.ai「设置 → 用量」同一个额度池）
- **ChatGPT**：订阅里 Codex 的 5 小时 / 每周额度
- **DeepSeek**：平台账户余额（充值 + 赠送）、累计消费
- 自动扫描电脑上的其他 AI 应用（Copilot、Gemini、Cursor、豆包、Kimi、通义……），可一键打开
- 极简风界面；迷你模式、缩放（70%–180%）、选择显示哪些 AI、始终置顶、开机自启
- Windows：可最小化到**系统托盘**，单击托盘图标即可查看；macOS：**菜单栏**直接显示剩余（4 档显示范围可选）
- 登录快过期 / 失效时自动打开重新登录，完成后自动刷新

## 下载

到 [Releases](https://github.com/richard-s-0909/ai-quota-desktop-widget/releases/latest) 下载：

| 系统 | 文件 | 说明 |
|---|---|---|
| Windows 10 / 11 | `ai-quota-desktop-widget-v*.zip` | 解压后双击 `启动小部件.vbs` |
| macOS 13+ | `ai-quota-desktop-widget-macos-universal-v*.dmg` | **通用版，Apple Silicon（M 系列）和 Intel 都用这一个** |

### Windows

1. 解压，双击 `启动小部件.vbs`
2. 小部件出现在屏幕右上角，可拖动；鼠标移上去会出现按钮（迷你模式 / 最小化到托盘 / 设置 / 刷新 / 退出）
3. 最小化到托盘后：**单击**托盘图标弹出面板查看，**双击**恢复悬浮窗，**右键**打开菜单

详细说明见 [使用说明.txt](使用说明.txt)。纯 PowerShell + WPF，无需安装任何依赖。

### macOS

1. 打开 `.dmg`，把 `AIQuota.app` 拖到「Applications」
2. **第一次打开**：右键 `AIQuota.app` → 打开 → 打开（应用没有苹果开发者签名，直接双击会被拦截）。
   如果仍提示“已损坏”，在终端运行：`xattr -dr com.apple.quarantine /Applications/AIQuota.app`
3. 菜单栏显示剩余（显示范围 4 档可选：图标 / 最低一项 `G 24%` / 每个 AI `C 79%  G 24%  D ¥106` / 详细 `C 81/79%  G 100/24%`），
   点它打开完整面板；桌面上还有一个悬浮窗（按住标题栏拖动）
4. 点面板右上角 ⚙ 进入设置（显示哪些 AI、菜单栏显示范围、面板大小、悬浮窗、刷新间隔、开机启动）
5. 第一次读取 Claude 登录时，系统会询问是否允许访问钥匙串项目「Claude Code-credentials」，点 **始终允许**

原生 SwiftUI 应用。源码在 [`macos/`](macos)，用 GitHub Actions 自动编译并截图检查界面。

## 数据从哪来

小部件**只读取本机已有的登录信息**，直接调用各家官方接口查询，不经过任何第三方服务器，也不需要你手动粘贴任何密钥。

| AI | 需要先装好并登录 | 读取的登录信息 | 查询的接口 |
|---|---|---|---|
| Claude | [Claude Code](https://docs.claude.com/en/docs/claude-code)（用 Claude 订阅账号登录） | Windows: `~\.claude\.credentials.json`<br>macOS: 钥匙串「Claude Code-credentials」 | `api.anthropic.com/api/oauth/usage` |
| ChatGPT | Codex（用 ChatGPT 账号登录） | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` |
| DeepSeek | DeepSeek Harness（登录 DeepSeek 账号） | `~/.dsh/.credentials.yaml` | `platform.deepseek.com/api/v0/users/get_user_summary` |

没装的就不显示，不影响其他功能。

> 注意：这些都是各客户端自己使用的接口，并非公开 API，官方改动后可能需要更新。
> ChatGPT 网页聊天的消息次数没有可用的接口，无法显示。

## 自己编译 macOS 版

需要 Xcode 15+（或 Swift 5.9+ 工具链）：

```bash
cd macos && ./build.sh 1.2.0
```

产物（`.app` 和 `.dmg`）在 `macos/build/`。
