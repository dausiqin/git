#!/usr/bin/env python3
"""Replay MobilePoseLab CSV directly as stock SPICExLAB/MobilePoser live_demo.py UDP.

This is the offline equivalent of:

    replay_csv_udp.py -> mobileposer_live_demo_adapter.py -> live_demo.py

It reads the current MobilePoseLab raw CSV schema and emits aggregate packets:

    acc0,acc1,...,acc14#qw0,qx0,qy0,qz0,...,qw4,qx4,qy4,qz4$

The aggregate slot order matches SPICExLAB/MobilePoser:

    0 Left_phone
    1 Left_watch
    2 Left_headphone
    3 Right_phone
    4 Right_watch
"""

from __future__ import annotations

import argparse
import csv
import socket
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from mobileposer_live_demo_adapter import AdapterState, aggregate_packet, slot_for


@dataclass
class ReplayStats:
    rows: int = 0
    sent: int = 0
    errors: int = 0
    active_slots: set[int] = field(default_factory=set)


def number(row: dict[str, str], name: str) -> float:
    try:
        return float(row.get(name, ""))
    except ValueError as exc:
        raise ValueError(f"{name} is not numeric: {row.get(name)!r}") from exc


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    rows.sort(key=lambda row: number(row, "host_time_s"))
    return rows


def update_state_from_row(state: AdapterState, row: dict[str, str]) -> int:
    device_id = row.get("device_id", "").strip().lower()
    device_type = row.get("device_type", "").strip().lower()
    slot_index = slot_for(device_id, device_type)
    slot = state.slots[slot_index]
    slot.acc_m_s2 = (
        number(row, "ax_m_s2"),
        number(row, "ay_m_s2"),
        number(row, "az_m_s2"),
    )
    slot.quat_xyzw = (
        number(row, "quat_x"),
        number(row, "quat_y"),
        number(row, "quat_z"),
        number(row, "quat_w"),
    )
    slot.last_host_time = number(row, "host_time_s")
    slot.count += 1
    return slot_index


def replay(rows: list[dict[str, str]], host: str, port: int, speed: float, output_hz: float, accel_mode: str, dry_run: bool) -> int:
    if not rows:
        print("No rows to replay.", file=sys.stderr)
        return 1

    state = AdapterState()
    stats = ReplayStats()
    first_host_time = number(rows[0], "host_time_s")
    started = time.monotonic()
    next_output_time = None
    min_output_interval = 1.0 / max(output_hz, 1e-9)
    target = (host, port)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for index, row in enumerate(rows, start=1):
            stats.rows += 1
            row_host_time = number(row, "host_time_s")
            wait_until = started + ((row_host_time - first_host_time) / max(speed, 1e-9))
            if not dry_run:
                delay = wait_until - time.monotonic()
                if delay > 0:
                    time.sleep(delay)

            try:
                slot_index = update_state_from_row(state, row)
            except Exception as exc:  # noqa: BLE001 - CLI replay should report row-specific failures.
                stats.errors += 1
                print(f"row {index}: {exc}", file=sys.stderr)
                continue

            stats.active_slots.add(slot_index)
            if next_output_time is not None and row_host_time < next_output_time:
                continue
            next_output_time = row_host_time + min_output_interval

            packet = aggregate_packet(state, accel_mode)
            if dry_run:
                print(packet)
            else:
                sock.sendto(packet.encode("utf-8"), target)
            stats.sent += 1

    mode = "would send" if dry_run else "sent"
    active = ",".join(str(index) for index in sorted(stats.active_slots)) or "none"
    print(f"{mode} {stats.sent} aggregate packets to {host}:{port}; rows={stats.rows}; errors={stats.errors}; active_slots={active}")
    return 1 if stats.errors else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", type=Path)
    parser.add_argument("--host", default="127.0.0.1", help="Destination host for live_demo.py, default 127.0.0.1")
    parser.add_argument("--port", type=int, default=7777, help="Destination UDP port for live_demo.py, default 7777")
    parser.add_argument("--speed", type=float, default=1.0, help="Replay speed multiplier, default 1.0")
    parser.add_argument("--output-hz", type=float, default=30.0, help="Aggregate output rate, default 30")
    parser.add_argument("--accel-mode", choices=["g", "negative-g", "m_s2"], default="g", help="Acceleration conversion before live_demo.py sees it")
    parser.add_argument("--dry-run", action="store_true", help="Print aggregate packets instead of sending UDP")
    args = parser.parse_args(argv)

    if not args.csv_path.exists():
        print(f"CSV not found: {args.csv_path}", file=sys.stderr)
        return 2
    if not 0 <= args.port <= 65_535:
        print("port must be between 0 and 65535", file=sys.stderr)
        return 2

    rows = load_rows(args.csv_path)
    return replay(rows, args.host, args.port, args.speed, args.output_hz, args.accel_mode, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
