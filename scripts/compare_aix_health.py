#!/usr/bin/env python3
"""Compare AIX health engine v2 KEY=value summaries without executing them.

Exit codes: 0 healthy/no regression, 1 review, 2 regression, 3 invalid/incomplete.
Only the Python standard library is required (Python 3.8+).
"""

import argparse
from datetime import datetime
from decimal import Decimal, localcontext
import json
from pathlib import Path
import re
import sys


STATUS_KEYS = tuple(name + "_STATUS" for name in (
    "OS", "PERFORMANCE", "PAGING", "FILESYSTEM", "VG_LV", "PV", "DEVICE",
    "MPIO", "DISK_IO", "ERRPT", "NETWORK", "SERVICE", "NTP", "DUMP", "POWERHA",
))
METRIC_KEYS = (
    "VCPU", "RUN_QUEUE", "CPU_BUSY_PERCENT", "IOWAIT_PERCENT", "PAGE_IN",
    "PAGE_OUT", "PAGING_USED_PERCENT", "MAX_DISK_BUSY_PERCENT", "FAILED_MPIO_PATHS",
)
REQUIRED_KEYS = frozenset(STATUS_KEYS + METRIC_KEYS + (
    "HOST", "CHECK_TYPE", "TIMESTAMP", "AIX_LEVEL", "POWERHA_STATE",
    "OVERALL_STATUS", "OVERALL_CODE",
))
SEVERITY = {"OK": 0, "WARNING": 1, "CRITICAL": 2, "UNKNOWN": 3}
MAX_INPUT_BYTES = 1024 * 1024


class ValidationError(ValueError):
    """An input cannot safely be used for change validation."""


def validate_summary(data):
    """Validate the complete legacy schema; blank metrics mean unavailable."""
    missing = REQUIRED_KEYS - data.keys()
    extra = data.keys() - REQUIRED_KEYS
    if missing or extra:
        raise ValidationError("schema mismatch: missing={} unexpected={}".format(
            sorted(missing), sorted(extra)))
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", data["HOST"]):
        raise ValidationError("HOST must be a short hostname")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", data["CHECK_TYPE"]):
        raise ValidationError("CHECK_TYPE must be a nonempty label")
    stamp = data["TIMESTAMP"]
    if not re.fullmatch(r"[0-9]{8}_[0-9]{6}", stamp):
        raise ValidationError("TIMESTAMP must use YYYYMMDD_HHMMSS")
    try:
        datetime.strptime(stamp, "%Y%m%d_%H%M%S")
    except ValueError as exc:
        raise ValidationError("TIMESTAMP is not a valid date/time") from exc
    if data["AIX_LEVEL"] and not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}", data["AIX_LEVEL"]):
        raise ValidationError("AIX_LEVEL must use the oslevel -s format")
    if not re.fullmatch(r"[A-Za-z0-9_/-]+", data["POWERHA_STATE"]):
        raise ValidationError("POWERHA_STATE must be a nonempty state token")
    for key in STATUS_KEYS + ("OVERALL_STATUS",):
        if data[key] not in SEVERITY:
            raise ValidationError("{} must be OK, WARNING, CRITICAL or UNKNOWN".format(key))
    expected = max(SEVERITY[data[key]] for key in STATUS_KEYS)
    if data["OVERALL_CODE"] != str(SEVERITY[data["OVERALL_STATUS"]]):
        raise ValidationError("OVERALL_CODE disagrees with OVERALL_STATUS")
    if SEVERITY[data["OVERALL_STATUS"]] != expected:
        raise ValidationError("OVERALL_STATUS disagrees with component statuses")
    for key in METRIC_KEYS:
        value = data[key]
        if value == "":
            continue
        if len(value) > 64 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value):
            raise ValidationError("{} must be a nonnegative number or blank".format(key))
        number = Decimal(value)
        if key.endswith("_PERCENT") and number > 100:
            raise ValidationError("{} must be between 0 and 100".format(key))
        if key in ("VCPU", "FAILED_MPIO_PATHS") and not re.fullmatch(r"[0-9]+", value):
            raise ValidationError("{} must be an integer".format(key))
        if key == "VCPU" and number < 1:
            raise ValidationError("VCPU must be positive")
    return data


