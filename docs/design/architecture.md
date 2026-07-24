# TexHub 整体架构

TexHub 是在线 LaTeX 协作编辑平台（类 Overleaf），提供多人实时编辑、项目编译、PDF 预览与源码双向定位（SyncTeX）。

本仓库 `texhub-ai` 为 AI 辅助开发工作区，镜像 `dolphin/texhub` 的前后端结构。实时协作服务 **texhub-broadcast** 独立部署，源码不在本 monorepo。

---

## 1. 系统总览

```mermaid
flowchart TB
  subgraph Client["客户端"]
    Browser["浏览器<br/>texhub-web"]
  end

  subgraph Edge["接入层"]
    Ingress["Ingress / Traefik<br/>tex / ws / socket 域名"]
  end

  subgraph App["应用服务"]
    Web["texhub-web<br/>React + Vite<br/>:3003 / :80"]
    Server["texhub-server<br/>Actix-Web<br/>:8000"]
    Infra["infra-server<br/>用户 / 鉴权 / 支付<br/>:8081"]
    Broadcast["texhub-broadcast<br/>Socket.IO + Yjs<br/>:1234<br/>（独立服务）"]
    Render["tex-render<br/>cv-render 编译消费者<br/>:8001"]
  end

  subgraph Data["数据与中间件"]
    PG[("PostgreSQL<br/>业务库 tex")]
    Redis[("Redis<br/>Stream / 缓存")]
    NFS[("NFS / 文件系统<br/>/opt/data/project")]
    Meili[("Meilisearch<br/>项目搜索")]
  end

  subgraph External["外部依赖"]
    TeX["TeX Live<br/>latexmk / xelatex"]
    Pay["支付宝 / 微信 / PayPal"]
    GH["GitHub Import"]
  end

  Browser --> Ingress
  Ingress --> Web
  Ingress --> Server
  Ingress --> Infra
  Ingress --> Broadcast

  Web -->|"REST /tex/*"| Server
  Web -->|"REST /infra/*"| Infra
  Web -->|"Socket.IO /sync"| Broadcast
  Server -->|"INFRA_URL 内部调用"| Infra
  Server -->|"XADD 编译任务"| Redis
  Redis -->|"XREAD 消费"| Render
  Render -->|"latexmk"| TeX
  Render -->|"产物回传 / 共享盘"| Server
  Render --> NFS
  Server --> PG
  Server --> Redis
  Server --> NFS
  Server --> Meili
  Infra --> PG
  Infra --> Redis
  Infra --> Pay
  Server --> GH
  Broadcast -->|"doc/initial"| Server
```

---

## 2. 仓库与组件分层

```mermaid
flowchart LR
  subgraph Frontend["frontend/"]
    TW["texhub-web<br/>主 Web 应用"]
    JW["js-wheel<br/>rdjs-wheel SDK"]
    RC["rd-component<br/>共享 React 组件"]
  end

  subgraph Backend["backend/"]
    TS["texhub-server<br/>主 API"]
    TR["tex-render<br/>cv-render"]
    IS["infra-server<br/>基础设施"]
    RW["rust_wheel<br/>共享 Rust 库"]
  end

  subgraph ExternalPkg["本仓外"]
    TB["texhub-broadcast<br/>npm 客户端 + 独立服务"]
  end

  TW --> JW
  TW --> RC
  TW --> TB
  TS --> RW
  TR --> RW
  IS --> RW
```

| 组件 | 路径 / 包名 | 职责 | 默认端口 |
|------|-------------|------|----------|
| texhub-web | `frontend/texhub-web` | 编辑器、PDF 预览、项目管理 | 3003（dev）/ 80（K8s） |
| js-wheel | `frontend/js-wheel`（`rdjs-wheel`） | 鉴权、HTTP、前端模型 | — |
| rd-component | `frontend/rd-component` | 登录/支付/用户等共享 UI | — |
| texhub-server | `backend/texhub-server` | 项目/文件/模板/编译队列/SyncTeX | 8000 |
| tex-render | `backend/tex-render`（`cv-render`） | 消费编译任务，执行 LaTeX | 8001 |
| infra-server | `backend/infra-server` | 用户、鉴权、支付 | 8081 |
| rust_wheel | `backend/rust_wheel` | 配置、鉴权中间件、通用模型 | — |
| texhub-broadcast | 独立部署 | Yjs 实时协作（Socket.IO） | 1234 |

