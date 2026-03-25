#!/usr/bin/env python3
"""
Extract time-series data from Aussie Broadband CVC capacity graph images.

Outputs InfluxDB line protocol to stdout.

Usage:
    # Extract from a local image
    python3 abb-cvc-extract.py /tmp/peakhurst_cvc.png

    # Download and extract a POI by name
    python3 abb-cvc-extract.py --poi peakhurst

    # Download all POI variants (link2, link3, etc.)
    python3 abb-cvc-extract.py --poi peakhurst --all-links

    # Specify custom date (default: parsed from image title)
    python3 abb-cvc-extract.py --poi peakhurst --date 2026-03-24

    # Write directly to InfluxDB
    python3 abb-cvc-extract.py --poi peakhurst | curl -s \\
        "$INFLUXDB_URL/api/v2/write?org=$INFLUXDB_ORG&bucket=homeassistant&precision=s" \\
        -H "Authorization: Token $INFLUXDB_TOKEN" \\
        --data-binary @-
"""

import argparse
import re
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

import cv2
import numpy as np

ABB_CVC_URL = "https://cvcs.aussiebroadband.com.au/{poi}.png"
AEDT = timezone(timedelta(hours=11))
AEST = timezone(timedelta(hours=10))


def download_image(poi: str) -> Path:
    """Download CVC graph image for a POI."""
    url = ABB_CVC_URL.format(poi=poi.lower())
    tmp = Path(tempfile.mktemp(suffix=".png"))
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0",
            "Referer": "https://www.aussiebroadband.com.au/network/cvc-graphs/",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            tmp.write_bytes(resp.read())
    except urllib.error.HTTPError as e:
        print(f"error: failed to download {url}: {e}", file=sys.stderr)
        sys.exit(1)
    return tmp


def find_gridlines_y(rgb: np.ndarray) -> list[int]:
    """Find horizontal gridlines by scanning for uniform gray rows."""
    h, w = rgb.shape[:2]
    gridlines = []
    for y in range(40, h - 40):
        row = rgb[y, 80:w - 40, :]
        gray = (
            (np.abs(row[:, 0].astype(int) - row[:, 1].astype(int)) < 12)
            & (np.abs(row[:, 1].astype(int) - row[:, 2].astype(int)) < 12)
            & (row[:, 0] > 185)
            & (row[:, 0] < 248)
        )
        if np.sum(gray) > (w * 0.7):
            if not gridlines or y - gridlines[-1] > 10:
                gridlines.append(y)
    return gridlines


