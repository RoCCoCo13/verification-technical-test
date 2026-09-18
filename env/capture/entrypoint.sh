#!/bin/sh
# Continuous capture in the network namespace of the attached service.
# One file per ROTATE_SECONDS, named <PREFIX>_YYYYmmdd_HHMMSS.pcap under /traces/pcap/live.
set -e
PREFIX="${CAPTURE_PREFIX:-live}"
ROTATE="${ROTATE_SECONDS:-120}"
FILTER="${CAPTURE_FILTER:-tcp and not port 5555}"
mkdir -p /traces/pcap/live
echo "[capture] prefix=$PREFIX rotate=${ROTATE}s filter='$FILTER'"
exec tcpdump -i any -nn -U -s 0 -Z root -G "$ROTATE" -w "/traces/pcap/live/${PREFIX}_%Y%m%d_%H%M%S.pcap" $FILTER
