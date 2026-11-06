#!/usr/bin/env python3
"""Measures one running process with proc_pid_rusage, the counters Activity Monitor uses.

    measure.py sample --pid PID --label NAME --warmup 10 --duration 60 --out result.json
    measure.py report result1.json result2.json ... > report.md

Memory is the physical footprint (Activity Monitor's "Memory" column), which also counts
GPU/IOSurface memory the window server holds for the app; RSS is shown for reference.
CPU is CPU time over wall time (100% = one core). Wakeups are idle + interrupt wakeups
per second, a proxy for energy use. Instructions and cycles come from the same counters.
"""

import argparse
import ctypes
import json
import os
import statistics
import sys
import time

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)

U64 = ctypes.c_uint64


class RusageInfoV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (name, U64)
        for name in (
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
            "wired_size", "resident_size", "phys_footprint", "proc_start_abstime",
            "proc_exit_abstime", "child_user_time", "child_system_time",
            "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins",
            "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten",
            "cpu_time_qos_default", "cpu_time_qos_maintenance", "cpu_time_qos_background",
            "cpu_time_qos_utility", "cpu_time_qos_legacy", "cpu_time_qos_user_initiated",
            "cpu_time_qos_user_interactive", "billed_system_time", "serviced_system_time",
            "logical_writes", "lifetime_max_phys_footprint", "instructions", "cycles",
            "billed_energy", "serviced_energy", "interval_max_phys_footprint", "runnable_time",
        )
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


RUSAGE_INFO_V4 = 4
libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
_timebase = Timebase()
libc.mach_timebase_info(ctypes.byref(_timebase))
TICKS_TO_NS = _timebase.numer / _timebase.denom


def rusage(pid):
    info = RusageInfoV4()
    if libc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(info)) != 0:
        raise OSError(ctypes.get_errno(), f"proc_pid_rusage({pid}) failed")
    return info


def snapshot(pid):
    info = rusage(pid)
    return {
        "time": time.monotonic(),
        "cpu_ns": (info.user_time + info.system_time) * TICKS_TO_NS,
        "wakeups": info.pkg_idle_wkups + info.interrupt_wkups,
        "instructions": info.instructions,
        "cycles": info.cycles,
        "footprint": info.phys_footprint,
        "resident": info.resident_size,
        "peak_footprint": info.lifetime_max_phys_footprint,
    }


def sample(args):
    pid = args.pid
    time.sleep(args.warmup)
    start = snapshot(pid)
    footprints, residents, cpu = [], [], []
    previous = start
    for _ in range(int(args.duration)):
        time.sleep(1)
        current = snapshot(pid)
        footprints.append(current["footprint"])
        residents.append(current["resident"])
        elapsed = current["time"] - previous["time"]
        cpu.append((current["cpu_ns"] - previous["cpu_ns"]) / (elapsed * 1e9) * 100)
        previous = current
    end = previous
    wall = end["time"] - start["time"]
    mb = 1024 * 1024
    result = {
        "label": args.label,
        "pid": pid,
        "seconds": round(wall, 1),
        "footprint_mb_mean": round(statistics.mean(footprints) / mb, 1),
        "footprint_mb_max": round(max(footprints) / mb, 1),
        "footprint_mb_end": round(footprints[-1] / mb, 1),
        "peak_footprint_mb": round(end["peak_footprint"] / mb, 1),
        "resident_mb_mean": round(statistics.mean(residents) / mb, 1),
        "cpu_percent_mean": round((end["cpu_ns"] - start["cpu_ns"]) / (wall * 1e9) * 100, 2),
        "cpu_percent_max": round(max(cpu), 2),
        "wakeups_per_second": round((end["wakeups"] - start["wakeups"]) / wall, 1),
        "instructions_per_second_m": round((end["instructions"] - start["instructions"]) / wall / 1e6, 1),
        "cycles_per_second_m": round((end["cycles"] - start["cycles"]) / wall / 1e6, 1),
    }
    with open(args.out, "w") as f:
        json.dump(result, f, indent=2)
    print(json.dumps(result))


COLUMNS = [
    ("footprint_mb_mean", "Memory (footprint, mean MB)"),
    ("footprint_mb_max", "Memory (footprint, max MB)"),
    ("peak_footprint_mb", "Lifetime peak footprint (MB)"),
    ("resident_mb_mean", "RSS (mean MB)"),
    ("cpu_percent_mean", "CPU (mean %, 100 = 1 core)"),
    ("cpu_percent_max", "CPU (max 1 s %)"),
    ("wakeups_per_second", "Wakeups / s"),
    ("instructions_per_second_m", "Instructions / s (M)"),
    ("cycles_per_second_m", "Cycles / s (M)"),
]


def report(args):
    results = []
    for path in args.files:
        with open(path) as f:
            results.append(json.load(f))
    labels = [r["label"] for r in results]
    print("| Metric | " + " | ".join(labels) + " |")
    print("| --- | " + " | ".join("---:" for _ in labels) + " |")
    for key, title in COLUMNS:
        print(f"| {title} | " + " | ".join(str(r.get(key, "")) for r in results) + " |")
    if args.sizes:
        print()
        print("| Binary | Size (MB) |")
        print("| --- | ---: |")
        for path in args.sizes:
            print(f"| `{os.path.basename(path)}` | {os.path.getsize(path) / 1024 / 1024:.1f} |")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    s = commands.add_parser("sample")
    s.add_argument("--pid", type=int, required=True)
    s.add_argument("--label", required=True)
    s.add_argument("--warmup", type=float, default=10)
    s.add_argument("--duration", type=float, default=60)
    s.add_argument("--out", required=True)
    r = commands.add_parser("report")
    r.add_argument("files", nargs="+")
    r.add_argument("--sizes", nargs="*", default=[])
    args = parser.parse_args()
    {"sample": sample, "report": report}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
