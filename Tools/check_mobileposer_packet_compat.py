#!/usr/bin/env python3
"""Check MobilePoseLab UDP packets against SPICExLAB/MobilePoser naming rules.

The official SPICExLAB/MobilePoser `sensor_utils.process_data` builds a lookup key
like this:

    f"{device_id.capitalize()}_{device_type}"

For example:

    right;phone:...      -> Right_phone
    left;watch:...       -> Left_watch
    left;headphone:...   -> Left_headphone

This checker catches packets that are syntactically valid but would fail the
official receiver's device lookup.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


OFFICIAL_DEVICE_KEYS = {
    "Left_phone",
    "Left_watch",
    "Left_headphone",
    "Right_phone",
    "Right_watch",
}


def parse_packet(packet: str) -> tuple[str, str, list[float]]:
    packet = packet.strip()
    if ";" not in packet or ":" not in packet:
        raise ValueError("packet must contain ';' and ':'")

    device_id, rest = packet.split(";", 1)
    device_type, values = rest.split(":", 1)
    numbers = [float(value) for value in values.split()]
    if len(numbers) not in (9, 12):
        raise ValueError(f"expected 9 or 12 numeric values, got {len(numbers)}")
    if device_type not in {"phone", "watch", "headphone"}:
        raise ValueError(f"unsupported device_type: {device_type}")
    return device_id, device_type, numbers


def official_key(device_id: str, device_type: str) -> str:
    return f"{device_id.capitalize()}_{device_type}"


def check_packet(packet: str) -> tuple[bool, str]:
    device_id, device_type, numbers = parse_packet(packet)
    key = official_key(device_id, device_type)
    if key not in OFFICIAL_DEVICE_KEYS:
        return (
            False,
            f"{key} is not in SPICExLAB/MobilePoser sensor.device_ids; "
            "use device_id 'left' or 'right' for the official receiver.",
        )

    acceleration = numbers[2:5]
    max_abs_acc = max(abs(value) for value in acceleration)
    unit_note = ""
    if max_abs_acc > 4:
        unit_note = (
            " Warning: acceleration magnitude looks like m/s^2. "
            "The official live_demo path multiplies received acceleration by -9.8, "
            "so a stock receiver may expect g-like units unless patched."
        )
    return True, f"{key} is accepted by official naming rules.{unit_note}"


def packet_from_csv_row(row: dict[str, str]) -> str:
    device_id = row["device_id"]
    device_type = row["device_type"]
    values = [
        row["host_time_s"],
        row["device_time_s"],
        row["ax_m_s2"],
        row["ay_m_s2"],
        row["az_m_s2"],
        row["quat_x"],
        row["quat_y"],
        row["quat_z"],
        row["quat_w"],
    ]
    if row.get("gyro_available") == "1":
        values.extend([row["gx_rad_s"], row["gy_rad_s"], row["gz_rad_s"]])
    return f"{device_id};{device_type}:{' '.join(values)}"


def iter_packets_from_csv(path: Path, limit: int) -> list[str]:
    packets: list[str] = []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        required = {"device_id", "device_type", "host_time_s", "device_time_s", "ax_m_s2", "ay_m_s2", "az_m_s2", "quat_x", "quat_y", "quat_z", "quat_w"}
        missing = required.difference(reader.fieldnames or [])
        if missing:
            raise ValueError(f"CSV is missing required columns: {', '.join(sorted(missing))}")
        for row in reader:
            packets.append(packet_from_csv_row(row))
            if len(packets) >= limit:
                break
    return packets


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="UDP packet string or current-schema MobilePoseLab CSV path")
    parser.add_argument("--limit", type=int, default=20, help="maximum CSV rows to check")
    args = parser.parse_args()

    input_path = Path(args.input).expanduser()
    packets = iter_packets_from_csv(input_path, args.limit) if input_path.exists() else [args.input]

    failures = 0
    for index, packet in enumerate(packets, start=1):
        try:
            ok, message = check_packet(packet)
        except Exception as exc:
            ok, message = False, str(exc)
        status = "OK" if ok else "FAIL"
        print(f"{index}: {status} - {message}")
        failures += 0 if ok else 1

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
