"""Summary figures across trials, from the outputs of image_output.m / trial_table.m.

Inputs (same folder as this script): TABLE (trial_table_revised.csv), segment_summary.csv, colon_cuts.json
segment_summary.csv is filtered to the trials listed in TABLE.
Outputs: fig1_reach.png ... fig6_peak_segment.png (300 dpi)

    python make_test_figures.py
"""
import json
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# ---------------------------------------------------------------- settings to tweak
FONT = "Calibri"     # font for every figure
FS = 14              # font size for all text; titles use FS + 1
TABLE = "trial_table_revised.csv"

HERE = os.path.dirname(os.path.abspath(__file__))
L_COLON = 1.35
GROUPS = ["S", "M", "L", "Mo"]
GROUP_NAME = {"S": "Small vine", "M": "Medium vine", "L": "Large vine", "Mo": "Endoscope"}
GCOL = {"S": "#2a78d6", "M": "#eb6834", "L": "#1baf7a", "Mo": "#eda100"}
SEGS = ["Rectum", "Sigmoid", "Descending colon", "Splenic flexure", "Transverse colon",
        "Hepatic flexure", "Ascending colon", "Cecum"]
SEG_SHORT = ["Rect", "Sig", "Desc", "SF", "Trans", "HF", "Asc", "Cec"]
SEG_COL = ["#a6a6a6", "#e07b39", "#c9a227", "#8c8c8c", "#3f9c4a", "#555555", "#2a78d6", "#8e5bd0"]
SEG_BG = ["#ededed", "#fde3cf", "#fbf1c6", "#dcdcdc", "#dff0d9", "#dcdcdc", "#d9e8fb", "#ebe1f7"]
INK, INK2, GRID = "#000000", "#5c5c5c", "#e6e6e6"

plt.rcParams.update({
    "font.family": FONT, "font.size": FS, "axes.edgecolor": INK2, "axes.labelcolor": INK, "xtick.color": INK,
    "ytick.color": INK, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
    "savefig.dpi": 300, "savefig.bbox": "tight",
})


def trial_name(label):
    parts = [p.strip() for p in label.split("/")]
    g = parts[0].lower()
    n = re.search(r"\d+", parts[-1])
    n = int(n.group()) if n else 0
    code = "S" if g.startswith("small") else "M" if g.startswith("med") else \
        "L" if g.startswith("large") else "Mo" if g.startswith("mo") else parts[0]
    return f"{code}{n}", code, n


def load():
    t = pd.read_csv(os.path.join(HERE, TABLE), encoding="utf-8-sig")
    t["retr_negligible"] = t.MaxRetractionF_N.astype(str).str.lower().eq("negligible")
    for c in ["MaxF_Sigmoid_N", "MaxF_N", "MaxP1_Sigmoid", "MaxP1", "MaxRetractionF_N"]:
        t[c] = pd.to_numeric(t[c], errors="coerce")     # "Negligible" -> NaN
    t["grp"] = t.Trial.str.extract(r"^(Mo|S|M|L)")[0]
    t["num"] = t.Trial.str.extract(r"(\d+)$")[0].astype(float)
    t["pos"] = t.MaxPosition.str.extract(r"([\d.]+) m")[0].astype(float)
    t["seg"] = t.MaxPosition.str.extract(r"\((.*)\)")[0]
    t["idx"] = t.groupby("grp").num.rank(method="first").astype(int)   # trials numbered 1..n per group
    s = pd.read_csv(os.path.join(HERE, "segment_summary.csv"))
    nm = s.test.map(trial_name)
    s["Trial"] = nm.str[0]
    s["grp"] = nm.str[1]
    s["num"] = nm.str[2]
    s = s[s.Trial.isin(t.Trial)].copy()
    s["idx"] = s.Trial.map(t.set_index("Trial").idx)
    with open(os.path.join(HERE, "colon_cuts.json"), encoding="utf-8") as f:
        cuts = json.load(f)
    edges = np.r_[0, cuts["frac_anatomical"], 1] * L_COLON
    return t, s, edges


def jitter(n, w=0.22, seed=0):
    r = np.random.default_rng(seed)
    return r.uniform(-w, w, n) if n > 1 else np.zeros(n)


def dots(ax, x, y, g, **kw):
    ax.scatter(x, y, s=34, color=GCOL[g], edgecolor="white", linewidth=0.8, zorder=3, **kw)


def group_axis(ax, t, col=None):
    ax.set_xticks(range(len(GROUPS)))
    n = [int(((t.grp == g) & (t[col].notna() if col else True)).sum()) for g in GROUPS]
    ax.set_xticklabels([f"{GROUP_NAME[g]}\n(n = {k})" for g, k in zip(GROUPS, n)])
    ax.set_xlim(-0.6, len(GROUPS) - 0.4)
    ax.grid(axis="x", visible=False)


