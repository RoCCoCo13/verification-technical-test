#!/bin/sh
set -e
mkdir -p /data/log/dlt /data/misc/telematics /data/vendor/vhal /data/property /sdcard/Download /data/local/tmp
: > /data/log/logcat.log
cp -n /vendor/etc/calibration/tcu_cal.json /data/local/tmp/tcu_cal.effective.json 2>/dev/null || true
echo "$(date '+%m-%d %H:%M:%S.000')     1     1 I init    : bench image boot, sw=$(getprop ro.oem.tcu.sw_version)" >> /data/log/logcat.log
python3 /opt/tcu/adbd.py &
exec python3 /opt/tcu/gateway.py
