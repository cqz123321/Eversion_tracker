"""Decode frames and run the per-frame image work (optical flow, edge map, colour) on a thread pool,
ahead of the sequential curve tracker. OpenCV releases the GIL, so this scales over CPU cores."""
import queue
import threading
from concurrent.futures import ThreadPoolExecutor

import cv2

from colon import to_small, gray_of


class FramePipeline:
    def __init__(self, path, tr, first, step, last, workers):
        """Frames first, first+step, ... <= last; tr.prev must be the gray of frame first-step."""
        self.tr, self.step, self.last = tr, step, last
        self.next_idx = first
        self._stop = threading.Event()
        self._pool = ThreadPoolExecutor(max(1, workers))
        self._q = queue.Queue(maxsize=2 * max(1, workers) + 4)
        self._thread = threading.Thread(target=self._decode, args=(path, first, tr.prev.copy()), daemon=True)
        self._thread.start()

    def _prepare(self, frame, prev):
        """prev: gray of the previous frame, or the previous full-res frame (re-reduced here, in parallel)."""
        if prev.ndim == 3:
            prev = gray_of(to_small(prev, self.tr.scale))
        return self.tr.prepare(frame, prev)

    def _decode(self, path, idx, prev):
        cap = cv2.VideoCapture(path)
        cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
        try:
            while not self._stop.is_set() and idx <= self.last:
                ok, frame = cap.read()
                if not ok:
                    break
                self._put((idx, frame, self._pool.submit(self._prepare, frame, prev)))
                prev = frame
                for _ in range(self.step - 1):
                    cap.grab()
                idx += self.step
        finally:
            cap.release()
            self._put(None)

    def _put(self, item):
        while not self._stop.is_set():
            try:
                self._q.put(item, timeout=0.1)
                return
            except queue.Full:
                pass

    def get(self):
        """(frame idx, full-res frame, Prepared) for the next frame, or None at the end."""
        item = self._q.get()
        if item is None:
            self._q.put(None)
            return None
        idx, frame, fut = item
        self.next_idx = idx + self.step
        return idx, frame, fut.result()

    def close(self):
        self._stop.set()
        while True:
            try:
                self._q.get_nowait()
            except queue.Empty:
                break
        self._thread.join(timeout=2)
        self._pool.shutdown(wait=False, cancel_futures=True)