---

## 3. 关键业务链路

### 3.1 鉴权与用户

```mermaid
sequenceDiagram
  participant U as 浏览器
  participant W as texhub-web
  participant I as infra-server
  participant S as texhub-server
  participant DB as PostgreSQL

  U->>W: 登录 / 注册 / 重置密码
  W->>I: POST /infra/user/login 等
  I->>DB: 校验用户
  I-->>W: JWT / 用户信息
  W->>S: 带 Token 访问 /tex/*
  S->>S: rust_wheel Auth 中间件校验
  opt 需要用户详情
    S->>I: INFRA_URL /infra-inner/*
  end
```

- 登录、注册、改密、当前用户、Token 刷新走 **infra-server**（`/infra/user/*`、`/infra/auth/*`）。
- 业务 API（`/tex/*`）由 **texhub-server** 用 JWT 鉴权；必要时经内部接口回调 infra。

### 3.2 项目与文件

```mermaid
flowchart LR
  Web["texhub-web"] -->|"/tex/project/*<br/>/tex/file/*"| Server["texhub-server"]
  Server --> PG[("PostgreSQL")]
  Server --> NFS[("NFS<br/>compile_base_dir")]
  Server --> Cache[("Redis 缓存<br/>proj/file info")]
  Server --> Search[("Meilisearch")]
  Server -->|"POST /doc/initial"| BC["texhub-broadcast"]
```

- 项目元数据与队列状态存 PostgreSQL；源码与编译产物落盘到共享目录（生产多为 NFS `/opt/data`）。
- 创建/初始化文档时可通知 broadcast 初始化 Yjs 文档。

### 3.3 编译流水线

```mermaid
sequenceDiagram
  participant W as texhub-web
  participant S as texhub-server
  participant R as Redis Stream
  participant C as tex-render
  participant T as TeX Live
  participant FS as NFS / 产物目录

  W->>S: POST/PUT /tex/project/compile*
  S->>S: 写入 tex_comp_queue
  S->>R: XADD texhub-server:proj:s-comp-queue
  C->>R: XREAD（消费组 g-comp-queue）
  C->>T: latexmk -xelatex
  T-->>C: PDF + SyncTeX + 日志
  C->>R: XADD texhub:compile:log:{pid}:{qid}
  C->>S: 产物回传 / 共享盘可见
  C->>FS: 写入编译产物
  W->>S: 拉取日志 / PDF 静态资源 / SyncTeX
```

| 配置项 | 典型值 |
|--------|--------|
| 编译任务 Stream | `texhub-server:proj:s-comp-queue` |
| 消费组 | `g-comp-queue` |
| 编译日志 Stream | `texhub:compile:log:{project_id}:{qid}` |
| 项目工作目录 | `compile_base_dir`（如 `/opt/data/project`） |

### 3.4 实时协作

```mermaid
flowchart TB
  E1["编辑器实例 A<br/>CodeMirror + rdyjs"]
  E2["编辑器实例 B"]
  BC["texhub-broadcast<br/>Socket.IO path=/sync"]
  S["texhub-server<br/>文件持久化 / 初始化"]

  E1 <-->|"Yjs 增量"| BC
  E2 <-->|"Yjs 增量"| BC
  S -->|"doc/initial"| BC
```

- 文档模型：Yjs（`rdyjs`）；传输：Socket.IO（客户端包 `texhub-broadcast`）。
- 可同步扩展名由服务端配置（如 `tex,cls,bib,...`）。
- 编译进度走 REST / SSE / 轮询，与 Yjs 主路径分离。