# ---------------------------------------------------------------- 1. reach
def fig_reach(t, edges):
    fig, ax = plt.subplots(figsize=(7.4, 4.8))
    for k in range(8):
        ax.axhspan(edges[k], edges[k + 1], color=SEG_BG[k], zorder=0, lw=0)
    for e in edges[1:-1]:
        ax.axhline(e, color="white", lw=1, zorder=1)
    for i, g in enumerate(GROUPS):
        d = t[(t.grp == g) & t.pos.notna()]
        dots(ax, i + jitter(len(d), seed=i), d.pos, g)
        if len(d):
            ax.hlines(d.pos.median(), i - 0.3, i + 0.3, color=INK, lw=1.6, zorder=4)
            n_asc = d.seg.isin(["Ascending colon", "Cecum"]).sum()
            ax.text(i, L_COLON + 0.03, f"{n_asc}/{len(d)} reach\nascending", ha="center", va="bottom",
                    fontsize=FS, color=INK)
    group_axis(ax, t, 'pos')
    ax.set_ylim(0, L_COLON)
    ax.set_ylabel("Max tip position (m from anus)")
    ax.grid(axis="y", visible=False)
    sec = ax.secondary_yaxis("right")
    mids = (edges[:-1] + edges[1:]) / 2
    sec.set_yticks(mids)
    sec.set_yticklabels(SEGS)
    sec.tick_params(length=0)
    sec.spines["right"].set_visible(False)
    ax.set_title("How far each trial got (black bar = median)", loc="left", fontsize=FS + 1, pad=40)
    fig.text(0.01, -0.08, "Bands: cuts of the reference video. Each trial's segment (and the 'reach ascending' "
             "count) uses the cuts fitted to its own video, so a dot near a boundary can sit in the neighbouring band.",
             fontsize=FS, color=INK, wrap=True)
    fig.savefig(os.path.join(HERE, "fig1_reach.png"))
    plt.close(fig)


# ---------------------------------------------------------------- 2. pressure vs force
def fig_pressure_force(t):
    fig, ax = plt.subplots(figsize=(6.0, 4.4))
    for g in ["S", "M", "L"]:
        d = t[(t.grp == g) & t.MaxP1.notna() & t.MaxF_N.notna()]
        dots(ax, d.MaxP1, d.MaxF_N, g, label=GROUP_NAME[g])
    ax.legend(loc="upper right", frameon=False)
    ax.set_xlabel("Max Pressure (kPa)")
    ax.set_ylabel("Max |F| (N)")
    ax.set_ylim(0, t.MaxF_N.max() * 1.18)
    ax.set_title("Smaller robots: higher pressure, lower force", loc="left", fontsize=FS + 1)
    fig.savefig(os.path.join(HERE, "fig2_pressure_vs_force.png"))
    plt.close(fig)


# ---------------------------------------------------------------- 3. where the peak force is
def fig_peak_location(t):
    d = t[t.MaxF_Sigmoid_N.notna()].sort_values(["grp", "num"], key=lambda c: c.map(
        {g: i for i, g in enumerate(GROUPS)}) if c.name == "grp" else c)
    fig, ax = plt.subplots(figsize=(9.0, 4.6))
    x, labels, xg = 0, [], []
    for g in GROUPS:
        dg = d[d.grp == g]
        for _, r in dg.iterrows():
            ax.scatter(x, r.MaxF_N, s=34, color=GCOL[g], edgecolor="white", lw=0.8, zorder=3)
            ax.scatter(x, r.MaxF_Sigmoid_N, s=34, facecolor="white", edgecolor=GCOL[g], lw=1.4, zorder=3)
            labels.append(r.idx)
            x += 1
        share = (dg.MaxF_Sigmoid_N >= dg.MaxF_N - 1e-9).sum()
        xg.append((x - len(dg), x - 1, g, share, len(dg)))
        x += 0.8
    pos = [p for a, b, *_ in xg for p in np.arange(a, b + 1)]
    ax.set_xticks(pos)
    ax.set_xticklabels(labels)
    ax.grid(axis="x", visible=False)
    top = d.MaxF_N.max() * 1.15
    for a, b, g, share, n in xg:
        ax.text((a + b) / 2, top, f"{GROUP_NAME[g]}\npeak in sigmoid {share}/{n}", ha="center",
                va="bottom", fontsize=FS, color=INK)
    ax.set_ylim(0, top * 1.22)
    ax.set_ylabel("|F| (N)")
    ax.scatter([], [], s=34, facecolor="white", edgecolor=INK2, lw=1.4, label="max in sigmoid")
    ax.scatter([], [], s=34, color=INK2, label="max over the whole go phase")
    ax.legend(loc="upper left", bbox_to_anchor=(0, -0.1), ncol=2, frameon=False, fontsize=FS)
    ax.set_title("Where the peak force happens: open = sigmoid, filled = overall (same point = peak in sigmoid)",
                 loc="left", fontsize=FS + 1)
    fig.savefig(os.path.join(HERE, "fig3_peak_location.png"))
    plt.close(fig)


