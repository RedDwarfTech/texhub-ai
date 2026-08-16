#!/usr/bin/env bash
#
# 备份 PostgreSQL 集群中每个数据库到独立 SQL 文件（macOS / Linux 通用）
#
# 用法:
#   ./shell/backup-postgres-databases.sh
#   BACKUP_DIR=./backups ./shell/backup-postgres-databases.sh
#   PGPASSWORD=secret ./shell/backup-postgres-databases.sh   # 免交互
#
# 从 macOS 连接 K8s 集群内服务时，需先建立端口转发，例如:
#   kubectl -n reddwarf-storage port-forward svc/pgbouncer 5432:5432
#   PGHOST=127.0.0.1 ./shell/backup-postgres-databases.sh

set -euo pipefail

PGHOST="${PGHOST:-pgbouncer.reddwarf-storage.svc.cluster.local}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-.}"
DATE="$(date +%Y%m%d)"

for cmd in pg_dump pg_dumpall psql; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "错误: 未找到 ${cmd}，请先安装 PostgreSQL 客户端工具。" >&2
    echo "macOS 示例: brew install libpq && brew link --force libpq" >&2
    exit 1
  fi
done

if [[ -z "${PGPASSWORD:-}" ]]; then
  read -r -s -p "PostgreSQL 密码 (${PGUSER}@${PGHOST}:${PGPORT}): " PGPASSWORD
  echo
  export PGPASSWORD
fi

mkdir -p "${BACKUP_DIR}"

echo "开始备份: host=${PGHOST} port=${PGPORT} user=${PGUSER} dir=${BACKUP_DIR}"

# 角色、表空间等全局对象（pg_dump 不包含这些内容）
GLOBALS_FILE="${BACKUP_DIR}/globals-${DATE}.sql"
echo "导出全局对象 -> ${GLOBALS_FILE}"
pg_dumpall \
  -h "${PGHOST}" \
  -p "${PGPORT}" \
  -U "${PGUSER}" \
  --globals-only \
  --no-role-passwords \
  > "${GLOBALS_FILE}"

# 列出所有非模板库
DATABASES=()
while IFS= read -r db; do
  [[ -n "${db}" ]] && DATABASES+=("${db}")
done < <(
  psql \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${PGUSER}" \
    -d postgres \
    -At \
    -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"
)

if [[ "${#DATABASES[@]}" -eq 0 ]]; then
  echo "错误: 未找到可备份的数据库。" >&2
  exit 1
fi

for db in "${DATABASES[@]}"; do
  outfile="${BACKUP_DIR}/${db}-${DATE}.sql"
  echo "导出数据库 ${db} -> ${outfile}"
  pg_dump \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${PGUSER}" \
    -d "${db}" \
    --no-owner \
    --no-acl \
    > "${outfile}"
done

echo
echo "备份完成，共 ${#DATABASES[@]} 个数据库 + 1 个全局对象文件:"
ls -lh "${GLOBALS_FILE}" "${BACKUP_DIR}"/*-"${DATE}".sql
