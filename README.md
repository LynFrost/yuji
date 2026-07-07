# 语迹 Yuji

语迹是一个本地优先的 AI 对话记录浏览器。它把 Codex、Claude 和外部导入的聊天记录整理成一个可搜索、可筛选、可备注、可导出的网页阅读器，让散落在本机里的 AI 协作过程重新变得可查、可复盘、可继续使用。

如果你经常用 AI 写代码、做笔记、调试项目，最后却发现“我明明之前问过这个问题，但到底在哪个会话里”，语迹就是为这个场景做的。

## 适合谁

- 经常使用 Codex 或 Claude 的开发者。
- 想把 AI 聊天记录按项目、标题、时间重新整理的人。
- 想搜索历史回答、命令输出、工具调用和最终结论的人。
- 想把某个会话导出成 Markdown，继续整理成笔记或文档的人。
- 想完全在本机查看记录，不想把私人聊天记录上传到第三方服务的人。

## 主要功能

- 本地读取 Codex 会话记录，默认扫描 `$HOME\.codex\sessions` 和 `$HOME\.codex\archived_sessions`。
- 支持本机 Claude 记录和外部复制来的 Codex JSONL 记录。
- 按工作目录、会话标题、更新时间、模型来源、归档状态组织历史记录。
- 支持全库搜索和当前会话内搜索，多个关键词按 AND 语义匹配。
- 支持只看用户提问，也支持查看完整对话、工具过程、系统事件和最终回答。
- 支持为项目组或单个会话添加本地备注。
- 支持复制消息全文、复制当前会话路径、复制继续会话命令。
- 支持导出当前会话为 Markdown。
- 支持输入图片记录的缩略图和预览。
- 支持增量刷新、当前会话快刷和全量重建。
- 运行数据默认保存在项目旁边的 `运行数据` 目录，不会写入源码目录。

## 快速开始

### 1. 准备环境

语迹当前主要面向 Windows 本地使用。你需要：

- Python 3
- PowerShell 7，命令名通常是 `pwsh`
- 一个已有的 Codex 或 Claude 本地记录目录

### 2. 启动浏览器

在项目根目录运行：

```powershell
.\Open-CodexChatIndex.cmd
```

它会自动准备本地目录，启动一个只监听 `127.0.0.1` 的本地服务，并打开浏览器。

默认地址类似：

```text
http://127.0.0.1:8765/CodexChatIndex/temp/CodexChatIndex.html
```

### 3. 手动构建静态索引

如果只想生成索引文件，可以运行：

```powershell
.\Build-CodexChatIndex.cmd
```

默认输出：

```text
temp/CodexChatIndex.html
```

共享运行数据默认放在项目上一级的：

```text
运行数据/
```

### 4. 常用刷新方式

在网页里可以使用：

- `刷新`：增量刷新记录。
- `快刷`：只重新读取当前会话。
- `全量`：重新扫描和解析全部聊天记录，适合缓存异常或数据结构升级后使用。

## 外部聊天记录

如果你从另一台电脑复制 Codex JSONL 记录，可以放到项目旁边的：

```text
外部聊天记录/
```

语迹会把每个子目录识别成一个独立来源，你可以在页面顶部的“来源”下拉框里切换。

## 项目结构

```text
.
├── Build-CodexChatIndex.cmd        # Windows 构建入口
├── Build-CodexChatIndex.ps1        # 解析 Codex / Claude 记录并生成索引
├── CodexChatIndexServer.py         # 本地 HTTP 服务和刷新 API
├── Open-CodexChatIndex.cmd         # 一键启动本地服务并打开浏览器
├── VERSION_V0.26.txt               # 当前版本标记
├── templates/
│   └── CodexChatIndex.template.html
└── tests/
    ├── Build-CodexChatIndex.Tests.ps1
    └── fixtures/
```

## 开发和测试

运行测试前需要 PowerShell 和 Pester。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester .\tests\Build-CodexChatIndex.Tests.ps1"
```

如果本机没有 Pester，可以先安装：

```powershell
Install-Module Pester -Scope CurrentUser
```

## 隐私说明

语迹按本地工具设计。它读取你本机的 AI 聊天记录，在本机生成索引，并通过本地服务展示。

需要注意：

- 聊天记录可能包含个人路径、项目名称、命令输出、密钥片段或业务信息。
- 不要把 `temp/`、`运行数据/`、`外部聊天记录/` 里的个人数据提交到公开仓库。
- 当前仓库的 `.gitignore` 已忽略 `temp/`。
- 开源前建议再次运行敏感信息扫描，确认已跟踪文件里没有私人内容。

## Roadmap

- 更完整的跨平台启动脚本。
- 更清晰的导入向导。
- 更细的搜索语法和高级筛选。
- 更方便的会话标注和知识整理能力。

## License

MIT License. See [LICENSE](LICENSE).
