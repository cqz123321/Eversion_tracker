"""Quantify how much the already-passed lumen keeps moving after the tip has gone by ("wake disturbance").

Just run this file. Reads the CSVs written by export_kymographs.py, no video decoding.
Needs numpy + matplotlib (+ scipy for the statistics).

Idea: in each frame the stations behind the tip (H side, station < furthest tip so far - GAP) have already been
traversed. A vine robot everts, so the wall it has passed stays still; a hand-pushed scope (Mo) keeps sliding
and dragging the passed wall. The recent_change signal in that region measures exactly that.

Per video (one row in data/wake_metrics.csv)
  wake_mean      mean signal over the passed region, all frames                       (main number)
  wake_active    fraction of passed-region pixels with signal > ACTIVE_LEVEL           (how often it moves)
  ahead_mean     mean signal ahead of the tip (stations > tip + GAP), the untouched baseline
  wake_ratio     wake_mean / ahead_mean                                                (baseline-normalised)
Figures
  wake_metrics.png   box + points per group (L, M, S, Mo) for wake_mean / wake_active / wake_ratio
  wake_profile.png   mean signal vs distance from the tip (tip-aligned kymograph), mean +/- SD per group
"""
# ------------------------------------------------------------------ settings
MATCH = ""              # only videos whose name contains this text ("" = all)
TRIAL_TABLE = "../ForceAnalysis/test/trial_table_revised.csv"   # only trials listed here (6 per group); "" = all
RUNS = ("G",)           # run types to include (last letter of the name); R runs: the active side is T, not H
GAP = 5                 # stations (= % path) on each side of the tip left out, so the tip's own motion is not counted
MIN_DEPTH = 10          # frames count only once the tip is this far in (so a passed region exists)
ACTIVE_LEVEL = 1.0      # signal level counted as "moving" for wake_active (fixed, the same for every video)
PROFILE_RANGE = (-80, 30)   # distance from the tip (% path) shown in wake_profile.png; negative = behind (H side)
PATH_LENGTH_M = 1.35    # length of the whole centerline (stations 0..n-1) in m, = L_COLON in ForceAnalysis/test
GROUPS = ("S", "M", "L", "Mo")   # figure order
NAMES = {"S": "Small vine (7 mm)", "M": "Medium vine (15 mm)", "L": "Large vine (22 mm)", "Mo": "Endoscope"}
COLORS = {"S": "#1baf7a", "M": "#d6372b", "L": "#2a5fd6", "Mo": "#8a4fd0"}   # as make_test_figures2.py
# ------------------------------------------------------------------
import glob
import os
import re

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
NAME_RE = re.compile(r"\s(L|M|S|Mo)\s+(\d+)\s+([GR])$")


def read_kymo(csv_path):
    a = np.loadtxt(csv_path, delimiter=",", skiprows=1, ndmin=2)
    return a[:, 2], a[:, 3:]                    # tip_station (frames), sig (frames x stations)


def metrics(tip, sig):
    """Wake numbers + tip-aligned profile of one video."""
    n = sig.shape[1]
    st = np.arange(n)
    ok = np.isfinite(tip)
    tip, sig = tip[ok], sig[ok]
    reach = np.maximum.accumulate(tip)          # furthest point reached so far = end of the passed region
    use = reach >= MIN_DEPTH
    tip, reach, sig = tip[use], reach[use], sig[use]
    behind = st[None, :] < reach[:, None] - GAP
    ahead = st[None, :] > reach[:, None] + GAP
    wake = sig[behind]
    front = sig[ahead]
    d = dict(n_frames=int(len(tip)),
             wake_mean=float(wake.mean()),
             wake_active=float((wake > ACTIVE_LEVEL).mean()),
             ahead_mean=float(front.mean()) if front.size else np.nan)
    d["wake_ratio"] = d["wake_mean"] / d["ahead_mean"] if d["ahead_mean"] > 0 else np.nan

    # tip-aligned profile: signal as a function of (station - tip), averaged over frames
    lo, hi = PROFILE_RANGE
    rel = np.arange(lo, hi + 1)
    idx = np.round(tip).astype(int)[:, None] + rel[None, :]
    inside = (idx >= 0) & (idx < n)
    vals = np.where(inside, np.take_along_axis(sig, np.clip(idx, 0, n - 1), 1), np.nan)
    cnt = np.isfinite(vals).sum(0)
    prof = np.where(cnt > 0, np.nansum(vals, 0) / np.maximum(cnt, 1), np.nan)
    d["profile"] = prof
    d["profile_n"] = st
    return d


def selected_trials(path=TRIAL_TABLE):
    """{(group, trial number)} from the Trial column of the trial table (e.g. "Mo3"), or None = keep all."""
    if not path:
        return None
    with open(os.path.join(HERE, path), encoding="utf-8-sig") as f:
        names = [line.split(",", 1)[0].strip() for line in f.readlines()[1:] if line.strip()]
    return {(m.group(1), int(m.group(2))) for m in map(re.compile(r"^(Mo|L|M|S)(\d+)$").match, names) if m}


def collect(match=MATCH):
    keep = selected_trials()
    rows = []
    for p in sorted(glob.glob(os.path.join(DATA, "*_kymograph.csv"))):
        name = os.path.basename(p)[:-len("_kymograph.csv")]
        m = NAME_RE.search(name)
        if not m or match.lower() not in name.lower() or m.group(3) not in RUNS:
            continue
        if keep is not None and (m.group(1), int(m.group(2))) not in keep:
            continue
        d = metrics(*read_kymo(p))
        d.update(video=name, group=m.group(1), trial=int(m.group(2)), run=m.group(3))
        rows.append(d)
    return rows


