#!/usr/bin/env bash
# How this Steady server is coping, in a few lines: speed, errors, database, disk, memory.
#   ./health.sh             the last 15 minutes, hour and day
#   ./health.sh --json      everything, as JSON (what a central dashboard reads)
#   watch -n 30 ./health.sh keep it on screen
# Uses STEADY_MONITOR_KEY from .env (gen-keys.sh makes one).
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
KEY="$(grep -E '^STEADY_MONITOR_KEY=' .env 2>/dev/null | cut -d= -f2- || true)"
[ -n "$KEY" ] || { echo "Set STEADY_MONITOR_KEY in deploy/.env first (./gen-keys.sh prints one), then: docker compose up -d" >&2; exit 1; }
JSON="$(docker compose exec -T pocketbase wget -qO- --header "X-Steady-Monitor: $KEY" "http://127.0.0.1:8090/api/steady/health?hours=24")" \
  || { echo "The server didn't answer. Check: docker compose ps" >&2; exit 1; }
if [ "${1:-}" = "--json" ]; then echo "$JSON"; exit 0; fi
command -v jq >/dev/null || { echo "$JSON"; exit 0; }
echo "$JSON" | jq -r '
  def ms: if . == null then "-" else "\(.) ms" end;
  def gb: (. / 1073741824 * 10 | round / 10 | tostring) + " GB";
  def mb: (. / 1048576 * 10 | round / 10 | tostring) + " MB";
  def win(w; name): "\(name): \(w.requests) requests, 95% within \(w.p95 | ms), slowest \(w.max | ms), database check \(w.probeMedian | ms), \(w.errors) errors";
  "Steady health: \(.health.status | ascii_upcase)" + (if (.health.reasons | length) > 0 then " (" + (.health.reasons | join("; ")) + ")" else "" end),
  "",
  win(.windows.last15m; "Last 15 min"),
  win(.windows.lastHour; "Last hour  "),
  win(.windows.last24h; "Last day   "),
  "",
  "Database: \(.database.bytes | mb)   Patients: \(.counts.patients)   Staff: \(.counts.staff)   Up: \((.uptimeSeconds // 0) / 3600 | floor) h   Code: \(.code)",
  (if .host then "Disk: \(.host.disk.used | gb) of \(.host.disk.total | gb)   Memory free: \(.host.memory.available | mb) of \(.host.memory.total | mb)   Load: \(.host.load | map(tostring) | join(" ")) on \(.host.cpus) cores" else "Disk and memory: run sudo ./ctl/install.sh to record them" end),
  (if (.windows.last24h.slow | length) > 0 then "\nSlowest kinds of request today:" else empty end),
  (.windows.last24h.slow[] | "  \(.worstMs) ms  \(.route)")'
