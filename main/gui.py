"""Staged GUI for tracking an eversion robot inside a colon phantom.

  Stage 1  标注:   draw the colon boundary and the centerline (head -> tail) by hand
  Stage 2  追踪:   boundary + centerline follow the colon (optical flow + edge snapping)
  Stage 3  尖端:   tip = most tail-ward position along the centerline reached by the robot

Usage:  python gui.py [video.mp4]
Keys:   Space play/pause, Right step
"""
import argparse
import csv
import glob
import gzip
import json
import os
import sys
import time
from bisect import bisect_right
from collections import deque

import cv2
import numpy as np

try:
    from PyQt5 import QtCore, QtGui, QtWidgets
    Signal = QtCore.pyqtSignal
except ImportError:
    from PySide6 import QtCore, QtGui, QtWidgets
    Signal = QtCore.Signal
QShortcut = getattr(QtWidgets, "QShortcut", None) or QtGui.QShortcut

from config import Params, PER_MODE, mode_key, mode_values
from colon import (ColonTracker, Progress, proc_scale, to_small, gray_of, edge_map, point_at, anchor_stations,
                   strap_dist, lab_delta)
from geometry import resample_closed, resample_open
from curves_io import curves_line
from pipeline import FramePipeline
import viz

HERE = os.path.dirname(os.path.abspath(__file__))

# (attr, kind, args..., title, description); ("#", "header", text) starts a group
STAGE2 = [
    ("#", "header", "运动跟随"),
    ("follow_flow", "bool", "跟随光流",
     "勾上: 边缘和中心线每帧按光流 (相邻两帧之间每个像素移动了多少) 跟着肠道移动。"
     "不勾: 不算光流, 曲线只靠边缘吸附修正 (假体几乎不动时可以试试, 也更快)。"),
    ("flow_smooth", "float", 0.0, 10.0, 0.5, "光流平滑",
     "光流场的空间平滑。大 = 运动更整体、抗噪; 小 = 保留局部变形。"),
    ("flow_view_frames", "int", 1, 100, "Flow 视图跨度 (帧)",
     "只影响右侧 Flow 视图: 显示当前帧与这么多帧之前之间的光流。追踪本身仍逐帧算光流, 但相邻两帧通常只动 0.01–0.1 px, "
     "直接画出来看不见, 跨几十帧才看得出运动。颜色 = 方向 (见右上角色轮), 亮度/箭头长度 = 移动距离 (左下角写着满刻度多少 px); "
     "黄色/青色短箭头 = 边缘点/中心线点从光流得到的位移。"),
    ("#", "header", "边缘图 (右侧选 Edge map 视图实时看效果)"),
    ("edge_channel", "combo", ["b", "gray", "L", "a", "S", "V", "R", "G", "B"], "边缘图通道",
     "在哪张图上找边缘: b = Lab 黄度 (假体偏黄), a = Lab 红绿, gray/L = 亮度, S = 饱和度, V = HSV 亮度, R/G/B = 单个颜色通道。"
     "选肠道边界最清楚、绑带/褶皱最弱的那个。"),
    ("edge_blur", "int", 1, 31, "边缘图模糊",
     "求边缘前的高斯模糊核大小。大 = 只留下粗的大边界, 细纹理和噪点消失; 小 = 边缘更细更准但噪声多。"),
    ("edge_clahe", "bool", "局部对比度增强 (CLAHE)",
     "求边缘前先增强局部对比度, 让较暗或较淡处的边界也变清楚 (噪声也会增强)。"),
    ("edge_min", "float", 0.0, 1.0, 0.02, "最弱边缘阈值",
     "边缘强度已归一化 (最强的 1% ≈ 1)。低于此值的弱边缘被丢掉, 不参与吸附。0 = 全部保留。"),
    ("#", "header", "边缘吸附"),
    ("snap_radius", "int", 0, 20, "边缘吸附范围 (px)",
     "每个边缘点沿法线 ±该范围内寻找边缘。0 = 不吸附。"),
    ("snap_weight", "float", 0.0, 1.0, 0.05, "吸附力度",
     "每帧往找到的边缘移动多少。1 = 直接跳到边缘; 小一些更稳但跟得慢。"),
    ("edge_polarity", "combo", ["inside_higher", "inside_lower", "any"], "边缘极性",
     "边缘的方向: 从肠内走到肠外, 通道值是变小还是变大。inside_higher = 肠内值更大 (b 通道: 肠道更黄, 选这个); "
     "inside_lower = 肠内值更小; any = 不限方向。只接受顺着轮廓走向且方向正确的边缘, 不易被绑带拉走。"),
    ("#", "header", "形状"),
    ("shape_smooth", "float", 0.0, 10.0, 0.5, "运动平滑",
     "相邻轮廓点每帧的移动量互相平滑 (只平滑移动, 不会让轮廓缩小)。大 = 轮廓整体移动, 不出尖刺。"),
    ("shape_keep", "float", 0.0, 0.3, 0.005, "形状保持",
     "每帧把轮廓/中心线往你画的形状拉回一点 (允许整体平移、旋转、缩放)。防止长时间累积漂移; "
     "太大会抵消肠道真实的局部变形。0 = 不拉回。"),
    ("center_pull", "float", 0.0, 1.0, 0.05, "中心线居中力度",
     "把中心线慢慢往肠道横截面中点拉 (每帧最多 0.5 px)。0 = 中心线只跟光流。"),
]
STAGE3 = [
    ("#", "header", "显示"),
    ("view_max", "float", 1.0, 150.0, 1.0, "Change/Recent 图像颜色上限",
     "右侧 Change / Recent 视图的颜色刻度: 单个像素的颜色差异 0 → 此值 (红)。只影响显示, 和信号阈值无关。"
     "注意信号是整个截面宽度上的平均 (再经过平滑/归一化), 所以比图上最红的像素小很多; 要看和阈值对应的值, 用 Signal 视图或下方剖面图。"),
    ("#", "header", "截面"),
    ("n_stations", "int", 20, 300, "截面数量",
     "中心线从 H 到 T 等分成多少个截面。多 = 尖端位置更细, 但每个截面更窄、噪声更大。改后需重新点 开始追踪。"),
    ("width_cap", "float", 0.0, 5.0, 0.1, "截面长度上限 (× 局部半径)",
     "每个截面从中心线沿法线走到边缘。在急弯处法线顺着肠道方向, 会走得很远 (Signal 视图里扇形的长线), "
     "两段肠贴近时还会穿到另一段肠里, 采到别处的变化。这里把每一侧限制在 '中心线点到最近肠壁的距离' 的这么多倍。"
     "正常截面约 1.1 倍; 1.5 = 只剪掉异常长的; 0 = 不限制。也影响中心线居中。改后需从基线重新追踪。"),
    ("strip_frac", "float", 0.1, 1.0, 0.05, "截面采样宽度",
     "每个截面只用中心线两侧这个比例的肠宽来算信号。1 = 整个截面, 小 = 只看中心附近 (避开边缘误差)。"),
    ("#", "header", "信号"),
    ("feature", "combo", ["change", "recent_change", "darker", "brighter", "intensity_abs", "wider", "darker+wider"],
     "信号类型",
     "change: 当前帧与基线帧 (开始追踪那帧) 的颜色差异 = 机器人到过哪里 (累积)。"
     "recent_change: 当前帧与 N 帧之前的差异 = 现在哪里在变 (机器人正在推进的区域), 配合尖端规则 peak 使用。"
     "其余: 跟随肠道材料点比较 变暗/变亮/亮度变化/变宽 (阈值约 0.02–0.2)。"),
    ("compare", "combo", ["pixel", "material"], "change 比较方式",
     "pixel: 与基线帧同一图像位置比较 (肠道整体移动/变形也会算变化); "
     "material: 与基线帧中同一个肠道点 (随追踪移动的截面采样点) 比较, 肠道/条带随肠道一起动时不算变化。"),
    ("light_weight", "float", 0.0, 1.0, 0.05, "亮度权重",
     "颜色差异中亮度 (Lab L) 占多少。1 = 亮度和颜色都算; 0 = 只看颜色 (色相/饱和度), 不受光照明暗变化影响。"),
    ("strap_tol", "float", 0.0, 80.0, 1.0, "条带颜色容差",
     "先在阶段 1 点选条带颜色。颜色与条带相近 (距离小于此值) 的采样点被忽略 (当前帧或参考帧中是条带都忽略), "
     "条带移动就不会被当成机器人到达。右侧选 Strap 视图看哪些地方被当成条带 (红色)。0 = 不用。"),
    ("recent_frames", "int", 2, 500, "recent_change 回看帧数",
     "recent_change 与多少帧之前比较。小 = 只看很快的变化 (噪声多); 大 = 看较慢的推进。改后需从基线重新追踪。"
     "每帧回看缓冲约占 0.7 MB 内存 (640 宽), 500 帧约 350 MB。"),
    ("exposure_comp", "bool", "曝光补偿",
     "用肠道外的背景估计相机曝光/白平衡变化并校正 (否则整条肠会同时'变化', kymograph 上出现竖条纹)。"
     "对 change/recent_change 需重新追踪才生效。"),
    ("normalize", "bool", "按终点帧归一化 (每个位置自己的阈值)",
     "需要在阶段 1 标注终点帧。每个截面的信号除以它在终点帧 (机器人已经完全进入) 的信号: "
     "0 = 和基线一样, 1 = 和机器人在时一样。这样不同位置用同一个阈值 (约 0.3–0.6)。"
     "如果终点帧机器人没到 T, 在终点帧也标一个尖端位置。只对 change/darker/wider 类信号有效。"),
    ("collective_q", "float", 0.0, 0.95, 0.05, "集体变化去除",
     "每一帧减去所有截面信号的这个分位数, 只留下比大部分截面更突出的局部变化。"
     "整条肠同时变 (光照闪烁、假体整体被推动, kymograph 上的竖条纹) 就被去掉。"
     "0 = 不去除; 0.5 = 减中位数; 0.8 = 覆盖超过 20% 截面的变化都算集体变化。每种信号模式各自记住。"
     "只适合 recent_change; change 类信号必须设 0 (机器人走过大半条肠后, 真正的信号本身就是'集体'的, 会被减掉)。"),
    ("sig_time_frames", "int", 1, 500, "信号时间平滑 (帧)",
     "每个截面的信号按时间平均约这么多帧。一个截面要持续变化一段时间才算'到达', 尖端不会因单帧噪声跳动。1 = 不平滑。"),
    ("sig_thresh", "float", 0.0, 100.0, 0.01, "信号阈值",
     "信号高于此值 = 机器人已到达该截面。每种信号模式 (change / change 归一化 / recent_change …) 各自记住自己的阈值, "
     "切换信号类型或归一化时自动换回该模式的值。参考: change 归一化约 0.4–0.6 (1 = 和终点帧一样); "
     "change 不归一化约 8–16; recent_change (去除集体变化后) 约 2–5。"
     "对照下方剖面图的橙线: 设在已到达部分 (H 一侧) 和未到达部分之间。"),
    ("#", "header", "尖端"),
    ("tip_rule", "combo", ["contiguous", "global", "ridge", "farthest", "peak"], "尖端规则",
     "contiguous (配 change): 从头(H)开始连续超过阈值的最远处; "
     "global: 在整段已追踪视频上找一条最合理的尖端轨迹 (H 侧高于阈值、T 侧低于阈值, 速度有上限, 经过你标的尖端点), "
     "后面的帧可以修正前面的判断, 对条带/光照造成的短暂误报最稳; "
     "ridge (配 recent_change): 在整段视频上沿 kymograph 的亮脊找一条最优轨迹 (速度有上限, 只前进, 经过尖端标注), "
     "没有超过阈值的信号时尖端不动, 单帧的远处亮点不会把尖端拉过去; "
     "farthest: 任何超过阈值的最靠尾部(T)的位置; peak (配 recent_change): 信号最强的截面。"
     "标注的尖端点在所有规则下都直接作为该帧的尖端。"),
    ("max_gap", "int", 0, 30, "允许间断 (截面数)",
     "contiguous 模式下, 从 H 往 T 找时, 允许连续多少个截面低于阈值还继续往下找。"),
    ("max_speed", "float", 0.05, 10.0, 0.05, "最大速度 (截面/帧, global)",
     "global/ridge 模式下尖端每个视频帧最多移动多少个截面。小于 1 时 = 每 1/值 帧最多移动 1 个截面 "
     "(例如 0.05 = 每 20 帧 1 个截面)。越小越不容易被远处的突变拉走; 标注的尖端点够不着时轨迹会尽量靠近。"),
    ("tip_alpha", "float", 0.02, 1.0, 0.02, "尖端时间平滑", "每帧尖端位置的更新比例。1 = 不平滑。global 模式不用。"),
    ("monotonic", "bool", "只前进", "尖端位置不允许往回退 (机器人不回缩时打开)。global 模式下强烈建议打开。"),
]
NEEDS_RESTART = {"n_stations": "截面数量改了: 回到基线帧重新点 开始追踪 才生效",
                 "recent_frames": "回看帧数改了: 需从基线重新追踪才生效",
                 "width_cap": "截面长度上限改了: 需从基线重新追踪才生效",
                 "exposure_comp": "曝光补偿: 对 change/recent_change 需从基线重新追踪才生效"}
