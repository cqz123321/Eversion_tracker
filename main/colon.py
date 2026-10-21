"""Stage 2: track the hand-drawn colon boundary + centerline.  Stage 3: tip progress along the centerline.

All coordinates inside this module are in processing pixels (frame scaled to proc_width).
"""
from bisect import bisect_left
from collections import deque, namedtuple

import cv2
import numpy as np

from config import N_BND, N_OFF, odd
from flowfield import FlowEngine, sample
from geometry import (resample_open, resample_closed, smooth_open, smooth_closed, normals,
                      snap_to_edges, half_widths, polygon_mask, arclength, fit_affine,
                      align_closed, project_station)

OFFS = np.linspace(-1, 1, N_OFF).astype(np.float32)

# Tracking-independent image work for one frame (computed ahead of time on worker threads).
Prepared = namedtuple("Prepared", "small gray flow edge lab")


def proc_scale(p, w):
    return 1.0 if p.proc_width <= 0 or p.proc_width >= w else p.proc_width / w


def to_small(frame, scale):
    if scale == 1.0:
        return frame
    h, w = frame.shape[:2]
    return cv2.resize(frame, (int(round(w * scale)), int(round(h * scale))), interpolation=cv2.INTER_AREA)


def gray_of(small):
    return cv2.GaussianBlur(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), (5, 5), 0)


EDGE_CHANNELS = ["b", "gray", "L", "a", "S", "V", "R", "G", "B"]


def edge_channel(small, name):
    if name in ("L", "a", "b"):
        return cv2.cvtColor(small, cv2.COLOR_BGR2LAB)[..., "Lab".index(name)]
    if name in ("S", "V"):
        return cv2.cvtColor(small, cv2.COLOR_BGR2HSV)[..., "HSV".index(name)]
    if name in ("R", "G", "B"):
        return small[..., "BGR".index(name)]
    return cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)


def edge_map(small, p):
    """Gradient of the chosen channel, normalised so the strongest 1% of edges ~ 1.

    Returns (magnitude, gx, gy); edges weaker than p.edge_min are removed.
    """
    g = np.ascontiguousarray(edge_channel(small, p.edge_channel))
    if p.edge_clahe:
        g = cv2.createCLAHE(2.0, (8, 8)).apply(g)
    k = odd(p.edge_blur)
    g = cv2.GaussianBlur(g, (k, k), 0).astype(np.float32) if k > 1 else g.astype(np.float32)
    gx, gy = cv2.Sobel(g, cv2.CV_32F, 1, 0), cv2.Sobel(g, cv2.CV_32F, 0, 1)
    mag = cv2.magnitude(gx, gy)
    s = float(np.percentile(mag[::3, ::3], 99)) + 1e-6
    mag, gx, gy = mag / s, gx / s, gy / s
    if p.edge_min > 0:
        weak = mag < p.edge_min
        mag[weak] = gx[weak] = gy[weak] = 0
    return mag, gx, gy


def lab_delta(a, b, light_weight):
    """Colour distance between Lab arrays (..., 3) (8-bit Lab units); brightness weighted by light_weight."""
    d = a.astype(np.float32) - b.astype(np.float32)
    return np.sqrt(light_weight * d[..., 0] ** 2 + d[..., 1] ** 2 + d[..., 2] ** 2)


def strap_dist(lab, colors):
    """Distance (..., ) from each Lab sample to the nearest picked strap colour."""
    d = lab.astype(np.float32)[..., None, :] - np.asarray(colors, np.float32)
    return np.sqrt((d ** 2).sum(-1)).min(-1)


def cross_section(ctr, mask, rmax):
    nrm = normals(ctr, closed=False)
    wp, wm = half_widths(mask, ctr, nrm, rmax)
    off = np.where(OFFS >= 0, OFFS[None] * wp[:, None], OFFS[None] * wm[:, None])
    pts = ctr[:, None, :] + nrm[:, None, :] * off[..., None]
    return nrm, wp, wm, pts