def find_label_centers_x(rgb: np.ndarray) -> list[int]:
    """Find X-axis label center positions from text in bottom margin."""
    h = rgb.shape[0]
    bottom = rgb[h - 50 : h - 20, :, :]
    text_mask = (bottom[:, :, 0] < 100) & (bottom[:, :, 1] < 100) & (bottom[:, :, 2] < 100)
    text_cols = sorted(set(np.where(text_mask)[1]))

    clusters = []
    for x in text_cols:
        if not clusters or x - clusters[-1][-1] > 8:
            clusters.append([x])
        else:
            clusters[-1].append(x)

    return [(c[0] + c[-1]) // 2 for c in clusters]


def parse_title(rgb: np.ndarray) -> tuple[str, str | None]:
    """Try to extract POI name and date from the title text area."""
    # Title is in the top ~40px, centered. We can't OCR without tesseract,
    # but we can return defaults. The caller should pass --date if needed.
    return ("unknown", None)


def extract_line(
    rgb: np.ndarray,
    x_left: int,
    x_right: int,
    color_mask_fn,
    y_search_top: int = 50,
    y_search_bot: int = 260,
) -> list[tuple[int, int]]:
    """Extract a colored line's y-coordinate at each x position.

    Returns list of (x, y) tuples. Uses column-wise scanning to find
    the topmost pixel matching the color mask at each x.
    """
    points = []
    for x in range(x_left, x_right + 1):
        col = rgb[y_search_top:y_search_bot, x, :]
        mask = color_mask_fn(col)
        matches = np.where(mask)[0]
        if len(matches) > 0:
            # Use the median y to handle line thickness
            y = int(np.median(matches)) + y_search_top
            points.append((x, y))
    return points


def pixel_to_mbps(y: int, gridlines: list[int], mbps_values: list[float]) -> float:
    """Convert pixel y-coordinate to Mbps using gridline calibration."""
    # gridlines[0] = highest Mbps, gridlines[-1] = lowest (0)
    if len(gridlines) < 2:
        return 0.0

    # Linear interpolation between gridlines
    for i in range(len(gridlines) - 1):
        if gridlines[i] <= y <= gridlines[i + 1]:
            frac = (y - gridlines[i]) / (gridlines[i + 1] - gridlines[i])
            return mbps_values[i] + frac * (mbps_values[i + 1] - mbps_values[i])

    # Extrapolate if outside gridline range
    if y < gridlines[0]:
        px_per_mbps = (gridlines[1] - gridlines[0]) / (mbps_values[1] - mbps_values[0])
        return mbps_values[0] + (y - gridlines[0]) / px_per_mbps
    else:
        px_per_mbps = (gridlines[-1] - gridlines[-2]) / (mbps_values[-1] - mbps_values[-2])
        return mbps_values[-1] + (y - gridlines[-1]) / px_per_mbps


def pixel_to_timestamp(
    x: int, x_labels: list[int], date: datetime
) -> datetime:
    """Convert pixel x-coordinate to timestamp using label positions.

    x_labels correspond to 00:00, 02:00, 04:00, ..., 24:00 (13 labels).
    """
    if len(x_labels) < 2:
        return date

    hours_per_label = 2.0
    # Find which segment we're in
    for i in range(len(x_labels) - 1):
        if x_labels[i] <= x <= x_labels[i + 1]:
            frac = (x - x_labels[i]) / (x_labels[i + 1] - x_labels[i])
            hours = (i + frac) * hours_per_label
            return date + timedelta(hours=hours)

    # Extrapolate
    if x < x_labels[0]:
        frac = (x - x_labels[0]) / (x_labels[1] - x_labels[0])
        hours = frac * hours_per_label
    else:
        frac = (x - x_labels[-2]) / (x_labels[-1] - x_labels[-2])
        hours = ((len(x_labels) - 2) + frac) * hours_per_label

    return date + timedelta(hours=max(0, min(24, hours)))


def detect_mbps_scale(gridlines: list[int], rgb: np.ndarray) -> list[float]:
    """Detect the Mbps values for each gridline from Y-axis label positions.

    ABB CVC graphs have 5 evenly-spaced gridlines. The scale is always a
    multiple of 2650 Mbps (i.e., max = N * 2650, gridline step = max / 4).
    Common scales: 2650, 5300, 10600, 15900, 21200.

    Detection strategy:
    1. Measure the pixel width of the top Y-axis label text.
    2. Compare to the second label to determine digit count (4 vs 5+).
    3. Use the blue capacity line position to narrow down the exact scale.
    """
    n = len(gridlines)
    if n != 5:
        print(f"warning: expected 5 gridlines, found {n}. Using default scale.", file=sys.stderr)
        step = 10600 / 4
        return [10600 - i * step for i in range(n)]

    # --- Step 1: Measure Y-axis label widths to determine digit count ---
    left = rgb[:, 0:70, :]
    text_mask = (left[:, :, 0] < 100) & (left[:, :, 1] < 100) & (left[:, :, 2] < 100)

    rows = sorted(set(np.where(text_mask)[0]))
    row_clusters = []
    for y in rows:
        if not row_clusters or y - row_clusters[-1][-1] > 5:
            row_clusters.append([y])
        else:
            row_clusters[-1].append(y)

    label_widths = []
    for c in row_clusters:
        label_text = text_mask[c[0] : c[-1] + 1, :]
        cols_with_text = np.where(np.any(label_text, axis=0))[0]
        if len(cols_with_text) > 0:
            label_widths.append(cols_with_text[-1] - cols_with_text[0])
        else:
            label_widths.append(0)

    # Determine digit count of each label from width.
    # 5-digit labels are ~10-15% wider than 4-digit labels.
    # Use relative widths to classify: top, 2nd, 3rd, 4th labels.
    # The 5th label (bottom, "0") is always narrow.
    digit_counts = []
    if len(label_widths) >= 4:
        median_4digit = np.median(sorted(label_widths[:4])[1:3])  # middle two
        for w_px in label_widths[:4]:
            digit_counts.append(5 if w_px > median_4digit * 1.05 else 4)

    # Use the digit pattern to determine the scale:
    # max=10600  → digits: [5, 4, 4, 4]  (10600, 7950, 5300, 2650)
    # max=5300   → digits: [4, 4, 4, 4]  (5300, 3975, 2650, 1325)
    # max=2650   → digits: [4, 4, 4, 3]  (2650, 1987, 1325, 662)
    # max=13250  → digits: [5, 4, 4, 4]  (13250, 9937, 6625, 3312) - 2nd could be 4-digit
    # max=15900  → digits: [5, 5, 4, 4]  (15900, 11925, 7950, 3975)
    # max=21200  → digits: [5, 5, 5, 4]  (21200, 15900, 10600, 5300)

    # Key insight: for max=10600, ONLY the top label is 5-digit.
    # For max=15900+, the 2nd label is also 5-digit.
    if digit_counts == [5, 4, 4, 4]:
        candidates = [10600]  # only standard ABB scale with this digit pattern
    elif digit_counts == [5, 5, 4, 4]:
        candidates = [15900]
    elif digit_counts == [5, 5, 5, 4]:
        candidates = [21200]
    elif digit_counts == [5, 5, 5, 5]:
        candidates = [26500]
    elif all(d == 4 for d in digit_counts[:4]):
        candidates = [2650, 5300, 7950]
    else:
        candidates = [10600]  # safe default

    print(f"info: label digit pattern={digit_counts}, candidates={candidates}", file=sys.stderr)

    # --- Step 2: Use blue line position to determine exact scale ---
    blue_mask_arr = (rgb[:, :, 0] < 110) & (rgb[:, :, 1] > 140) & (rgb[:, :, 2] > 180)
    blue_ys = np.where(blue_mask_arr)[0]

    if len(blue_ys) > 0:
        blue_y = int(np.median(blue_ys))
        total_px = gridlines[-1] - gridlines[0]
        blue_frac = (blue_y - gridlines[0]) / total_px

        best = None
        best_err = float("inf")
        for max_mbps in candidates:
            blue_mbps = max_mbps * (1 - blue_frac)
            rounded = round(blue_mbps / 50) * 50
            err = abs(blue_mbps - rounded)
            if err < best_err:
                best = (max_mbps, rounded)
                best_err = err

        if best:
            max_mbps, capacity = best
            print(
                f"info: detected scale max={max_mbps} Mbps, "
                f"CVC capacity={capacity} Mbps (blue y={blue_y}, "
                f"digits={digit_counts}, "
                f"widths={label_widths[:3]})",
                file=sys.stderr,
            )
            return [max_mbps - i * (max_mbps / 4) for i in range(5)]

    # Fallback: use label width heuristic alone
    max_mbps = candidates[0]
    print(f"warning: using fallback scale max={max_mbps} Mbps", file=sys.stderr)
    return [max_mbps - i * (max_mbps / 4) for i in range(5)]


def extract_graph(
    image_path: Path, poi: str, date_str: str | None = None
) -> list[dict]:
    """Extract all time-series data from a CVC graph image."""
    img = cv2.imread(str(image_path))
    if img is None:
        print(f"error: cannot read image {image_path}", file=sys.stderr)
        sys.exit(1)

    rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    h, w = img.shape[:2]

    # --- Calibration ---
    gridlines = find_gridlines_y(rgb)
    x_labels = find_label_centers_x(rgb)
    mbps_values = detect_mbps_scale(gridlines, rgb)

    print(
        f"info: gridlines={gridlines}, x_labels={len(x_labels)}, "
        f"scale={mbps_values[0]:.0f}-{mbps_values[-1]:.0f} Mbps",
        file=sys.stderr,
    )

    # Parse date
    if date_str:
        base_date = datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=AEDT)
    else:
        # Try to extract from image filename or title
        # ABB images show date in title like "24/03/2026"
        # Without OCR, default to today
        base_date = datetime.now(AEDT).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        print(
            f"info: no date specified, using {base_date.strftime('%Y-%m-%d')}",
            file=sys.stderr,
        )

    # --- Extract lines ---
    x_left = x_labels[0] if x_labels else 70
    x_right = x_labels[-1] if x_labels else w - 30

    # Black line: download/usage (dark pixels, exclude axis text area)
    def black_mask(col):
        return (col[:, 0] < 55) & (col[:, 1] < 55) & (col[:, 2] < 55)

    # Green line: upload
    def green_mask(col):
        return (col[:, 1] > 100) & (col[:, 0] < 160) & (col[:, 2] < 100) & (col[:, 1] > col[:, 0])

    # Blue line: CVC capacity (provisioned)
    def blue_mask(col):
        return (col[:, 0] < 110) & (col[:, 1] > 140) & (col[:, 2] > 180)

    black_points = extract_line(rgb, x_left, x_right, black_mask, 50, gridlines[-1] + 10)
    green_points = extract_line(rgb, x_left, x_right, green_mask, gridlines[-3], gridlines[-1] + 10)
    blue_points = extract_line(rgb, x_left, x_right, blue_mask, 50, gridlines[-1] + 10)

    print(
        f"info: extracted {len(black_points)} download, "
        f"{len(green_points)} upload, {len(blue_points)} capacity points",
        file=sys.stderr,
    )

    # --- Convert to time-series ---
    results = []

    for x, y in black_points:
        ts = pixel_to_timestamp(x, x_labels, base_date)
        mbps = pixel_to_mbps(y, gridlines, mbps_values)
        results.append(
            {
                "ts": ts,
                "measurement": "abb_cvc",
                "tags": {"poi": poi, "metric": "download"},
                "value": max(0, mbps),
            }
        )

    for x, y in green_points:
        ts = pixel_to_timestamp(x, x_labels, base_date)
        mbps = pixel_to_mbps(y, gridlines, mbps_values)
        results.append(
            {
                "ts": ts,
                "measurement": "abb_cvc",
                "tags": {"poi": poi, "metric": "upload"},
                "value": max(0, mbps),
            }
        )

    for x, y in blue_points:
        ts = pixel_to_timestamp(x, x_labels, base_date)
        mbps = pixel_to_mbps(y, gridlines, mbps_values)
        results.append(
            {
                "ts": ts,
                "measurement": "abb_cvc",
                "tags": {"poi": poi, "metric": "capacity"},
                "value": max(0, mbps),
            }
        )

    return results


