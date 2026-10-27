"""Draw the kymograph PNGs from the CSVs written by export_kymographs.py (fast: no video decoding).

Just run this file. Change the display settings below and run again; every PNG is redrawn in seconds.
Needs only numpy + opencv.

Reads  data/<video>_kymograph.csv        frame, time_s, tip_station, s000 ... s099 (signal per station)
       data/<video>_kymograph_meta.json  threshold, fps, ... (one per video)
Writes <video>_kymograph.png in this folder.
"""
# ------------------------------------------------------------------ display settings
MATCH = ""            # only videos whose name contains this text ("" = all)
VMAX_FACTOR = 2.0     # colour scale = 0 .. VMAX_FACTOR x threshold (the GUI uses 2)
COLORMAP = "TURBO"    # any OpenCV colormap name: TURBO, JET, VIRIDIS, INFERNO, MAGMA, HOT, ...
SHOW_TIP = True       # white tip line
TIP_WIDTH = 3         # px
TIME_RANGE = None     # (t0, t1) in seconds to zoom in, None = whole video
SIZE = (1900, 620)    # PNG width, height (px)
# ------------------------------------------------------------------
import glob
import json
import os

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")


def read_kymo(csv_path):
    """-> frames, time_s, tip_station, sig (n_stations x n_frames)."""
    a = np.loadtxt(csv_path, delimiter=",", skiprows=1, ndmin=2)
    return a[:, 0].astype(int), a[:, 1], a[:, 2], a[:, 3:].T


INK, INK2 = (31, 31, 31), (92, 92, 92)


def _text(img, s, org, scale=0.6, color=INK, th=1, anchor="left"):
    import cv2
    (w, h), _ = cv2.getTextSize(s, cv2.FONT_HERSHEY_SIMPLEX, scale, th)
    x, y = org
    if anchor == "center":
        x -= w // 2
    elif anchor == "right":
        x -= w
    cv2.putText(img, s, (int(x), int(y)), cv2.FONT_HERSHEY_SIMPLEX, scale, color, th, cv2.LINE_AA)
    return w, h


def _nice_step(span, target=10):
    for s in (0.5, 1, 2, 5, 10, 20, 30, 60, 120, 300, 600):
        if span / s <= target:
            return s
    return 1200


def draw(name, frames, t, tip, sig, thr, out_png):
    cmap = getattr(cv2, "COLORMAP_" + COLORMAP.upper(), cv2.COLORMAP_TURBO)
    vmax = VMAX_FACTOR * thr
    if TIME_RANGE is not None:
        keep = (t >= TIME_RANGE[0]) & (t <= TIME_RANGE[1])
        frames, t, tip, sig = frames[keep], t[keep], tip[keep], sig[:, keep]
    n, T = sig.shape
    W, H = SIZE
    L, R, TOP, BOT = 110, 190, 60, 80
    kw, kh = W - L - R, H - TOP - BOT
    img = np.full((H, W, 3), 255, np.uint8)

    # column = the frame nearest to that time
    tx = np.linspace(t[0], t[-1], kw)
    cols = np.clip(np.searchsorted(t, tx), 0, T - 1)
    k = cv2.applyColorMap(np.clip(sig[:, cols] / vmax * 255, 0, 255).astype(np.uint8), cmap)
    img[TOP:TOP + kh, L:L + kw] = cv2.resize(k, (kw, kh), interpolation=cv2.INTER_NEAREST)

    def X(tt):
        return L + (tt - t[0]) / max(t[-1] - t[0], 1e-9) * (kw - 1)

    def Y(st):
        return TOP + st / max(n - 1, 1) * (kh - 1)

    if SHOW_TIP:
        ok = np.isfinite(tip)
        pts = np.stack([X(t[ok]), Y(tip[ok])], 1)
        cv2.polylines(img, [np.round(pts).astype(np.int32)], False, (255, 255, 255), TIP_WIDTH, cv2.LINE_AA)

    step = _nice_step(t[-1] - t[0])
    for v in np.arange(np.ceil(t[0] / step) * step, t[-1] + 1e-9, step):
        x = int(round(X(v)))
        cv2.line(img, (x, TOP + kh), (x, TOP + kh + 8), INK2, 1)
        _text(img, f"{v:g}", (x, TOP + kh + 32), 0.6, INK2, anchor="center")
    _text(img, "video time (s)", (L + kw // 2, H - 18), 0.7, INK, anchor="center")
    _text(img, "H", (L - 14, TOP + 18), 0.8, (26, 143, 26), 2, anchor="right")
    _text(img, "T", (L - 14, TOP + kh), 0.8, (40, 40, 198), 2, anchor="right")
    lab = np.full((40, kh, 3), 255, np.uint8)
    _text(lab, "station along the centerline", (kh // 2, 28), 0.65, INK, anchor="center")
    img[TOP:TOP + kh, 20:60] = cv2.rotate(lab, cv2.ROTATE_90_COUNTERCLOCKWISE)

    cx0, cx1 = L + kw + 25, L + kw + 50
    bar = cv2.applyColorMap(np.linspace(255, 0, kh).astype(np.uint8).reshape(-1, 1), cmap)
    img[TOP:TOP + kh, cx0:cx1] = cv2.resize(bar, (cx1 - cx0, kh), interpolation=cv2.INTER_NEAREST)
    for v in (0, vmax / 2, vmax):
        y = int(round(TOP + (1 - v / vmax) * (kh - 1)))
        cv2.line(img, (cx1, y), (cx1 + 6, y), INK2, 1)
        _text(img, f"{v:g}", (cx1 + 10, y + 6), 0.55, INK2)
    _text(img, "signal", (cx0, TOP - 12), 0.55, INK2)
    _text(img, f"(thr = {thr:g})", (cx0, TOP + kh + 32), 0.5, INK2)
    nm = name.encode("ascii", "replace").decode()
    _text(img, f"{nm}   -   recent_change kymograph (frames {frames[0]}-{frames[-1]}), white = tip",
          (L, 38), 0.75, INK)

    ok, buf = cv2.imencode(".png", img)        # imencode + tofile: works with non-ASCII paths on Windows
    if ok:
        buf.tofile(out_png)


def plot_one(name, out_dir=HERE):
    csv_path = os.path.join(DATA, name + "_kymograph.csv")
    with open(os.path.join(DATA, name + "_kymograph_meta.json"), encoding="utf-8") as f:
        meta = json.load(f)
    frames, t, tip, sig = read_kymo(csv_path)
    png = os.path.join(out_dir, name + "_kymograph.png")
    draw(name, frames, t, tip, sig, float(meta["thresh"]), png)
    return png


def main(match=None):
    match = MATCH if match is None else match
    names = sorted(os.path.basename(p)[:-len("_kymograph.csv")]
                   for p in glob.glob(os.path.join(DATA, "*_kymograph.csv")))
    names = [n for n in names if match.lower() in n.lower()]
    print(f"drawing {len(names)} kymograph(s)", flush=True)
    for n in names:
        try:
            plot_one(n)
            print("  " + n, flush=True)
        except Exception as e:
            print(f"  FAILED {n}: {e!r}", flush=True)


if __name__ == "__main__":
    main()
