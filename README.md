# 语迹 Yuji

语迹是一个本地优先的 AI 对话记录浏览器。它把 Codex、Claude 和外部导入的聊天记录整理成一个可搜索、可筛选、可备注、可导出的网页阅读器，让散落在本机里的 AI 协作过程重新变得可查、可复盘、可继续使用。

如果你经常用 AI 写代码、做笔记、调试项目，最后却发现“我明明之前问过这个问题，但到底在哪个会话里”，语迹就是为这个场景做的。

## 适合谁

- 经常使用 Codex 或 Claude 的开发者。
- 想把 AI 聊天记录按项目、标题、时间重新整理的人。
- 想搜索历史回答、命令输出、工具调用和最终结论的人。
- 想把某个会话导出成 Markdown，继续整理成笔记或文档的人。
- 默认只想在本机查看记录，或希望主动选择用自己的 WebDAV 在多台电脑间同步的人。

## 主要功能

- 本地读取 Codex 会话记录，默认扫描 `$HOME\.codex\sessions` 和 `$HOME\.codex\archived_sessions`。
- 支持本机 Claude 记录和外部复制来的 Codex JSONL 记录。
- 按工作目录、会话标题、更新时间、模型来源、归档状态组织历史记录。
- 支持全库搜索、当前会话内搜索和独立提问搜索；全文搜索可命中标题、提问、回答、过程和工具。为控制超大记录的索引体积，全库搜索保留工具名称、状态、摘要及输出首尾片段，当前会话搜索仍检查完整工具输出；提问搜索只检查用户提问正文。
- 多个关键词按空格、Tab 或换行拆分并采用 AND 语义匹配；提问搜索要求同一条提问同时包含全部关键词。
- 搜索框在当前浏览器保存最近 20 条搜索历史，支持键盘复用、单条删除和清空；历史不会上传到 WebDAV。
- 自动过滤 Codex 在真实提问前注入的已知上下文区块，避免它们进入标题、提问导航、搜索和导出内容。
- 校正续接或恢复会话中明显错误的固定消息时间，同时保持原始事件顺序和正文不变。
- 兼容新版 Codex `item_completed` 可见回答、过程说明和工具记录，并避免把内部续接摘要显示成回答。
- 支持只看用户提问，也支持查看完整对话、工具过程、系统事件和最终回答。
- 支持为项目组或单个会话添加本地备注；V0.33 可在顶部通过“备注 / 隐藏”切换悬浮与常驻显示，显示偏好只保存在当前浏览器。
- 支持复制消息全文、复制当前会话路径、复制继续会话命令。
- 支持导出当前会话为 Markdown。
- 支持输入图片记录的缩略图和预览；V0.32 会把成功识别的 PNG/JPEG/GIF/WebP/AVIF 首次快照保存到 `运行数据/CodexChatIndex.images/`，后续即使原图片移动、删除或同路径被替换，历史会话仍按首次托管内容显示。
- V0.33 中，同标题下存在多个子会话时，点击母标题主体或右下角带边框箭头都会收起/展开，不再自动打开第一条子会话；单会话标题仍直接打开，折叠状态仅保存在当前浏览器 `localStorage`。
- 支持增量刷新、当前会话快刷和全量重建。
- 可选支持 WebDAV 多端同步，默认适配坚果云；每台设备只写自己的云端目录。
- 本机 Codex、Claude 只上传，其他设备的云端来源只下载并保持只读。
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

V0.32 首次刷新会因图片托管规则升级自动执行一次兼容迁移：对当时仍可访问的历史本地图片、Base64 图片和已识别 URL 图片尝试建立托管快照；完成后记录迁移版本，后续刷新恢复正常增量路径。

## 坚果云 WebDAV 同步

网页顶栏的 `云设置` 可以保存一组 WebDAV 连接。坚果云推荐填写：

```text
WebDAV URL: https://dav.jianguoyun.com/dav/
用户名: 坚果云账号邮箱
密码: 坚果云生成的第三方应用密码
远端根目录: YujiSync
```

保存前可使用“检查连通性”验证 `PROPFIND`、`MKCOL`、`PUT`、`GET`、`MOVE`、`DELETE`、ETag 和条件请求。密码由 Windows DPAPI CurrentUser 加密后保存在本机隔离目录中，设置 API 不返回密码或密文。

同步由用户手动触发：