COLS = ("video", "group", "trial", "run", "n_frames", "wake_mean", "wake_active", "ahead_mean", "wake_ratio")


def write_csv(rows, path):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(",".join(COLS) + "\n")
        for r in rows:
            f.write(",".join(f'"{r[k]}"' if isinstance(r[k], str) else f"{r[k]:.6g}" for k in COLS) + "\n")


def stats(rows, key):
    """Kruskal-Wallis over all groups, then each robot group vs Mo (Mann-Whitney, Holm-corrected)."""
    try:
        from scipy.stats import kruskal, mannwhitneyu
    except ImportError:
        return [f"{key}: scipy not installed, no statistics"]
    by = {g: np.array([r[key] for r in rows if r["group"] == g and np.isfinite(r[key])]) for g in GROUPS}
    by = {g: v for g, v in by.items() if len(v)}
    out = [f"{key}:  " + "   ".join(f"{g} {np.median(v):.3g} [{np.percentile(v, 25):.3g}-{np.percentile(v, 75):.3g}] "
                                     f"(n={len(v)})" for g, v in by.items())]
    if len(by) >= 2:
        out.append(f"  Kruskal-Wallis H = {kruskal(*by.values()).statistic:.2f}, p = {kruskal(*by.values()).pvalue:.2g}")
    if "Mo" in by:
        tests = [(g, mannwhitneyu(by[g], by["Mo"], alternative="two-sided").pvalue) for g in by if g != "Mo"]
        order = np.argsort([p for _, p in tests])
        k, prev = len(tests), 0.0
        for rank, i in enumerate(order):
            g, p = tests[i]
            prev = max(prev, min(1.0, p * (k - rank)))            # Holm step-down
            fold = np.median(by["Mo"]) / np.median(by[g]) if np.median(by[g]) > 0 else np.nan
            delta = np.mean(np.sign(by["Mo"][:, None] - by[g][None, :]))   # Cliff's delta, Mo vs robot
            out.append(f"  {g} vs Mo: p_holm = {prev:.2g}, Mo/{g} median = {fold:.2f}x, Cliff's delta = {delta:+.2f}")
    return out


def plot_metrics(rows, path):
    import matplotlib.pyplot as plt
    keys = [("wake_mean", "Wake disturbance\n(mean signal behind tip)"),
            ("wake_active", f"Active fraction behind tip\n(signal > {ACTIVE_LEVEL:g})"),
            ("wake_ratio", "Wake / ahead ratio")]
    groups = [g for g in GROUPS if any(r["group"] == g for r in rows)]
    fig, axs = plt.subplots(1, len(keys), figsize=(4 * len(keys), 3.6))
    rng = np.random.default_rng(0)
    for ax, (k, lab) in zip(axs, keys):
        data = [[r[k] for r in rows if r["group"] == g and np.isfinite(r[k])] for g in groups]
        ax.boxplot(data, widths=0.55, showfliers=False, medianprops=dict(color="k"))
        for i, (g, v) in enumerate(zip(groups, data)):
            ax.scatter(i + 1 + rng.uniform(-0.12, 0.12, len(v)), v, s=22, color=COLORS.get(g, "k"), zorder=3)
        ax.set_xticks(range(1, len(groups) + 1), [NAMES[g] for g in groups], rotation=20)
        ax.set_ylabel(lab)
        ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(path, dpi=300)
    plt.close(fig)


def plot_profile(rows, path):
    import matplotlib.pyplot as plt
    rel = np.arange(PROFILE_RANGE[0], PROFILE_RANGE[1] + 1)
    n = len(rows[0]["profile_n"]) if rows else 100
    x = rel * PATH_LENGTH_M / n                 # stations -> m
    fig, ax = plt.subplots(figsize=(6, 3.6))
    for g in GROUPS:
        P = np.array([r["profile"] for r in rows if r["group"] == g])
        if not len(P):
            continue
        m, s = np.nanmean(P, 0), np.nanstd(P, 0)
        ax.plot(x, m, color=COLORS.get(g, "k"), lw=2, label=NAMES[g])
        ax.fill_between(x, m - s, m + s, color=COLORS.get(g, "k"), alpha=0.18, lw=0)
    ax.axvline(0, color="0.4", lw=1, ls="--")
    ax.set_xlabel("Distance from tip (m)")
    ax.set_ylabel("Time-averaged\ncolour-change signal")
    ax.legend(frameon=False)
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(path, dpi=300)
    plt.close(fig)


def main():
    rows = collect()
    print(f"{len(rows)} video(s), runs {RUNS}", flush=True)
    for r in rows:
        print(f"  {r['video']:22s} wake {r['wake_mean']:.3f}  active {r['wake_active']:.3f}  "
              f"ratio {r['wake_ratio']:.2f}", flush=True)
    write_csv(rows, os.path.join(DATA, "wake_metrics.csv"))
    lines = [ln for k in ("wake_mean", "wake_active", "wake_ratio") for ln in stats(rows, k)]
    print("\n".join(lines), flush=True)
    with open(os.path.join(DATA, "wake_stats.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    plot_metrics(rows, os.path.join(HERE, "wake_metrics.png"))
    plot_profile(rows, os.path.join(HERE, "wake_profile.png"))
    print("wrote data/wake_metrics.csv, data/wake_stats.txt, wake_metrics.png, wake_profile.png", flush=True)


if __name__ == "__main__":
    main()
