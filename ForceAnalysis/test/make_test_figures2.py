"""Fig 1 (reach) and fig 6 (peak force location) merged into one figure with shared axes.

x: one column per trial, grouped by robot (as fig 6). y: tip position in m from the anus (as fig 1),
over the reference colon bands. Per trial: group-coloured cap = max reach,
blue dot = tip position at the go peak force (shade + label = peak |F|).
Uses load() and settings from make_test_figures.py. Output: fig1_6_reach_and_peak.png

    python make_test_figures2.py
"""
import os

import matplotlib
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from make_test_figures import (FS, GROUP_NAME, GROUPS, HERE, INK, INK2, L_COLON, SEG_BG, SEGS, load)

# robot colours for this figure only: small green, medium red, large blue, endoscope purple
GCOL = {"S": "#1baf7a", "M": "#d6372b", "L": "#2a5fd6", "Mo": "#8a4fd0"}


def fig_reach_peak(t, edges):
    pk = pd.read_csv(os.path.join(HERE, "peak_position.csv"))
    d = t[t.pos.notna()].merge(pk, on="Trial", how="left")
    d = d.sort_values(["grp", "num"], key=lambda c: c.map(
        {g: i for i, g in enumerate(GROUPS)}) if c.name == "grp" else c).reset_index(drop=True)
    # both reach and peak position in raw metres, so the peak dot can never sit above its own reach
    d["ypk"] = d.PosAtMaxF_m.where(d.SegAtMaxF.isin(SEGS))

    fig, ax = plt.subplots(figsize=(10.0, 6.4))
    for j in range(8):
        ax.axhspan(edges[j], edges[j + 1], color=SEG_BG[j], zorder=0, lw=0)
    for e in edges[1:-1]:
        ax.axhline(e, color="white", lw=1, zorder=1)

    x, xs, xg = 0, [], []
    for g in GROUPS:
        n = int((d.grp == g).sum())
        xs += list(x + np.arange(n))
        xg.append((x, x + n - 1, g))
        x += n + 0.8
    d["x"] = xs

    cmap = matplotlib.colors.LinearSegmentedColormap.from_list(
        "blue", ["#cfe2fa", "#9ec5f4", "#3987e5", "#1c5cab", "#0d366b"])
    norm = matplotlib.colors.Normalize(0, d.MaxF_N.max())
    for _, r in d.iterrows():
        ax.hlines(r.pos, r.x - 0.3, r.x + 0.3, color=GCOL[r.grp], lw=3, zorder=3)
    p = d[d.ypk.notna()]
    sc = ax.scatter(p.x, p.ypk, c=p.MaxF_N, cmap=cmap, norm=norm, s=110, edgecolor="white", lw=1, zorder=4)
    for _, r in p.iterrows():
        ax.annotate(f"{r.MaxF_N:.1f}", (r.x, r.ypk), xytext=(0, -9), textcoords="offset points",
                    ha="center", va="top", fontsize=FS - 2, color=INK, zorder=5)

    for a, b, g in xg[:-1]:
        ax.axvline(b + 0.9, color=INK2, lw=1.2, zorder=2)
    for a, b, g in xg:
        dg = d[d.grp == g]
        n_asc = dg.seg.isin(["Ascending colon", "Cecum"]).sum()
        ax.text((a + b) / 2, L_COLON + 0.03, f"{GROUP_NAME[g]}\n{n_asc}/{len(dg)} reach ascending",
                ha="center", va="bottom", fontsize=FS, color=INK)

    ax.set_xticks(d.x)
    ax.set_xticklabels(d.idx)
    ax.set_xlim(-0.8, x - 0.6)
    ax.set_ylim(0, L_COLON)
    ax.set_ylabel("Tip position (m)")
    ax.grid(False)
    sec = ax.secondary_yaxis("right")
    sec.set_yticks((edges[:-1] + edges[1:]) / 2)
    sec.set_yticklabels(SEGS)
    sec.tick_params(length=0)
    sec.spines["right"].set_visible(False)

    for g in GROUPS:
        ax.plot([], [], color=GCOL[g], lw=3, label=GROUP_NAME[g])
    leg = ax.legend(loc="upper left", title="max reach", frameon=True, fontsize=FS - 2,
                    title_fontsize=FS - 2, handlelength=1.2, handletextpad=0.5, borderpad=0.5)
    leg.get_frame().set(facecolor="white", edgecolor="none", alpha=0.9)
    leg.set_zorder(6)
    cb = fig.colorbar(sc, ax=ax, orientation="horizontal", fraction=0.04, pad=0.1, aspect=40)
    cb.set_label("peak |F| (N)")
    cb.outline.set_visible(False)
    ax.set_title("How far each trial got, and where its peak force happens (go phase)",
                 loc="left", fontsize=FS + 1, pad=3.2 * FS)
    fig.text(0.01, -0.06, "Bands: cuts of the reference video. Each trial's segment (and the 'reach ascending' "
             "count) uses the cuts fitted to its own video, so a mark near a boundary can sit in the neighbouring band.",
             fontsize=FS - 2, color=INK, wrap=True)
    fig.savefig(os.path.join(HERE, "fig1_6_reach_and_peak.png"))
    plt.close(fig)


if __name__ == "__main__":
    T, S, E = load()
    fig_reach_peak(T, E)
    print("figure written to", HERE)