def downsample(points: list[dict], interval_seconds: int = 60) -> list[dict]:
    """Downsample points to one per interval by averaging."""
    if not points:
        return []

    # Group by (metric, interval)
    buckets: dict[tuple[str, int], list[dict]] = {}
    for p in points:
        metric = p["tags"]["metric"]
        bucket_ts = int(p["ts"].timestamp()) // interval_seconds * interval_seconds
        key = (metric, bucket_ts)
        buckets.setdefault(key, []).append(p)

    result = []
    for (metric, bucket_ts), group in sorted(buckets.items()):
        avg_val = np.mean([p["value"] for p in group])
        representative = group[0].copy()
        representative["ts"] = datetime.fromtimestamp(bucket_ts, tz=AEDT)
        representative["value"] = float(avg_val)
        result.append(representative)

    return result


def to_line_protocol(points: list[dict]) -> str:
    """Convert extracted data to InfluxDB line protocol."""
    lines = []
    for p in sorted(points, key=lambda x: (x["tags"]["metric"], x["ts"])):
        tags = ",".join(f"{k}={v}" for k, v in sorted(p["tags"].items()))
        ts_unix = int(p["ts"].timestamp())
        lines.append(f'{p["measurement"]},{tags} value={p["value"]:.1f} {ts_unix}')
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Extract time-series data from ABB CVC graph images"
    )
    parser.add_argument("image", nargs="?", help="Path to CVC graph image")
    parser.add_argument("--poi", help="POI name (downloads from ABB if no image given)")
    parser.add_argument(
        "--all-links",
        action="store_true",
        help="Also download link2, link3, etc. variants",
    )
    parser.add_argument("--date", help="Date for timestamps (YYYY-MM-DD)")
    parser.add_argument(
        "--interval",
        type=int,
        default=60,
        help="Downsample interval in seconds (default: 60)",
    )
    parser.add_argument(
        "--format",
        choices=["influx", "csv"],
        default="influx",
        help="Output format (default: influx line protocol)",
    )
    args = parser.parse_args()

    if not args.image and not args.poi:
        parser.error("provide either an image path or --poi name")

    # Collect all (image_path, poi_name) pairs to process
    targets = []
    if args.image:
        poi = args.poi or Path(args.image).stem
        targets.append((Path(args.image), poi))
    else:
        targets.append((download_image(args.poi), args.poi))
        if args.all_links:
            for i in range(2, 10):
                variant = f"{args.poi}link{i}"
                try:
                    img_path = download_image(variant)
                    targets.append((img_path, variant))
                except SystemExit:
                    break

    all_points = []
    for image_path, poi in targets:
        points = extract_graph(image_path, poi, args.date)
        points = downsample(points, args.interval)
        all_points.extend(points)
        print(
            f"info: {poi}: {len(points)} points after {args.interval}s downsample",
            file=sys.stderr,
        )

    if args.format == "csv":
        print("timestamp,poi,metric,value_mbps")
        for p in sorted(all_points, key=lambda x: (x["tags"]["poi"], x["tags"]["metric"], x["ts"])):
            print(
                f'{p["ts"].isoformat()},{p["tags"]["poi"]},{p["tags"]["metric"]},{p["value"]:.1f}'
            )
    else:
        print(to_line_protocol(all_points))


if __name__ == "__main__":
    main()