### 3.5 PDF 预览与 SyncTeX

```mermaid
flowchart LR
  PDF["PDF + .synctex.gz"] --> Preview["previewer<br/>pdfjs-dist / react-pdf"]
  Preview -->|"点击 PDF"| API1["GET /tex/project/pos/src"]
  Preview -->|"编辑器定位"| API2["GET /tex/project/pos/pdf"]
  API1 --> Server["texhub-server<br/>libsynctex_parser FFI"]
  API2 --> Server
  Server --> Editor["CodeMirror 跳转 / 高亮"]
```

坐标约定：后端 SyncTeX box（pt）→ 前端 viewport 像素，需统一 `scale = viewportWidth / pageWidth`。

---

## 4. 技术栈

| 层级 | 技术 |
|------|------|
| 前端框架 | React 18、Vite 7、TypeScript 5 |
| 状态管理 | Redux Toolkit |
| UI | Ant Design 6、Bootstrap 5 |
| 编辑器 | CodeMirror 6（Overleaf fork） |
| PDF | pdfjs-dist 5.x、react-pdf、SyncTeX |
| 实时协作 | texhub-broadcast、Socket.IO、Yjs |
| 后端 | Actix-Web 4、Tokio |
| ORM | Diesel |
| 数据库 | PostgreSQL |
| 队列 / 缓存 | Redis Stream |
| 搜索 | Meilisearch |
| 日志 | log4rs + log |
| 国际化 | i18next（前端）、rust_i18n（后端） |
| 编译环境 | TeX Live、latexmk、XeLaTeX |

---

## 5. 部署拓扑（概要）

生产常见命名空间：`reddwarf-pro`（应用）、`reddwarf-storage`（PG/存储）、`reddwarf-toolbox`（Meilisearch）。

```mermaid
flowchart TB
  subgraph IngressHosts["域名接入"]
    H1["tex.* → texhub-web / API"]
    H2["ws.* / socket.* → broadcast"]
  end

  subgraph NS["reddwarf-pro"]
    WebSvc["texhub-web"]
    TexSvc["tex-service<br/>texhub-server:8000"]
    CvSvc["cv-render-service<br/>tex-render"]
    InfraSvc["infra-server-service:8081"]
    BcSvc["texhub-broadcast-service:1234"]
    PVC["共享 PVC / NFS<br/>/opt/data"]
  end

  H1 --> WebSvc
  H1 --> TexSvc
  H1 --> InfraSvc
  H2 --> BcSvc
  TexSvc --- PVC
  CvSvc --- PVC
```

详细部署清单见各服务 `docs/deploy/`；PostgreSQL 备份见 [`docs/ops/backup/`](../ops/backup/README.md)。

---

## 6. 服务交互速查

| 调用方 | 被调用方 | 协议 / 机制 | 用途 |
|--------|----------|-------------|------|
| texhub-web | texhub-server | REST `/tex/*` | 项目、文件、编译、SyncTeX |
| texhub-web | infra-server | REST `/infra/*` | 登录、注册、支付 |
| texhub-web | texhub-broadcast | Socket.IO `/sync` | 协同编辑 |
| texhub-server | infra-server | 内部 HTTP | 用户详情、ID 生成等 |
| texhub-server | Redis | Stream XADD | 投递编译任务 |
| tex-render | Redis | Stream XREAD | 消费编译任务 / 写日志 |
| tex-render | TeX Live | 本地进程 | latexmk 编译 |
| texhub-server / tex-render | NFS | 文件系统 | 源码与 PDF 产物共享 |

---

## 相关文档

- 根目录约定与开发入口：[AGENTS.md](../../AGENTS.md)
- 前端说明：`frontend/texhub-web/README.md`
- 备份运维：[docs/ops/backup/README.md](../ops/backup/README.md)