- 本机 Codex 和本机 Claude 显示“上传”，不会用云端内容覆盖本机原始记录；聊天正文仍只在用户手动点击“上传”时上传。
- V0.32 的图片使用独立 `YujiImageSync/v1` sidecar。启用 WebDAV 后，每次刷新会先完成本地图片托管，再在后台仅增量上传图片对象/清单；不会因此自动上传整套聊天记录。
- 手动上传聊天时会先确保当前托管图片已同步；从其他设备下载聊天时，如存在图片 sidecar，会同时下载缺失图片并做 SHA-256 校验；没有 sidecar 的 V0.31 云端数据继续兼容。
- 其他设备的 Codex 和 Claude 分别显示为只读云端来源，并显示“下载”。
- 手工外部来源和 WebDAV 来源不会再次上传。
- 停用 WebDAV 后，已成功下载的本机缓存仍可离线查看。
- 清除缓存只删除本机内容，不删除坚果云数据。

WebDAV 使用 HTTPS 传输，但 V0.32 没有端到端加密。聊天正文、备注、来源原路径，以及已托管并同步的图片内容在 WebDAV 服务端可被读取，请在启用前确认数据风险。

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
├── VERSION_V0.33.txt               # 当前版本标记
├── templates/
│   └── CodexChatIndex.template.html
├── webdav_sync/
│   ├── config.py                   # 本机身份、DPAPI 和配置
│   ├── client.py                   # 受限 WebDAV 客户端
│   ├── protocol.py                 # 对象、清单、打包和校验
│   ├── tasks.py                    # 后台任务、取消和恢复
│   └── service.py                  # 上传、下载和来源编排
└── tests/
    ├── Build-CodexChatIndex.Tests.ps1
    ├── test_webdav_sync.py
    └── fixtures/
```

## 开发和测试

运行测试前需要 PowerShell 和 Pester。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester .\tests\Build-CodexChatIndex.Tests.ps1"
python -m unittest discover -s tests -p test_webdav_sync.py -v
```

如果本机没有 Pester，可以先安装：

```powershell
Install-Module Pester -Scope CurrentUser
```

## 隐私说明

语迹默认按本地工具设计。未启用 WebDAV 时，它不会发起 WebDAV 同步请求。启用 WebDAV 后，聊天正文仍只在用户手动上传时同步；V0.32 会在刷新成功后自动尝试增量同步已托管图片的独立 sidecar。

需要注意：

- 聊天记录可能包含个人路径、项目名称、命令输出、密钥片段或业务信息。
- 不要把 `temp/`、`运行数据/`、`外部聊天记录/` 里的个人数据提交到公开仓库。
- WebDAV 缓存和配置位于 `运行数据/CodexChatIndex.local/<本机键>/`；项目位于 OneDrive 时，这些缓存可能被 OneDrive 再次同步。
- WebDAV 密码使用当前 Windows 用户的 DPAPI 保存，项目复制到其他电脑或切换 Windows 用户后需要重新输入。
- WebDAV 同步没有端到端加密，远端服务理论上可以读取聊天正文、备注和来源路径。
- 图片识别不会因为地址是 `localhost`、`127.0.0.1`、局域网或内网 URL 就自动排除；只要该 URL 已被语迹识别为图片且刷新时可以访问，其图片内容就可能被保存到本机托管库，并在启用 WebDAV 时自动上传到你配置的 WebDAV。图片抓取不会携带浏览器 Cookie、浏览器登录态或浏览器认证信息。
- 单张托管图片上限为 30 MiB；仅支持实际内容为 PNG、JPEG、GIF、WebP、AVIF 的图片，SVG 不进入托管图片库。
- 搜索历史只保存在浏览器的 `localStorage` 键 `yuji-search-history-v1`；可在搜索历史浮层中单条删除或清空。
- V0.33 的备注显示模式只保存在浏览器的 `localStorage` 键 `Yuji.noteDisplayMode.v1`，不会写入备注数据，也不会上传 WebDAV。
- 当前仓库的 `.gitignore` 已忽略 `temp/`。
- 开源前建议再次运行敏感信息扫描，确认已跟踪文件里没有私人内容。

## Roadmap

- 更完整的跨平台启动脚本。
- 更清晰的导入向导。
- 更细的搜索语法和高级筛选。
- 更方便的会话标注和知识整理能力。

## License

MIT License. See [LICENSE](LICENSE).
