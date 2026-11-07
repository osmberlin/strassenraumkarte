#!/usr/bin/env bash
# Performance audit helpers for Straßenraumkarte.
# Active when PERF_AUDIT_DIR is set to an existing or creatable directory.
# No-op otherwise — safe to source from all pipeline scripts.

# shellcheck disable=SC2034

# Resolve this file's directory (bash when sourced; also works when executed).
_AUDIT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ ! -f "$_AUDIT_LIB_DIR/record.py" ]]; then
  # Fallback: repo/audit next to common callers
  for _cand in \
    "$(pwd)/audit" \
    "$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." 2>/dev/null && pwd)/audit"
  do
    if [[ -f "$_cand/record.py" ]]; then
      _AUDIT_LIB_DIR="$_cand"
      break
    fi
  done
fi
unset _cand

perf_enabled() {
  [[ -n "${PERF_AUDIT_DIR:-}" ]]
}

perf_now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

perf_init() {
  perf_enabled || return 0
  mkdir -p "$PERF_AUDIT_DIR"
  export PERF_AUDIT_DIR
  python3 "$_AUDIT_LIB_DIR/record.py" init \
    --dir "$PERF_AUDIT_DIR" \
    --label "${PERF_AUDIT_LABEL:-}" \
    --extra "${PERF_AUDIT_EXTRA_JSON:-{}}"
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Performance audit → $PERF_AUDIT_DIR"
}

perf_finish() {
  local run_status="${1:-ok}"
  perf_enabled || return 0
  python3 "$_AUDIT_LIB_DIR/record.py" finish \
    --dir "$PERF_AUDIT_DIR" \
    --status "$run_status"
}

# Record a timed step. Usage:
#   perf_step <name> <phase> [--] <command> [args...]
#   perf_step <name> <phase> --detail '{"label":"..."}' -- <command>...
perf_step() {
  local name="$1"
  local phase="$2"
  shift 2
  local detail="{}"
  if [[ "${1:-}" == "--detail" ]]; then
    detail="$2"
    shift 2
  fi
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi

  if ! perf_enabled; then
    "$@"
    return $?
  fi

  local start end rc
  local had_errexit=0
  [[ $- == *e* ]] && had_errexit=1
  start=$(perf_now_ms)
  set +e
  "$@"
  rc=$?
  if [[ "$had_errexit" -eq 1 ]]; then
    set -e
  fi
  end=$(perf_now_ms)

  python3 "$_AUDIT_LIB_DIR/record.py" step \
    --dir "$PERF_AUDIT_DIR" \
    --name "$name" \
    --phase "$phase" \
    --start-ms "$start" \
    --end-ms "$end" \
    --status "$([[ $rc -eq 0 ]] && echo ok || echo fail)" \
    --detail "$detail" \
    --exit-code "$rc"

  return "$rc"
}

# Record a note / snapshot without timing a command.
perf_note() {
  local name="$1"
  local phase="$2"
  local detail="${3:-{}}"
  perf_enabled || return 0
  python3 "$_AUDIT_LIB_DIR/record.py" step \
    --dir "$PERF_AUDIT_DIR" \
    --name "$name" \
    --phase "$phase" \
    --start-ms "$(perf_now_ms)" \
    --end-ms "$(perf_now_ms)" \
    --status "note" \
    --detail "$detail" \
    --exit-code 0
}
