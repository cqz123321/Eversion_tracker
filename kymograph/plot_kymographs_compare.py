"""Kymographs of several videos stacked for comparison (paper figure), with a window to pick them.

Just run this file. Pick videos on the left (Add / Remove / Up / Down set the order, top to bottom); the
preview on the right updates at once. "Save" writes a PNG (600 dpi) and a PDF with the same name.
Reads the CSVs written by export_kymographs.py (data/<video>_kymograph.csv + _meta.json); plot_kymographs.py
is not used or changed. Needs numpy + matplotlib + pillow (tkinter comes with Python).

Figure: one panel per video, x = normalized elapsed time (0-100 %), y = path progression (S at the top,
E at the bottom), white line = tip, one colour bar for all panels. If the selected videos have different
thresholds, every panel is divided by its own threshold (colour bar in units of the threshold).
The two blur sliders smooth the signal (Gaussian) before drawing, to calm a busy background.
"""
# ------------------------------------------------------------------ defaults (all can be changed in the window)
FONT = "Calibri"
TICK_SIZE = 12         # pt, tick labels (S 25 50 75 E, 0..100, colour bar)
LABEL_SIZE = 14        # pt, axis titles
CBAR_SIZE = 9          # pt, colour bar title
NAME_SIZE = 20         # pt, group name in the panels
WIDTH_CM = 15.0        # figure width; A4 text width is about 16-18 cm
PANEL_CM = 3.5         # height of one kymograph panel
GAP_CM = 0.0           # space between the panels
CBAR_CM = 0.3          # colour bar width
CBAR_TITLE = ""
VMAX_FACTOR = 2.0      # colour scale = 0 .. VMAX_FACTOR x threshold
COLORMAP = "turbo"
TIP_WIDTH = 1.0        # pt
PANEL_LABELS = True    # group name (Small, Medium, ...) in the lower left corner of each panel
BLUR_PATH = 0.5        # Gaussian sigma along the path, in % path (stations)
BLUR_TIME = 0.2        # Gaussian sigma along time, in % of the run duration
DEFAULT = ("M 09 G", "Mo 06 G")   # selected when the window opens (text contained in the video name)
# ------------------------------------------------------------------
import glob
import io
import json
import os
import re
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import numpy as np
from PIL import Image, ImageTk
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "figures")
NAME_RE = re.compile(r"\s(L|M|S|Mo)\s+(\d+)\s+([GR])$")
GROUP = {"S": "Small", "M": "Medium", "L": "Large", "Mo": "Endoscope"}
ORDER = {"S": 0, "M": 1, "L": 2, "Mo": 3}
CM = 1 / 2.54
N_COLS = 1200          # time columns drawn per panel
TIGHT = dict(bbox_inches="tight", pad_inches=0.03)   # the colour bar labels stick out of the layout a little


def videos():
    """Video names with a kymograph CSV, sorted Small, Medium, Large, Endoscope, test number, G before R."""
    names = [os.path.basename(p)[:-len("_kymograph.csv")] for p in glob.glob(os.path.join(DATA, "*_kymograph.csv"))]

    def key(n):
        m = NAME_RE.search(n)
        return (ORDER[m.group(1)], int(m.group(2)), m.group(3)) if m else (9, 0, n)
    return sorted(names, key=key)


def short(name):
    m = NAME_RE.search(name)
    return f"{m.group(1)} {int(m.group(2))} {m.group(3)}" if m else name


_CACHE = {}


def load(name):
    """-> t (s), tip (station), sig (stations x frames), threshold."""
    if name not in _CACHE:
        a = np.loadtxt(os.path.join(DATA, name + "_kymograph.csv"), delimiter=",", skiprows=1, ndmin=2)
        with open(os.path.join(DATA, name + "_kymograph_meta.json"), encoding="utf-8") as f:
            thr = float(json.load(f)["thresh"])
        _CACHE[name] = (a[:, 1], a[:, 2], a[:, 3:].T, thr)
    return _CACHE[name]


def gauss(a, sigma, axis):
    """Gaussian smoothing of a along axis (sigma in samples), edges extended."""
    if sigma < 0.3:
        return a
    r = int(np.ceil(3 * sigma))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r, r)
    a = np.pad(a, pad, mode="edge")
    return np.apply_along_axis(lambda x: np.convolve(x, k, mode="valid"), axis, a)


