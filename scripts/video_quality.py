#!/usr/bin/env python3
"""Measure an eight-bar HDMI capture using ffmpeg and the Python standard library.

This counts luminance-order defects, NOT colour accuracy. Fix the ROI across
comparisons; exclude the M5 pattern's bottom-quarter grey ramp. No frames are
silently filtered out, including capture-card "No Signal" frames.
"""
import argparse
import glob
import json
import statistics
import subprocess


def measure_frame(data, width, height, rows, start, bar_width, radius=8):
    centres = [start + bar_width * i + bar_width // 2 for i in range(8)]
    if not (0 <= rows[0] < rows[1] <= height):
        raise ValueError("rows must be inside the image")
    if centres[0] - radius < 0 or centres[-1] + radius > width:
        raise ValueError("bar samples must be inside the image")
    counts = dict(correct=0, dropped=0, wrong_order=0)
    bars = [[] for _ in centres]
    saturated = total = colour_rows = 0
    differences = []
    previous = None
    for y in range(*rows):
        rgb = []
        for i, x in enumerate(centres):
            offset = (y * width + x - radius) * 3
            block = data[offset:offset + 2 * radius * 3]
            p = tuple(sum(block[c::3]) / (2 * radius) for c in range(3))
            rgb.append(p)
            bars[i].append(p)
            saturated += sum(v >= 253 for v in block)
            total += len(block)
        luma = [0.299*r + 0.587*g + 0.114*b for r, g, b in rgb]
        if luma[0] < 100:
            counts["dropped"] += 1
            previous = None
        elif any(b > a + 12 for a, b in zip(luma, luma[1:])):
            counts["wrong_order"] += 1
            previous = None
        else:
            counts["correct"] += 1
            if previous is not None:
                differences.append(statistics.mean(abs(a-b) for p, q in
                    zip(previous[1:7], rgb[1:7]) for a, b in zip(p, q)))
            previous = rgb
        if sum(max(p)-min(p) > 30 for p in rgb[1:7]) >= 4:
            colour_rows += 1
    return dict(**counts, colour_rows=colour_rows,
                saturated_channels=saturated, sampled_channels=total,
                row_difference=statistics.median(differences) if differences else None,
                bar_rgb=[[round(statistics.median(p[c] for p in bar), 1)
                          for c in range(3)] for bar in bars])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pattern", help="quoted PNG glob, e.g. 'build/cap*.png'")
    parser.add_argument("--rows", default="20:350", help="exclusive y range; default 20:350")
    parser.add_argument("--start", type=int, default=24, help="left edge of first bar")
    parser.add_argument("--bar-width", type=int, default=80)
    args = parser.parse_args()
    paths = sorted(glob.glob(args.pattern))
    if not paths:
        parser.error("no input frames")
    rows = tuple(map(int, args.rows.split(":")))
    if len(rows) != 2:
        parser.error("--rows must be START:END")
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=width,height", "-of", "json", paths[0]]))["streams"][0]
    width, height = probe["width"], probe["height"]
    frame_size = width * height * 3
    command = ["ffmpeg", "-v", "error", "-pattern_type", "glob", "-i", args.pattern,
               "-f", "rawvideo", "-pix_fmt", "rgb24", "-fps_mode", "passthrough", "pipe:1"]
    results = []
    with subprocess.Popen(command, stdout=subprocess.PIPE) as proc:
        while True:
            data = proc.stdout.read(frame_size)
            if not data:
                break
            if len(data) != frame_size:
                raise RuntimeError("incomplete frame from ffmpeg")
            results.append(measure_frame(data, width, height, rows, args.start, args.bar_width))
        if proc.wait():
            raise RuntimeError("ffmpeg failed")
    if len(results) != len(paths):
        raise RuntimeError("decoded frame count differs from input count")
    count = len(results) * (rows[1]-rows[0])
    sums = {k: sum(r[k] for r in results) for k in ("correct", "dropped", "wrong_order")}
    differences = [r["row_difference"] for r in results if r["row_difference"] is not None]
    report = dict(pattern=args.pattern, frames=len(results), size=[width, height],
                  rows=rows, start=args.start, bar_width=args.bar_width,
                  row_counts=sums, row_percent={k: round(v*100/count, 3) for k, v in sums.items()},
                  colour_frames=sum(r["colour_rows"] > (rows[1]-rows[0])*0.8 for r in results),
                  saturated_channel_percent=round(100*sum(r["saturated_channels"] for r in results)/
                                                  sum(r["sampled_channels"] for r in results), 3),
                  median_row_difference=round(statistics.median(differences), 3) if differences else None,
                  median_bar_rgb=[[round(statistics.median(r["bar_rgb"][i][c] for r in results), 1)
                                   for c in range(3)] for i in range(8)])
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
