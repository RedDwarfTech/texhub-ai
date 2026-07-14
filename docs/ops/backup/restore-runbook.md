# PostgreSQL pgBackRest 恢复 Runbook

本文档描述 TexHub PostgreSQL（`reddwarf-postgresql` / 数据库 `tex`）的备份恢复操作流程。执行前请确认已阅读 [postgresql-pgbackrest-backup-plan.md](./postgresql-pgbackrest-backup-plan.md)。

---

## 0. 恢复前检查清单

- [ ] 确认事故范围：误删 / 数据损坏 / 全集群不可用
- [ ] 确认目标恢复点（最新 / 指定时间点 PITR）
- [ ] 通知相关方，应用侧已停止写入（或准备切换）
- [ ] 确认备份 repo 可访问（S3 / PVC）
- [ ] 在 **非生产命名空间** 先演练（如 `reddwarf-storage-restore-test`）

---

## 1. 查看可用备份

### 1.1 PGO 集群

```bash
# 进入 pgBackRest repo pod 或带 pgbackrest 容器的 pod
kubectl -n reddwarf-storage exec -it \
  $(kubectl -n reddwarf-storage get pods -l postgres-operator.crunchydata.com/cluster=reddwarf-postgresql,postgres-operator.crunchydata.com/role=pgbackrest -o name | head -1) \
  -- pgbackrest info
```

### 1.2 独立 CronJob 方案

```bash
kubectl -n reddwarf-storage exec -it <postgres-pod> -c pgbackrest -- \
  pgbackrest --stanza=pod info
```

输出示例解读：

```
full backup: 20260707-020001F
incr backup: 20260714-060001F_I
             ^label          ^incremental chain
```

记录要恢复到的 **backup label** 或 **时间戳**。

---

## 2. 场景 A：全量恢复到最新备份

适用于：主库 PV 损坏、需整库替换。

### 2.1 PGO 流程

1. 缩容或删除现有 PostgresCluster（**务必确认无唯一副本**）
2. 在 CR 中启用 restore 模式，或使用 PGO 文档中的 `dataSource.pgbackrest` 从备份创建新集群

```yaml
# 新建集群时从备份恢复（示例）
spec:
  dataSource:
    pgbackrest:
      stanza: db
      options:
        - --type=immediate
      repo:
        name: repo1
```

3. Apply 后 Operator 自动执行 restore Job

```bash
kubectl -n reddwarf-storage get jobs -w
kubectl -n reddwarf-storage logs -l postgres-operator.crunchydata.com/pgbackrest-restore=true -f
```

### 2.2 独立 Pod 手动 restore

```bash
# 1. 停止 PostgreSQL
kubectl -n reddwarf-storage exec -it <postgres-pod> -- \
  pg_ctl -D /var/lib/postgresql/data stop -m fast

# 2. 清空数据目录（危险操作，确认 Pod 已隔离）
kubectl -n reddwarf-storage exec -it <postgres-pod> -c pgbackrest -- \
  rm -rf /var/lib/postgresql/data/*

# 3. 执行 restore
kubectl -n reddwarf-storage exec -it <postgres-pod> -c pgbackrest -- \
  pgbackrest --stanza=pod restore --type=immediate

# 4. 启动 PostgreSQL
kubectl -n reddwarf-storage exec -it <postgres-pod> -- \
  pg_ctl -D /var/lib/postgresql/data start
```

### 2.3 验证

```bash
kubectl -n reddwarf-storage exec -it <postgres-pod> -- psql -U postgres -d tex -c "\dt"
kubectl -n reddwarf-storage exec -it <postgres-pod> -- psql -U postgres -d tex -c "SELECT count(*) FROM <关键表>;"
```

---

## 3. 场景 B：PITR 恢复到指定时间点

适用于：误操作后回退到某一时刻。

### 3.1 确定目标时间

目标时间必须在 `[最早可用 WAL, 最新 WAL]` 范围内，且早于误操作发生时间。

```bash
pgbackrest --stanza=pod info
# 查看 archive 段的起止
```

### 3.2 执行 PITR restore

```bash
kubectl -n reddwarf-storage exec -it <postgres-pod> -c pgbackrest -- \
  pgbackrest --stanza=pod restore \
    --type=time \
    --target="2026-07-14 10:30:00+08" \
    --target-action=promote
```

参数说明：

| 参数 | 说明 |
|------|------|
| `--type=time` | 按时间恢复 |
| `--target` | 目标时间点（含时区） |
| `--target-action=promote` | 恢复完成后自动 promote 为可写主库 |
| `--set` | 可选，指定 backup label 作为起点加速 restore |

### 3.3 验证数据时间点

```bash
psql -U postgres -d tex -c "SELECT now(), max(updated_at) FROM <业务表>;"
```

确认 `max(updated_at)` 符合预期时间窗口。

---

## 4. 场景 C：恢复到隔离环境（演练 / 取证）

不覆盖生产，用于季度演练。

```bash
# 1. 创建临时 PVC + Pod（使用相同 PG 版本镜像）
kubectl apply -f manifests/restore-test-pod.yaml  # 可按 plan 自行编写

# 2. 在临时 Pod 中 restore
pgbackrest --stanza=pod restore --type=immediate

# 3. 启动并验证
pg_ctl start && pg_isready

# 4. 演练完成后删除临时资源
kubectl -n reddwarf-storage-restore-test delete pod,pvc --all
```

---

## 5. 场景 D：单库逻辑导出（补充手段）

pgBackRest 为**整集群物理恢复**，无法只恢复单个 database。若只需 `tex` 库的部分数据：

1. 按场景 C 恢复到临时实例
2. 使用 pg_dump 导出所需对象：

```bash
pg_dump -h <temp-service> -U postgres -d tex -t <table> > export.sql
```

---

## 6. 恢复后操作

| 步骤 | 操作 |
|------|------|
| 1 | 重建只读副本（如有） |
| 2 | 确认 WAL 归档恢复：`SELECT * FROM pg_stat_archiver;` |
| 3 | 重新启用应用连接，观察错误率 |
| 4 | 触发一次 manual full backup，重建备份链 |
| 5 | 编写事故报告，记录 root cause 与恢复耗时 |

---

## 7. 常见问题

### Q1: `pgbackrest restore` 报 archive missing

**原因**：WAL 保留不足或 S3 对象被误删。  
**处理**：检查 `repo1-retention-archive`；若 full backup 仍在，可尝试 `--type=immediate` 放弃 PITR。

### Q2: restore 后 PostgreSQL 处于 recovery 模式

**原因**：未执行 `--target-action=promote`。  
**处理**：`pg_ctl promote -D $PGDATA` 或重新 restore 并加 `--target-action=promote`。

### Q3: PGO restore Job 长时间 Pending

**原因**：Repo PVC 未绑定或 S3 凭证错误。  
**处理**：`kubectl describe job <name>` 查看 Events；验证 Secret 与网络。

---

## 8. 演练记录模板

| 字段 | 值 |
|------|-----|
| 演练日期 | |
| 执行人 | |
| 恢复类型 | full / PITR / 隔离演练 |
| 目标 backup label | |
| 开始时间 | |
| PG 可用时间 | |
| 数据验证结果 | pass / fail |
| 发现问题 | |
| 改进项 | |
