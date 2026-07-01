#!/usr/bin/env python3
"""Validate MobilePoseLab exported raw CSV files.

The app writes a long-format CSV: one row is one IMU frame from one device.
This checker is intended for the Windows/Python preprocessing side before
feeding data into MobilePoser, mobile_6Dof, or IMU_VIZ.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path


EXPECTED_COLUMNS = [
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

VALID_DEVICE_TYPES = {"phone", "watch", "headphone"}


@dataclass
class SourceStats:
    key: str
    count: int = 0
    host_times: list[float] = field(default_factory=list)
    receive_times: list[float] = field(default_factory=list)
    quat_norms: list[float] = field(default_factory=list)
    accel_norms: list[float] = field(default_factory=list)
    gravity_norms: list[float] = field(default_factory=list)
    gyro_rows: int = 0
    raw_extra_rows: int = 0
    gravity_baseline_rows: int = 0
    parse_errors: list[str] = field(default_factory=list)

    def add(self, row_number: int, row: dict[str, str]) -> None:
        self.count += 1
        try:
            host_time = number(row, "host_time_s")
            receive_time = number(row, "receive_time_s")
            quat = [number(row, name) for name in ("quat_x", "quat_y", "quat_z", "quat_w")]
            accel = [number(row, name) for name in ("ax_m_s2", "ay_m_s2", "az_m_s2")]
            gravity = [number(row, name) for name in ("gravity_x_m_s2", "gravity_y_m_s2", "gravity_z_m_s2")]
        except ValueError as exc:
            self.parse_errors.append(f"row {row_number}: {exc}")
            return

        self.host_times.append(host_time)
        self.receive_times.append(receive_time)
        self.quat_norms.append(norm(quat))
        self.accel_norms.append(norm(accel))
        self.gravity_norms.append(norm(gravity))

        if row.get("gyro_available") == "1":
            self.gyro_rows += 1

        raw_extra = row.get("raw_extra_json", "")
        if raw_extra:
            try:
                raw = json.loads(raw_extra)
            except json.JSONDecodeError:
                self.parse_errors.append(f"row {row_number}: invalid raw_extra_json")
            else:
                self.raw_extra_rows += 1
                if "gravity_calibration_baseline_m_s2" in raw:
                    self.gravity_baseline_rows += 1

    @property
    def duration(self) -> float:
        if len(self.host_times) < 2:
            return 0.0
        return max(self.host_times) - min(self.host_times)

    @property
    def hz(self) -> float:
        if self.duration <= 0 or len(self.host_times) < 2:
            return 0.0
        return (len(self.host_times) - 1) / self.duration

    def gap_count(self, target_hz: float) -> int:
        if len(self.host_times) < 2:
            return 0
        threshold = max(0.12, 3.0 / max(target_hz, 1.0))
        ordered = sorted(self.host_times)
        return sum(1 for left, right in zip(ordered, ordered[1:]) if right - left > threshold)

    def max_gap(self) -> float:
        if len(self.host_times) < 2:
            return 0.0
        ordered = sorted(self.host_times)
        return max((right - left for left, right in zip(ordered, ordered[1:])), default=0.0)


def number(row: dict[str, str], name: str) -> float:
    value = row.get(name, "")
    try:
        return float(value)
    except ValueError as exc:
        raise ValueError(f"{name} is not numeric: {value!r}") from exc


def norm(values: list[float]) -> float:
    return math.sqrt(sum(value * value for value in values))


def median(values: list[float]) -> float:
    return statistics.median(values) if values else 0.0


def validate_header(fieldnames: list[str] | None) -> list[str]:
    if fieldnames is None:
        return ["CSV has no header"]
    errors: list[str] = []
    missing = [name for name in EXPECTED_COLUMNS if name not in fieldnames]
    extra = [name for name in fieldnames if name not in EXPECTED_COLUMNS]
    if missing:
        errors.append("missing columns: " + ", ".join(missing))
    if extra:
        errors.append("unexpected columns: " + ", ".join(extra))
    if fieldnames != EXPECTED_COLUMNS:
        errors.append("column order differs from MobilePoseLab raw schema")
    return errors


def validate_rows(path: Path, require: set[str], target_hz: float) -> int:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        errors = validate_header(reader.fieldnames)
        stats: dict[str, SourceStats] = {}
        row_count = 0
        invalid_types: list[str] = []

        for row_number, row in enumerate(reader, start=2):
            row_count += 1
            device_type = row.get("device_type", "")
            device_id = row.get("device_id", "")
            if device_type not in VALID_DEVICE_TYPES:
                invalid_types.append(f"row {row_number}: invalid device_type {device_type!r}")
                continue
            if not device_id:
                invalid_types.append(f"row {row_number}: empty device_id")
                continue
            key = f"{device_type}/{device_id}"
            stats.setdefault(key, SourceStats(key=key)).add(row_number, row)

    if row_count == 0:
        errors.append("CSV has no data rows")

    present_types = {key.split("/", 1)[0] for key in stats}
    missing_required = sorted(require - present_types)
    if missing_required:
        errors.append("missing required device types: " + ", ".join(missing_required))

    errors.extend(invalid_types[:20])
    for source in stats.values():
        errors.extend(source.parse_errors[:20])
        if source.key.startswith(("phone/", "watch/")) and source.gyro_rows != source.count:
            errors.append(f"{source.key}: phone/watch rows should all include gyro_available=1")

    print(f"file: {path}")
    print(f"rows: {row_count}")
    print(f"sources: {len(stats)}")
    for key in sorted(stats):
        source = stats[key]
        print(
            f"- {key}: count={source.count} duration={source.duration:.3f}s "
            f"hz={source.hz:.2f} gaps={source.gap_count(target_hz)} "
            f"max_gap={source.max_gap():.3f}s gyro_rows={source.gyro_rows}"
        )
        print(
            f"  median |q|={median(source.quat_norms):.3f} "
            f"median |a|={median(source.accel_norms):.3f}m/s^2 "
            f"median |g|={median(source.gravity_norms):.3f}m/s^2 "
            f"raw_extra={source.raw_extra_rows}/{source.count} "
            f"gravity_baseline={source.gravity_baseline_rows}/{source.count}"
        )

    if errors:
        print("\nFAIL:")
        for error in errors[:50]:
            print(f"- {error}")
        if len(errors) > 50:
            print(f"- ... {len(errors) - 50} more errors")
        return 1

    print("\nPASS: CSV matches the MobilePoseLab raw schema.")
    return 0


def parse_required_device_types(value: str) -> set[str]:
    if not value:
        return set()
    result = {part.strip() for part in value.split(",") if part.strip()}
    unknown = result - VALID_DEVICE_TYPES
    if unknown:
        raise argparse.ArgumentTypeError("unknown device type(s): " + ", ".join(sorted(unknown)))
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Validate a MobilePoseLab exported raw CSV.")
    parser.add_argument("csv_path", type=Path)
    parser.add_argument("--target-hz", type=float, default=30.0)
    parser.add_argument(
        "--require",
        type=parse_required_device_types,
        default=set(),
        help="Comma-separated required device types, e.g. phone,watch,headphone",
    )
    args = parser.parse_args(argv)

    if not args.csv_path.exists():
        print(f"CSV not found: {args.csv_path}", file=sys.stderr)
        return 2
    return validate_rows(args.csv_path, require=args.require, target_hz=args.target_hz)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