def blurred(sig, s):
    """Gaussian smoothing of sig (stations x frames): sigma in % path and % of the run duration."""
    sig = gauss(sig, s["blur_y"] * (sig.shape[0] - 1) / 100, 0)
    return gauss(sig, s["blur_t"] * sig.shape[1] / 100, 1)


def make_figure(names, s):
    """New figure with the stacked kymographs of names, settings s (dict)."""
    plt.rcParams.update({"font.family": s["font"], "font.size": s["tick_size"], "pdf.fonttype": 42,
                         "axes.linewidth": 0.6, "xtick.major.width": 0.6, "ytick.major.width": 0.6})
    n = len(names)
    h = n * s["panel"] + max(n - 1, 0) * s["gap"]                    # height of the panel stack, cm
    fig = plt.figure(figsize=(s["width"] * CM, h * CM + 2.2 * s["label_size"] / 72), layout="constrained")
    fig.get_layout_engine().set(h_pad=0.01, w_pad=0.02, hspace=s["gap"] / s["panel"], wspace=0)
    if not n:
        return fig
    data = [load(v) for v in names]
    thrs = {d[3] for d in data}
    same = len(thrs) == 1
    vmax = s["vmax"] * (data[0][3] if same else 1.0)

    axs = fig.subplots(n, 1, sharex=True, squeeze=False)[:, 0]
    for ax, v, (t, tip, sig, thr) in zip(axs, names, data):
        sig = blurred(sig, s)
        if not same:
            sig = sig / thr
        st = sig.shape[0]
        tx = np.linspace(t[0], t[-1], N_COLS)                       # column = the frame nearest to that time
        cols = np.clip(np.searchsorted(t, tx), 0, len(t) - 1)
        im = ax.imshow(sig[:, cols], cmap=s["cmap"], vmin=0, vmax=vmax, aspect="auto",
                       extent=(0, 100, 100, 0), interpolation="nearest")
        if s["tip"] > 0:
            ok = np.isfinite(tip)
            ax.plot((t[ok] - t[0]) / max(t[-1] - t[0], 1e-9) * 100, tip[ok] / max(st - 1, 1) * 100,
                    color="w", lw=s["tip"], solid_joinstyle="round")
        ax.set_xlim(0, 100)
        ax.set_ylim(100, 0)
        ax.set_yticks([0, 25, 50, 75, 100], ["S", "25", "50", "75", "E"])
        ticks = ax.yaxis.get_major_ticks()
        ticks[0].label1.set_va("top")                               # S and E sit inside the panel, so the E of
        ticks[-1].label1.set_va("bottom")                           # one panel never runs into the S of the next
        ax.tick_params(direction="out", length=3, pad=2)
        if s["labels"]:
            m = NAME_RE.search(v)
            ax.text(0.01, 0.05, GROUP[m.group(1)] if m else v, transform=ax.transAxes, ha="left", va="bottom",
                    color="w", fontweight="bold", fontsize=s["name_size"])
    axs[-1].set_xticks([0, 25, 50, 75, 100])
    for ax in axs[:-1]:
        ax.tick_params(labelbottom=False)
    fig.supxlabel("Normalized Elapsed Time (%)", fontsize=s["label_size"])
    fig.supylabel("Path Progression (%)", fontsize=s["label_size"])

    cb = fig.colorbar(im, ax=list(axs), fraction=s["cbar_w"] / s["width"], pad=0.01, aspect=h / s["cbar_w"])
    cb.set_ticks([0, vmax / 2, vmax], labels=[f"{x:g}" for x in (0, vmax / 2, vmax)])
    cb.ax.tick_params(direction="out", length=3, pad=2, labelsize=s["tick_size"])
    cb.outline.set_linewidth(0.6)
    title = s["cbar_title"].strip() + ("" if same else "")
    if title.strip():
        cb.ax.set_title(title.strip(), fontsize=s["cbar_size"], pad=4, linespacing=1.0)
    if n > 1:                                                       # the layout pads around the tick marks: shift
        fig.canvas.draw()                                           # the spacing so the gap is what was asked for
        a, b = axs[0].get_position(), axs[1].get_position()
        got = (a.y0 - b.y1) * fig.get_figheight() / CM
        hs = fig.get_layout_engine().get()["hspace"]
        fig.get_layout_engine().set(hspace=max(hs + (s["gap"] - got) / s["panel"], 0))
    return fig