class ColonTracker:
    def __init__(self, p):
        self.p = p
        self.flow = FlowEngine(p)
        self.active = False
        self.history = {}
        self.end = None

    # -------------------------------------------------------------- start
    def start(self, frame, idx, bnd_orig, ctr_orig, end=None):
        """end (optional): dict(frame=image, idx, bnd, ctr, tip=(x, y) or None) -- the annotated last frame."""
        p = self.p
        self.scale = proc_scale(p, frame.shape[1])
        small = to_small(frame, self.scale)
        self.shape = small.shape[:2]
        self.rmax = int(max(self.shape) * 0.3)
        bnd = np.asarray(bnd_orig, np.float32) * self.scale
        perim = arclength(np.vstack([bnd, bnd[:1]]))[-1]
        self.bnd = resample_closed(bnd, int(np.clip(perim / 3, N_BND, 1000)))  # ~3 px spacing
        self.ctr = resample_open(np.asarray(ctr_orig, np.float32) * self.scale, max(5, p.n_stations))
        self.bnd0, self.ctr0 = self.bnd.copy(), self.ctr.copy()
        self.prev = gray_of(small)
        self.start_idx = self.last_idx = idx
        mask = polygon_mask(self.bnd, self.shape)
        _, wp, wm, pts = cross_section(self.ctr, mask, self.rmax)
        self.base_width = wp + wm
        self.base_samples = sample(self.prev.astype(np.float32), pts)
        self.colon_len0 = arclength(self.ctr)[-1]
        # colour baseline + background pixels used to estimate the camera gain
        self.base_color = cv2.GaussianBlur(small, (7, 7), 0).astype(np.float32)
        outside = (cv2.dilate(mask, np.ones((25, 25), np.uint8)) == 0) & (self.base_color.mean(2) > 40)
        self._out_idx = np.flatnonzero(outside)[::7]
        self._base_gain = (np.median(self.base_color.reshape(-1, 3)[self._out_idx], 0)
                           if len(self._out_idx) else None)
        self.base_lab_img = cv2.cvtColor(np.clip(self.base_color, 0, 255).astype(np.uint8), cv2.COLOR_BGR2LAB)
        self.base_lab = sample(self.base_lab_img, pts)  # baseline colour at the colon points ("material")
        self.recent_buf = deque()  # (frame idx, Lab image) for "recent_change"
        self.history = {}
        self.vis = {}
        self.end = self._measure_end(end) if end else None
        self._record(idx, Prepared(small, self.prev, None, None, self.lab_image(small)), mask)
        self._snap = None
        self.active = True

    def _measure_end(self, end):
        """Annotated end frame: target shape for shape_keep + per-station reference signal."""
        small = to_small(end["frame"], self.scale)
        ctr = resample_open(np.asarray(end["ctr"], np.float32) * self.scale, len(self.ctr))
        bnd = align_closed(self.bnd, np.asarray(end["bnd"], np.float32) * self.scale)
        mask = polygon_mask(bnd, self.shape)
        tip = None
        if end.get("tip") is not None:
            tip = project_station(ctr, np.asarray(end["tip"], np.float32) * self.scale)
        h = self._measure(ctr, mask, gray_of(small), self.lab_image(small), None)
        return dict(idx=int(end["idx"]), bnd=bnd, ctr=ctr, h=h, tip=tip)

    def corrected(self, small):
        """Blurred frame with the camera gain corrected on the background outside the colon."""
        cur = cv2.GaussianBlur(small, (7, 7), 0).astype(np.float32)
        if self.p.exposure_comp and self._base_gain is not None:
            cur = cur * (self._base_gain / np.maximum(np.median(cur.reshape(-1, 3)[self._out_idx], 0), 1.0))
        return cur

    def lab_image(self, small):
        return cv2.cvtColor(np.clip(self.corrected(small), 0, 255).astype(np.uint8), cv2.COLOR_BGR2LAB)

    # -------------------------------------------------------------- per frame
    def prepare(self, frame, prev_gray, small=None, gray=None):
        """All image work for one frame that does not depend on the tracked curves (thread-safe)."""
        p = self.p
        if small is None:
            small = to_small(frame, self.scale)
        if gray is None:
            gray = gray_of(small)
        flow = self.flow.compute(prev_gray, gray) if p.follow_flow else None
        return Prepared(small, gray, flow, edge_map(small, p), self.lab_image(small))

    def _shape_target(self, idx):
        """Drawn shape at frame idx: the start shape, blended towards the end shape if one was annotated."""
        if self.end is None or self.end["idx"] <= self.start_idx:
            return self.bnd0, self.ctr0
        t = np.clip((idx - self.start_idx) / (self.end["idx"] - self.start_idx), 0.0, 1.0)
        return self.bnd0 + t * (self.end["bnd"] - self.bnd0), self.ctr0 + t * (self.end["ctr"] - self.ctr0)

    def process(self, frame, idx, redo=False):
        """Advance the tracked curves to `frame` (an image or a Prepared).
        redo=True re-runs the last frame with the current params."""
        p = self.p
        if redo:
            if self._snap is None:
                return
            self.prev, self.bnd, self.ctr = (a.copy() for a in self._snap)
        else:
            self._snap = (self.prev.copy(), self.bnd.copy(), self.ctr.copy())
        pr = frame if isinstance(frame, Prepared) else self.prepare(frame, self.prev)
        f = pr.flow if pr.flow is not None else np.zeros(pr.gray.shape + (2,), np.float32)
        _, gx, gy = pr.edge
        # Only the per-frame DISPLACEMENT is smoothed (smoothing positions every frame shrinks the curve).
        bnd = self.bnd + sample(f, self.bnd)
        if p.snap_radius > 0 and p.snap_weight > 0:
            snapped = snap_to_edges(bnd, gx, gy, p.snap_radius, p.edge_polarity, polygon_mask(bnd, self.shape))
            bnd = bnd + p.snap_weight * (snapped - bnd)
        bnd = self.bnd + smooth_closed(bnd - self.bnd, p.shape_smooth * len(bnd) / N_BND)
        bnd_t, ctr_t = self._shape_target(idx)
        if p.shape_keep > 0:  # pull towards the drawn shape, after its best global (affine) motion
            bnd = bnd + p.shape_keep * (fit_affine(bnd_t, bnd)(bnd_t) - bnd)
        mask = polygon_mask(bnd, self.shape)

        ctr = self.ctr + sample(f, self.ctr)
        if p.center_pull > 0:
            nrm = normals(ctr, closed=False)
            wp, wm = half_widths(mask, ctr, nrm, self.rmax)
            # slow, smooth correction: capped per frame and smoothed along the centerline,
            # so boundary wobble (e.g. at tight bends) does not shake the centerline
            corr = np.clip(p.center_pull * (wp - wm) / 2, -0.5, 0.5)[:, None] * nrm
            ctr = ctr + smooth_open(corr, 5.0)
        ctr = self.ctr + smooth_open(ctr - self.ctr, p.shape_smooth)
        if p.shape_keep > 0:
            ctr = ctr + p.shape_keep * (fit_affine(ctr_t, ctr)(ctr_t) - ctr)

        self.bnd, self.ctr, self.prev = bnd, ctr, pr.gray
        self.last_idx = idx
        self.vis = dict(edge=pr.edge[0])
        if pr.flow is not None:
            self.vis["flow"] = pr.flow
        self._record(idx, pr, mask)

    def _measure(self, ctr, mask, gray, lab, lab_old):
        """Per-station samples for one frame (stage 3 turns these into a signal)."""
        _, wp, wm, pts = cross_section(ctr, mask, self.rmax)
        h = dict(ctr=ctr.copy(), width=wp + wm, xs=pts,
                 samples=sample(gray.astype(np.float32), pts),
                 lab=sample(lab, pts), lab_base=sample(self.base_lab_img, pts))
        if lab_old is not None:
            h["lab_old"] = sample(lab_old, pts)
        return h

    def _old_lab(self, idx, lab):
        """Lab image `recent_frames` before idx (oldest available) for "recent_change"."""
        buf = self.recent_buf
        while buf and buf[-1][0] >= idx:  # redo / restore: drop this frame and later ones
            buf.pop()
        buf.append((idx, lab))
        target = idx - self.p.recent_frames
        while len(buf) > 1 and buf[1][0] <= target:
            buf.popleft()
        return buf[0][1]

    def _record(self, idx, pr, mask):
        h = self._measure(self.ctr, mask, pr.gray, pr.lab, self._old_lab(idx, pr.lab))
        h["bnd"] = self.bnd.copy()
        self.history[idx] = h
        self.small, self.lab = pr.small, pr.lab

    # -------------------------------------------------------------- analysis views
    def change_map(self, small, live=False, old=None):
        """Colour distance to the baseline frame and to the `recent` frame
        (live: from the look-back buffer; reviewing: `old` = the full-res frame recent_frames earlier)."""
        lab = self.lab if live else self.lab_image(small)
        out = dict(change=lab_delta(lab, self.base_lab_img, self.p.light_weight))
        if live and self.recent_buf:
            out["recent"] = lab_delta(lab, self.recent_buf[0][1], self.p.light_weight)
        elif old is not None:
            out["recent"] = lab_delta(lab, self.lab_image(to_small(old, self.scale)), self.p.light_weight)
        return out

    def recent_ref(self, idx):
        """Tracked frame that "recent_change" compares frame idx with (as _old_lab picks it)."""
        keys = sorted(k for k in self.history if k < idx)
        older = [k for k in keys if k <= idx - self.p.recent_frames]
        return older[-1] if older else keys[0] if keys else idx

    # -------------------------------------------------------------- seeking
    def restore(self, frame, idx, read=None):
        """Make frame `idx` (already in history) the current state; later history is discarded.
        read(k) -> full-res frame k: used to rebuild the "recent_change" look-back buffer."""
        h = self.history[idx]
        self.bnd, self.ctr = h["bnd"].copy(), h["ctr"].copy()
        self.small = to_small(frame, self.scale)
        self.prev = gray_of(self.small)
        self.lab = self.lab_image(self.small)
        self.last_idx = idx
        self._snap = None
        self.vis = {}
        self.recent_buf.clear()
        if read is not None:
            ref = self.recent_ref(idx)
            for k in sorted(k for k in self.history if ref <= k < idx):
                f = read(k)
                if f is not None:
                    self.recent_buf.append((k, self.lab_image(to_small(f, self.scale))))
        self.recent_buf.append((idx, self.lab))
        for k in [k for k in self.history if k > idx]:
            del self.history[k]


