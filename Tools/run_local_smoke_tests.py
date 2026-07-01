#!/usr/bin/env python3
"""Run local MobilePoseLab format smoke tests without iOS hardware."""

from __future__ import annotations

import csv
import json
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "Tools"
PYTHON = sys.executable

HEADER = [
    "session_id",
    "source",
    "device_type",
    "device_id",
    "placement",
    "packet_seq",
    "host_time_s",
    "device_time_s",
    "receive_time_s",
    "ax_m_s2",
    "ay_m_s2",
    "az_m_s2",
    "gx_rad_s",
    "gy_rad_s",
    "gz_rad_s",
    "gyro_available",
    "quat_x",
    "quat_y",
    "quat_z",
    "quat_w",
    "gravity_x_m_s2",
    "gravity_y_m_s2",
    "gravity_z_m_s2",
    "user_accel_x_m_s2",
    "user_accel_y_m_s2",
    "user_accel_z_m_s2",
    "raw_extra_json",
]


def run(cmd: list[str], *, check: bool = True, timeout: float = 20) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(cmd))
    result = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed with exit code {result.returncode}: {' '.join(cmd)}")
    return result


def make_sample_csv(path: Path) -> None:
    rows = []
    sources = [
        ("iPhone", "phone", "right", "rightPocket", (0.980665, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0)),
        ("appleWatch", "watch", "left", "leftWrist", (0.0, 0.980665, 0.0), (0.001, 0.002, 0.003, 0.99999)),
        ("airPods", "headphone", "left", "head", (0.0, 0.0, 0.980665), (0.004, 0.005, 0.006, 0.99990)),
    ]
    seq = 1
    for frame in range(3):
        host_time = 1000.0 + frame / 30.0
        for source, device_type, device_id, placement, accel, quat in sources:
            raw_extra = {
                "reference_frame": "headphoneDeviceMotion" if device_type == "headphone" else "xArbitraryCorrectedZVertical",
                "capture_phase": "recording",
                "gravity_calibration_samples": 90,
                "gravity_calibration_baseline_m_s2": {"x": 0.0, "y": -9.80665, "z": 0.0},
                "gravity_calibration_norm_m_s2": 9.80665,
            }
            rows.append({
                "session_id": "smoke-test-session",
                "source": source,
                "device_type": device_type,
                "device_id": device_id,
                "placement": placement,
                "packet_seq": str(seq),
                "host_time_s": f"{host_time:.6f}",
                "device_time_s": f"{host_time:.6f}",
                "receive_time_s": f"{host_time:.6f}",
                "ax_m_s2": f"{accel[0]:.6f}",
                "ay_m_s2": f"{accel[1]:.6f}",
                "az_m_s2": f"{accel[2]:.6f}",
                "gx_rad_s": "0.010000",
                "gy_rad_s": "0.020000",
                "gz_rad_s": "0.030000",
                "gyro_available": "1",
                "quat_x": f"{quat[0]:.6f}",
                "quat_y": f"{quat[1]:.6f}",
                "quat_z": f"{quat[2]:.6f}",
                "quat_w": f"{quat[3]:.6f}",
                "gravity_x_m_s2": "0.000000",
                "gravity_y_m_s2": "-9.806650",
                "gravity_z_m_s2": "0.000000",
                "user_accel_x_m_s2": f"{accel[0]:.6f}",
                "user_accel_y_m_s2": f"{accel[1]:.6f}",
                "user_accel_z_m_s2": f"{accel[2]:.6f}",
                "raw_extra_json": json.dumps(raw_extra, separators=(",", ":")),
            })
            seq += 1

    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER)
        writer.writeheader()
        writer.writerows(rows)


def run_adapter_smoke() -> None:
    cmd = [
        PYTHON,
        str(TOOLS / "mobileposer_live_demo_adapter.py"),
        "--listen-host",
        "127.0.0.1",
        "--listen-port",
        "18001",
        "--output-port",
        "17777",
        "--output-hz",
        "1000",
        "--dry-run",
        "--print-outgoing",
        "--max-packets",
        "3",
        "--summary-interval",
        "0.25",
    ]
    print("+ " + " ".join(cmd))
    proc = subprocess.Popen(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(0.5)
        packets = [
            "right;phone:1000.000000 1000.000000 0.980665 0.000000 0.000000 0.000000 0.000000 0.000000 1.000000 0.010000 0.020000 0.030000",
            "left;watch:1000.033333 1000.033333 0.000000 0.980665 0.000000 0.001000 0.002000 0.003000 0.999990 0.010000 0.020000 0.030000",
            "left;headphone:1000.066667 1000.066667 0.000000 0.000000 0.980665 0.004000 0.005000 0.006000 0.999900",
        ]
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            for packet in packets:
                sock.sendto(packet.encode("utf-8"), ("127.0.0.1", 18001))
                time.sleep(0.03)
        stdout, stderr = proc.communicate(timeout=5)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)

    if stdout:
        print(stdout, end="")
    if stderr:
        print(stderr, end="", file=sys.stderr)
    if proc.returncode != 0:
        raise RuntimeError(f"adapter smoke failed with exit code {proc.returncode}")
    if "received=3 forwarded=3 errors=0" not in stdout:
        raise RuntimeError("adapter smoke did not report received=3 forwarded=3 errors=0")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="mobileposelab-smoke-") as tmp_dir:
        csv_path = Path(tmp_dir) / "sample_mobile_pose_lab.csv"
        make_sample_csv(csv_path)
        print(f"sample CSV: {csv_path}")

        run([PYTHON, "-m", "py_compile", *map(str, sorted(TOOLS.glob("*.py")))])
        run([PYTHON, str(TOOLS / "validate_stream_csv.py"), str(csv_path), "--target-hz", "30", "--require", "phone,watch,headphone"])
        run([PYTHON, str(TOOLS / "check_mobileposer_packet_compat.py"), str(csv_path)])
        dry_run = run([PYTHON, str(TOOLS / "replay_csv_udp.py"), str(csv_path), "--dry-run", "--speed", "100"])
        if "right;phone:" not in dry_run.stdout or "left;watch:" not in dry_run.stdout or "left;headphone:" not in dry_run.stdout:
            raise RuntimeError("replay dry-run did not include expected official device IDs")
        live_demo_dry_run = run([PYTHON, str(TOOLS / "replay_csv_to_live_demo.py"), str(csv_path), "--dry-run", "--speed", "100", "--output-hz", "1000"])
        if "#" not in live_demo_dry_run.stdout or "$" not in live_demo_dry_run.stdout or "active_slots=1,2,3" not in live_demo_dry_run.stdout:
            raise RuntimeError("live_demo CSV replay dry-run did not emit expected aggregate packets")
        run_adapter_smoke()

    print("\nPASS: local MobilePoseLab smoke tests completed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 - command-line smoke runner should print concise failure.
        print(f"\nFAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
