"""Drawing: left overlay, right analysis views, signal profile and kymograph."""
import cv2
import numpy as np

from colon import point_at

CMAP = getattr(cv2, "COLORMAP_TURBO", cv2.COLORMAP_JET)
C_BND = (0, 255, 255)
C_CTR = (255, 255, 0)
C_ROBOT = (255, 0, 255)
C_TIP = (0, 0, 255)
C_HEAD = (0, 200, 0)
C_TAIL = (0, 0, 230)

C_ANCHOR = (0, 255, 0)
C_STRAP = (255, 80, 0)

VIEWS = ["Tracking 追踪叠加", "Signal 沿中心线信号", "Change 与基线差异", "Recent 短时间变化",
         "Strap 条带遮挡 (红)", "Edge map 边缘图 (吸附依据)", "Flow 帧间光流"]


def text(img, s, org, scale=0.6, color=(255, 255, 255)):
    cv2.putText(img, s, org, cv2.FONT_HERSHEY_SIMPLEX, scale, (0, 0, 0), 3, cv2.LINE_AA)
    cv2.putText(img, s, org, cv2.FONT_HERSHEY_SIMPLEX, scale, color, 1, cv2.LINE_AA)


def _pts(a, s):
    return np.round(np.asarray(a, np.float32) * s).astype(np.int32)


def draw_head_tail(img, ctr, s, th):
    if len(ctr) == 0:
        return
    h, t = _pts(ctr[0], s), _pts(ctr[-1], s)
    cv2.circle(img, tuple(h), 3 * th + 3, C_HEAD, -1, cv2.LINE_AA)
    text(img, "H", (int(h[0]) + 8, int(h[1]) - 8), 0.5 * th + 0.3, C_HEAD)
    if len(ctr) > 1:
        cv2.circle(img, tuple(t), 3 * th + 3, C_TAIL, -1, cv2.LINE_AA)
        text(img, "T", (int(t[0]) + 8, int(t[1]) - 8), 0.5 * th + 0.3, C_TAIL)


def draw_tracking(img, h, tip_station, s, th, robot=True, curves=True):
    """curves=False: only the robot (pink body + red tip) and the H/T markers, no boundary / centerline."""
    if curves:
        cv2.polylines(img, [_pts(h["bnd"], s)], True, C_BND, th, cv2.LINE_AA)
        cv2.polylines(img, [_pts(h["ctr"], s)], False, C_CTR, max(1, th - 1), cv2.LINE_AA)
    draw_head_tail(img, h["ctr"], s, th)
    if robot and tip_station is not None and tip_station > 0:
        i = int(np.floor(tip_station))
        tip, _, _ = point_at(h["ctr"], tip_station)
        body = np.vstack([h["ctr"][:i + 1], tip[None]])
        cv2.polylines(img, [_pts(body, s)], False, C_ROBOT, th + 2, cv2.LINE_AA)
        cv2.circle(img, tuple(_pts(tip, s)), 5 * th + 2, C_TIP, th + 1, cv2.LINE_AA)


def render_left(frame, h, tip_station, scale, editor=None, show_tracking=True, marks=None, curves=True):
    """frame at original resolution; h in processing pixels.
    editor = dict(bnd, ctr, active) in original px; marks = dict(tips, straps) points on this frame (original px)."""
    img = frame.copy()
    th = max(2, int(round(img.shape[1] / 700)))
    if h is not None and show_tracking:
        draw_tracking(img, h, tip_station, 1.0 / scale, th, curves=curves)
    if editor is not None:
        for key, closed, col in (("bnd", True, C_BND), ("ctr", False, C_CTR)):
            pts = editor[key]
            active = editor["active"] == key
            if len(pts) >= 2:
                cv2.polylines(img, [_pts(pts, 1)], closed and len(pts) >= 3, col, th + (1 if active else 0), cv2.LINE_AA)
            if active:
                for q in pts:
                    cv2.circle(img, tuple(_pts(q, 1)), 3 * th, (0, 128, 255), -1, cv2.LINE_AA)
        draw_head_tail(img, editor["ctr"], 1.0, th)
    for q in (marks or {}).get("tips", []):
        c = tuple(_pts(q, 1))
        cv2.drawMarker(img, c, C_ANCHOR, cv2.MARKER_CROSS, 12 * th, th + 1, cv2.LINE_AA)
        text(img, "tip", (c[0] + 8, c[1] + 18), 0.5 * th, C_ANCHOR)
    for q in (marks or {}).get("straps", []):
        cv2.drawMarker(img, tuple(_pts(q, 1)), C_STRAP, cv2.MARKER_SQUARE, 6 * th, th, cv2.LINE_AA)
    return img


