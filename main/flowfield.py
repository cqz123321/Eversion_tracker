"""Dense optical flow (DIS) and sampling helpers."""
import threading

import cv2
import numpy as np


class FlowEngine:
    """Thread-safe: every thread gets its own DIS instance (frames are processed in parallel)."""

    def __init__(self, p):
        self.p = p
        self._local = threading.local()

    def compute(self, a, b):
        """Flow f with a(x) ~ b(x + f(x))."""
        dis = getattr(self._local, "dis", None)
        if dis is None:
            dis = self._local.dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
        f = dis.calc(a, b, None)
        if self.p.flow_smooth > 0:
            f = cv2.GaussianBlur(f, (0, 0), self.p.flow_smooth)
        return f


def sample(img, pts):
    """Bilinear sample of img at pts (..., 2). Returns shape pts.shape[:-1] (+ channels)."""
    shp = pts.shape[:-1]
    flat = pts.reshape(1, -1, 2).astype(np.float32)
    mx, my = np.ascontiguousarray(flat[..., 0]), np.ascontiguousarray(flat[..., 1])
    out = cv2.remap(img, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    return out.reshape(shp + img.shape[2:])
