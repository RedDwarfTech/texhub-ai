# AGENTS.md — TexHub Project Root

## Project Purpose

TexHub 是一个在线 LaTeX 协作编辑平台（类 Overleaf），支持多人实时编辑、项目编译、PDF 预览与源码双向定位（SyncTeX）。本仓库 `texhub-ai` 是 TexHub 的 AI 辅助开发工作区。

## Top-level Architecture

```
texhub-ai/
├── frontend/
│   ├── texhub-web/      # 主 Web 应用：编辑器、预览器、项目管理
│   ├── js-wheel/        # rdjs-wheel：前端 SDK（网络、鉴权、模型）
│   └── rd-component/    # 共享 React 组件库
└── backend/
    ├── texhub-server/   # 主 API：用户、项目、文件、模板、队列
    ├── tex-render/      # LaTeX 编译服务（cv-render）：编译任务消费与 SyncTeX，项目为无状态项目
    ├── rust_wheel/      # 共享 Rust 基础库（配置、模型、中间件）
    └── infra-server/    # RedDwarf 基础设施服务（用户/鉴权等）
```

**关键交互：**

1. `texhub-web` ↔ `texhub-server`：REST API（项目 CRUD、文件、编译触发）
2. `texhub-web` ↔ `texhub-broadcast`：Socket.IO 实时协作（Yjs 协同编辑）
3. `texhub-server` → `tex-render`：通过 Redis Stream 投递编译任务
4. `tex-render` → 前端：编译产物（PDF + `.synctex.gz`）供预览与高亮定位
5. 前后端共享 `rust_wheel` / `rdjs-wheel` / `rd-component` 中的模型与工具约定

## Setup

### 前端（texhub-web）

```bash
cd frontend/texhub-web
pnpm install
pnpm dev          # Vite 开发服务器，默认 0.0.0.0:3003
pnpm build        # tsc && vite build
pnpm test         # jest
```

### 后端（texhub-server / tex-render）

```bash
cd backend/texhub-server   # 或 backend/tex-render
cargo build
cargo run
```

- `texhub-server`：Actix-Web 主 API，配置见 `settings.toml` / `rust_wheel` 配置体系
- `tex-render`：编译服务，监听 `0.0.0.0:8001`，依赖 Redis Stream 与本地 TeX 环境


## Conventions

### 通用

- 保持改动范围最小，只修改与任务直接相关的文件
- 未经用户明确要求，不要自动创建 git commit 或 push
- 未经用户明确要求，不要生成测试用例
- 回答与文档默认使用中文

### 实时协作

- 编辑态通过 Yjs + broadcast 同步；编译态通过 REST + 轮询/WebSocket 通知

## Anti-Patterns

- **不要**在前端组件中硬编码 API 基址或鉴权逻辑，应走 `service/` 与 `rdjs-wheel` 配置
- **不要**在 Rust `controller` 中写复杂业务逻辑，应下沉到 `service`
- **不要**混用 PDF 坐标系：后端 SyncTeX box 与 pdf.js viewport 的 scale/offset 必须一致，否则高亮定位会偏移
- **不要**修改 `rd-component` / `js-wheel` / `rust_wheel` 的公开 API 而不评估 texhub-web 的依赖影响
- **不要**在未经确认的情况下升级 `pdfjs-dist` 主版本（与 `react-pdf` 存在兼容性约束）
- **不要**提交 `.env`、密钥、数据库连接串等敏感文件

## Verification

完成改动后，按范围选择验证手段：

| 改动范围 | 验证命令 |
|---|---|
| 前端 UI / 逻辑 | `cd frontend/texhub-web && pnpm build` |
| 后端 API | `cd backend/texhub-server && cargo build` |
| 编译服务 | `cd backend/tex-render && cargo build` |
| 共享 Rust 库 | `cd backend/rust_wheel && cargo build` |
