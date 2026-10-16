# Tee stdout/stderr to logs/srk-*.log once per process tree.
# Source after REPO_ROOT is set. Nested scripts inherit SRK_LOG_FILE and skip.
#
# shellcheck shell=bash

if [[ -z "${SRK_LOG_FILE:-}" ]]; then
  if [[ -z "${REPO_ROOT:-}" ]]; then
    echo "log_tee.sh: REPO_ROOT must be set before sourcing" >&2
    return 1 2>/dev/null || exit 1
  fi
  mkdir -p "$REPO_ROOT/logs"
  export SRK_LOG_FILE="$REPO_ROOT/logs/srk-$(date +'%Y%m%d-%H%M%S').log"
  # Process substitution keeps the console live while appending to the file.
  exec > >(tee -a "$SRK_LOG_FILE") 2>&1
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Logging to $SRK_LOG_FILE"
fi