DISPLAY_ONLY = ("view_max", "flow_view_frames")  # only change the right-hand view: nothing is recomputed
STAGE1_HELP = (
    "<b>步骤</b><br>"
    "1. 拖动进度条到机器人<b>还没进入</b>的帧, 点 <b>设为起点</b> (基线)。<br>"
    "2. <b>起点边缘</b>: 沿肠道外轮廓左键依次加点 (自动闭合)。<b>起点中心线</b>: 从<b>头 H</b> (入口) 点到<b>尾 T</b>。<br>"
    "3. (推荐) 拖到机器人<b>走到最远</b>的帧, 点 <b>设为终点</b>, 再画终点边缘和中心线 "
    "(可先 <b>复制起点曲线</b> 再拖点修改)。追踪到终点停止; 终点曲线用于防漂移和每个位置的阈值归一化。<br>"
    "4. (可选) <b>标尖端</b>: 在任意帧上点机器人尖端位置, 数量不限, 尖端轨迹会经过这些点。<br>"
    "5. (可选) <b>选条带颜色</b>: 在条带上点几下, 阶段 3 用 条带颜色容差 忽略条带。<br>"
    "&nbsp;&nbsp;编辑: 拖动已有点移动; 点在线段上插入; 右键删除点。<br>"
    "6. 点 <b>开始追踪</b>, 然后播放或 <b>追踪到终点</b>。<br><br>"
    "暂停时修改第 2/3 阶段参数会立即作用于当前帧; 要用新参数重算前面的帧, 拖回去再播放。")
EDIT_MSG = {"bnd": "画起点边缘: 左键加点/拖动, 点在线上插入, 右键删点",
            "ctr": "画起点中心线: 从头 H 开始依次点到尾 T; 拖动/插入/右键删点",
            "bnd_end": "画终点边缘: 左键加点/拖动, 点在线上插入, 右键删点",
            "ctr_end": "画终点中心线: 从头 H 开始依次点到尾 T; 拖动/插入/右键删点",
            "tips": "标尖端: 左键点机器人尖端 (每帧一个, 再点替换), 右键删除; 拖进度条换帧",
            "straps": "选条带颜色: 左键点在条带上 (多点几处, 亮处暗处都点), 右键删除"}


