#!/usr/bin/env python3
"""Minimal UDP receiver for validating MobilePoseLab streamer packets.

This is not a replacement for IMU_VIZ or mobile_6Dof. It is a local smoke test
that checks whether iOS packets match the expected mobile_6Dof / IMU_VIZ wire
format before the full backend is connected.
"""

from __future__ import annotations

import argparse
import math
import socket
import time
from dataclasses import dataclass, field


VALID_DEVICE_TYPES = {"phone", "watch", "headphone"}


@dataclass
class SourceStats:
    count: int = 0
    first_host_time: float | None = None
    last_host_time: float | None = None
    last_seen_wall_time: float = 0.0
    errors: int = 0
    recent_host_times: list[float] = field(default_factory=list)

    def record(self, host_time: float) -> None:
        self.count += 1
        if self.first_host_time is None:
            self.first_host_time = host_time
        self.last_host_time = host_time
        self.last_seen_wall_time = time.monotonic()
        self.recent_host_times.append(host_time)
        cutoff = host_time - 3.0
        self.recent_host_times = [value for value in self.recent_host_times if value >= cutoff]

    @property
    def hz(self) -> float:
        if len(self.recent_host_times) < 2:
            return 0.0
        duration = self.recent_host_times[-1] - self.recent_host_times[0]
        if duration <= 0:
            return 0.0
        return (len(self.recent_host_times) - 1) / duration


def parse_packet(text: str) -> tuple[str, str, list[float]]:
    if ";" not in text or ":" not in text:
        raise ValueError("packet must contain ';' and ':'")
    device_id, rest = text.split(";", 1)
    device_type, values_text = rest.split(":", 1)
    if not device_id:
        raise ValueError("empty device_id")
    if device_type not in VALID_DEVICE_TYPES:
        raise ValueError(f"invalid device_type {device_type!r}")

    parts = values_text.split()
    if len(parts) not in (9, 12):
        raise ValueError(f"expected 9 or 12 numeric values after type, got {len(parts)}")
    values = [float(part) for part in parts]

    host_time, device_time = values[0], values[1]
    if host_time <= 0 or device_time <= 0:
        raise ValueError("host_time and device_time must be positive seconds")

    quat = values[5:9]
    quat_norm = math.sqrt(sum(value * value for value in quat))
    if not 0.5 <= quat_norm <= 1.5:
        raise ValueError(f"unexpected quaternion norm {quat_norm:.3f}")

    if device_type in {"phone", "watch"} and len(values) != 12:
        raise ValueError(f"{device_type} packets must include gyro gx gy gz")

    return device_id, device_type, values


def print_summary(stats: dict[str, SourceStats]) -> None:
    if not stats:
        return
    lines = []
    now = time.monotonic()
    for key in sorted(stats):
        source = stats[key]
        age = now - source.last_seen_wall_time if source.last_seen_wall_time else 0.0
        lines.append(
            f"{key}: count={source.count} hz={source.hz:.1f} "
            f"age={age:.2f}s errors={source.errors}"
        )
    print(" | ".join(lines), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate MobilePoseLab UDP IMU packets.")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host, default 0.0.0.0")
    parser.add_argument("--port", type=int, default=8001, help="Bind UDP port, default 8001")
    parser.add_argument("--summary-interval", type=float, default=2.0, help="Summary interval seconds")
    parser.add_argument("--max-errors", type=int, default=20, help="Stop after this many parse errors")
    args = parser.parse_args()

    stats: dict[str, SourceStats] = {}
    total_errors = 0
    last_summary = time.monotonic()

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((args.host, args.port))
        sock.settimeout(0.5)
        print(f"Listening for MobilePoseLab UDP packets on {args.host}:{args.port}", flush=True)
        while True:
            try:
                data, address = sock.recvfrom(4096)
            except socket.timeout:
                if time.monotonic() - last_summary >= args.summary_interval:
                    print_summary(stats)
                    last_summary = time.monotonic()
                continue

            text = data.decode("utf-8", errors="replace").strip()
            try:
                device_id, device_type, values = parse_packet(text)
            except Exception as exc:  # noqa: BLE001 - command-line validator should report parse cause.
                total_errors += 1
                print(f"ERROR from {address}: {exc}; packet={text!r}", flush=True)
                if total_errors >= args.max_errors:
                    return 1
                continue

            key = f"{device_type}/{device_id}"
            stats.setdefault(key, SourceStats()).record(values[0])

            if time.monotonic() - last_summary >= args.summary_interval:
                print_summary(stats)
                last_summary = time.monotonic()


if __name__ == "__main__":
    raise SystemExit(main())
