# AGENTS.md — TexHub Project Root

## Project Purpose

TexHub 是一个在线 LaTeX 协作编辑平台（类 Overleaf），支持多人实时编辑、项目编译、PDF 预览与源码双向定位（SyncTeX）。本仓库 `texhub-ai` 是 TexHub 的 AI 辅助开发工作区，镜像 `dolphin/texhub` 的前后端代码结构。

## Top-level Architecture

```
texhub-ai/
├── frontend/
│   ├── texhub-web/      # 主 Web 应用：编辑器、预览器、项目管理
│   ├── js-wheel/        # rdjs-wheel：前端 SDK（网络、鉴权、模型）
│   └── rd-component/    # 共享 React 组件库
└── backend/
    ├── texhub-server/   # 主 API：用户、项目、文件、模板、队列
    ├── tex-render/      # LaTeX 编译服务（cv-render）：编译任务消费与 SyncTeX
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

### 共享库

| 库 | 语言 | 构建 |
|---|---|---|
| `frontend/js-wheel` | TypeScript | `pnpm build` |
| `frontend/rd-component` | TypeScript/React | `pnpm build` |
| `backend/rust_wheel` | Rust | `cargo build` |

## Stack

| 层级 | 技术 |
|---|---|
| 前端框架 | React 18、Vite 7、TypeScript 5 |
| 状态管理 | Redux Toolkit |
| UI | Ant Design 6、Bootstrap 5 |
| 编辑器 | CodeMirror 6（Overleaf fork） |
| PDF 预览 | pdfjs-dist 5.x、react-pdf、SyncTeX |
| 实时协作 | texhub-broadcast、Socket.IO、Yjs |
| 后端框架 | Actix-Web 4、Tokio |
| 数据库 | PostgreSQL + Diesel ORM |
| 消息队列 | Redis Stream（编译任务） |
| 日志 | log4rs + log |
| 国际化 | rust_i18n（后端）、i18next（前端） |

## Conventions

### 通用

- 保持改动范围最小，只修改与任务直接相关的文件
- 未经用户明确要求，不要自动创建 git commit 或 push
- 未经用户明确要求，不要生成测试用例
- 回答与文档默认使用中文

### 前端（texhub-web）

- 目录约定：`component/` UI 组件、`service/` API 调用、`redux/` 状态、`model/` 类型与实体
- 使用函数式 React 组件与 Hooks；遵守 `react-hooks/rules-of-hooks`
- API 调用走 `service/` 层，不在组件内直接拼 URL
- 样式使用 SCSS，与组件同目录或 `scss/` 下组织
- 包管理使用 **pnpm**；`rd-component`、`rdjs-wheel` 为内部依赖，版本在 `package.json` / `pnpm.overrides` 中锁定

### 后端（Rust）

- 模块分层：`controller` → `service` → `model`；`common` 放横切关注点（日志、中间件）
- 使用 `rust_wheel` 提供的配置读取、鉴权中间件、通用模型，避免重复实现
- 错误处理：业务错误返回结构化响应，使用 `log` 记录上下文，不要吞掉 `Err`
- 文档注释遵循 rustdoc 惯例：`///` 写 API 说明，`//` 写实现细节；公开函数标注 `# Errors` / `# Panics`（如适用）
- 数据库迁移与 schema 变更通过 Diesel 脚本管理（`infra-server/scripts/diesel` 可参考）

### 命名

- Rust：snake_case 函数/变量，PascalCase 类型，模块名小写
- TypeScript：camelCase 变量/函数，PascalCase 组件与类型，文件名与导出名一致

## Typical Patterns

### 前端 Service 层调用后端

```typescript
// service/project/ProjectService.ts
const resp = await axios.get(`/api/project/${projectId}`);
```

### 后端 Controller 注册路由

```rust
// controller 模块提供 config 函数，在 main.rs 中 .configure(xxx_controller::config)
pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(web::resource("/health").route(web::get().to(health)));
}
```

### PDF 预览与源码定位

- 后端 `tex-render` 编译产出 PDF 与 SyncTeX 数据
- 前端 `component/common/previewer/` 负责 PDF 渲染与高亮层叠加
- 坐标转换须统一：后端 box 坐标（pt）→ 前端 viewport 像素，需乘以 `scale = viewportWidth / pageWidth`

### 实时协作

- 编辑态通过 Yjs + broadcast 同步；编译态通过 REST + 轮询/WebSocket 通知

## Anti-Patterns

- **不要**在前端组件中硬编码 API 基址或鉴权逻辑，应走 `service/` 与 `rdjs-wheel` 配置
- **不要**在 Rust `controller` 中写复杂业务逻辑，应下沉到 `service`
- **不要**混用 PDF 坐标系：后端 SyncTeX box 与 pdf.js viewport 的 scale/offset 必须一致，否则高亮定位会偏移
- **不要**修改 `rd-component` / `js-wheel` / `rust_wheel` 的公开 API 而不评估 texhub-web 的依赖影响
- **不要**在未经确认的情况下升级 `pdfjs-dist` 主版本（与 `react-pdf` 存在兼容性约束）
- **不要**提交 `.env`、密钥、数据库连接串等敏感文件

## Gotchas

- `texhub-ai` 是开发镜像目录，生产部署配置在 `infra-server/doc/deploy` 与各服务 `settings.toml`
- `tex-render` 的 Cargo 包名为 `cv-render`，目录名为 `tex-render`
- 前端 `package.json` 中 `react` 版本通过 `pnpm.overrides` 锁定为 `18.2.0`
- CodeMirror 依赖 Overleaf fork 版本（`github:overleaf/...`），升级需谨慎
- 编译服务依赖宿主机 TeX Live 环境，本地开发需确认 `pdflatex` / `xelatex` 可用

## Cross-Skill Notes

- 若项目 vendoring 了 **HarnessFlow** skill pack，遵循其工作流约束：同一时刻只有一个 Active Task、审批与 gate 为一等节点、以仓库产物为证据而非聊天记忆
- 本文件为 **root 层**上下文；子目录（`frontend/texhub-web`、`backend/texhub-server` 等）可另建 mid/leaf 层 `AGENTS.md` 补充模块级约定
- Cursor 用户可将目录级规则写入 `.cursor/rules/*.mdc`（`globs` 指向对应子目录），内容与本文互补而非重复

## Verification

完成改动后，按范围选择验证手段：

| 改动范围 | 验证命令 |
|---|---|
| 前端 UI / 逻辑 | `cd frontend/texhub-web && pnpm build` |
| 前端单元测试 | `cd frontend/texhub-web && pnpm test` |
| 后端 API | `cd backend/texhub-server && cargo build` |
| 编译服务 | `cd backend/tex-render && cargo build` |
| 共享 Rust 库 | `cd backend/rust_wheel && cargo build` |

涉及 PDF 预览 / SyncTeX 高亮的改动，须在浏览器中手动验证：编辑器光标位置与 PDF 高亮区域是否对齐。