class ImageView(QtWidgets.QLabel):
    mouse = Signal(str, float, float, int)  # kind (press/move/release), image x, y, button (1 L / 2 R)

    def __init__(self, min_h=240):
        super().__init__()
        self.setMinimumSize(320, min_h)
        self.setAlignment(QtCore.Qt.AlignCenter)
        self.setSizePolicy(QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Ignored)
        self.setStyleSheet("background:#111;")
        self.setMouseTracking(False)
        self._img = None
        self.scale = 1.0
        self._off = (0, 0)

    def set_image(self, bgr):
        self._img = bgr
        self._refresh()

    def _refresh(self):
        if self._img is None:
            return
        rgb = cv2.cvtColor(self._img, cv2.COLOR_BGR2RGB)
        h, w = rgb.shape[:2]
        qimg = QtGui.QImage(rgb.data, w, h, 3 * w, QtGui.QImage.Format_RGB888).copy()
        pix = QtGui.QPixmap.fromImage(qimg).scaled(self.size(), QtCore.Qt.KeepAspectRatio,
                                                   QtCore.Qt.SmoothTransformation)
        self.scale = pix.width() / w
        self._off = ((self.width() - pix.width()) / 2, (self.height() - pix.height()) / 2)
        self.setPixmap(pix)

    def resizeEvent(self, e):
        self._refresh()
        super().resizeEvent(e)

    def _emit(self, kind, e):
        if self._img is None:
            return
        pos = e.position() if hasattr(e, "position") else e.pos()
        btn = e.button() if kind != "move" else e.buttons()
        b = 1 if btn & QtCore.Qt.LeftButton else 2 if btn & QtCore.Qt.RightButton else 0
        self.mouse.emit(kind, (pos.x() - self._off[0]) / self.scale, (pos.y() - self._off[1]) / self.scale, b)

    def mousePressEvent(self, e):
        self._emit("press", e)

    def mouseMoveEvent(self, e):
        self._emit("move", e)

    def mouseReleaseEvent(self, e):
        self._emit("release", e)


class IntSlider(QtWidgets.QWidget):
    valueChanged = Signal(int)

    def __init__(self, lo, hi):
        super().__init__()
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.slider = QtWidgets.QSlider(QtCore.Qt.Horizontal)
        self.spin = QtWidgets.QSpinBox()
        for wdg in (self.slider, self.spin):
            wdg.setRange(lo, hi)
        self.spin.setFixedWidth(90)
        lay.addWidget(self.slider)
        lay.addWidget(self.spin)
        self.slider.valueChanged.connect(self.spin.setValue)
        self.spin.valueChanged.connect(self.slider.setValue)
        self.spin.valueChanged.connect(self.valueChanged.emit)

    def setValue(self, v):
        self.spin.setValue(int(v))


class FloatSlider(QtWidgets.QWidget):
    valueChanged = Signal(float)

    def __init__(self, lo, hi, step):
        super().__init__()
        self.lo, self.step = lo, step
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.slider = QtWidgets.QSlider(QtCore.Qt.Horizontal)
        self.slider.setRange(0, int(round((hi - lo) / step)))
        self.spin = QtWidgets.QDoubleSpinBox()
        self.spin.setRange(lo, hi)
        self.spin.setSingleStep(step)
        self.spin.setDecimals(3)
        self.spin.setFixedWidth(110)
        lay.addWidget(self.slider)
        lay.addWidget(self.spin)
        self.slider.valueChanged.connect(lambda i: self.spin.setValue(self.lo + i * self.step))
        self.spin.valueChanged.connect(self._spin_changed)

    def _spin_changed(self, v):
        self.slider.blockSignals(True)
        self.slider.setValue(int(round((v - self.lo) / self.step)))
        self.slider.blockSignals(False)
        self.valueChanged.emit(float(v))

    def setValue(self, v):
        self.spin.setValue(float(v))