def read_summary(path):
    """Parse literal key/value data, never source a summary as shell code."""
    try:
        with Path(path).open("rb") as stream:
            raw = stream.read(MAX_INPUT_BYTES + 1)
        if len(raw) > MAX_INPUT_BYTES:
            raise ValidationError("summary exceeds 1 MiB")
        content = raw.decode("utf-8-sig")
    except (OSError, UnicodeError) as exc:
        raise ValidationError("cannot read {}: {}".format(path, exc)) from exc
    data = {}
    for line_number, line in enumerate(content.split("\n"), 1):
        if line.endswith("\r"):
            line = line[:-1]
        if any(ord(char) < 32 or ord(char) == 127 for char in line):
            raise ValidationError("line {} contains control characters".format(line_number))
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ValidationError("line {} must be KEY=value".format(line_number))
        if key in data:
            raise ValidationError("duplicate key: {}".format(key))
        data[key] = value
    return validate_summary(data)


def compare_summaries(before, after):
    """Return a deterministic report. Regressions take precedence over improvements."""
    validate_summary(before)
    validate_summary(after)
    if before["HOST"] != after["HOST"]:
        raise ValidationError("HOST mismatch: {} != {}".format(before["HOST"], after["HOST"]))
    if after["TIMESTAMP"] < before["TIMESTAMP"]:
        raise ValidationError("post-change timestamp precedes pre-change timestamp")
    if before["CHECK_TYPE"] == "postcheck" or after["CHECK_TYPE"] == "precheck":
        raise ValidationError("precheck/postcheck labels are reversed or used in the wrong position")

    regressions, improvements, review, unavailable = [], [], [], []
    statuses = []
    unresolved_baseline = []
    for key in STATUS_KEYS:
        old, new = before[key], after[key]
        direction = "UNCHANGED"
        if "UNKNOWN" in (old, new):
            direction = "UNKNOWN"
            unavailable.append(key)
        elif SEVERITY[new] > SEVERITY[old]:
            direction = "REGRESSED"
            regressions.append(key)
        elif SEVERITY[new] < SEVERITY[old]:
            direction = "IMPROVED"
            improvements.append(key)
        row = {"key": key, "before": old, "after": new, "change": direction}
        statuses.append(row)
        if old in ("WARNING", "CRITICAL") and new != "OK":
            unresolved_baseline.append(row.copy())

    metrics = []
    for key in METRIC_KEYS:
        numeric_type = int if key in ("VCPU", "FAILED_MPIO_PATHS") else float
        old = numeric_type(before[key]) if before[key] else None
        new = numeric_type(after[key]) if after[key] else None
        delta = None
        if old is not None and new is not None:
            # Subtract the source decimals before conversion to JSON numbers,
            # avoiding artifacts such as 0.3 - 0.1 = 0.19999999999999998.
            with localcontext() as context:
                context.prec = max(len(before[key]), len(after[key])) + 2
                delta = numeric_type(Decimal(after[key]) - Decimal(before[key]))
        metrics.append({"key": key, "before": old, "after": new, "delta": delta})
        if delta is None:
            unavailable.append(key)
        elif key == "FAILED_MPIO_PATHS":
            if delta > 0:
                regressions.append(key)
            elif delta < 0:
                improvements.append(key)
        elif key == "VCPU" and delta != 0:
            review.append("VCPU changed")
        if key == "FAILED_MPIO_PATHS" and old is not None and old > 0 and (new is None or new > 0):
            change = "UNKNOWN" if delta is None else ("REGRESSED" if delta > 0 else "IMPROVED" if delta < 0 else "UNCHANGED")
            unresolved_baseline.append({"key": key, "before": old, "after": new, "change": change})

    metadata = []
    for key in ("AIX_LEVEL", "POWERHA_STATE"):
        if before[key] != after[key]:
            metadata.append({"key": key, "before": before[key], "after": after[key]})
            review.append("{} changed".format(key))
    if not before["AIX_LEVEL"] or not after["AIX_LEVEL"]:
        unavailable.append("AIX_LEVEL")
    if "UNKNOWN" in (before["POWERHA_STATE"], after["POWERHA_STATE"]):
        unavailable.append("POWERHA_STATE")

    # Incomplete evidence cannot establish a safe result, even when known checks regress.
    if unavailable:
        outcome, code = "INCONCLUSIVE", 3
    elif regressions:
        outcome, code = "REGRESSED", 2
    elif improvements:
        outcome, code = "IMPROVED", 0
    else:
        outcome, code = "UNCHANGED", 0
    # A restored PowerHA state is already explained by its status improvement.
    if "POWERHA_STATUS" in improvements and after["POWERHA_STATE"] == "STABLE":
        review = [item for item in review if item != "POWERHA_STATE changed"]
    if unresolved_baseline:
        review.append("Unresolved baseline problems remain (UNKNOWN means resolution unverified)")
    if code == 0 and (after["OVERALL_STATUS"] != "OK" or review):
        code = 1
    return {
        "schema_version": 1, "host": before["HOST"],
        "before_timestamp": before["TIMESTAMP"], "after_timestamp": after["TIMESTAMP"],
        "before_overall": before["OVERALL_STATUS"], "after_overall": after["OVERALL_STATUS"],
        "outcome": outcome, "exit_code": code,
        "regressions": regressions, "improvements": improvements,
        "unresolved_baseline": unresolved_baseline,
        "review_reasons": review, "unavailable": unavailable,
        "statuses": statuses, "metrics": metrics, "metadata_changes": metadata,
    }


