# Hive

一个「主管家 + 子机器人 + 共享记忆 + 自由换模型」的 iOS App。当前是 **P0**：先把地基跑通。

## P0 做了什么

- **可中断续跑的编排**：每次模型调用是一个 `steps` 行，调用前写 `running`，完成后写 `done`。App 被挂起或杀掉后重开，发现残留的 `running` 步骤就重置为 `pending` 并重放。用户主动取消写 `cancelled`，不会被自动复活
- **三层共享记忆 + 私有区**：`semantic`（全局事实）、`episodic`（会话情节）、`blackboard`（预留）、`scratchpad`（不参与检索）。按需检索 top-k 注入 system prompt，不是全量塞上下文
- **混合 embedding**：远程 OpenAI 兼容 `/embeddings` → Apple `NLEmbedding` 端上模型 → 关键词 LIKE 兜底
- **三家模型协议**：OpenAI 兼容 / Anthropic / Gemini，流式。Base URL 可填任意中转或自建服务
- **Keychain**：API Key 只进 Keychain，不进 SQLite
- **本地 SQLite**：零第三方依赖，系统 `libsqlite3`

## 还没做（P1/P2）

- 总管真正拆任务、派发给多个子机器人（当前所有工作由主管家自己完成）
- 子机器人之间的事件总线与黑板并发写
- 本地编排服务（Mac/PC 跑引擎，iPhone 只做 UI）
- 工具调用 / MCP / 快捷指令
- 记忆提炼与冲突消解（当前只写原始对话）
- 自定义子机器人

## 构建

本地是 Windows，没有 Xcode。编译和测试都走 GitHub Actions：

1. 推到 GitHub
2. Actions → **Build Hive** → Run workflow（普通 push 也会自动跑）
3. 失败时下载 `build-logs` artifact，`build.log` 和 `test.log` 里有完整输出

本地生成工程（有 Mac 时）：

```sh
brew install xcodegen
xcodegen generate
open Hive.xcodeproj
```

## 目录

```
HiveApp.swift              入口
Core/
  DesignSystem.swift       颜色与卡片样式
  Keychain.swift           API Key 存取
Models/
  Models.swift             领域模型、Run/Step 状态机类型
Services/
  Database.swift           零依赖 SQLite 封装
  Migrations.swift         schema v1
  Store.swift              全部持久化
  Embedding.swift          远程 / Apple / 混合
  MemoryService.swift      写入与相似度检索
  Orchestrator.swift       可恢复的步骤状态机
  AppEnvironment.swift     依赖装配与用户配置
  LLM/
    LLMKit.swift           请求类型、SSE、错误
    Providers.swift        三家协议 + 连通性检查
Views/
  RootView.swift           Tab 容器
  ChatView.swift           对话与流式气泡
  RunsView.swift           任务列表与步骤时间线
  SettingsView.swift       模型配置
Tests/
  HiveStorageTests.swift   存储层、状态机、向量编解码
```

## 加一个新模型

设置页 → 添加模型 → 选协议 → 填 Base URL 和模型 ID → 填 Key → 测试连接 → 保存。

OpenAI 兼容协议的 Base URL 要填到 `/v1`（例如 `https://api.example.com/v1`），代码会自己拼 `/chat/completions` 和 `/embeddings`。

## 已知取舍

- 远程 embedding 的模型名写死为 `text-embedding-3-small`；换成不认这个名字的中转站会自动降级到 Apple 端上模型，不会报错
- 重放中断的步骤会重新调用一次模型，可能重复计费。这是「可恢复」的代价，P1 会加幂等键
- 一次只允许一个 run 在跑（单会话单任务）
