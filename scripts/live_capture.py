#!/usr/bin/env python3
"""Capture twice or more, rejecting frozen/wrong-mode HDMI images.

Attempts are retained in a unique directory alongside PREFIX. Successful frames
are copied to PREFIX_001.png etc.; existing files are not replaced. Mode/phase
validation requires the new scope header. Without it, changing pixels prove
motion only, NOT which FPGA image is loaded.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

from scope_trace import scope_identity


def live_reason(hashes, identities, mode=None, phase=None):
    if len(hashes) < 4 or len(hashes) != len(identities):
        return "fewer than four complete frames"
    if (mode is not None or phase is not None) and any(i is None for i in identities):
        return "missing scope identity (old or non-scope image)"
    if any(i is not None for i in identities):
        if any(i is None for i in identities):
            return "mixed scope and non-scope images"
        if len({(i['mode'], i['phase']) for i in identities}) != 1:
            return "diagnostic mode/phase changed during capture"
        if mode is not None and any(i['mode'] != mode for i in identities):
            return "wrong diagnostic mode"
        if phase is not None and any(i['phase'] != phase for i in identities):
            return "wrong ADC phase"
        if len({i['frame'] for i in identities[-8:]}) < 2:
            return "scope frame counter is frozen"
    elif len(set(hashes[-8:])) < 2:
        return "pixels are frozen (a static picture also needs a scope heartbeat)"
    return None


def inspect_frames(paths):
    command = ["ffmpeg", "-v", "error", "-framerate", "60", "-i",
               str(paths[0].parent / "%03d.png"), "-f", "rawvideo", "-pix_fmt",
               "rgb24", "-fps_mode", "passthrough", "pipe:1"]
    hashes, identities = [], []
    size = 640*480*3
    with subprocess.Popen(command, stdout=subprocess.PIPE) as proc:
        while True:
            data = proc.stdout.read(size)
            if not data:
                break
            if len(data) != size:
                raise RuntimeError("incomplete RGB frame")
            hashes.append(hashlib.sha256(data).hexdigest())
            identities.append(scope_identity(data))
        if proc.wait():
            raise RuntimeError("frame decoding failed")
    if len(hashes) != len(paths):
        raise RuntimeError("decoded frame count differs from capture")
    return hashes, identities


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", nargs="?", default="build/live")
    parser.add_argument("frames", nargs="?", type=int, default=120)
    parser.add_argument("tries", nargs="?", type=int, default=8)
    parser.add_argument("--scope-mode", type=int, choices=range(16))
    parser.add_argument("--phase", type=int, choices=range(5))
    parser.add_argument("--warmup", type=int, default=120,
                        help="startup frames retained but excluded before each measurement (default 120)")
    args = parser.parse_args()
    if args.frames < 4 or args.tries < 2 or args.warmup < 0:
        parser.error("need at least four frames, two passes, and nonnegative warmup")
    prefix = Path(args.prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    outputs = [prefix.parent / f"{prefix.name}_{i:03d}.png" for i in range(1, args.frames+1)]
    if any(p.exists() for p in outputs):
        parser.error("output frames already exist; choose a new prefix")
    work = Path(tempfile.mkdtemp(prefix=prefix.name+"_passes_", dir=prefix.parent))
    print(f"Capture attempts: {work}", flush=True)
    for attempt in range(1, args.tries+1):
        directory = work / f"pass{attempt:02d}"
        directory.mkdir()
        command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation",
                   "-pixel_format", "uyvy422", "-video_size", "640x480", "-framerate", "60",
                   "-i", "0:none", "-frames:v", str(args.frames+args.warmup), "-fps_mode", "passthrough",
                   str(directory / "%03d.png")]
        result = subprocess.run(command)
        paths = sorted(directory.glob("*.png"))
        if result.returncode or len(paths) != args.frames+args.warmup:
            print(f"pass {attempt}: capture failed", flush=True)
            continue
        hashes, identities = inspect_frames(paths)
        # AVFoundation returns cached/No Signal frames at the start of EACH
        # stream, not just the first stream after FPGA programming. Retain
        # them in the attempt directory, but start the defined measurement
        # interval only after a fixed warmup. Never filter within that interval.
        paths = paths[args.warmup:]
        hashes, identities = hashes[args.warmup:], identities[args.warmup:]
        reason = live_reason(hashes, identities, args.scope_mode, args.phase)
        if attempt == 1 or reason:
            print(f"pass {attempt}: {reason or 'first pass discarded for acquisition'}", flush=True)
            continue
        for source, output in zip(paths, outputs):
            with output.open("xb") as dst, source.open("rb") as src:
                shutil.copyfileobj(src, dst)
        print(f"live after {attempt} passes: {prefix}_*.png", flush=True)
        return
    parser.exit(1, f"No verified live capture after {args.tries} passes; retained in {work}\n")


if __name__ == "__main__":
    main()
