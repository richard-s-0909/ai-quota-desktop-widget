# AI 用量 · 桌面小部件

一个 Windows 桌面小部件，实时显示你各个 AI 订阅的**剩余用量 / 余额**。
A small Windows desktop widget that shows how much of your Claude, ChatGPT (Codex) and DeepSeek quota is left.

- **Claude**：5 小时 / 每周额度剩余百分比和重置时间（与 claude.ai「设置 → 用量」同一个额度池）
- **ChatGPT**：订阅里 Codex 的 5 小时 / 每周额度
- **DeepSeek**：平台账户余额（充值 + 赠送）、累计消费
- 自动扫描电脑上的其他 AI 应用（Copilot、Gemini、Cursor、豆包、Kimi、通义……），可一键打开
- 迷你模式、缩放（70%–180%）、选择显示哪些 AI、始终置顶、开机自启
- 登录快过期 / 失效时自动打开重新登录，完成后自动刷新

纯 PowerShell + WPF，无需安装 Python / Node 等任何依赖。

## 使用

1. 下载或克隆本仓库
2. 双击 `启动小部件.vbs`

小部件默认出现在屏幕右上角，可拖动；右上角 ⚙ 打开设置。详细说明见 [使用说明.txt](使用说明.txt)。

## 数据从哪来

小部件**只读取本机已有的登录信息**，直接调用各家官方接口查询，不经过任何第三方服务器，也不需要你手动粘贴任何密钥。

| AI | 需要先装好并登录 | 读取的本地文件 | 查询的接口 |
|---|---|---|---|
| Claude | [Claude Code](https://docs.claude.com/en/docs/claude-code)（用 Claude 订阅账号登录） | `~\.claude\.credentials.json` | `api.anthropic.com/api/oauth/usage` |
| ChatGPT | Codex（用 ChatGPT 账号登录） | `~\.codex\auth.json` | `chatgpt.com/backend-api/wham/usage` |
| DeepSeek | DeepSeek Harness（登录 DeepSeek 账号） | `~\.dsh\.credentials.yaml` | `platform.deepseek.com/api/v0/users/get_user_summary` |

没装的就不显示，不影响其他功能。

> 注意：这些都是各客户端自己使用的接口，并非公开 API，官方改动后可能需要更新本脚本。
> ChatGPT 网页聊天的消息次数没有可用的接口，无法显示。

## 系统要求

- Windows 10 / 11（自带 Windows PowerShell 5.1 即可）
