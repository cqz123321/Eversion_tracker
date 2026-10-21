"""Curve utilities for the boundary (closed) and centerline (open)."""
import cv2
import numpy as np


def _arclen(pts):
    return np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))])


def resample_open(pts, n):
    pts = np.asarray(pts, np.float32)
    s = _arclen(pts)
    if s[-1] < 1e-6:
        return np.repeat(pts[:1], n, 0)
    t = np.linspace(0, s[-1], n)
    return np.stack([np.interp(t, s, pts[:, 0]), np.interp(t, s, pts[:, 1])], 1).astype(np.float32)


def resample_closed(pts, n):
    pts = np.asarray(pts, np.float32)
    closed = np.vstack([pts, pts[:1]])
    s = _arclen(closed)
    if s[-1] < 1e-6:
        return np.repeat(pts[:1], n, 0)
    t = np.linspace(0, s[-1], n, endpoint=False)
    return np.stack([np.interp(t, s, closed[:, 0]), np.interp(t, s, closed[:, 1])], 1).astype(np.float32)


def _kernel(sigma):
    r = int(3 * sigma) + 1
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    return k / k.sum(), r


def smooth_closed(pts, sigma):
    if sigma <= 0 or len(pts) < 5:
        return pts
    k, r = _kernel(sigma)
    r = min(r, len(pts) - 1)
    k = k[len(k) // 2 - r: len(k) // 2 + r + 1]
    k /= k.sum()
    padded = np.pad(pts, ((r, r), (0, 0)), mode="wrap")
    return np.stack([np.convolve(padded[:, i], k, "valid") for i in range(2)], 1).astype(np.float32)


def smooth_open(pts, sigma):
    """Gaussian smoothing along an open curve (edge-padded)."""
    if sigma <= 0 or len(pts) < 5:
        return pts
    k, r = _kernel(sigma)
    padded = np.pad(pts, ((r, r), (0, 0)), mode="edge")
    return np.stack([np.convolve(padded[:, i], k, "valid") for i in range(2)], 1).astype(np.float32)


def fit_affine(src, dst):
    """Least-squares 2x3 affine mapping src -> dst."""
    X = np.hstack([src, np.ones((len(src), 1), np.float32)])
    A, *_ = np.linalg.lstsq(X, dst, rcond=None)
    return lambda pts: (np.hstack([pts, np.ones((len(pts), 1), np.float32)]) @ A).astype(np.float32)


def normals(pts, closed):
    if closed:
        tang = np.roll(pts, -1, 0) - np.roll(pts, 1, 0)
    else:
        tang = np.gradient(pts, axis=0)
    tang = tang / (np.linalg.norm(tang, axis=1, keepdims=True) + 1e-6)
    return np.stack([-tang[:, 1], tang[:, 0]], 1).astype(np.float32)


def outward_normals(pts, mask):
    """Normals of a closed curve, oriented to point out of `mask`."""
    nrm = normals(pts, True)
    probe = pts + 3 * nrm
    h, w = mask.shape
    xi = np.clip(np.round(probe[:, 0]).astype(int), 0, w - 1)
    yi = np.clip(np.round(probe[:, 1]).astype(int), 0, h - 1)
    return -nrm if (mask[yi, xi] > 0).mean() > 0.5 else nrm


def snap_to_edges(pts, gx, gy, radius, polarity, mask):
    """Move each closed-curve point along its normal to the best edge within +-radius.

    Only the gradient component ACROSS the contour counts (edges crossing the contour are ignored).
    polarity: "any" | "inside_higher" (channel larger inside the colon) | "inside_lower".
    """
    nrm = outward_normals(pts, mask)
    offs = np.arange(-radius, radius + 1, dtype=np.float32)
    sx = (pts[:, 0, None] + nrm[:, 0, None] * offs[None]).astype(np.float32)
    sy = (pts[:, 1, None] + nrm[:, 1, None] * offs[None]).astype(np.float32)
    rx = cv2.remap(gx, sx, sy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    ry = cv2.remap(gy, sx, sy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    d = rx * nrm[:, 0, None] + ry * nrm[:, 1, None]  # derivative along the outward normal
    vals = {"inside_higher": np.maximum(-d, 0), "inside_lower": np.maximum(d, 0)}.get(polarity, np.abs(d))
    vals = vals * np.exp(-0.5 * (offs / max(radius, 1)) ** 2)[None]  # mild preference for small moves
    best = np.argmax(vals, axis=1)
    shift = np.where(vals[np.arange(len(pts)), best] > 0, offs[best], 0)  # no edge found -> stay
    return (pts + nrm * shift[:, None]).astype(np.float32)


def half_widths(mask, pts, nrm, rmax):
    """Distance from each station to the mask border along +normal and -normal."""
    offs = np.arange(1, rmax + 1, dtype=np.float32)
    m = mask.astype(np.float32)
    out = []
    for sgn in (1, -1):
        sx = (pts[:, 0, None] + sgn * nrm[:, 0, None] * offs[None]).astype(np.float32)
        sy = (pts[:, 1, None] + sgn * nrm[:, 1, None] * offs[None]).astype(np.float32)
        inside = cv2.remap(m, sx, sy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=0) >= 127
        w = np.where(inside.all(1), rmax, np.argmin(inside, axis=1)).astype(np.float32)
        out.append(np.maximum(w, 1.0))
    return out[0], out[1]


def polygon_mask(pts, shape):
    m = np.zeros(shape, np.uint8)
    cv2.fillPoly(m, [np.round(pts).astype(np.int32)], 255)
    return m


def arclength(pts):
    return _arclen(pts)


def signed_area(pts):
    x, y = pts[:, 0], pts[:, 1]
    return 0.5 * float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))


def align_closed(ref, pts):
    """Resample closed curve `pts` to len(ref) points with ref's orientation and starting point,
    so that pts[i] corresponds to ref[i]."""
    pts = resample_closed(pts, len(ref))
    if np.sign(signed_area(pts)) != np.sign(signed_area(ref)):
        pts = pts[::-1].copy()
    a, b = ref - ref.mean(0), pts - pts.mean(0)
    # corr[k] = sum_i a_i . b_(i+k)  (circular cross-correlation)
    corr = np.fft.irfft(np.conj(np.fft.rfft(a, axis=0)) * np.fft.rfft(b, axis=0), n=len(a), axis=0).sum(1)
    return np.roll(pts, -int(np.argmax(corr)), 0).astype(np.float32)


def project_station(ctr, pt):
    """Fractional index of the point on the open polyline `ctr` closest to `pt`."""
    a, b = ctr[:-1], ctr[1:]
    ab = b - a
    t = np.clip(((pt - a) * ab).sum(1) / np.maximum((ab * ab).sum(1), 1e-9), 0, 1)
    i = int(np.argmin(np.linalg.norm(a + t[:, None] * ab - pt, axis=1)))
    return i + float(t[i])
