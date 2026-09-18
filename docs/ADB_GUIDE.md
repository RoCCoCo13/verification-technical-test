# ADB Guide - gateway ECU (TCU-GW-2)

The gateway exposes an ADB daemon over TCP. It is not a full Android system: it is a Linux
container with an Android-like filesystem layout and the Android tools a validation engineer
uses daily (`getprop`, `dumpsys`, `logcat`, `am`, `pm`). Standard Linux tools (`ls`, `cat`,
`grep`, `tail`, `ps`, `ip`, `curl`) are available too.

```bash
adb connect localhost:5555            # or ecu-gateway:5555 from inside the toolbox container
adb devices -l                        # ecu-gateway:5555 device product:aaos_tcu_gw2 model:TCU_GW_2
adb -s localhost:5555 shell           # interactive shell (prompt: tcu_gw2:/ #)
```

If you have several devices (emulator, phone), always pass `-s localhost:5555`.

## Inspection

| Task | Command |
|---|---|
| Build / software version | `adb shell getprop ro.build.fingerprint`, `getprop ro.oem.tcu.sw_version` |
| Services running | `adb shell getprop init.svc.telematics`, `adb shell service list` |
| VHAL properties (what the head unit shows) | `adb shell dumpsys vehicle` or `adb shell cat /data/vendor/vhal/props.json` |
| Telematics service status | `adb shell dumpsys telematics` |
| Commands received by the vehicle | `adb shell cat /data/misc/telematics/command_journal.jsonl` |
| Calibration in use | `adb shell cat /vendor/etc/calibration/tcu_cal.json` |
| Release notes / known issues | `adb shell cat /vendor/etc/release_notes.txt` |
| Android log | `adb shell logcat -d`, `adb shell logcat -d TelematicsSvc:I '*:S'`, `adb logcat` (follow) |
| Gateway DLT log | `adb shell tail -f /data/log/dlt/tcu.dlt`, `adb pull /data/log/dlt/tcu.dlt` |
| Network | `adb shell ip addr`, `adb shell curl -s http://127.0.0.1:8081/telematics/state` |
| Push a helper script | `adb push myscript.sh /data/local/tmp/ && adb shell sh /data/local/tmp/myscript.sh` |

## Notes and limitations

* `adb root` and `adb remount` answer like a userdebug build (already root). `adb reboot` is ignored;
  use `docker compose restart ecu-gateway`.
* The shell is a POSIX `sh` without shell-v2 framing, so exit codes are not propagated to the adb client
  (as on old devices). Print `$?` if you need it.
* `am`, `pm`, `settings` are stubs that behave plausibly and leave a trace in `logcat`.
* Everything under `/data` is writable and persists until `docker compose down`.

## In Robot Framework

There is no official ADB library needed: a thin Python library around `subprocess` (`adb -s <serial>
shell ...`) or Robot's `Process` library is enough. Keep the serial in a variable file so the same
suite runs on your host (`127.0.0.1:5555`) and in the toolbox/CI (`ecu-gateway:5555`).
