"""Compact '<video>_track_curves.jsonl.gz' (gzipped, one JSON line per frame: boundary + centerline, full-res px).

Read by ForceAnalysis/force_viewer_v2.m. Size is kept down by:
  - boundary resampled to a fixed EXPORT_BND points and rounded to whole pixels (display only)
  - centerline kept at 0.1 px (used for the everted arc length)
  - no float32 noise (692.9000244140625 -> 692.9) and no spaces in the JSON
  - gzip (~10x smaller again, lossless)

Shrink '*_curves.jsonl' files exported by older versions into '*_curves.jsonl.gz' (the .jsonl is deleted):
    python curves_io.py <file_or_folder> [...]
"""
import glob
import gzip
import json
import os
import sys

import numpy as np

from geometry import resample_closed

EXPORT_BND = 300


def curves_line(frame, bnd, ctr):
    """bnd, ctr: (N, 2) arrays in full-resolution pixels."""
    b = np.rint(resample_closed(np.asarray(bnd, np.float32), EXPORT_BND).astype(np.float64)).astype(int)
    c = np.round(np.asarray(ctr, np.float64), 1)
    return json.dumps(dict(frame=int(frame), boundary=b.tolist(), centerline=c.tolist()),
                      separators=(",", ":")) + "\n"


def shrink(path):
    if not path.endswith(".jsonl"):
        print(f"skip (not .jsonl): {path}")
        return
    out = path + ".gz"
    before = os.path.getsize(path)
    tmp = out + ".tmp"
    with open(path, encoding="utf-8") as src, gzip.open(tmp, "wt", encoding="utf-8", newline="\n") as dst:
        for line in src:
            if line.strip():
                d = json.loads(line)
                dst.write(curves_line(d["frame"], d["boundary"], d["centerline"]))
    os.replace(tmp, out)
    os.remove(path)
    after = os.path.getsize(out)
    print(f"{before / 1e6:7.1f} MB -> {after / 1e6:6.1f} MB  {out}")


def main(args):
    if not args:
        print(__doc__)
        return
    for a in args:
        files = glob.glob(os.path.join(a, "*_curves.jsonl")) if os.path.isdir(a) else [a]
        for p in sorted(files):
            shrink(p)


if __name__ == "__main__":
    main(sys.argv[1:])
