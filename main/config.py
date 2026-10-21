"""Tunable parameters, grouped by stage."""
import json
from dataclasses import dataclass, asdict, fields, field

N_BND = 200   # tracked boundary points
N_CTR = 100   # centerline stations (head -> tail)
N_OFF = 9     # samples across the colon at each station


@dataclass
class Params:
    proc_width: int = 640
    frame_step: int = 1
    workers: int = 12               # frames prepared in parallel ahead of the tracker

    # ---- stage 2: colon tracking ----
    follow_flow: bool = True
    flow_smooth: float = 2.0
    flow_view_frames: int = 10      # Flow view only: show the motion over this many frames (per-frame flow is ~0.1 px)
    edge_channel: str = "b"
    edge_blur: int = 5
    edge_clahe: bool = False
    edge_min: float = 0.0
    edge_polarity: str = "inside_higher"
    snap_radius: int = 5
    snap_weight: float = 0.5
    shape_smooth: float = 2.0
    center_pull: float = 0.3
    shape_keep: float = 0.02

    # ---- stage 3: tip ----
    n_stations: int = 100           # centerline cross-sections (needs Start tracking again)
    width_cap: float = 1.5          # each side of a cross-section <= this x the inscribed radius (0 = off)
    recent_frames: int = 5          # look-back of "recent_change" (needs re-tracking)
    feature: str = "change"
    compare: str = "pixel"          # change vs baseline at the same image pixel, or at the same colon point
    light_weight: float = 1.0       # weight of brightness (Lab L) in colour differences; 0 = colour only
    strap_tol: float = 0.0          # colour distance to picked strap colours below which a sample is ignored
    strip_frac: float = 0.6
    exposure_comp: bool = True
    normalize: bool = True          # divide each station by its signal at the annotated end frame
    sig_thresh: float = 12.0
    collective_q: float = 0.0       # remove per-frame changes shared by this fraction of stations (0 = off)
    view_max: float = 40.0          # colour scale of the Change/Recent image views (colour-difference units)
    mode_values: dict = field(default_factory=dict)  # PER_MODE values remembered for each signal mode
    sig_time_frames: int = 50
    tip_rule: str = "contiguous"
    max_gap: int = 8
    max_speed: float = 1.0          # "global": max stations the tip may move per video frame
    tip_alpha: float = 0.5
    monotonic: bool = False

    def to_dict(self):
        return asdict(self)

    def update(self, d):
        names = {f.name for f in fields(self)}
        for k, v in d.items():
            if k in names:
                setattr(self, k, type(getattr(self, k))(v))

    def save(self, path):
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2)

    @classmethod
    def load(cls, path):
        p = cls()
        with open(path, "r", encoding="utf-8") as f:
            p.update(json.load(f))
        return p


# Parameters whose sensible value depends on the signal mode; each mode remembers its own.
PER_MODE = ("sig_thresh", "collective_q")
NORMALIZABLE = ("change", "darker", "wider", "darker+wider")
MODE_DEFAULTS = {"change_norm": dict(sig_thresh=0.5, collective_q=0.0),
                 "change": dict(sig_thresh=12.0, collective_q=0.0),
                 "recent_change": dict(sig_thresh=4.0, collective_q=0.7)}


def mode_key(p):
    """Signal mode: the feature, plus "_norm" when it is divided by the end-frame reference."""
    return p.feature + ("_norm" if p.normalize and p.feature in NORMALIZABLE else "")


def mode_values(p, key):
    """PER_MODE values for signal mode `key` (remembered ones, else defaults)."""
    other = dict(sig_thresh=0.5 if key.endswith("_norm") else 0.05, collective_q=0.0)
    vals = dict(MODE_DEFAULTS.get(key, other))
    vals.update(p.mode_values.get(key, {}))
    return vals


def odd(k):
    k = int(k)
    return k if k % 2 == 1 else k + 1