def render_text(report):
    lines = [
        "AIX change validation: {} (exit {})".format(report["outcome"], report["exit_code"]),
        "Host: {} | {} -> {}".format(report["host"], report["before_timestamp"], report["after_timestamp"]),
        "Overall health: {} -> {}".format(report["before_overall"], report["after_overall"]),
        "Component statuses:",
    ]
    for row in report["statuses"]:
        lines.append("  {key}: {before} -> {after} [{change}]".format(**row))
    lines.append("Metrics (performance deltas are informational):")
    for row in report["metrics"]:
        lines.append("  {key}: {before} -> {after} (delta {delta})".format(**row))
    for row in report["metadata_changes"]:
        lines.append("  {key}: {before} -> {after}".format(**row))
    lines.append("New or worsened degradation: {}".format(", ".join(report["regressions"]) or "none detected"))
    lines.append("Unresolved baseline problems: {}".format(len(report["unresolved_baseline"])))
    for row in report["unresolved_baseline"]:
        lines.append("  {key}: {before} -> {after} [{change}]".format(**row))
    for label, key in (("Improvements", "improvements"),
                       ("Review", "review_reasons"), ("Unavailable", "unavailable")):
        if report[key]:
            lines.append("{}: {}".format(label, ", ".join(report[key])))
    return "\n".join(lines)


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(3, "error: {}\n".format(message))


def main(argv=None):
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path, help="pre-change .summary file")
    parser.add_argument("after", type=Path, help="post-change .summary file")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    args = parser.parse_args(argv)
    try:
        before = read_summary(args.before)
        after = read_summary(args.after)
        if args.before.samefile(args.after):
            raise ValidationError("pre-change and post-change inputs must be different files")
        report = compare_summaries(before, after)
        output = json.dumps(report, indent=2, allow_nan=False) if args.format == "json" else render_text(report)
        print(output)
        return report["exit_code"]
    except (ValidationError, OSError) as exc:
        if args.format == "json":
            print(json.dumps({"schema_version": 1, "outcome": "INVALID_INPUT", "exit_code": 3, "error": str(exc)}))
        print("error: {}".format(exc), file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
