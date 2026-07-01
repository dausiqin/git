#!/usr/bin/env python3
"""Replay a MobilePoseLab raw CSV as mobile_6Dof / IMU_VIZ UDP packets.

This tool is for backend debugging: it converts each CSV row back into the same
wire format emitted by the iOS app:

    device_id;device_type:host_time device_time ax ay az qx qy qz qw [gx gy gz]

It does not resample, calibrate, align, or convert to MobilePoser tensors.
"""

from __future__ import annotations

import argparse
import csv
import socket
import sys
import time
from pathlib import Path


VALID_DEVICE_TYPES = {"phone", "watch", "headphone"}


def number(row: dict[str, str], name: str) -> float:
    try:
        return float(row.get(name, ""))
    except ValueError as exc:
        raise ValueError(f"{name} is not numeric: {row.get(name)!r}") from exc


def fixed6(value: float) -> str:
    return f"{value:.6f}"


def format_packet(row: dict[str, str]) -> str:
    device_id = row.get("device_id", "")
    device_type = row.get("device_type", "")
    if not device_id:
        raise ValueError("empty device_id")
    if device_type not in VALID_DEVICE_TYPES:
        raise ValueError(f"invalid device_type {device_type!r}")

    values = [
        number(row, "host_time_s"),
        number(row, "device_time_s"),
        number(row, "ax_m_s2"),
        number(row, "ay_m_s2"),
        number(row, "az_m_s2"),
        number(row, "quat_x"),
        number(row, "quat_y"),
        number(row, "quat_z"),
        number(row, "quat_w"),
    ]

    if row.get("gyro_available") == "1":
        values.extend([
            number(row, "gx_rad_s"),
            number(row, "gy_rad_s"),
            number(row, "gz_rad_s"),
        ])

    return f"{device_id};{device_type}:{' '.join(fixed6(value) for value in values)}"


def selected(row: dict[str, str], device_types: set[str], device_ids: set[str]) -> bool:
    if device_types and row.get("device_type", "") not in device_types:
        return False
    if device_ids and row.get("device_id", "") not in device_ids:
        return False
    return True


def load_rows(path: Path, device_types: set[str], device_ids: set[str]) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        rows = [row for row in csv.DictReader(handle) if selected(row, device_types, device_ids)]
    rows.sort(key=lambda row: number(row, "host_time_s"))
    return rows


def replay_rows(rows: list[dict[str, str]], host: str, port: int, speed: float, dry_run: bool) -> int:
    if not rows:
        print("No rows to replay.", file=sys.stderr)
        return 1

    first_host_time = number(rows[0], "host_time_s")
    started = time.monotonic()
    sent = 0
    errors = 0

    target = (host, port)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for index, row in enumerate(rows, start=1):
            row_host_time = number(row, "host_time_s")
            wait_until = started + ((row_host_time - first_host_time) / max(speed, 1e-9))
            if not dry_run:
                delay = wait_until - time.monotonic()
                if delay > 0:
                    time.sleep(delay)

            try:
                packet = format_packet(row)
            except ValueError as exc:
                errors += 1
                print(f"row {index}: {exc}", file=sys.stderr)
                continue

            if dry_run:
                print(packet)
            else:
                sock.sendto(packet.encode("utf-8"), target)
            sent += 1

    mode = "would send" if dry_run else "sent"
    print(f"{mode} {sent} packets to {host}:{port}; errors={errors}")
    return 1 if errors else 0


def parse_set(value: str) -> set[str]:
    return {part.strip() for part in value.split(",") if part.strip()}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Replay MobilePoseLab CSV rows as UDP IMU packets.")
    parser.add_argument("csv_path", type=Path)
    parser.add_argument("--host", default="127.0.0.1", help="Destination host, default 127.0.0.1")
    parser.add_argument("--port", type=int, default=8001, help="Destination UDP port, default 8001")
    parser.add_argument("--speed", type=float, default=1.0, help="Replay speed multiplier, default 1.0")
    parser.add_argument("--device-types", type=parse_set, default=set(), help="Comma list, e.g. phone,watch")
    parser.add_argument("--device-ids", type=parse_set, default=set(), help="Comma list, e.g. right,left")
    parser.add_argument("--dry-run", action="store_true", help="Print packets instead of sending UDP")
    args = parser.parse_args(argv)

    if not args.csv_path.exists():
        print(f"CSV not found: {args.csv_path}", file=sys.stderr)
        return 2
    if args.port < 0 or args.port > 65_535:
        print("port must be between 0 and 65535", file=sys.stderr)
        return 2
    unknown_types = args.device_types - VALID_DEVICE_TYPES
    if unknown_types:
        print("unknown device type(s): " + ", ".join(sorted(unknown_types)), file=sys.stderr)
        return 2

    rows = load_rows(args.csv_path, args.device_types, args.device_ids)
    return replay_rows(rows, host=args.host, port=args.port, speed=args.speed, dry_run=args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
