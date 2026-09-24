#!/bin/bash
# minikube driver probe benchmark (macOS).
#
# Same method as the Windows / WSL runs:
#   steady state: RUNS x `minikube start --no-kubernetes --dry-run`, engine already up
#   cold start:   CYCLES x (quit Docker Desktop -> start it -> wait until `docker version`
#                 answers -> PROBES consecutive probes)
# Timings come from minikube's "<driver> probed in" log lines. Percentiles are nearest-rank.
#
# Usage:   ./probe-bench-macos.sh [path/to/minikube]      (default: ./out/minikube)
# Env:     RUNS=20 CYCLES=20 PROBES=5 SKIP_COLD=1 OUT=<dir>
#          SUMMARY_ONLY=1 OUT=<dir>   re-print the summary for an earlier run
#
# Uses a throwaway MINIKUBE_HOME, so existing clusters in ~/.minikube are not touched.
# The cold-start phase restarts Docker Desktop CYCLES times: running containers will stop.

set -u
MK=${1:-./out/minikube}
RUNS=${RUNS:-20}
CYCLES=${CYCLES:-20}
PROBES=${PROBES:-5}
OUT=${OUT:-probe-results-$(date +%Y%m%d-%H%M%S)}

# "<driver> probed in 1.23s: ..." -> milliseconds (handles ns/µs/ms/s).
to_ms() {
  sed -E 's/.*probed in ([0-9.]+)([^0-9.: ]+).*/\1 \2/' |
    awk '{v=$1; u=$2; if (u=="ms") ; else if (u=="s") v*=1000; else if (u=="ns") v/=1000000; else v/=1000; printf "%.3f\n", v}'
}

# stdin: one ms value per line.
stats() {
  sort -n | awk -v l="$1" '{a[NR]=$1; s+=$1}
    END {
      if (NR == 0) { printf "%-32s n=0\n", l; exit }
      r = int(NR*0.95); if (r < NR*0.95) r++
      m = int(NR*0.5);  if (m < NR*0.5)  m++
      printf "%-32s n=%-3d avg=%8.1f  p50=%8.1f  p95=%8.1f  slowest=%8.1f ms\n", l, NR, s/NR, a[m], a[r], a[NR]
    }'
}

health() { grep -o 'Healthy:[a-z]*' | sort | uniq -c | awk '{printf "%s %s  ", $1, $2}'; }

summary() {
  echo
  echo "================ RESULTS ================"
  if [ -s "$OUT/steady.log" ]; then
    echo "Steady state ($(grep -c '] docker probed in' "$OUT/steady.log") runs):"
    for d in docker podman; do
      grep "] $d probed in" "$OUT/steady.log" | to_ms | stats "  $d"
      echo "      health: $(grep "] $d probed in" "$OUT/steady.log" | health)"
    done
  fi
  if [ -s "$OUT/coldstart.log" ]; then
    echo "Docker cold start ($(grep -c 'engine ready' "$OUT/coldstart.log") cycles x $PROBES probes):"
    grep ' run 1: [0-9]' "$OUT/coldstart.log" | awk '{print $5}' | stats "  1st probe after start"
    grep ' run [0-9]*: [0-9]' "$OUT/coldstart.log" | grep -v ' run 1: ' | awk '{print $5}' | stats "  probes 2-$PROBES"
    grep ' run [0-9]*: [0-9]' "$OUT/coldstart.log" | awk '{print $5}' | stats "  all probes"
    echo "      healthy: $(grep -c 'healthy=true' "$OUT/coldstart.log") / $(grep -c ' run ' "$OUT/coldstart.log")"
    echo "      engine ready after: $(grep -o 'after [0-9]*s' "$OUT/coldstart.log" | awk '{print $2}' | sort | uniq -c | awk '{printf "%sx %s  ", $1, $2}')"
  fi
  echo
  echo "================ MACHINE ================"
  [ -f "$OUT/specs.txt" ] && cat "$OUT/specs.txt"
  echo
  echo "Raw logs: $OUT/"
}

if [ -n "${SUMMARY_ONLY:-}" ]; then summary; exit 0; fi