# ---------------------------------------------------------------- 4. heatmap trial x segment
def fig_segment_heatmap(s):
    g = s[s.role == "G"].copy()
    g["gi"] = g.grp.map({k: i for i, k in enumerate(GROUPS)})
    rows = g[["Trial", "grp", "gi", "num", "idx"]].drop_duplicates().sort_values(["gi", "num"])
    order = rows.Trial.tolist()
    M = g.pivot_table(index="Trial", columns="segment", values="F_max_N", aggfunc="max")
    M = M.reindex(index=order, columns=SEGS)
    fig, ax = plt.subplots(figsize=(7.6, 0.3 * len(order) + 1.6))
    cmap = matplotlib.colors.LinearSegmentedColormap.from_list(
        "blue", ["#eef5fd", "#9ec5f4", "#3987e5", "#1c5cab", "#0d366b"])
    cmap.set_bad("white")
    vmax = np.nanpercentile(M.values, 98)
    im = ax.imshow(np.ma.masked_invalid(M.values), aspect="auto", cmap=cmap, vmin=0, vmax=vmax)
    for i in range(M.shape[0]):
        for j in range(M.shape[1]):
            v = M.values[i, j]
            if np.isfinite(v):
                ax.text(j, i, f"{v:.1f}", ha="center", va="center", fontsize=FS,
                        color="white" if v > 0.55 * vmax else INK)
    ax.set_xticks(range(8))
    ax.set_xticklabels(SEG_SHORT)
    ax.xaxis.tick_top()
    ax.set_yticks(range(len(order)))
    ax.set_yticklabels(rows.idx)
    for gr, rg in rows.reset_index(drop=True).groupby("grp", sort=False):   # group names left of the rows
        ax.text(-0.09, 1 - (rg.index.min() + rg.index.max() + 1) / 2 / len(order), GROUP_NAME[gr],
                transform=ax.transAxes, rotation=90, ha="center", va="center", fontsize=FS, color=INK)
    ax.grid(False)
    for sp in ax.spines.values():
        sp.set_visible(False)
    prev = None
    for i, tr in enumerate(order):        # thin white lines between size groups
        gr = re.match(r"^(Mo|S|M|L)", tr).group(1)
        if prev is not None and gr != prev:
            ax.axhline(i - 0.5, color="white", lw=3)
        prev = gr
    cb = fig.colorbar(im, ax=ax, fraction=0.04, pad=0.02)
    cb.set_label(f"max |F| in segment (N); colour capped at {vmax:.1f}")
    cb.outline.set_visible(False)
    ax.set_title("Max force per colon segment (go; blank = not reached in the window)",
                 loc="left", fontsize=FS + 1, pad=24)
    fig.savefig(os.path.join(HERE, "fig4_segment_heatmap.png"))
    plt.close(fig)


# ---------------------------------------------------------------- 5. go vs retraction
def fig_go_vs_retraction(t):
    d = t[t.MaxF_N.notna() & t.MaxRetractionF_N.notna()]
    negl = t[t.retr_negligible]
    fig, ax = plt.subplots(figsize=(8.0, 4.4))
    for i, g in enumerate(GROUPS):
        dg = d[d.grp == g]
        x0, x1 = 3 * i, 3 * i + 1
        for _, r in dg.iterrows():
            ax.plot([x0, x1], [r.MaxF_N, r.MaxRetractionF_N], color=GCOL[g], lw=1, alpha=0.8, zorder=2)
            ax.scatter([x0, x1], [r.MaxF_N, r.MaxRetractionF_N], s=26, color=GCOL[g],
                       edgecolor="white", lw=0.7, zorder=3)
            if r.MaxRetractionF_N > r.MaxF_N:
                ax.annotate(f"{GROUP_NAME[g]} {r.idx}", (x1, r.MaxRetractionF_N), xytext=(5, 0), textcoords="offset points",
                            va="center", fontsize=FS, color=INK)
        ax.text(3 * i + 0.5, -0.12, f"{GROUP_NAME[g]}\n(n = {len(dg)})", ha="center", va="top",
                transform=ax.get_xaxis_transform(), fontsize=FS, color=INK)
        k = int((negl.grp == g).sum())
        if k:
            ax.text(3 * i + 0.5, 0.04, f"retraction\nnegligible\n({k} trials)", ha="center", va="bottom",
                    transform=ax.get_xaxis_transform(), fontsize=FS, color=INK)
    ax.set_xticks([v for i in range(4) for v in (3 * i, 3 * i + 1)])
    ax.set_xticklabels(["go", "retr."] * 4)
    ax.grid(axis="x", visible=False)
    ax.set_ylim(0, None)
    ax.set_ylabel("Max |F| (N)")
    ax.set_title("Go vs retraction peak force (labelled: retraction higher than go)", loc="left", fontsize=FS + 1)
    fig.savefig(os.path.join(HERE, "fig5_go_vs_retraction.png"))
    plt.close(fig)


