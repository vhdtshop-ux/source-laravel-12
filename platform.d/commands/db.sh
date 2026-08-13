#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../lib/common.sh"
ensure_project

show_help() {
cat <<'EOF'
USAGE
  ./platform-cli db <command> [arguments]

COMMANDS
  status
  shell
  export [file.sql]
  backup [file.sql.gz]
  import <file.sql|file.sql.gz>
  restore <file.sql|file.sql.gz>

EXAMPLES
  ./platform-cli db status
  ./platform-cli db shell
  ./platform-cli db export
  ./platform-cli db backup
  ./platform-cli db import /opt/nvh/db_nvh.sql
EOF
}

DB_HOST="$(read_env_value DB_HOST "$LARAVEL_ENV" || true)"
DB_PORT="$(read_env_value DB_PORT "$LARAVEL_ENV" || true)"
DB_DATABASE="$(read_env_value DB_DATABASE "$LARAVEL_ENV" || true)"
DB_USERNAME="$(read_env_value DB_USERNAME "$LARAVEL_ENV" || true)"
DB_PASSWORD="$(read_env_value DB_PASSWORD "$LARAVEL_ENV" || true)"
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
[[ -n "$DB_DATABASE" ]] || die "Thiếu DB_DATABASE"
[[ -n "$DB_USERNAME" ]] || die "Thiếu DB_USERNAME"

detect_client() {
  if compose_cmd exec -T db sh -lc 'command -v mariadb' >/dev/null 2>&1; then echo mariadb
  elif compose_cmd exec -T db sh -lc 'command -v mysql' >/dev/null 2>&1; then echo mysql
  else die "Container db không có mariadb/mysql client"
  fi
}

detect_dump() {
  if compose_cmd exec -T db sh -lc 'command -v mariadb-dump' >/dev/null 2>&1; then echo mariadb-dump
  elif compose_cmd exec -T db sh -lc 'command -v mysqldump' >/dev/null 2>&1; then echo mysqldump
  else return 1
  fi
}

db_exec() {
  local client="$1"; shift
  compose_cmd exec -T -e MYSQL_PWD="$DB_PASSWORD" db "$client" -u "$DB_USERNAME" "$@"
}

db_container_network() {
  command -v docker >/dev/null 2>&1 || die "Thiếu docker cho database dump fallback"

  local cid network
  cid="$(compose_cmd ps -q db 2>/dev/null | head -n1)"
  [[ -n "$cid" ]] || die "Không tìm thấy container db đang chạy"

  network="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$cid" 2>/dev/null | head -n1)"
  [[ -n "$network" ]] || die "Không xác định được Docker network của container db"
  printf '%s' "$network"
}

db_dump_fallback() {
  local network image
  network="$(db_container_network)"
  image="${DB_DUMP_FALLBACK_IMAGE:-mariadb:11}"

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    warn "Không có dump client trong container db. Đang pull fallback image: $image"
    docker pull "$image" >/dev/null
  else
    warn "Không có dump client trong container db. Dùng fallback image: $image"
  fi

  docker run --rm \
    --network "$network" \
    -e MYSQL_PWD="$DB_PASSWORD" \
    "$image" \
    mariadb-dump \
      -h "$DB_HOST" \
      -P "$DB_PORT" \
      -u "$DB_USERNAME" \
      --single-transaction \
      --quick \
      --routines \
      --triggers \
      --events \
      "$DB_DATABASE"
}

db_export_to_file() {
  local out="$1" dump=""

  rm -f "$out"
  if dump="$(detect_dump)"; then
    compose_cmd exec -T -e MYSQL_PWD="$DB_PASSWORD" db "$dump" \
      -u "$DB_USERNAME" \
      --single-transaction \
      --quick \
      --routines \
      --triggers \
      --events \
      "$DB_DATABASE" > "$out"
  else
    db_dump_fallback > "$out"
  fi

  if [[ ! -s "$out" ]]; then
    rm -f "$out"
    die "Database dump rỗng."
  fi
}

command="${1:-help}"
shift || true
case "$command" in
  help|-h|--help) show_help ;;
  status)
    CLIENT="$(detect_client)"
    echo "Database : $DB_DATABASE"
    echo "User     : $DB_USERNAME"
    TABLES="$(db_exec "$CLIENT" -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_DATABASE}';" "$DB_DATABASE")"
    SIZE="$(db_exec "$CLIENT" -Nse "SELECT ROUND(COALESCE(SUM(data_length+index_length),0)/1024/1024,2) FROM information_schema.tables WHERE table_schema='${DB_DATABASE}';" "$DB_DATABASE")"
    echo "Tables   : $TABLES"
    echo "Size MB  : $SIZE"
    ;;
  shell)
    CLIENT="$(detect_client)"
    exec env PROJECT_DIR="$PROJECT_DIR" "$CENTRAL_PLATFORM_DIR/scripts/compose.sh" exec -e MYSQL_PWD="$DB_PASSWORD" db "$CLIENT" -u "$DB_USERNAME" "$DB_DATABASE"
    ;;
  export)
    OUT="${1:-$PROJECT_DIR/backup/database/${DB_DATABASE}_$(date +%Y%m%d_%H%M%S).sql}"
    [[ "$OUT" = /* ]] || OUT="$PROJECT_DIR/$OUT"
    mkdir -p "$(dirname "$OUT")"
    db_export_to_file "$OUT"
    success "Đã export: $OUT"
    ;;
  backup)
    OUT="${1:-$PROJECT_DIR/backup/database/${DB_DATABASE}_$(date +%Y%m%d_%H%M%S).sql.gz}"
    [[ "$OUT" = /* ]] || OUT="$PROJECT_DIR/$OUT"
    mkdir -p "$(dirname "$OUT")"
    TMP="${OUT%.gz}.tmp.$$.sql"
    trap 'rm -f "$TMP"' EXIT
    db_export_to_file "$TMP"
    gzip -c "$TMP" > "$OUT"
    [[ -s "$OUT" ]] || die "Database backup gzip rỗng."
    rm -f "$TMP"
    trap - EXIT
    success "Đã backup: $OUT"
    ;;
  import|restore)
    FILE="${1:-}"
    [[ -n "$FILE" ]] || die "Thiếu file import"
    [[ "$FILE" = /* ]] || FILE="$PROJECT_DIR/$FILE"
    [[ -f "$FILE" ]] || die "Không thấy file: $FILE"
    echo "Database đích: $DB_DATABASE"
    echo "File import  : $FILE"
    confirm "Import sẽ thay đổi dữ liệu. Tiếp tục?" || die "Đã hủy"
    CLIENT="$(detect_client)"
    case "$FILE" in
      *.sql) db_exec "$CLIENT" "$DB_DATABASE" < "$FILE" ;;
      *.sql.gz|*.gz) gzip -dc "$FILE" | db_exec "$CLIENT" "$DB_DATABASE" ;;
      *) die "Chỉ hỗ trợ .sql hoặc .sql.gz" ;;
    esac
    success "Import thành công vào $DB_DATABASE"
    ;;
  *) error "DB command không hợp lệ: $command"; show_help; exit 1 ;;
esac
