"""Export the recent_change kymograph of every tracked video (same signal as the tracker GUI).

Just run this file (e.g. "Run Python File" in VS Code, with the tracker's Python environment).
The settings are right below. Needs only numpy + opencv (the tracker's own packages).

For each '<video>_track.csv' under compressedvideo/ (with its _track_curves.jsonl.gz, _track_params.json,
_annotation.json and the video) the colon boundary + centerline of every tracked frame are read from the
curves file -- no re-tracking -- and the per-station signal is recomputed with the tracker's own code
(main/colon.py: ColonTracker._record, station_signal and the signal part of Progress.update), always with
feature = recent_change and the recent_change threshold / collective_q saved in the params file.
The white line is the exported tip (tip_station in the CSV). Hand-marked tip anchors are not drawn.

Outputs
  data/<video>_kymograph.csv        one row per tracked frame: frame, time_s (video time), tip_station,
                                    s000 ... s099 = recent_change signal of each centerline station (H -> T)
  data/<video>_kymograph_meta.json  threshold, collective_q, fps, ... of that video
  data/kymograph_index.csv          the meta of all videos in one table
  <video>_kymograph.png             drawn by plot_kymographs.py (run that alone to change the display)
A video whose CSV exists is not decoded again, so a stopped run continues where it stopped.
"""
# ------------------------------------------------------------------ settings
MATCH = ""          # only videos whose name contains this text ("" = all), e.g. "L 01"
JOBS = 4            # videos processed in parallel
RECOMPUTE = False   # True: decode the videos again even if data/<video>_kymograph.csv exists
DRAW = True         # draw the PNGs at the end (plot_kymographs.py, its display settings)
# ------------------------------------------------------------------

import glob
import gzip
import json
import os
import re
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                      # Eversion_tracker
sys.path.insert(0, os.path.join(ROOT, "main"))


# ------------------------------------------------------------------ files
def find_jobs(video_dir, match):
    jobs = []
    for csv in sorted(glob.glob(os.path.join(video_dir, "**", "*_track.csv"), recursive=True)):
        base = csv[:-len("_track.csv")]
        name = os.path.basename(base)
        if match and match.lower() not in name.lower():
            continue
        curves = next((f for f in (base + "_track_curves.jsonl.gz", base + "_track_curves.jsonl") if os.path.isfile(f)), None)
        params = base + "_track_params.json"
        jobs.append(dict(name=name, csv=csv, curves=curves, params=params if os.path.isfile(params) else None,
                         ann=base + "_annotation.json", video=find_video(base)))
    return jobs


def find_video(base):
    """The video may differ in spacing ('Mvi 1378 M 01 G' vs 'Mvi 1378  M 01 G.mp4')."""
    for ext in (".mp4", ".MP4", ".avi", ".mov", ".MOV"):
        if os.path.isfile(base + ext):
            return base + ext
    squash = lambda s: re.sub(r"\s+", " ", s.strip()).lower()
    folder, name = os.path.split(base)
    for f in os.listdir(folder):
        stem, ext = os.path.splitext(f)
        if ext.lower() in (".mp4", ".avi", ".mov") and squash(stem) == squash(name):
            return os.path.join(folder, f)
    return None