class Reader:
    """Frame access by index; reading forward grabs instead of seeking."""

    def __init__(self, cap):
        self.cap, self.pos = cap, 0

    def read(self, idx):
        if not (0 <= idx - self.pos < 30):
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
            self.pos = idx
        while self.pos < idx:
            self.cap.grab()
            self.pos += 1
        ok, f = self.cap.read()
        self.pos += 1
        return f if ok else None


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self, video=None, params=None):
        super().__init__()
        self.p = params or Params()
        self.tracker = ColonTracker(self.p)
        self.progress = Progress(self.p)
        self.cap = None
        self.reader = self.ref_reader = None  # ref_reader: second capture for look-back frames
        self.video_path = None
        self.n_frames = 0
        self.fps = 30.0
        self.cur_idx = 0
        self.replay = False            # play / step / seek only show tracked results, never re-track
        self.tip_fix = False           # left-click on the video marks the tip, also while playing
        self._tip_hold = None          # (x, y) while the left button is held in tip_fix mode
        self._clock = (0.0, 0)         # replay time origin, see _reset_clock
        self.frame = None
        self.edit_mode = None          # None | a key of EDIT_MSG
        self.ann = self._empty_ann()   # editor points, ORIGINAL pixels
        self.start_frame, self.end_frame = 0, None
        self.drag = None
        self.setters = {}
        self.pipe = None
        self._last_show = 0.0
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self._tick)
        self._show_later = QtCore.QTimer(self)  # coalesces bursts of stage-3 slider changes
        self._show_later.setSingleShot(True)
        self._show_later.setInterval(200)
        self._show_later.timeout.connect(self._show)
        self._build_ui()
        for n, v in mode_values(self.p, mode_key(self.p)).items():  # threshold etc. of the current signal mode
            self.setters[n](v)
        if video:
            self.open_video(video)

    # ================================================================ UI
    def _build_ui(self):
        central = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(central)
        bar = QtWidgets.QHBoxLayout()

        def btn(text, slot, lay=bar, tip=""):
            b = QtWidgets.QPushButton(text)
            b.clicked.connect(slot)
            b.setToolTip(tip)
            lay.addWidget(b)
            return b
        btn("Open…", self._open_dialog)
        self.play_btn = btn("▶ 播放", self.toggle_play, tip="Space")
        btn("单步 ▶|", self.step, tip="Right")
        bar.addWidget(QtWidgets.QLabel("  步长"))
        self.step_spin = QtWidgets.QSpinBox()
        self.step_spin.setRange(1, 20)
        self.step_spin.setValue(self.p.frame_step)
        self.step_spin.setToolTip("每次前进多少帧 (追踪时越小越稳, 越大越快)")
        self.step_spin.valueChanged.connect(lambda x: setattr(self.p, "frame_step", int(x)))
        bar.addWidget(self.step_spin)
        btn("⏩ 追踪到终点", self.track_to_end, tip="不逐帧显示, 最快速度追踪到终点帧 (或视频结尾)")
        bar.addSpacing(20)
        self.replay_btn = btn("⟲ 回放模式", self.toggle_replay,
                              tip="打开后 播放/单步/拖进度条 只显示已追踪的结果, 不会从当前帧重新追踪; "
                                  "在最后一帧点播放 = 从头回放")
        self.replay_btn.setCheckable(True)
        bar.addWidget(QtWidgets.QLabel("倍速"))
        self.speed_spin = QtWidgets.QDoubleSpinBox()
        self.speed_spin.setRange(0.1, 8.0)
        self.speed_spin.setSingleStep(0.25)
        self.speed_spin.setValue(1.0)
        self.speed_spin.setSuffix("x")
        self.speed_spin.setToolTip("回放速度 (相对原视频)。画面绘制跟不上时会跳帧, 保证速度准确")
        self.speed_spin.valueChanged.connect(lambda *_: self._reset_clock())
        bar.addWidget(self.speed_spin)
        self.tipfix_btn = btn("✎ 播放中修正尖端", self.toggle_tip_fix,
                              tip="左键点视频上的机器人尖端 = 该帧的尖端标注 (不暂停); 按住左键跟着尖端移动, "
                                  "播放经过的每一帧都标在鼠标位置; 右键删除该帧的标注。关闭时自动保存标注")
        self.tipfix_btn.setCheckable(True)
        bar.addSpacing(20)
        btn("导出 CSV", self.export_csv, tip="尖端位置、轮廓、中心线 (原视频像素)")
        btn("导出视频", self.export_video, tip="左: 原视频+机器人 (粉线/红点/H/T); 右: recent 或 change 差异图 (随信号类型); 下: 剖面图和 kymograph")
        btn("保存参数", self.save_params)
        btn("载入参数", self.load_params)
        bar.addStretch(1)
        v.addLayout(bar)

        split = QtWidgets.QSplitter(QtCore.Qt.Horizontal)
        self.left = ImageView()
        self.left.mouse.connect(self._on_left_mouse)
        right_box = QtWidgets.QWidget()
        rv = QtWidgets.QVBoxLayout(right_box)
        rv.setContentsMargins(0, 0, 0, 0)
        self.view_combo = QtWidgets.QComboBox()
        self.view_combo.addItems(viz.VIEWS)
        self.view_combo.currentIndexChanged.connect(lambda *_: self._show())
        rv.addWidget(self.view_combo)
        self.right = ImageView()
        rv.addWidget(self.right, 1)
        split.addWidget(self.left)
        split.addWidget(right_box)

        vsplit = QtWidgets.QSplitter(QtCore.Qt.Vertical)
        vsplit.addWidget(split)
        self.plots = ImageView(min_h=150)
        self.plots.mouse.connect(self._on_plot_mouse)
        self.plots.setToolTip("左: 当前帧沿中心线 (H→T) 的信号; 右: kymograph, 点击跳到该帧")
        vsplit.addWidget(self.plots)
        vsplit.setSizes([700, 230])
        v.addWidget(vsplit, 1)

        nav = QtWidgets.QHBoxLayout()
        self.slider = QtWidgets.QSlider(QtCore.Qt.Horizontal)
        self.slider.sliderReleased.connect(lambda: self.go_to(self.slider.value()))
        self.frame_lbl = QtWidgets.QLabel("-")
        self.frame_lbl.setMinimumWidth(160)
        nav.addWidget(self.slider, 1)
        nav.addWidget(self.frame_lbl)
        v.addLayout(nav)
        self.setCentralWidget(central)

        tabs = QtWidgets.QTabWidget()
        tabs.addTab(self._stage1_tab(), "1 标注")
        tabs.addTab(self._param_tab(STAGE2, "<b>阶段 2: 追踪肠道</b><br>边缘点和中心线点跟着光流走, "
                                    "边缘再吸附到图像边缘, 中心线往截面中点修正。<br>"
                                    "检查: 黄色边缘贴住肠道, 青色中心线在肠道中间。", redo=True), "2 追踪肠道")
        tabs.addTab(self._param_tab(STAGE3, "<b>阶段 3: 尖端位置</b><br>中心线分成 100 个截面 (H→T)。"
                                    "每个截面算一个信号 (相对基线的变化), 尖端 = 机器人到达的最靠尾部的截面。<br>"
                                    "下方: 左边是当前帧的信号剖面, 右边 kymograph (横轴时间, 纵轴 H→T), 白线 = 尖端。"
                                    , redo=False), "3 尖端")
        dock = QtWidgets.QDockWidget("Stages", self)
        dock.setWidget(tabs)
        dock.setMinimumWidth(400)
        dock.setFeatures(QtWidgets.QDockWidget.NoDockWidgetFeatures)
        self.addDockWidget(QtCore.Qt.RightDockWidgetArea, dock)

        self.status = self.statusBar()
        QShortcut(QtGui.QKeySequence("Space"), self, self.toggle_play)
        QShortcut(QtGui.QKeySequence("Right"), self, self.step)
        self.resize(1750, 1000)

    def _stage1_tab(self):
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        help_lbl = QtWidgets.QLabel(STAGE1_HELP)
        help_lbl.setWordWrap(True)
        lay.addWidget(help_lbl)
        grid = QtWidgets.QGridLayout()
        def gbtn(text, slot, r, c, tip=""):
            b = QtWidgets.QPushButton(text)
            b.clicked.connect(slot)
            b.setToolTip(tip)
            grid.addWidget(b, r, c)
            return b
        gbtn("设当前帧为起点", self.set_start_frame, 0, 0, "基线帧: 机器人还没进入")
        def gpair(r, c, *specs):
            # several buttons side by side in one grid cell; buttons are parented to the cell widget
            cell = QtWidgets.QWidget()
            h = QtWidgets.QHBoxLayout(cell)
            h.setContentsMargins(0, 0, 0, 0)
            out = []
            for text, slot, tip in specs:
                b = QtWidgets.QPushButton(text, cell)
                if slot is not None:
                    b.clicked.connect(slot)
                b.setToolTip(tip)
                h.addWidget(b)
                out.append(b)
            grid.addWidget(cell, r, c)
            return out
        gpair(0, 1, ("设当前帧为终点", self.set_end_frame, "机器人走到最远的帧; 追踪到这里停止"),
              ("取消终点", self.clear_end_frame,
               "不再使用终点帧: 追踪到视频结尾; 已画的终点曲线保留但不使用, 重新设终点后恢复"))
        self.kf_lbl = QtWidgets.QLabel()
        grid.addWidget(self.kf_lbl, 1, 0, 1, 2)
        self.mode_btns = {}
        for key, text, r, c in (("bnd", "起点边缘", 2, 0), ("ctr", "起点中心线 (H→T)", 2, 1),
                                ("bnd_end", "终点边缘", 3, 0), ("ctr_end", "终点中心线 (H→T)", 3, 1),
                                ("tips", "标尖端 (任意帧)", 4, 0), ("straps", "选条带颜色", 4, 1)):
            slot = lambda _=False, k=key: self.set_edit(k)
            if key == "tips":   # shares its cell with "clear all tips"
                b, _ = gpair(r, c, (text, slot, ""),
                             ("清除所有尖端标注", self.clear_all_tips, "删除所有帧上的尖端标注 (会先确认)"))
            else:
                b = gbtn(text, slot, r, c)
            b.setCheckable(True)
            self.mode_btns[key] = b
        gbtn("终点复制起点曲线", self.copy_start_to_end, 5, 0, "终点边缘/中心线 = 起点的, 然后拖点修改")
        gbtn("反转头尾", self.reverse_ctr, 5, 1, "交换 H 和 T (起点和终点中心线)")
        gbtn("完成编辑", lambda: self.set_edit(None), 6, 0)
        gbtn("清除正在编辑的", self.clear_ann, 6, 1, "清除当前编辑模式的点 (标尖端模式: 只清除当前帧)")
        gbtn("保存标注", self.save_ann, 7, 0)
        gbtn("载入标注", self.load_ann, 7, 1)
        gbtn("用当前追踪结果编辑", self.edit_from_tracking, 8, 0,
             "把当前帧追踪到的边缘/中心线拿来修改, 当前帧设为新起点, 然后重新开始追踪")
        lay.addLayout(grid)
        start = QtWidgets.QPushButton("▶ 开始追踪 (从起点帧)")
        start.setStyleSheet("font-weight:bold; padding:8px;")
        start.clicked.connect(self.start_tracking)
        lay.addWidget(start)
        lay.addStretch(1)
        return w

    def _param_tab(self, spec, header, redo):
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)
        h = QtWidgets.QLabel(header)
        h.setWordWrap(True)
        lay.addWidget(h)
        for item in spec:
            name, kind = item[0], item[1]
            if kind == "header":
                hd = QtWidgets.QLabel(f"<b>— {item[2]} —</b>")
                hd.setStyleSheet("color:#4aa3ff; margin-top:10px;")
                lay.addWidget(hd)
                continue
            title, desc = item[-2], item[-1]
            cur = getattr(self.p, name)
            if kind == "int":
                wd = IntSlider(item[2], item[3])
                wd.setValue(cur)
                wd.valueChanged.connect(lambda x, n=name: self._set_param(n, int(x), redo))
            elif kind == "float":
                wd = FloatSlider(item[2], item[3], item[4])
                wd.setValue(cur)
                wd.valueChanged.connect(lambda x, n=name: self._set_param(n, float(x), redo))
            elif kind == "combo":
                wd = QtWidgets.QComboBox()
                wd.addItems(item[2])
                wd.setCurrentText(cur)
                wd.currentTextChanged.connect(lambda x, n=name: self._set_param(n, x, redo))
            else:
                wd = QtWidgets.QCheckBox()
                wd.setChecked(cur)
                wd.toggled.connect(lambda x, n=name: self._set_param(n, bool(x), redo))
            self.setters[name] = wd.setCurrentText if kind == "combo" else wd.setChecked if kind == "bool" else wd.setValue
            t = QtWidgets.QLabel(f"<b>{title}</b>")
            d = QtWidgets.QLabel(desc)
            d.setWordWrap(True)
            d.setStyleSheet("color:#777; margin-bottom:8px;")
            lay.addWidget(t)
            lay.addWidget(wd)
            lay.addWidget(d)
        lay.addStretch(1)
        sa = QtWidgets.QScrollArea()
        sa.setWidgetResizable(True)
        sa.setWidget(w)
        return sa

    def _set_param(self, name, value, redo):
        if name in DISPLAY_ONLY:
            setattr(self.p, name, value)
            return self._show()
        old_mode = mode_key(self.p)
        setattr(self.p, name, value)
        if name in PER_MODE:  # remembered separately for each signal mode
            self.p.mode_values.setdefault(old_mode, {})[name] = value
        elif mode_key(self.p) != old_mode:  # switched mode: bring back that mode's threshold etc.
            for n, v in mode_values(self.p, mode_key(self.p)).items():
                self.setters[n](v)
            self.status.showMessage(f"信号模式 {mode_key(self.p)}: 阈值 {self.p.sig_thresh:g}, "
                                    f"集体变化去除 {self.p.collective_q:g} (每种模式各自记住)", 6000)
        tr = self.tracker
        self._close_pipe()  # frames prepared ahead used the old params
        if name in NEEDS_RESTART:
            self.status.showMessage(NEEDS_RESTART[name], 6000)
        if redo and tr.active and not self.timer.isActive():
            if self.cur_idx == tr.last_idx and tr._snap is not None:
                tr.process(self.frame, self.cur_idx, redo=True)
            else:
                self.status.showMessage("当前是回看/起始帧: 参数会在继续播放时生效", 4000)
        self.progress.invalidate()
        if redo or self.timer.isActive():
            self._show()
        else:
            self._show_later.start()

    # ================================================================ video
    def _open_dialog(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Open video", os.path.dirname(HERE),
                                                        "Video (*.mp4 *.avi *.mov *.mkv);;All (*)")
        if path:
            self.open_video(path)

    def open_video(self, path):
        cap = cv2.VideoCapture(path)
        if not cap.isOpened():
            QtWidgets.QMessageBox.warning(self, "Error", f"Cannot open {path}")
            return
        if self.cap is not None:
            self.cap.release()
        if self.ref_reader is not None:
            self.ref_reader.cap.release()
        self._close_pipe()
        self.cap, self.video_path = cap, path
        self.reader, self.ref_reader = Reader(cap), Reader(cv2.VideoCapture(path))
        self.n_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        self.fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        self.slider.setRange(0, max(0, self.n_frames - 1))
        self.setWindowTitle(f"Eversion robot tracker — {os.path.basename(path)}")
        self.tracker.active = False
        self.progress.invalidate()
        self.ann = self._empty_ann()
        self.start_frame, self.end_frame = 0, None
        ann = self._ann_path()
        if os.path.exists(ann):
            self._load_ann_file(ann)
            self.status.showMessage(f"已自动载入标注 {os.path.basename(ann)}", 6000)
        else:
            self._update_kf_label()
            self.go_to(0)

    def _read_at(self, idx):
        return self.reader.read(idx)

    def go_to(self, idx):
        """Jump to a frame. Past tracked frames are only displayed; frames ahead are tracked up to idx."""
        if self.cap is None:
            return
        idx = int(np.clip(idx, 0, max(0, self.n_frames - 1)))
        tr = self.tracker
        if tr.active and idx > tr.last_idx and self.edit_mode is None and not self.replay:
            self._ensure_live()
            self._track_until(idx)
        else:
            f = self._read_at(idx)
            if f is None:
                return
            self.frame, self.cur_idx = f, idx
        self._show()

    def _ensure_live(self):
        """If we are reviewing an earlier frame, resume tracking from there (later history is dropped)."""
        tr = self.tracker
        if not tr.active or self.cur_idx == tr.last_idx or self.cur_idx < tr.start_idx:
            return
        k = max(i for i in tr.history if i <= self.cur_idx)
        f = self._read_at(k)
        tr.restore(f, k, read=self.ref_reader.read)
        self._close_pipe()
        self.frame, self.cur_idx = f, k
        self.progress.invalidate()
        self.status.showMessage(f"从帧 {k} 继续追踪 (之后的结果已丢弃)", 4000)

    def _last_frame(self):
        last = self.n_frames - 1
        return last if self.end_frame is None or self.end_frame <= self.tracker.start_idx else min(last, self.end_frame)

    def _close_pipe(self):
        if self.pipe is not None:
            self.pipe.close()
            self.pipe = None

    def _advance(self):
        """Track one more step (frames are prepared in parallel ahead of time). False at the end."""
        tr, step = self.tracker, self.p.frame_step
        nxt = tr.last_idx + step
        if nxt > self._last_frame():
            return False
        if self.pipe is None or self.pipe.next_idx != nxt or self.pipe.step != step:
            self._close_pipe()
            self.pipe = FramePipeline(self.video_path, tr, nxt, step, self._last_frame(), self.p.workers)
        item = self.pipe.get()
        if item is None:
            self._close_pipe()
            return False
        idx, f, prepared = item
        tr.process(prepared, idx)
        self.frame, self.cur_idx = f, idx
        return True

    def _track_until(self, idx):
        tr = self.tracker
        dlg = None
        idx = min(idx, self._last_frame())
        if idx - tr.last_idx > 10 * self.p.frame_step:
            dlg = QtWidgets.QProgressDialog("Tracking…", "Stop", tr.last_idx, idx, self)
            dlg.setWindowModality(QtCore.Qt.WindowModal)
        t0, n0 = time.time(), tr.last_idx
        while tr.last_idx < idx and self._advance():
            if dlg is not None and (tr.last_idx // self.p.frame_step) % 20 == 0:
                rate = (tr.last_idx - n0) / max(time.time() - t0, 1e-3)
                dlg.setLabelText(f"Tracking…  {rate:.0f} 帧/s")
                dlg.setValue(tr.last_idx)
                QtWidgets.QApplication.processEvents()
                if dlg.wasCanceled():
                    break
        if dlg is not None:
            dlg.close()

    def track_to_end(self):
        tr = self.tracker
        if not tr.active:
            return
        if self.timer.isActive():
            self.toggle_play()
        self.set_edit(None)
        self._ensure_live()
        self._track_until(self._last_frame())
        self._show()

    def _tick(self):
        if self.cap is None:
            return
        tr = self.tracker
        if self._replaying():
            self.progress.update(tr)
            fr = self.progress.frames
            i = bisect_right(fr, self.cur_idx)
            if self.timer.isActive() and i < len(fr):
                # follow the wall clock: wait when ahead, skip frames when drawing cannot keep up
                t0, f0 = self._clock
                target = f0 + (time.time() - t0) * self.fps * self.speed_spin.value()
                if fr[i] > target:
                    return
                i = max(i, bisect_right(fr, target) - 1)
            f = self._read_at(fr[i]) if i < len(fr) else None
            if f is None:
                self.toggle_play(stop=True)
                return self._show()
            self.frame, self.cur_idx = f, fr[i]
            if self._tip_hold:
                self._set_tip(*self._tip_hold)
            return self._show()
        if tr.active and self.cur_idx >= tr.start_idx:
            self._ensure_live()
            if not self._advance():
                self.toggle_play(stop=True)
                return self._show()
            if self._tip_hold:
                self._set_tip(*self._tip_hold)
        else:
            nxt = self.cur_idx + self.p.frame_step
            f = self._read_at(nxt)
            if f is None:
                return self.toggle_play(stop=True)
            self.frame, self.cur_idx = f, nxt
        # while playing, redraw at most ~15 times per second (drawing costs more than tracking)
        if not self.timer.isActive() or time.time() - self._last_show > 0.066:
            self._show()

    def toggle_play(self, stop=False):
        if self.timer.isActive() or stop:
            self.timer.stop()
            self.play_btn.setText("▶ 播放")
        elif self.cap is not None:
            self.set_edit(None)
            if self._replaying() and self.cur_idx >= self.tracker.last_idx:  # at the end: replay from the start
                self.go_to(self.tracker.start_idx)
            self._reset_clock()
            self.timer.start(5 if self._replaying() else 0)
            self.play_btn.setText("❚❚ 暂停")

    def _replaying(self):
        return self.replay and self.tracker.active

    def _reset_clock(self):
        """Replay time origin: (wall time, frame shown then)."""
        self._clock = (time.time(), self.cur_idx)

    def toggle_replay(self, on):
        self.replay = bool(on)
        if self.timer.isActive():
            self.toggle_play(stop=True)
        self.status.showMessage("回放模式: 播放/单步/拖进度条只显示已追踪的结果, 不重新追踪" if on else
                                "回放模式关闭: 从回看位置播放 = 从那里重新追踪", 6000)

    def toggle_tip_fix(self, on):
        self.tip_fix = bool(on)
        self._tip_hold = None
        if on:
            self.set_edit(None)
            self.status.showMessage("修正尖端: 左键点/按住跟随尖端, 右键删除该帧标注 (可以边播放边改)", 6000)
        elif self.video_path:
            self.save_ann(path=self._ann_path())
            self.status.showMessage(f"尖端标注已保存 ({len(self.ann['tips'])} 个)", 4000)

    def step(self):
        if self.timer.isActive():
            self.toggle_play()
        self._tick()

    # ================================================================ display
    def _current(self):
        """(history entry, tip station, signal, progress index) for the displayed frame."""
        tr = self.tracker
        if not tr.active or self.cur_idx < tr.start_idx:
            return None, None, None, None
        self.progress.set_anchors(anchor_stations(tr, self.ann["tips"], self.p.frame_step))
        self.progress.update(tr)
        ci = self.progress.at(self.cur_idx)
        if ci is None:
            return None, None, None, None
        k = self.progress.frames[ci]
        return tr.history[k], self.progress.tip[ci], self.progress.sig[ci], ci

    def _show(self):
        if self.frame is None:
            return
        self._last_show = time.time()
        tr = self.tracker
        h, tip, sig, ci = self._current()
        scale = tr.scale if tr.active else proc_scale(self.p, self.frame.shape[1])
        editor = None
        if self.edit_mode or not tr.active:
            end = self.edit_mode in ("bnd_end", "ctr_end") or (
                self.edit_mode is None and self.end_frame is not None and self.cur_idx == self.end_frame)
            sfx = "_end" if end else ""
            active = self.edit_mode[:3] if self.edit_mode and self.edit_mode[:3] in ("bnd", "ctr") else None
            editor = dict(bnd=self.ann["bnd" + sfx], ctr=self.ann["ctr" + sfx], active=active)
        marks = dict(tips=[t[1:] for t in self.ann["tips"] if t[0] == self.cur_idx],
                     straps=[s[1:3] for s in self.ann["straps"] if s[0] == self.cur_idx])
        self.left.set_image(viz.render_left(self.frame, h, tip, scale, editor,
                                            show_tracking=self.edit_mode is None, marks=marks))

        small = to_small(self.frame, scale)
        live = tr.active and self.cur_idx == tr.last_idx
        vis = dict(tr.vis) if live else {}
        view = self.view_combo.currentText()
        if view.startswith("Edge") and "edge" not in vis:
            vis["edge"] = edge_map(small, self.p)[0]
        if view.startswith("Flow") and self.ref_reader is not None:
            # motion over flow_view_frames (one frame is ~0.1 px: invisible); also works when paused / reviewing
            n = min(self.p.flow_view_frames, self.cur_idx)
            old = self.ref_reader.read(self.cur_idx - n) if n > 0 else None
            if old is not None:
                vis["flow"] = tr.flow.compute(gray_of(to_small(old, scale)), gray_of(small))
                vis["flow_frames"] = n
        if view.startswith(("Change", "Recent")) and tr.active:
            old = None  # reviewing: read the frame "recent" compares with
            if view.startswith("Recent") and not live and self.cur_idx >= tr.start_idx:
                old = self.ref_reader.read(tr.recent_ref(self.cur_idx))
            vis.update(tr.change_map(small, live, old))  # recomputed so stage-3 param changes show immediately
        if view.startswith("Strap") and len(self.ann["straps"]):
            lab = tr.lab_image(small) if tr.active else cv2.cvtColor(cv2.GaussianBlur(small, (7, 7), 0),
                                                                    cv2.COLOR_BGR2LAB)
            vis["strap"] = strap_dist(lab, self._strap_colors()) <= self.p.strap_tol
        self.right.set_image(viz.render_view(view, small, h, vis, self.p.sig_thresh, tip, sig, self.p.view_max))
        self.plots.set_image(viz.render_plots(self.progress, ci, self.p.sig_thresh))

        self.slider.blockSignals(True)
        self.slider.setValue(self.cur_idx)
        self.slider.blockSignals(False)
        kf = " [起点]" if self.cur_idx == self.start_frame else " [终点]" if self.cur_idx == self.end_frame else ""
        self.frame_lbl.setText(f"{self.cur_idx}/{self.n_frames - 1}  {self.cur_idx / self.fps:.2f}s{kf}")
        if self.edit_mode:
            msg = EDIT_MSG[self.edit_mode]
        elif h is not None:
            pos, s_px, total = point_at(h["ctr"], tip)
            msg = (f"尖端 截面 {tip:.1f}/{len(h['ctr']) - 1}  沿中心线 {s_px / tr.scale:.0f}/{total / tr.scale:.0f} px "
                   f"({100 * s_px / max(total, 1e-6):.0f}%)  位置 ({pos[0] / tr.scale:.0f}, {pos[1] / tr.scale:.0f})")
            if self.replay:
                msg += "   [回放模式]"
            elif self.cur_idx != tr.last_idx:
                msg += "   [回看模式]"
            if self.tip_fix:
                msg += "   [修正尖端: 左键点/按住, 右键删]"
        elif not tr.active:
            msg = "阶段 1: 画边缘和中心线, 然后点 开始追踪"
        else:
            msg = "基线之前的帧"
        self.status.showMessage(msg)

    # ================================================================ stage 1 editing
    @staticmethod
    def _empty_ann():
        # tips: [frame, x, y]; straps: [frame, x, y, L, a, b] (8-bit Lab of the picked strap colour)
        return {"bnd": [], "ctr": [], "bnd_end": [], "ctr_end": [], "tips": [], "straps": []}

    def _update_kf_label(self):
        end = "未设" if self.end_frame is None else f"帧 {self.end_frame}"
        self.kf_lbl.setText(f"起点 帧 {self.start_frame}   终点 {end}   尖端标注 {len(self.ann['tips'])} 个   "
                            f"条带颜色 {len(self.ann['straps'])} 个")

    def set_start_frame(self):
        self.start_frame = self.cur_idx
        if self.end_frame is not None and self.end_frame <= self.start_frame:
            self.end_frame = None
        self._update_kf_label()
        self._show()

    def set_end_frame(self):
        if self.cur_idx <= self.start_frame:
            QtWidgets.QMessageBox.information(self, "终点", "终点帧必须在起点帧之后。")
            return
        self.end_frame = self.cur_idx
        self._update_kf_label()
        self._show()

    def clear_end_frame(self):
        if self.end_frame is None:
            return
        self.end_frame = None
        if self.edit_mode in ("bnd_end", "ctr_end"):
            self.set_edit(None)
        self._update_kf_label()
        self._show()

    def set_edit(self, mode):
        if mode and self.timer.isActive():
            self.toggle_play()
        if mode in ("bnd_end", "ctr_end") and self.end_frame is None:
            QtWidgets.QMessageBox.information(self, "终点", "先拖到终点帧, 点 设当前帧为终点。")
            mode = None
        self.edit_mode = mode
        for k, b in self.mode_btns.items():
            b.setChecked(mode == k)
        if mode in ("bnd", "ctr") and self.cur_idx != self.start_frame:
            return self.go_to(self.start_frame)
        if mode in ("bnd_end", "ctr_end") and self.cur_idx != self.end_frame:
            return self.go_to(self.end_frame)
        self._show()

    def clear_ann(self):
        mode = self.edit_mode
        if mode is None:
            return
        if mode == "tips":
            self.ann["tips"] = [t for t in self.ann["tips"] if t[0] != self.cur_idx]
        else:
            self.ann[mode] = []
        self._ann_changed()

    def clear_all_tips(self):
        n = len(self.ann["tips"])
        if n == 0:
            return
        r = QtWidgets.QMessageBox.question(self, "清除尖端标注", f"删除全部 {n} 个尖端标注?")
        if r != QtWidgets.QMessageBox.Yes:
            return
        self.ann["tips"] = []
        self._ann_changed()

    def _ann_changed(self):
        straps = self._strap_colors()
        if self.progress.straps is None or not np.array_equal(straps, self.progress.straps):
            self.progress.straps = straps
            self.progress.invalidate()
        self._update_kf_label()
        self._show()

    def _strap_colors(self):
        return np.array([s[3:6] for s in self.ann["straps"]], np.float32).reshape(-1, 3)

    def reverse_ctr(self):
        self.ann["ctr"] = self.ann["ctr"][::-1]
        self.ann["ctr_end"] = self.ann["ctr_end"][::-1]
        self._show()

    def copy_start_to_end(self):
        if self.end_frame is None:
            QtWidgets.QMessageBox.information(self, "终点", "先拖到终点帧, 点 设当前帧为终点。")
            return
        self.ann["bnd_end"] = [list(q) for q in self.ann["bnd"]]
        self.ann["ctr_end"] = [list(q) for q in self.ann["ctr"]]
        self.set_edit("bnd_end")

    def edit_from_tracking(self):
        h, _, _, _ = self._current()
        if h is None:
            return
        s = 1.0 / self.tracker.scale
        self.ann["bnd"] = (resample_closed(h["bnd"], 40) * s).tolist()
        self.ann["ctr"] = (resample_open(h["ctr"], 15) * s).tolist()
        self.start_frame = self.cur_idx
        self._update_kf_label()
        self.set_edit("bnd")

    def _on_left_mouse(self, kind, x, y, btn):
        if self.edit_mode is None:
            if self.tip_fix:
                self._fix_tip(kind, x, y, btn)
            return
        if self.edit_mode in ("tips", "straps"):
            if kind == "press":
                self._mark(x, y, btn)
            return
        pts = self.ann[self.edit_mode]
        tol = 12 / max(self.left.scale, 1e-6)
        closed = self.edit_mode.startswith("bnd")
        if kind == "press":
            near = self._nearest_vertex(pts, x, y, tol)
            if btn == 2:
                if near is not None:
                    pts.pop(near)
            elif near is not None:
                self.drag = near
            else:
                seg = self._nearest_segment(pts, x, y, tol, closed)
                if seg is not None:
                    pts.insert(seg + 1, [x, y])
                    self.drag = seg + 1
                else:
                    pts.append([x, y])
                    self.drag = len(pts) - 1
        elif kind == "move" and self.drag is not None:
            pts[self.drag] = [x, y]
        elif kind == "release":
            self.drag = None
        self._show()

    def _fix_tip(self, kind, x, y, btn):
        """Tip correction without pausing: while the left button is held, every frame shown gets a tip mark there."""
        if kind == "release":
            self._tip_hold = None
        elif btn == 2:
            if kind == "press":
                self._mark(x, y, 2, "tips")
        elif btn == 1:
            self._tip_hold = (x, y)
            self._set_tip(x, y)
            if not self.timer.isActive():  # while playing, the next tick redraws
                self._show()

    def _set_tip(self, x, y):
        self.ann["tips"] = [t for t in self.ann["tips"] if t[0] != self.cur_idx] + [[self.cur_idx, x, y]]
        self.ann["tips"].sort(key=lambda t: t[0])
        self._update_kf_label()

    def _mark(self, x, y, btn, key=None):
        """Tip anchor / strap colour sample on the current frame."""
        key = key or self.edit_mode
        here = [i for i, m in enumerate(self.ann[key]) if m[0] == self.cur_idx]
        if btn == 2:
            tol = 15 / max(self.left.scale, 1e-6)
            near = [i for i in here if np.hypot(self.ann[key][i][1] - x, self.ann[key][i][2] - y) < tol]
            if near:
                self.ann[key].pop(near[0])
        elif btn == 1 and key == "tips":
            self._set_tip(x, y)
        elif btn == 1:
            tr = self.tracker
            scale = tr.scale if tr.active else proc_scale(self.p, self.frame.shape[1])
            small = to_small(self.frame, scale)
            # same colour space as the stage-3 samples (blurred, exposure-corrected Lab)
            lab = tr.lab_image(small) if tr.active else cv2.cvtColor(cv2.GaussianBlur(small, (7, 7), 0),
                                                                     cv2.COLOR_BGR2LAB)
            xi, yi = int(round(x * scale)), int(round(y * scale))
            patch = lab[max(0, yi - 2):yi + 3, max(0, xi - 2):xi + 3].reshape(-1, 3)
            if not len(patch):
                return
            self.ann["straps"].append([self.cur_idx, x, y] + np.median(patch, 0).round(1).tolist())
        self._ann_changed()

    @staticmethod
    def _nearest_vertex(pts, x, y, tol):
        if not pts:
            return None
        d = np.linalg.norm(np.array(pts) - [x, y], axis=1)
        i = int(np.argmin(d))
        return i if d[i] < tol else None

    @staticmethod
    def _nearest_segment(pts, x, y, tol, closed):
        n = len(pts)
        if n < 2:
            return None
        best, bi = tol, None
        q = np.array([x, y], np.float32)
        for i in range(n if closed and n >= 3 else n - 1):
            a, b = np.array(pts[i], np.float32), np.array(pts[(i + 1) % n], np.float32)
            ab = b - a
            t = np.clip(np.dot(q - a, ab) / max(np.dot(ab, ab), 1e-6), 0, 1)
            d = np.linalg.norm(a + t * ab - q)
            if d < best:
                best, bi = d, i
        return bi

    def start_tracking(self):
        if self.frame is None:
            return
        if len(self.ann["bnd"]) < 3 or len(self.ann["ctr"]) < 2:
            QtWidgets.QMessageBox.information(self, "标注不完整", "需要: 起点边缘至少 3 个点, 中心线至少 2 个点。")
            return
        end = None
        if self.end_frame is not None:
            if len(self.ann["bnd_end"]) < 3 or len(self.ann["ctr_end"]) < 2:
                QtWidgets.QMessageBox.information(self, "终点标注不完整",
                                                  "设了终点帧但没画终点边缘/中心线: 只用终点截断, 不做终点修正和归一化。")
            else:
                tip = [t[1:] for t in self.ann["tips"] if t[0] == self.end_frame]
                end = dict(frame=self._read_at(self.end_frame), idx=self.end_frame, bnd=self.ann["bnd_end"],
                           ctr=self.ann["ctr_end"], tip=tip[0] if tip else None)
        self.set_edit(None)
        if self.timer.isActive():
            self.toggle_play()
        self._close_pipe()
        self.frame, self.cur_idx = self._read_at(self.start_frame), self.start_frame
        self.tracker.start(self.frame, self.cur_idx, self.ann["bnd"], self.ann["ctr"], end)
        self.progress.straps = self._strap_colors()
        self.progress.invalidate()
        self.save_ann(path=self._ann_path())
        self.status.showMessage("开始追踪。标注已自动保存。", 4000)
        self._show()

    def _ann_path(self):
        return os.path.splitext(self.video_path or os.path.join(HERE, "video"))[0] + "_annotation.json"

    def save_ann(self, path=None):
        if not path:
            path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Save annotation", self._ann_path(), "JSON (*.json)")
            if not path:
                return
        with open(path, "w", encoding="utf-8") as f:
            json.dump(dict(frame=self.start_frame, video=os.path.basename(self.video_path or ""),
                           boundary=self.ann["bnd"], centerline=self.ann["ctr"],
                           end_frame=self.end_frame, boundary_end=self.ann["bnd_end"],
                           centerline_end=self.ann["ctr_end"], tips=self.ann["tips"],
                           strap_colors=self.ann["straps"]), f, indent=1)

    def load_ann(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Load annotation", os.path.dirname(self._ann_path()),
                                                        "JSON (*.json)")
        if path:
            self._load_ann_file(path)

    def _load_ann_file(self, path):
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        self.tracker.active = False
        self._close_pipe()
        self.ann = dict(self._empty_ann(), bnd=d["boundary"], ctr=d["centerline"],
                        bnd_end=d.get("boundary_end", []), ctr_end=d.get("centerline_end", []),
                        tips=d.get("tips", []), straps=d.get("strap_colors", []))
        self.start_frame, self.end_frame = int(d.get("frame", 0)), d.get("end_frame")
        self.progress.straps = self._strap_colors()
        self.progress.invalidate()
        self._update_kf_label()
        self.go_to(self.start_frame)

    # ================================================================ plots
    def _on_plot_mouse(self, kind, x, y, btn):
        if kind != "press" or btn != 1:
            return
        f = viz.kymo_frame_at(x, self.progress)
        if f is not None:
            if self.timer.isActive():
                self.toggle_play()
            self.go_to(f)

    # ================================================================ export / params
    def _rows(self):
        tr, pg = self.tracker, self.progress
        pg.update(tr)
        s = 1.0 / tr.scale
        for i, k in enumerate(pg.frames):
            h = tr.history[k]
            pos, s_px, total = point_at(h["ctr"], pg.tip[i])
            yield k, h, dict(frame=k, time_s=round(k / self.fps, 4), tip_station=round(pg.tip[i], 2),
                             raw_station=round(pg.raw[i], 2), tip_frac=round(float(s_px) / max(total, 1e-6), 4),
                             tip_arclen_px=round(float(s_px * s), 2), colon_len_px=round(float(total * s), 2),
                             tip_x=round(float(pos[0]) * s, 2), tip_y=round(float(pos[1]) * s, 2))

    def export_csv(self):
        if not self.tracker.active:
            return
        default = os.path.splitext(self.video_path)[0] + "_track.csv"
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Export", default, "CSV (*.csv)")
        if not path:
            return
        stem = os.path.splitext(path)[0]
        s = 1.0 / self.tracker.scale
        with open(stem + ".csv", "w", newline="", encoding="utf-8") as cf, \
                gzip.open(stem + "_curves.jsonl.gz", "wt", encoding="utf-8", newline="\n") as jf:
            w = None
            for k, h, row in self._rows():
                if w is None:
                    w = csv.DictWriter(cf, fieldnames=list(row))
                    w.writeheader()
                w.writerow(row)
                jf.write(curves_line(k, h["bnd"] * s, h["ctr"] * s))
        self.p.save(stem + "_params.json")
        self.status.showMessage(f"已导出 {stem}.csv / _curves.jsonl.gz / _params.json", 8000)

    def export_video(self):
        """One video, same layout as the window: left = original frame with the robot only (pink body, red tip,
        H/T; no boundary / centerline), right = recent or change colour-difference map (no overlay), plots below."""
        tr, pg, p = self.tracker, self.progress, self.p
        if not tr.active:
            return
        pg.update(tr)
        default = os.path.splitext(self.video_path)[0] + "_track.mp4"
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Export video", default, "MP4 (*.mp4)")
        if not path:
            return
        recent = p.feature == "recent_change"
        view = viz.VIEWS[3] if recent else viz.VIEWS[2]
        buf = deque()  # (frame idx, Lab image) for the recent map: compare with recent_frames earlier
        dlg = QtWidgets.QProgressDialog("Rendering…", "Stop", 0, len(pg.frames), self)
        dlg.setWindowModality(QtCore.Qt.WindowModal)
        writer = viz.VideoOut(path, self.fps / max(1, p.frame_step))
        for i, k in enumerate(pg.frames):
            f = self._read_at(k)
            if f is None:
                break
            small = to_small(f, tr.scale)
            lab = tr.lab_image(small)
            if recent:
                buf.append((k, lab))
                while len(buf) > 1 and buf[1][0] <= k - p.recent_frames:
                    buf.popleft()
                vis = {"recent": lab_delta(lab, buf[0][1], p.light_weight)}
            else:
                vis = {"change": lab_delta(lab, tr.base_lab_img, p.light_weight)}
            left = viz.render_left(f, tr.history[k], pg.tip[i], tr.scale, curves=False)
            right = viz.render_view(view, small, None, vis, p.sig_thresh, None, None, p.view_max)
            top = viz.side_by_side(left, right, min(540, f.shape[0]))
            plots = viz.render_plots(pg, i, p.sig_thresh)
            plots = cv2.resize(plots, (top.shape[1], int(plots.shape[0] * top.shape[1] / plots.shape[1])))
            writer.write(np.vstack([top, plots]))
            if i % 10 == 0:
                dlg.setValue(i)
                QtWidgets.QApplication.processEvents()
                if dlg.wasCanceled():
                    break
        writer.close()
        dlg.close()
        self.go_to(self.cur_idx)
        self.status.showMessage(f"已导出 {path}", 8000)
        if writer.fallback:
            QtWidgets.QMessageBox.warning(self, "导出视频", "没有找到 imageio-ffmpeg, 用的是 OpenCV 的 mp4v 编码, "
                                          "文件会大 10-30 倍。\npip install imageio-ffmpeg 后重新导出。")

    def save_params(self):
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Save params", os.path.join(HERE, "params.json"),
                                                        "JSON (*.json)")
        if path:
            self.p.save(path)

    def load_params(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Load params", HERE, "JSON (*.json)")
        if not path:
            return
        self.p.update(Params.load(path).to_dict())
        for name, setter in self.setters.items():
            setter(getattr(self.p, name))
        self.step_spin.setValue(self.p.frame_step)

    def closeEvent(self, e):
        self._close_pipe()
        super().closeEvent(e)


def default_video():
    hits = glob.glob(os.path.join(os.path.dirname(HERE), "*1379*.mp4"))
    return hits[0] if hits else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video", nargs="?", default=None)
    ap.add_argument("--params", default=None)
    a = ap.parse_args()
    pfile = a.params or os.path.join(HERE, "params.json")
    params = Params.load(pfile) if os.path.exists(pfile) else None
    app = QtWidgets.QApplication(sys.argv)
    w = MainWindow(a.video or default_video(), params)
    w.show()
    sys.exit(app.exec() if hasattr(app, "exec") else app.exec_())


if __name__ == "__main__":
    main()
