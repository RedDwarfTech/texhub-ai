# PostgreSQL 备份运维检查清单

配合 [postgresql-pgbackrest-backup-plan.md](./postgresql-pgbackrest-backup-plan.md) 使用的日常运维与告警配置参考。

---

## 1. 每日检查（自动化优先）

| # | 检查项 | 命令 / 来源 | 正常标准 |
|---|--------|-------------|----------|
| D1 | 最近 incr/diff 备份成功 | `kubectl get jobs -l app=pgbackrest-backup --field-selector status.successful=1` | 24h 内有成功 Job |
| D2 | WAL 归档正常 | `SELECT archived_count, failed_count FROM pg_stat_archiver;` | `failed_count` 不增长 |
| D3 | 无失败 CronJob | `kubectl get cronjobs -n reddwarf-storage` | `LAST SCHEDULE` 非 `<none>` 且无连续 Failed |
| D4 | Repo 空间 | S3 控制台 / `df -h` on repo PVC | 使用率 < 80% |

---

## 2. 每周检查

| # | 检查项 | 说明 |
|---|--------|------|
| W1 | full backup 存在 | `pgbackrest info` 显示 7 天内有 `full` |
| W2 | backup 校验 | `pgbackrest --stanza=pod verify`（pgBackRest 2.38+） |
| W3 | 备份大小趋势 | 对比上周 full backup 大小，异常增长 > 50% 需排查 |
| W4 | Secret 有效期 | S3 凭证是否在轮换周期内 |

---

## 3. 每月 / 每季度

| # | 检查项 | 频率 |
|---|--------|------|
| M1 | 恢复演练 | 每季度 |
| M2 | 保留策略审查 | 每月 |
| M3 | RPO/RTO 复盘 | 每季度 |
| M4 | 备份文档与 Runbook 更新 | 变更后即时 |

---

## 4. Prometheus 告警规则示例

```yaml
groups:
  - name: postgres-backup
    rules:
      - alert: PostgresBackupJobFailed
        expr: |
          kube_job_status_failed{namespace="reddwarf-storage", job_name=~"pgbackrest.*"} > 0
        for: 1h
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL pgBackRest backup job failed"
          description: "Job {{ $labels.job_name }} in {{ $labels.namespace }} has failed."

      - alert: PostgresBackupTooOld
        expr: |
          (time() - kube_cronjob_status_last_successful_time{
            namespace="reddwarf-storage",
            cronjob=~"pgbackrest.*"
          }) > 86400
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "No successful PostgreSQL backup in 24 hours"

      - alert: PostgresArchiveFailed
        expr: |
          increase(pg_stat_archiver_failed_count{datname="tex"}[1h]) > 0
        for: 15m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL WAL archive failures detected"
```

> `pg_stat_archiver_*` 指标需通过 postgres_exporter 暴露；Job/CronJob 指标来自 kube-state-metrics。

---

## 5. 告警响应 SOP

| 级别 | 场景 | 响应时间 | 动作 |
|------|------|----------|------|
| P1 | 连续 2 次 backup Job 失败 + archive failed | 30 分钟 | 检查 S3/PVC、凭证、磁盘；手动触发 backup |
| P2 | 24h 无成功备份 | 4 小时 | 检查 CronJob 调度、pgBackRest 锁 |
| P3 | Repo 使用率 > 80% | 1 工作日 | 扩容 Bucket/PVC 或调整 retention |

---

## 6. 手动运维命令速查

```bash
# 查看备份信息
kubectl -n reddwarf-storage exec -it <pgbackrest-pod> -- pgbackrest info

# 手动 full backup
kubectl -n reddwarf-storage exec -it <pgbackrest-pod> -- \
  pgbackrest --stanza=pod backup --type=full

# PGO 手动触发
kubectl -n reddwarf-storage annotate postgrescluster reddwarf-postgresql \
  postgres-operator.crunchydata.com/pgbackrest-backup="$(date +%s)" --overwrite

# 查看 CronJob 历史
kubectl -n reddwarf-storage get jobs -l app=pgbackrest-backup --sort-by=.metadata.creationTimestamp

# 查看 WAL 归档统计
kubectl -n reddwarf-storage exec -it <postgres-pod> -- \
  psql -U postgres -c "SELECT * FROM pg_stat_archiver;"
```

---

## 7. 变更管理

对以下变更需走变更窗口并提前通知：

- 修改 backup schedule（Cron 表达式）
- 调整 retention 参数（可能导致旧备份被提前 expire）
- 切换 repo 存储（S3 ↔ PVC）
- PostgreSQL 大版本升级（需重新 stanza-create / 全量 backup）

变更后 **必须** 执行：

1. 手动 full backup
2. `pgbackrest info` 确认新 backup set
3. 更新本文档与 Runbook 中的版本/路径信息