def read_curves(path):
    op = gzip.open if path.endswith(".gz") else open
    out = {}
    with op(path, "rt", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                d = json.loads(line)
                out[int(d["frame"])] = (np.asarray(d["boundary"], np.float32), np.asarray(d["centerline"], np.float32))
    return out


def read_tip(csv):
    import csv as _csv
    frames, tip = [], []
    with open(csv, newline="", encoding="utf-8") as f:
        for r in _csv.DictReader(f):
            frames.append(int(r["frame"]))
            tip.append(float(r["tip_station"]))
    return np.array(frames), np.array(tip)


# ------------------------------------------------------------------ signal
def compute(job):
    """Per-station recent_change signal for every tracked frame -> dict for the cache."""
    import cv2
    from config import Params, mode_values
    from colon import ColonTracker, Prepared, Progress, to_small, gray_of
    from geometry import polygon_mask

    p = Params.load(job["params"]) if job["params"] else Params()
    p.feature = "recent_change"
    p.update(mode_values(p, "recent_change"))       # threshold / collective_q of the recent_change mode
    straps = None
    if os.path.isfile(job["ann"]):
        with open(job["ann"], encoding="utf-8") as f:
            s = json.load(f).get("strap_colors", [])
        if s:
            straps = np.asarray(s, np.float32)[:, 3:6]

    curves = read_curves(job["curves"])
    want = sorted(curves)
    tr = ColonTracker(p)
    cap = cv2.VideoCapture(job["video"])
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    cap.set(cv2.CAP_PROP_POS_FRAMES, want[0])
    idx, wi = want[0], 0
    while wi < len(want):
        ok, frame = cap.read()
        if not ok:
            break
        if idx == want[wi]:
            bnd, ctr = curves[idx]
            if not tr.active:
                tr.start(frame, idx, bnd, ctr)
            else:
                small = to_small(frame, tr.scale)
                tr.bnd = bnd * tr.scale
                tr.ctr = ctr * tr.scale
                tr.last_idx = idx
                tr._record(idx, Prepared(small, gray_of(small), None, None, tr.lab_image(small)),
                           polygon_mask(tr.bnd, tr.shape))
            wi += 1
        idx += 1
    cap.release()

    pg = Progress(p)
    pg.straps = straps
    _signal_only(pg, tr)
    return dict(sig=np.stack(pg.sig, 1).astype(np.float32), frames=np.array(pg.frames), fps=fps,
                thresh=float(p.sig_thresh), collective_q=float(p.collective_q), n_curves=len(want))


def _signal_only(pg, tr):
    """The signal part of colon.Progress.update (the tip comes from the CSV, so the DP is skipped)."""
    from colon import station_signal, reference_signal
    p = pg.p
    ref = reference_signal(tr, p, pg.straps)
    for k in sorted(tr.history):
        s = station_signal(tr.history[k], tr, p, pg.straps)
        if ref is not None:
            s = s / ref
        if p.collective_q > 0:
            s = np.maximum(s - np.quantile(s, p.collective_q), 0.0)
        if pg.sig:
            a = min(1.0, (k - pg.frames[-1]) / max(p.sig_time_frames, 1))
            s = a * s + (1 - a) * pg.sig[-1]
        pg.frames.append(k)
        pg.sig.append(s)


def write_csv(job, d, csv_path):
    """Signal matrix + the exported tip (matched by frame) -> one CSV row per frame."""
    tf, tip = read_tip(job["csv"])
    tip_at = dict(zip(tf.tolist(), tip.tolist()))
    frames, sig, fps = d["frames"], d["sig"], float(d["fps"])
    tcol = np.array([tip_at.get(int(k), np.nan) for k in frames])
    n = sig.shape[0]
    head = "frame,time_s,tip_station," + ",".join(f"s{i:03d}" for i in range(n))
    a = np.column_stack([frames, frames / fps, tcol, sig.T])
    fmt = ["%d", "%.4f", "%.2f"] + ["%.4f"] * n
    tmp = csv_path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        np.savetxt(f, a, delimiter=",", header=head, comments="", fmt=fmt)
    os.replace(tmp, csv_path)          # a half-written CSV never looks finished


def run(job, data_dir):
    csv_path = os.path.join(data_dir, job["name"] + "_kymograph.csv")
    meta_path = os.path.join(data_dir, job["name"] + "_kymograph_meta.json")
    if os.path.isfile(csv_path) and os.path.isfile(meta_path) and not RECOMPUTE:
        return f"{job['name']}: CSV exists, skipped"
    t0 = time.time()
    old = os.path.join(HERE, "cache", job["name"] + ".npz")   # signals cached by the earlier version
    if os.path.isfile(old) and not RECOMPUTE:
        d = dict(np.load(old))
    else:
        d = compute(job)
    write_csv(job, d, csv_path)
    meta = dict(video=job["name"], video_file=os.path.basename(job["video"]), n_frames=int(d["sig"].shape[1]),
                n_stations=int(d["sig"].shape[0]), first_frame=int(d["frames"][0]), last_frame=int(d["frames"][-1]),
                fps=float(d["fps"]), thresh=float(d["thresh"]), collective_q=float(d["collective_q"]),
                feature="recent_change", csv=os.path.basename(csv_path))
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=1)
    return f"{job['name']}: {meta['n_frames']} frames, {time.time() - t0:.0f} s -> {os.path.basename(csv_path)}"


def write_index(data_dir):
    rows = []
    for p in sorted(glob.glob(os.path.join(data_dir, "*_kymograph_meta.json"))):
        with open(p, encoding="utf-8") as f:
            rows.append(json.load(f))
    if not rows:
        return
    keys = list(rows[0])
    with open(os.path.join(data_dir, "kymograph_index.csv"), "w", encoding="utf-8", newline="") as f:
        f.write(",".join(keys) + "\n")
        for r in rows:
            f.write(",".join(f'"{r[k]}"' if isinstance(r[k], str) else f"{r[k]}" for k in keys) + "\n")


def main():
    data_dir = os.path.join(HERE, "data")
    os.makedirs(data_dir, exist_ok=True)
    jobs = find_jobs(os.path.join(ROOT, "compressedvideo"), MATCH)
    todo = []
    for j in jobs:
        miss = [k for k in ("curves", "video") if not j[k]]
        if miss:
            print(f"skip {j['name']}: no {' / '.join(miss)}")
        else:
            todo.append(j)
    print(f"{len(todo)} video(s), {JOBS} in parallel; CSVs go to {data_dir}", flush=True)
    t0 = time.time()
    if JOBS <= 1:
        for j in todo:
            try:
                print(run(j, data_dir), flush=True)
            except Exception as e:  # keep going with the other videos
                print(f"FAILED {j['name']}: {e!r}", flush=True)
    else:
        with ProcessPoolExecutor(JOBS) as ex:
            futs = {ex.submit(run, j, data_dir): j for j in todo}
            for f in as_completed(futs):
                try:
                    print(f.result(), flush=True)
                except Exception as e:
                    print(f"FAILED {futs[f]['name']}: {e!r}", flush=True)
    write_index(data_dir)
    print(f"signals done in {(time.time() - t0) / 60:.1f} min", flush=True)
    if DRAW:
        import plot_kymographs
        plot_kymographs.main(MATCH)


if __name__ == "__main__":
    main()