class App:
    def __init__(self, root):
        self.root = root
        root.title("Kymograph comparison")
        self.all = videos()
        self.sel = [v for d in DEFAULT for v in self.all if d.lower() in v.lower()][:len(DEFAULT)]
        self._job = None

        left = ttk.Frame(root, padding=6)
        left.pack(side="left", fill="y")
        ttk.Label(left, text="Filter:").grid(row=0, column=0, sticky="w")
        self.filt = tk.StringVar()
        self.filt.trace_add("write", lambda *a: self.fill())
        ttk.Entry(left, textvariable=self.filt, width=24).grid(row=0, column=1, columnspan=2, sticky="we")
        ttk.Label(left, text="Videos").grid(row=1, column=0, columnspan=3, sticky="w", pady=(6, 0))
        self.lb_all = tk.Listbox(left, selectmode="extended", height=16, width=34, exportselection=False)
        self.lb_all.grid(row=2, column=0, columnspan=3, sticky="nsew")
        self.lb_all.bind("<Double-Button-1>", lambda e: self.add())
        bar = ttk.Frame(left)
        bar.grid(row=3, column=0, columnspan=3, pady=4)
        for txt, fn in (("Add ↓", self.add), ("Remove", self.remove), ("Up", lambda: self.move(-1)),
                        ("Down", lambda: self.move(1))):
            ttk.Button(bar, text=txt, command=fn, width=8).pack(side="left", padx=1)
        ttk.Label(left, text="In the figure (top to bottom)").grid(row=4, column=0, columnspan=3, sticky="w")
        self.lb_sel = tk.Listbox(left, selectmode="extended", height=6, width=34, exportselection=False)
        self.lb_sel.grid(row=5, column=0, columnspan=3, sticky="nsew")
        self.lb_sel.bind("<Double-Button-1>", lambda e: self.remove())

        self.vars = {}
        opts = [("font", "Font", FONT), ("tick_size", "Tick labels (pt)", TICK_SIZE),
                ("label_size", "Axis titles (pt)", LABEL_SIZE), ("cbar_size", "Colour bar title (pt)", CBAR_SIZE),
                ("name_size", "Group names (pt)", NAME_SIZE), ("cbar_title", "Colour bar title", CBAR_TITLE),
                ("width", "Width (cm)", WIDTH_CM), ("panel", "Panel height (cm)", PANEL_CM),
                ("gap", "Gap between panels (cm)", GAP_CM), ("cbar_w", "Colour bar width (cm)", CBAR_CM),
                ("vmax", "Colour max (x thr)", VMAX_FACTOR), ("tip", "Tip line (pt, 0 = off)", TIP_WIDTH)]
        r = 6
        for key, lab, val in opts:
            ttk.Label(left, text=lab).grid(row=r, column=0, columnspan=2, sticky="w", pady=1)
            var = tk.StringVar(value=str(val))
            var.trace_add("write", lambda *a: self.schedule())
            ttk.Entry(left, textvariable=var, width=14 if key == "cbar_title" else 10).grid(row=r, column=2,
                                                                                         sticky="e")
            self.vars[key] = var
            r += 1
        for key, lab, val, top in (("blur_y", "Blur along path (% path)", BLUR_PATH, 5),
                                   ("blur_t", "Blur along time (% duration)", BLUR_TIME, 2)):
            ttk.Label(left, text=lab).grid(row=r, column=0, columnspan=3, sticky="w", pady=(4, 0))
            var = tk.DoubleVar(value=val)
            tk.Scale(left, variable=var, from_=0, to=top, resolution=top / 50, orient="horizontal",
                     command=lambda e: self.schedule()).grid(row=r + 1, column=0, columnspan=3, sticky="we")
            self.vars[key] = var
            r += 2
        ttk.Label(left, text="Colour map").grid(row=r, column=0, columnspan=2, sticky="w")
        self.vars["cmap"] = tk.StringVar(value=COLORMAP)
        cm = ttk.Combobox(left, textvariable=self.vars["cmap"], width=9, state="readonly",
                          values=["turbo", "jet", "viridis", "inferno", "magma", "hot"])
        cm.grid(row=r, column=2, sticky="e")
        cm.bind("<<ComboboxSelected>>", lambda e: self.schedule())
        r += 1
        self.labels = tk.BooleanVar(value=PANEL_LABELS)
        ttk.Checkbutton(left, text="Group name in each panel", variable=self.labels,
                        command=self.schedule).grid(row=r, column=0, columnspan=3, sticky="w", pady=2)
        r += 1
        ttk.Button(left, text="Save PNG + PDF ...", command=self.save).grid(row=r, column=0, columnspan=3,
                                                                          sticky="we", pady=(8, 0))
        self.status = ttk.Label(left, text="", foreground="#a00", wraplength=230)
        self.status.grid(row=r + 1, column=0, columnspan=3, sticky="w")

        self.view = tk.Label(root, bg="#d0d0d0")
        self.view.pack(side="left", fill="both", expand=True)
        self.view.bind("<Configure>", lambda e: self.schedule())
        self.fill()

    # ---- lists
    def fill(self):
        f = self.filt.get().lower()
        self.shown = [v for v in self.all if f in v.lower()]
        self.lb_all.delete(0, "end")
        for v in self.shown:
            self.lb_all.insert("end", f"{short(v):12s} {v}")
        self.lb_sel.delete(0, "end")
        for v in self.sel:
            self.lb_sel.insert("end", f"{short(v):12s} {v}")

    def add(self):
        for i in self.lb_all.curselection():
            if self.shown[i] not in self.sel:
                self.sel.append(self.shown[i])
        self.fill()
        self.schedule()

    def remove(self):
        drop = {self.sel[i] for i in self.lb_sel.curselection()}
        self.sel = [v for v in self.sel if v not in drop]
        self.fill()
        self.schedule()

    def move(self, d):
        idx = list(self.lb_sel.curselection())
        if len(idx) != 1:
            return
        i, j = idx[0], idx[0] + d
        if 0 <= j < len(self.sel):
            self.sel[i], self.sel[j] = self.sel[j], self.sel[i]
            self.fill()
            self.lb_sel.selection_set(j)
            self.schedule()

    # ---- figure
    def settings(self):
        s = {k: float(self.vars[k].get()) for k in ("tick_size", "label_size", "cbar_size", "name_size", "width",
                                                    "panel", "gap", "cbar_w", "vmax", "tip", "blur_y", "blur_t")}
        s["font"] = self.vars["font"].get().strip() or FONT
        s["cbar_title"] = self.vars["cbar_title"].get()
        s["cmap"] = self.vars["cmap"].get()
        s["labels"] = self.labels.get()
        return s

    def schedule(self):
        if self._job:
            self.root.after_cancel(self._job)
        self._job = self.root.after(300, self.redraw)

    def redraw(self):
        """Preview = the saved figure rendered as an image, scaled to the window (real proportions)."""
        self._job = None
        if not self.sel:
            self.view.config(image="", text="Add videos to the figure.")
            return
        try:
            fig = make_figure(self.sel, self.settings())
        except Exception as e:                  # e.g. a half-typed number
            self.status.config(text=f"Preview not updated: {e}", foreground="#a00")
            return
        # rendered at 300 dpi, then scaled down: Calibri has bitmap glyphs for 12-19 px text, which matplotlib
        # draws blank, so text must never be rendered at those sizes
        buf = io.BytesIO()
        fig.savefig(buf, format="png", dpi=300, facecolor="w", **TIGHT)
        plt.close(fig)
        im = Image.open(buf)
        cw, ch = max(self.view.winfo_width(), 400) - 20, max(self.view.winfo_height(), 300) - 20
        f = min(cw / im.width, ch / im.height, 1.0)
        im = im.resize((max(1, int(im.width * f)), max(1, int(im.height * f))), Image.LANCZOS)
        self.img = ImageTk.PhotoImage(im)
        self.view.config(image=self.img, text="")
        self.status.config(text="")

    def save(self):
        if not self.sel:
            messagebox.showinfo("Kymograph comparison", "No videos selected.")
            return
        os.makedirs(OUT, exist_ok=True)
        default = "kymo_" + "_".join(short(v).replace(" ", "") for v in self.sel) + ".png"
        p = filedialog.asksaveasfilename(initialdir=OUT, initialfile=default, defaultextension=".png",
                                         filetypes=[("PNG", "*.png")])
        if not p:
            return
        fig = make_figure(self.sel, self.settings())
        fig.savefig(p, dpi=600, **TIGHT)
        fig.savefig(os.path.splitext(p)[0] + ".pdf", **TIGHT)
        plt.close(fig)
        self.status.config(text=f"Saved {os.path.basename(p)} + .pdf", foreground="#060")


def main():
    root = tk.Tk()
    root.geometry("1400x950")
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
