# PostgreSQL 备份方案

TexHub PostgreSQL 备份文档，按集群资源与架构选型。

## 快速决策

```
集群是否资源紧张 / 无 Operator？
  ├─ 是 → 轻量方案：pg_dump + CronJob（零常驻 Pod）
  │         见 postgresql-lightweight-backup-plan.md
  └─ 否 → 完整方案：pgBackRest + CronJob（支持 PITR）
            见 postgresql-pgbackrest-backup-plan.md
```

| 场景 | 推荐方案 | 常驻额外 Pod | RPO |
|------|----------|--------------|-----|
| 无 Operator、资源紧张、库 < 50GB | **轻量 pg_dump** | 0 | ≤ 24h |
| 有 PGO / 资源充足、需 PITR | pgBackRest（Operator） | 1+ | ≤ 15min |
| 无 Operator 但资源充足 | pgBackRest（独立 CronJob） | 0–1 | ≤ 15min |

## 文档索引

| 文档 | 说明 |
|------|------|
| [postgresql-lightweight-backup-plan.md](./postgresql-lightweight-backup-plan.md) | **轻量方案**：pg_dump + 单 CronJob + PVC |
| [postgresql-pgbackrest-backup-plan.md](./postgresql-pgbackrest-backup-plan.md) | 完整方案：pgBackRest 物理备份 + WAL |
| [restore-runbook.md](./restore-runbook.md) | pgBackRest 恢复 Runbook |
| [operations-checklist.md](./operations-checklist.md) | 运维检查清单与告警 |

## 示例 Manifest

| 文件 | 方案 |
|------|------|
| [manifests/backup-cronjob-pgdump.yaml](./manifests/backup-cronjob-pgdump.yaml) | **轻量** CronJob + PVC + Secret |
| [manifests/backup-restore-job-pgdump.yaml](./manifests/backup-restore-job-pgdump.yaml) | **轻量** 恢复演练 Job |
| [manifests/postgrescluster-backup.yaml](./manifests/postgrescluster-backup.yaml) | PGO Operator 备份配置 |
| [manifests/backup-cronjob-standalone.yaml](./manifests/backup-cronjob-standalone.yaml) | 独立 pgBackRest CronJob |
| [manifests/backup-repo-pvc.yaml](./manifests/backup-repo-pvc.yaml) | pgBackRest 本地 PVC |
| [manifests/backup-repo-s3-secret.yaml](./manifests/backup-repo-s3-secret.yaml) | S3/MinIO 凭证模板 |

## 环境占位符

| 占位符 | 示例值（TexHub） |
|--------|------------------|
| `NAMESPACE` | `reddwarf-storage` |
| `PG_SERVICE` | `reddwarf-postgresql.reddwarf-storage.svc.cluster.local` |
| `PG_DATABASE` | `tex` |
| `PG_VERSION` | `16` |
