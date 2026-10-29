#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

duration=${1:-1800}
interval=${SAMPLE_INTERVAL:-5}
case "$duration" in *[!0-9]*|'') echo "Usage: scripts/measure-resources.sh [seconds]" >&2; exit 64;; esac
case "$interval" in *[!0-9]*|''|0) echo "SAMPLE_INTERVAL must be a positive integer" >&2; exit 64;; esac

pid=$(pgrep -f '/Rationbook.app/Contents/MacOS/Rationbook$' | head -1 || true)
if [ -z "$pid" ]; then
    echo "Rationbook.app is not running." >&2
    exit 2
fi

samples=$((duration / interval))
if [ "$samples" -lt 1 ]; then samples=1; fi
temporary=$(mktemp)
trap '/bin/rm -f "$temporary"' EXIT

count=0
while [ "$count" -lt "$samples" ]; do
    if ! ps -p "$pid" -o %cpu=,rss= >> "$temporary"; then
        echo "Rationbook exited during measurement." >&2
        exit 2
    fi
    count=$((count + 1))
    if [ "$count" -lt "$samples" ]; then sleep "$interval"; fi
done

awk '
    { cpu += $1; if ($1 > max_cpu) max_cpu = $1; rss += $2; if ($2 > max_rss) max_rss = $2 }
    END {
        printf "samples=%d mean_cpu=%.3f%% max_cpu=%.3f%% mean_rss=%.1fMiB max_rss=%.1fMiB\n", NR, cpu/NR, max_cpu, rss/NR/1024, max_rss/1024
    }
' "$temporary"

median_cpu=$(awk '{ print $1 }' "$temporary" | sort -n | awk '
    { values[NR] = $1 }
    END {
        if (NR % 2) printf "%.3f", values[(NR + 1) / 2]
        else printf "%.3f", (values[NR / 2] + values[NR / 2 + 1]) / 2
    }
')
echo "median_cpu=${median_cpu}%"