# ---------------------------------------------------------------- 6. peak location, coloured by segment
def fig_peak_segment(t, edges):
    # peak_position.csv (from trial_table.m): segment of the tip at the go peak force and how far into it.
    # Each trial's own cuts differ a little, so the dot is placed at that fraction of the reference band.
    pk = pd.read_csv(os.path.join(HERE, "peak_position.csv"))
    d = t.merge(pk, on="Trial")
    d = d[d.SegAtMaxF.isin(SEGS)].sort_values(["grp", "num"], key=lambda c: c.map(
        {g: i for i, g in enumerate(GROUPS)}) if c.name == "grp" else c)
    pct = edges / L_COLON * 100
    k = d.SegAtMaxF.map(SEGS.index).to_numpy()
    d["yi"] = pct[k] + d.SegFracAtMaxF.clip(0, 1).to_numpy() * (pct[k + 1] - pct[k])
    fig, ax = plt.subplots(figsize=(10.0, 5.6))
    for j in range(8):
        ax.axhspan(pct[j], pct[j + 1], color=SEG_BG[j], zorder=0, lw=0)
    for e in pct[1:-1]:
        ax.axhline(e, color="white", lw=1, zorder=1)
    cmap = matplotlib.colors.LinearSegmentedColormap.from_list(
        "blue", ["#cfe2fa", "#9ec5f4", "#3987e5", "#1c5cab", "#0d366b"])
    norm = matplotlib.colors.Normalize(0, d.MaxF_N.max())
    x, xs, labels, xg = 0, [], [], []
    for g in GROUPS:
        dg = d[d.grp == g]
        xs += list(x + np.arange(len(dg)))
        labels += dg.idx.tolist()
        xg.append((x, x + len(dg) - 1, g))
        x += len(dg) + 0.8
    sc = ax.scatter(xs, d.yi, c=d.MaxF_N, cmap=cmap, norm=norm, s=110, edgecolor="white", lw=1, zorder=3)
    for xi, (_, r) in zip(xs, d.iterrows()):
        ax.annotate(f"{r.MaxF_N:.1f}", (xi, r.yi), xytext=(0, 8), textcoords="offset points",
                    ha="center", va="bottom", fontsize=FS, color=INK)
    ax.set_xticks(xs)
    ax.set_xticklabels(labels)
    for a, b, g in xg:
        ax.text((a + b) / 2, 101.5, GROUP_NAME[g], ha="center", va="bottom", fontsize=FS, color=INK)
    ax.set_xlim(-0.8, x - 0.6)
    ax.set_ylim(0, 100)
    ax.set_ylabel("Tip position at peak force (% of colon length)")
    ax.grid(False)
    sec = ax.secondary_yaxis("right")
    sec.set_yticks((pct[:-1] + pct[1:]) / 2)
    sec.set_yticklabels(SEGS)
    sec.tick_params(length=0)
    sec.spines["right"].set_visible(False)
    cb = fig.colorbar(sc, ax=ax, orientation="horizontal", fraction=0.05, pad=0.1, aspect=40)
    cb.set_label("peak |F| (N)")
    cb.outline.set_visible(False)
    ax.set_title("Where each trial's peak force happens (go phase)", loc="left", fontsize=FS + 1, pad=2.6 * FS)
    fig.savefig(os.path.join(HERE, "fig6_peak_segment.png"))
    plt.close(fig)


if __name__ == "__main__":
    T, S, E = load()
    fig_reach(T, E)
    fig_pressure_force(T)
    fig_peak_location(T)
    fig_segment_heatmap(S)
    fig_go_vs_retraction(T)
    fig_peak_segment(T, E)
    print("figures written to", HERE)