def render_view(name, small, h, vis, thresh, tip_station, sig, view_max=40.0):
    img = small.copy()
    if name.startswith("Edge") and "edge" in vis:
        e = vis["edge"]
        img = cv2.applyColorMap(np.clip(e / (np.percentile(e, 99) + 1e-6) * 255, 0, 255).astype(np.uint8),
                                cv2.COLORMAP_BONE)
    elif name.startswith(("Change", "Recent")) and ("change" if name.startswith("Change") else "recent") in vis:
        m = vis["change" if name.startswith("Change") else "recent"]
        # raw per-pixel colour difference on a fixed scale (NOT the station signal, which is averaged
        # across the colon, smoothed and possibly normalised -- see the Signal view for that)
        img = cv2.applyColorMap(np.clip(m / max(view_max, 1e-3) * 255, 0, 255).astype(np.uint8), CMAP)
        text(img, f"pixel colour diff 0-{view_max:g} (display only)", (8, img.shape[0] - 10), 0.45)
    elif name.startswith("Strap") and "strap" in vis:
        img[vis["strap"]] = (0.4 * img[vis["strap"]] + (0, 0, 153)).astype(np.uint8)
    elif name.startswith("Flow") and "flow" in vis:
        f = vis["flow"]
        mag, ang = cv2.cartToPolar(f[..., 0], f[..., 1])
        hsv = np.zeros(img.shape, np.uint8)
        hsv[..., 0] = (ang * 90 / np.pi).astype(np.uint8)
        hsv[..., 1] = 255
        hsv[..., 2] = np.clip(mag / 3.0 * 255, 0, 255).astype(np.uint8)
        img = cv2.addWeighted(img, 0.4, cv2.cvtColor(hsv, cv2.COLOR_HSV2BGR), 0.8, 0)
        step = 24
        for y in range(step // 2, img.shape[0], step):
            for x in range(step // 2, img.shape[1], step):
                dx, dy = f[y, x] * 5
                cv2.arrowedLine(img, (x, y), (int(x + dx), int(y + dy)), (255, 255, 255), 1, cv2.LINE_AA, tipLength=0.3)
    if h is None:
        return img
    if name.startswith("Signal") and sig is not None:
        cols = cv2.applyColorMap(np.clip(sig / (2 * thresh) * 255, 0, 255).astype(np.uint8).reshape(-1, 1), CMAP)
        for i, xs in enumerate(h["xs"]):
            cv2.line(img, tuple(_pts(xs[0], 1)), tuple(_pts(xs[-1], 1)), tuple(int(c) for c in cols[i, 0]), 3, cv2.LINE_AA)
        cv2.polylines(img, [_pts(h["bnd"], 1)], True, C_BND, 1, cv2.LINE_AA)
        draw_head_tail(img, h["ctr"], 1.0, 1)
        if tip_station is not None:
            tip, _, _ = point_at(h["ctr"], tip_station)
            cv2.circle(img, tuple(_pts(tip, 1)), 8, C_TIP, 2, cv2.LINE_AA)
    else:
        draw_tracking(img, h, tip_station, 1.0, 1)
        if name.startswith("Tracking"):
            for xs in h["xs"][::5]:
                cv2.line(img, tuple(_pts(xs[0], 1)), tuple(_pts(xs[-1], 1)), (180, 180, 180), 1, cv2.LINE_AA)
    return img


PLOT_W, PLOT_H, PLOT_M = 1100, 260, 30


def _kymo_x():
    pw = int(PLOT_W * 0.32)
    return pw + PLOT_M, PLOT_W - 10


def kymo_frame_at(x, prog):
    """Frame index under plot x coordinate (None if outside the kymograph)."""
    kx0, kx1 = _kymo_x()
    if not prog.frames or not kx0 <= x < kx1:
        return None
    T = len(prog.frames)
    return prog.frames[int(np.clip((x - kx0) / (kx1 - kx0) * T, 0, T - 1))]


def render_plots(prog, cur_i, thresh):
    """Left: signal profile head->tail at the current frame. Right: kymograph (time x position)."""
    w, h, m = PLOT_W, PLOT_H, PLOT_M
    img = np.full((h, w, 3), 30, np.uint8)
    pw = int(w * 0.32)
    if cur_i is None or not prog.frames:
        text(img, "no tracking yet - draw boundary + centerline, then Start tracking", (10, h // 2), 0.55)
        return img
    # ---- profile
    sig = prog.sig[cur_i]
    n = len(sig)
    vmax = max(3 * thresh, float(np.abs(sig).max()) * 1.1, 1e-3)
    def py(v):
        return int(h - m - (np.clip(v, -vmax, vmax) + vmax) / (2 * vmax) * (h - 2 * m))
    def px(i):
        return int(m + i / max(n - 1, 1) * (pw - 2 * m))
    cv2.rectangle(img, (m, m), (pw - m, h - m), (90, 90, 90), 1)
    cv2.line(img, (m, py(0)), (pw - m, py(0)), (90, 90, 90), 1)
    cv2.line(img, (m, py(thresh)), (pw - m, py(thresh)), (0, 165, 255), 1)
    cv2.polylines(img, [np.array([[px(i), py(v)] for i, v in enumerate(sig)], np.int32)], False, (255, 255, 255), 1, cv2.LINE_AA)
    tip = prog.tip[cur_i]
    cv2.line(img, (px(tip), m), (px(tip), h - m), C_TIP, 1)
    cv2.line(img, (px(prog.raw[cur_i]), m), (px(prog.raw[cur_i]), h - m), (150, 150, 150), 1)
    text(img, "signal profile", (m, 20), 0.5)
    text(img, "H", (m - 5, h - 8), 0.5, C_HEAD)
    text(img, "T", (pw - m - 5, h - 8), 0.5, C_TAIL)
    text(img, f"thr {thresh:.3f}", (pw - m - 80, py(thresh) - 4), 0.4, (0, 165, 255))
    # ---- kymograph: x = time, y = station (head at top)
    kx0, kx1 = _kymo_x()
    kw, kh = kx1 - kx0, h - 2 * m
    mat = np.stack(prog.sig, 1)  # (n, T)
    T = mat.shape[1]
    cols = np.linspace(0, T - 1, min(T, kw)).astype(int)
    k = cv2.applyColorMap(np.clip(mat[:, cols] / (2 * thresh) * 255, 0, 255).astype(np.uint8), CMAP)
    k = cv2.resize(k, (kw, kh), interpolation=cv2.INTER_NEAREST)
    img[m:m + kh, kx0:kx1] = k
    tips = np.array(prog.tip)[cols]
    xs = kx0 + np.arange(len(cols)) * kw / max(len(cols), 1)
    ys = m + tips / max(n - 1, 1) * (kh - 1)
    cv2.polylines(img, [np.stack([xs, ys], 1).astype(np.int32)], False, (255, 255, 255), 2, cv2.LINE_AA)
    for f, st in prog.anchors.items():  # hand-marked tip positions
        if f in prog.frames:
            ax = kx0 + np.searchsorted(cols, prog.frames.index(f)) * kw / max(len(cols), 1)
            cv2.circle(img, (int(ax), int(m + st / max(n - 1, 1) * (kh - 1))), 5, C_ANCHOR, 2, cv2.LINE_AA)
    cx = int(kx0 + np.searchsorted(cols, cur_i) * kw / max(len(cols), 1))
    cv2.line(img, (cx, m), (cx, m + kh), (0, 165, 255), 1)
    text(img, f"kymograph (frames {prog.frames[0]}-{prog.frames[-1]}), white = tip", (kx0, 20), 0.5)
    text(img, "H", (kx0 - 18, m + 12), 0.5, C_HEAD)
    text(img, "T", (kx0 - 18, m + kh), 0.5, C_TAIL)
    return img


def side_by_side(left, right, height):
    def fit(im):
        return cv2.resize(im, (int(round(im.shape[1] * height / im.shape[0])), height), interpolation=cv2.INTER_AREA)
    return np.hstack([fit(left), fit(right)])


class VideoOut:
    """H.264 (libx264, constant quality) through the ffmpeg bundled with imageio-ffmpeg -- several times smaller
    than OpenCV's mp4v. Falls back to cv2.VideoWriter (mp4v) if imageio-ffmpeg is not installed."""

    def __init__(self, path, fps, crf=28):
        self.path, self.fps, self.crf = path, fps, crf
        self._proc = self._cv = None
        self.fallback = False

    def write(self, img):
        if self._proc is None and self._cv is None:
            self._open(img.shape[1] // 2 * 2, img.shape[0] // 2 * 2)
        img = img[:img.shape[0] // 2 * 2, :img.shape[1] // 2 * 2]  # yuv420p needs even sizes
        if self._proc is not None:
            self._proc.stdin.write(np.ascontiguousarray(img).tobytes())
        else:
            self._cv.write(img)

    def _open(self, w, h):
        try:
            import subprocess
            import imageio_ffmpeg
            self._proc = subprocess.Popen(
                [imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgr24",
                 "-s", f"{w}x{h}", "-r", f"{self.fps:g}", "-i", "-", "-c:v", "libx264", "-preset", "medium",
                 "-crf", str(self.crf), "-pix_fmt", "yuv420p", self.path], stdin=subprocess.PIPE)
        except ImportError:  # mp4v needs ~10-30x the bytes of H.264 at similar quality
            self.fallback = True
            self._cv = cv2.VideoWriter(self.path, cv2.VideoWriter_fourcc(*"mp4v"), self.fps, (w, h))

    def close(self):
        if self._proc is not None:
            self._proc.stdin.close()
            self._proc.wait()
        if self._cv is not None:
            self._cv.release()
