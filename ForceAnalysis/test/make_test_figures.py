"""Summary figures across trials, from the outputs of image_output.m / trial_table.m.

Inputs (same folder as this script): trial_table.csv, segment_summary.csv, colon_cuts.json
Outputs: fig1_reach.png ... fig5_go_vs_retraction.png (300 dpi)

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

HERE = os.path.dirname(os.path.abspath(__file__))
L_COLON = 1.35
GROUPS = ["S", "M", "L", "Mo"]
GROUP_NAME = {"S": "Small", "M": "Medium", "L": "Large", "Mo": "Mo"}
GCOL = {"S": "#2a78d6", "M": "#eb6834", "L": "#1baf7a", "Mo": "#eda100"}
SEGS = ["Rectum", "Sigmoid", "Descending colon", "Splenic flexure", "Transverse colon",
        "Hepatic flexure", "Ascending colon", "Cecum"]
SEG_SHORT = ["Rect", "Sig", "Desc", "SF", "Trans", "HF", "Asc", "Cec"]
SEG_BG = ["#ededed", "#fde3cf", "#fbf1c6", "#dcdcdc", "#dff0d9", "#dcdcdc", "#d9e8fb", "#ebe1f7"]
INK, INK2, GRID = "#1f1f1f", "#5c5c5c", "#e6e6e6"

plt.rcParams.update({
    "font.size": 9, "axes.edgecolor": INK2, "axes.labelcolor": INK, "xtick.color": INK2,
    "ytick.color": INK2, "axes.spines.top": False, "axes.spines.right": False,
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
    t = pd.read_csv(os.path.join(HERE, "trial_table.csv"))
    t["grp"] = t.Trial.str.extract(r"^(Mo|S|M|L)")[0]
    t["num"] = t.Trial.str.extract(r"(\d+)$")[0].astype(float)
    t["pos"] = t.MaxPosition.str.extract(r"([\d.]+) m")[0].astype(float)
    t["seg"] = t.MaxPosition.str.extract(r"\((.*)\)")[0]
    s = pd.read_csv(os.path.join(HERE, "segment_summary.csv"))
    nm = s.test.map(trial_name)
    s["Trial"] = nm.str[0]
    s["grp"] = nm.str[1]
    s["num"] = nm.str[2]
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
    fig, ax = plt.subplots(figsize=(6.2, 4.2))
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
                    fontsize=8, color=INK2)
    group_axis(ax, t, 'pos')
    ax.set_ylim(0, L_COLON)
    ax.set_ylabel("Max tip position (m from anus)")
    ax.grid(axis="y", visible=False)
    sec = ax.secondary_yaxis("right")
    mids = (edges[:-1] + edges[1:]) / 2
    sec.set_yticks(mids)
    sec.set_yticklabels(SEGS, fontsize=7.5)
    sec.tick_params(length=0)
    sec.spines["right"].set_visible(False)
    ax.set_title("How far each trial got (black bar = median)", loc="left", fontsize=10, pad=34)
    fig.text(0.01, -0.07, "Bands: cuts of the reference video. Each trial's segment (and the 'reach ascending' "
             "count) uses the cuts fitted to its own video, so a dot near a boundary can sit in the neighbouring band.",
             fontsize=7, color=INK2, wrap=True)
    fig.savefig(os.path.join(HERE, "fig1_reach.png"))
    plt.close(fig)


# ---------------------------------------------------------------- 2. pressure vs force
def fig_pressure_force(t):
    fig, ax = plt.subplots(figsize=(5.4, 4.0))
    for g in ["S", "M", "L"]:
        d = t[(t.grp == g) & t.MaxP1.notna() & t.MaxF_N.notna()]
        dots(ax, d.MaxP1, d.MaxF_N, g)
        lab = {"S": (99, 1.35, "right"), "M": (55, 2.95, "left"), "L": (36, 5.6, "left")}[g]
        ax.text(lab[0], lab[1], f"{GROUP_NAME[g]}\nmedian F/P = {np.median(d.MaxF_N / d.MaxP1):.3f} N per unit P",
                ha=lab[2], va="bottom", fontsize=8, color=INK)
    ax.set_xlabel("Max P1 (go)")
    ax.set_ylabel("Max |F| (N, go)")
    ax.set_ylim(0, t.MaxF_N.max() * 1.18)
    ax.set_title("Smaller robots: higher pressure, lower force  (Mo: no pressure record)",
                 loc="left", fontsize=10)
    fig.savefig(os.path.join(HERE, "fig2_pressure_vs_force.png"))
    plt.close(fig)


# ---------------------------------------------------------------- 3. where the peak force is
def fig_peak_location(t):
    d = t[t.MaxF_Sigmoid_N.notna()].sort_values(["grp", "num"], key=lambda c: c.map(
        {g: i for i, g in enumerate(GROUPS)}) if c.name == "grp" else c)
    fig, ax = plt.subplots(figsize=(7.2, 3.8))
    x, labels, xg = 0, [], []
    for g in GROUPS:
        dg = d[d.grp == g]
        for _, r in dg.iterrows():
            ax.plot([x, x], [r.MaxF_Sigmoid_N, r.MaxF_N], color=GCOL[g], lw=1.6, zorder=2)
            ax.scatter(x, r.MaxF_N, s=34, color=GCOL[g], edgecolor="white", lw=0.8, zorder=3)
            ax.scatter(x, r.MaxF_Sigmoid_N, s=34, facecolor="white", edgecolor=GCOL[g], lw=1.4, zorder=3)
            labels.append(r.Trial)
            x += 1
        share = (dg.MaxF_Sigmoid_N >= dg.MaxF_N - 1e-9).sum()
        xg.append((x - len(dg), x - 1, g, share, len(dg)))
        x += 0.8
    pos = [p for a, b, *_ in xg for p in np.arange(a, b + 1)]
    ax.set_xticks(pos)
    ax.set_xticklabels(labels, fontsize=7, rotation=90)
    ax.grid(axis="x", visible=False)
    top = d.MaxF_N.max() * 1.15
    for a, b, g, share, n in xg:
        ax.text((a + b) / 2, top, f"{GROUP_NAME[g]}\npeak in sigmoid {share}/{n}", ha="center",
                va="bottom", fontsize=8, color=INK)
    ax.set_ylim(0, top * 1.18)
    ax.set_ylabel("|F| (N)")
    ax.scatter([], [], s=34, facecolor="white", edgecolor=INK2, lw=1.4, label="max in sigmoid")
    ax.scatter([], [], s=34, color=INK2, label="max over the whole go phase")
    ax.legend(loc="upper left", bbox_to_anchor=(0, -0.18), ncol=2, frameon=False, fontsize=8)
    ax.set_title("Where the peak force happens: open = sigmoid, filled = overall (same point = peak in sigmoid)",
                 loc="left", fontsize=9.5)
    fig.savefig(os.path.join(HERE, "fig3_peak_location.png"))
    plt.close(fig)


# ---------------------------------------------------------------- 4. heatmap trial x segment
def fig_segment_heatmap(s):
    g = s[s.role == "G"].copy()
    g["gi"] = g.grp.map({k: i for i, k in enumerate(GROUPS)})
    order = g[["Trial", "gi", "num"]].drop_duplicates().sort_values(["gi", "num"]).Trial.tolist()
    M = g.pivot_table(index="Trial", columns="segment", values="F_max_N", aggfunc="max")
    M = M.reindex(index=order, columns=SEGS)
    fig, ax = plt.subplots(figsize=(6.2, 0.24 * len(order) + 1.4))
    cmap = matplotlib.colors.LinearSegmentedColormap.from_list(
        "blue", ["#eef5fd", "#9ec5f4", "#3987e5", "#1c5cab", "#0d366b"])
    cmap.set_bad("white")
    vmax = np.nanpercentile(M.values, 98)
    im = ax.imshow(np.ma.masked_invalid(M.values), aspect="auto", cmap=cmap, vmin=0, vmax=vmax)
    for i in range(M.shape[0]):
        for j in range(M.shape[1]):
            v = M.values[i, j]
            if np.isfinite(v):
                ax.text(j, i, f"{v:.1f}", ha="center", va="center", fontsize=6.5,
                        color="white" if v > 0.55 * vmax else INK)
    ax.set_xticks(range(8))
    ax.set_xticklabels(SEG_SHORT)
    ax.xaxis.tick_top()
    ax.set_yticks(range(len(order)))
    ax.set_yticklabels(order, fontsize=7.5)
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
                 loc="left", fontsize=10, pad=22)
    fig.savefig(os.path.join(HERE, "fig4_segment_heatmap.png"))
    plt.close(fig)


# ---------------------------------------------------------------- 5. go vs retraction
def fig_go_vs_retraction(t):
    d = t[t.MaxF_N.notna() & t.MaxRetractionF_N.notna()]
    fig, ax = plt.subplots(figsize=(5.6, 3.8))
    for i, g in enumerate(GROUPS):
        dg = d[d.grp == g]
        x0, x1 = 3 * i, 3 * i + 1
        for _, r in dg.iterrows():
            ax.plot([x0, x1], [r.MaxF_N, r.MaxRetractionF_N], color=GCOL[g], lw=1, alpha=0.8, zorder=2)
            ax.scatter([x0, x1], [r.MaxF_N, r.MaxRetractionF_N], s=26, color=GCOL[g],
                       edgecolor="white", lw=0.7, zorder=3)
            if r.MaxRetractionF_N > r.MaxF_N:
                ax.annotate(r.Trial, (x1, r.MaxRetractionF_N), xytext=(5, 0), textcoords="offset points",
                            va="center", fontsize=8, color=INK)
        ax.text(3 * i + 0.5, -0.12, f"{GROUP_NAME[g]} (n = {len(dg)})", ha="center", va="top",
                transform=ax.get_xaxis_transform(), fontsize=8.5, color=INK)
    ax.set_xticks([v for i in range(4) for v in (3 * i, 3 * i + 1)])
    ax.set_xticklabels(["go", "retr."] * 4, fontsize=8)
    ax.grid(axis="x", visible=False)
    ax.set_ylim(0, None)
    ax.set_ylabel("Max |F| (N)")
    ax.set_title("Go vs retraction peak force (labelled: retraction higher than go)", loc="left", fontsize=10)
    fig.savefig(os.path.join(HERE, "fig5_go_vs_retraction.png"))
    plt.close(fig)


if __name__ == "__main__":
    T, S, E = load()
    fig_reach(T, E)
    fig_pressure_force(T)
    fig_peak_location(T)
    fig_segment_heatmap(S)
    fig_go_vs_retraction(T)
    print("figures written to", HERE)