[ -x "$MK" ] || { echo "minikube binary not found at $MK (build it with: make)"; exit 1; }
mkdir -p "$OUT"
export MINIKUBE_HOME
MINIKUBE_HOME=$(mktemp -d)
trap 'rm -rf "$MINIKUBE_HOME"' EXIT

probe_all() { "$MK" start --no-kubernetes --dry-run --logtostderr 2>&1 | grep 'probed in'; }

dd_start() { docker desktop start >/dev/null 2>&1 || open -a Docker; }
dd_stop() {
  docker desktop stop >/dev/null 2>&1 || osascript -e 'quit app "Docker"' >/dev/null 2>&1
  while docker version --format '{{.Server.Version}}' >/dev/null 2>&1; do sleep 1; done
}
wait_ready() {
  local t=0
  until docker version --format '{{.Server.Version}}' >/dev/null 2>&1; do
    sleep 1; t=$((t+1)); [ $t -ge 300 ] && return 1
  done
}

# ---- specs (captured up front, engine state as found) ----
{
  echo "Model:     $(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name|Model Identifier/{printf "%s ", $2}')"
  echo "CPU:       $(sysctl -n machdep.cpu.brand_string) ($(sysctl -n hw.physicalcpu) cores / $(sysctl -n hw.logicalcpu) threads)"
  echo "RAM:       $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
  echo "macOS:     $(sw_vers -productVersion) (build $(sw_vers -buildVersion)), $(uname -m)"
  echo "Power:     $(pmset -g batt 2>/dev/null | head -1 | sed "s/Now drawing from //; s/'//g")"
  echo "minikube:  $("$MK" version 2>/dev/null | tr '\n' ' ')"
  echo "Docker:    $(docker version --format 'client {{.Client.Version}}, server {{.Server.Version}} ({{.Server.Platform.Name}})' 2>/dev/null || echo 'not reachable')"
  echo "Docker VM: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes RAM, {{.OperatingSystem}}' 2>/dev/null || echo 'n/a')"
  if ! command -v podman >/dev/null; then
    echo "Podman:    not installed"
  elif pv=$(podman version --format 'client {{.Client.Version}}, server {{.Server.Version}}' 2>/dev/null); then
    echo "Podman:    $pv"
  else
    echo "Podman:    $(podman --version), engine not reachable"
  fi
  echo "Shell:     $BASH_VERSION"
} > "$OUT/specs.txt"

echo "Results dir: $OUT   (MINIKUBE_HOME=$MINIKUBE_HOME)"

# ---- steady state ----
if ! docker version >/dev/null 2>&1; then
  echo "Docker engine not reachable; starting Docker Desktop first..."
  dd_start; wait_ready || { echo "Docker did not come up"; exit 1; }
  sleep 30
fi
echo "Steady state: $RUNS runs..."
: > "$OUT/steady.log"
for i in $(seq "$RUNS"); do
  probe_all >> "$OUT/steady.log"
  printf '.'
done
echo

# ---- cold start ----
if [ -z "${SKIP_COLD:-}" ]; then
  echo "Cold start: $CYCLES cycles x $PROBES probes (restarts Docker Desktop each cycle)..."
  : > "$OUT/coldstart.log"
  for c in $(seq "$CYCLES"); do
    dd_stop
    sleep 5
    t0=$(date +%s)
    dd_start
    wait_ready || { echo "cycle $c: engine never came up" | tee -a "$OUT/coldstart.log"; continue; }
    echo "cycle $c: engine ready after $(( $(date +%s) - t0 ))s" >> "$OUT/coldstart.log"
    for r in $(seq "$PROBES"); do
      line=$(probe_all | grep '] docker probed in')
      if [ -z "$line" ]; then
        echo "cycle $c run $r: NA" >> "$OUT/coldstart.log"
      else
        echo "cycle $c run $r: $(echo "$line" | to_ms) healthy=$(echo "$line" | grep -o 'Healthy:[a-z]*' | cut -d: -f2)" >> "$OUT/coldstart.log"
      fi
    done
    printf 'cycle %s/%s done\n' "$c" "$CYCLES"
  done
fi

summary