# ---------------------------------------------------------------- stage 3
def _fill_nan(s):
    ok = np.isfinite(s)
    if ok.all() or not ok.any():
        return np.nan_to_num(s)
    i = np.arange(len(s))
    return np.interp(i, i[ok], s[ok])


def _smooth_stations(s):
    return cv2.GaussianBlur(s.astype(np.float32).reshape(-1, 1), (1, 7), 0, sigmaY=1.5).ravel()


def station_signal(h, tr, p, straps=None):
    """Per-station signal (head -> tail) for one history entry. straps: picked strap Lab colours."""
    sel = np.abs(OFFS) <= max(p.strip_frac, 0.13)
    if p.feature in ("change", "recent_change"):
        cur = h["lab"][:, sel]
        if p.feature == "recent_change":
            ref = h.get("lab_old", h["lab"])[:, sel]
        else:
            ref = (tr.base_lab if p.compare == "material" else h["lab_base"])[:, sel]
        d = lab_delta(cur, ref, p.light_weight)
        if straps is not None and len(straps) and p.strap_tol > 0:
            # a sample on a strap (now or in the reference frame) says nothing about the robot
            valid = (strap_dist(cur, straps) > p.strap_tol) & (strap_dist(ref, straps) > p.strap_tol)
            n = valid.sum(1)
            s = np.where(n >= max(1, valid.shape[1] // 4), (d * valid).sum(1) / np.maximum(n, 1), np.nan)
            return _smooth_stations(_fill_nan(s))
        return _smooth_stations(d.mean(1))
    cur = h["samples"][:, sel]
    base = tr.base_samples[:, sel]
    if p.exposure_comp:
        cur = cur * (np.median(base) / max(np.median(cur), 1e-3))
    darker = ((base - cur) / (base + 10.0)).mean(1)
    wider = h["width"] / np.maximum(tr.base_width, 1.0) - 1.0
    s = {"darker": darker, "brighter": -darker, "intensity_abs": np.abs(darker),
         "wider": wider, "darker+wider": darker + wider}[p.feature]
    return _smooth_stations(s)


def reference_signal(tr, p, straps=None):
    """Per-station signal at the annotated end frame (robot fully in), used to normalise every station.
    None if there is no end annotation or the feature is not cumulative."""
    if not p.normalize or tr.end is None or p.feature in ("recent_change", "brighter", "intensity_abs"):
        return None
    ref = station_signal(tr.end["h"], tr, p, straps)
    if tr.end["tip"] is not None:  # stations beyond the robot's final position were never reached
        reach = int(np.clip(np.floor(tr.end["tip"]), 1, len(ref) - 1))
        ref[reach:] = np.median(ref[:reach])
    return np.maximum(ref, max(0.3 * float(np.median(ref)), 1e-3))


def find_tip(sig, p):
    above = sig >= p.sig_thresh
    # peak / farthest return None when nothing is above threshold -> the tip holds its last position
    if p.tip_rule == "peak":  # strongest station (useful for recent_change: the actively moving zone)
        i = int(np.argmax(sig))
        return float(i) if above[i] else None
    if p.tip_rule == "farthest":
        idx = np.nonzero(above)[0]
        return float(idx.max()) if len(idx) else None
    last, gap = 0, 0
    for i, a in enumerate(above):
        if a:
            last, gap = i, 0
        else:
            gap += 1
            if gap > p.max_gap:
                break
    return float(last)


def anchor_stations(tr, tips, step):
    """Hand-marked tip positions [(frame, x, y) original px] -> {tracked frame: station}."""
    out = {}
    if not tr.history:
        return out
    keys = np.array(sorted(tr.history))
    for f, x, y in tips:
        k = int(keys[np.argmin(np.abs(keys - f))])
        if abs(k - f) <= max(step, 1):
            out[k] = project_station(tr.history[k]["ctr"], np.array([x, y], np.float32) * tr.scale)
    return out


class Progress:
    """Signal + tip for every tracked frame; recomputed instantly when stage-3 params change."""

    def __init__(self, p):
        self.p = p
        self.straps = None     # picked strap Lab colours
        self.anchors = {}      # tracked frame -> hand-marked tip station
        self._ckpt = {}        # "global"/"ridge": DP state after the first j frames, every CKPT frames
        self.invalidate()

    def invalidate(self):
        self.frames, self.sig = [], []
        self._ref = False  # per-station normaliser, computed on the next update
        self.invalidate_tips()

    CKPT = 100

    def invalidate_tips(self, keep=0):
        """Forget the tips; the global DP keeps its state for the first `keep` frames (rounded down to a checkpoint)."""
        self.raw, self.tip = [], []
        keep = max((j for j in self._ckpt if j <= keep), default=0)
        self._ckpt = {j: d for j, d in self._ckpt.items() if j <= keep}
        self._D = self._ckpt[keep].copy() if keep else None
        self._bp = self._bp[:keep] if keep else []

    def set_anchors(self, anchors):
        if anchors != self.anchors:
            changed = set(anchors.items()) ^ set(self.anchors.items())
            self.anchors = anchors
            # only frames from the first changed anchor on need the DP again
            self.invalidate_tips(bisect_left(self.frames, min(f for f, _ in changed)))

    def update(self, tr):
        keys = sorted(tr.history)
        if keys[:len(self.frames)] != self.frames:
            self.invalidate()
        if self._ref is False:
            self._ref = reference_signal(tr, self.p, self.straps)
        for k in keys[len(self.frames):]:
            s = station_signal(tr.history[k], tr, self.p, self.straps)
            if self._ref is not None:
                s = s / self._ref
            if self.p.collective_q > 0:
                # changes covering most of the colon at once (lighting, whole-phantom motion) are not the tip:
                # keep only what rises above the q-quantile of this frame's stations
                s = np.maximum(s - np.quantile(s, self.p.collective_q), 0.0)
            if self.sig:  # temporal smoothing of the signal (per station), time constant in video frames
                a = min(1.0, (k - self.frames[-1]) / max(self.p.sig_time_frames, 1))
                s = a * s + (1 - a) * self.sig[-1]
            self.frames.append(k)
            self.sig.append(s)
        if len(self.tip) == len(self.frames):
            return
        if self.p.tip_rule in ("global", "ridge"):
            self._update_global()
            return
        for i in range(len(self.tip), len(self.frames)):
            raw = self.anchors.get(self.frames[i])
            if raw is None:
                raw = find_tip(self.sig[i], self.p)
            if raw is None:
                raw = self.tip[-1] if self.tip else 0.0
            if self.tip and self.frames[i] not in self.anchors:
                prev = self.tip[-1]
                t = prev + self.p.tip_alpha * (raw - prev)
                if self.p.monotonic:
                    t = max(t, prev)
            else:
                t = raw
            self.raw.append(raw)
            self.tip.append(t)

    def _update_global(self):
        """Best tip path over ALL tracked frames (dynamic programming / Viterbi).
        global: per frame, stations behind the tip should be above the threshold and stations ahead below it.
        ridge:  the path collects as much above-threshold signal as possible (follows the bright ridge of
                recent_change in the kymograph); where nothing is above threshold the tip stays.
        The tip moves at most max_speed stations per video frame (only forward if monotonic) and passes
        through the hand-marked anchors. Later frames can correct earlier tips.

        max_speed < 1 is enforced with a cool-down: the DP state is (station, frames since the last move,
        capped at L = 1/max_speed); a move is allowed only once L frames have passed."""
        p = self.p
        ridge = p.tip_rule == "ridge"
        thr = max(p.sig_thresh, 1e-6)
        n = len(self.sig[0])
        stations = np.arange(n)
        r = max(p.max_speed, 1e-3)
        L = max(1, int(round(1.0 / r))) if r < 1 else 1
        eps = 1e-4  # tiny cost per station moved: with no signal (ties) the tip stays rather than drifting
        itype = np.int16 if (L + 1) * n < 32767 else np.int32
        flat = np.arange(L + 1)[:, None] * n + stations  # state (c, s) -> c * n + s
        for i in range(len(self._bp), len(self.frames)):
            if ridge:
                cost = -np.clip((self.sig[i] - thr) / thr, 0.0, 3.0)
            else:
                cost = -np.cumsum(np.clip((self.sig[i] - thr) / thr, -1.0, 1.0))
            a = self.anchors.get(self.frames[i], 0.0 if i == 0 else None)  # baseline frame: robot not in yet
            if a is not None:  # grows with the distance, so an anchor out of reach is still approached
                cost = cost + 1e4 * np.maximum(np.abs(stations - a) - 1.0, 0.0)
            if self._D is None:
                self._D = np.full((L + 1, n), np.inf)
                self._D[L] = cost  # may move right away
                self._bp.append(None)
                continue
            dt = self.frames[i] - self.frames[i - 1]
            d = min(dt, L)
            k = max(1, int(np.floor(r * dt + 1e-6)))
            best = np.full((L + 1, n), np.inf)
            arg = np.zeros((L + 1, n), itype)  # previous state
            # stay: the cool-down counter advances by dt (capped at L)
            best[d:L], arg[d:L] = self._D[:L - d], flat[:L - d]
            ready = self._D[L - d:]
            j = ready.argmin(0)
            best[L], arg[L] = ready[j, stations], flat[L - d + j, stations]
            # move m stations (previous station = s - m): only from a ready state; resets the counter
            src, src_arg = best[L].copy(), arg[L].copy()
            for m in range(1, k + 1):
                for mm in ((m,) if p.monotonic else (m, -m)):
                    cand = np.full(n, np.inf)
                    carg = np.zeros(n, itype)
                    if mm > 0:
                        cand[mm:], carg[mm:] = src[:n - mm], src_arg[:n - mm]
                    else:
                        cand[:mm], carg[:mm] = src[-mm:], src_arg[-mm:]
                    cand += eps * m
                    better = cand < best[0]
                    best[0][better] = cand[better]
                    arg[0][better] = carg[better]
            self._D = best + cost
            self._D -= self._D[np.isfinite(self._D)].min()
            self._bp.append(arg)
            if len(self._bp) % self.CKPT == 0:
                self._ckpt[len(self._bp)] = self._D.copy()
        state = int(np.argmin(self._D))
        tips = np.empty(len(self.frames))
        for i in range(len(self.frames) - 1, -1, -1):
            tips[i] = state % n
            if i:
                state = int(self._bp[i].flat[state])
        self.tip = tips.tolist()
        self.raw = self.tip

    def at(self, idx):
        if not self.frames:
            return None
        i = int(np.searchsorted(self.frames, idx, side="right")) - 1
        return None if i < 0 else i


def point_at(ctr, station):
    """Interpolated centerline position and arc length at a fractional station index."""
    i0 = int(np.clip(np.floor(station), 0, len(ctr) - 1))
    i1 = min(i0 + 1, len(ctr) - 1)
    a = station - i0
    s = arclength(ctr)
    return ctr[i0] * (1 - a) + ctr[i1] * a, s[i0] * (1 - a) + s[i1] * a, s[-1]
