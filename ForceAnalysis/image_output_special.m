function image_output_special(pick)
%IMAGE_OUTPUT_SPECIAL Paper figure: several go runs side by side (Small, Medium, Large, Endoscope),
%   |F|, pressure and tip position on shared y axes, no gaps between the panels.
%
%   Just run  image_output_special : a window opens to pick the recordings, the font size and the size
%   of the figure; "Make figure" writes <name>.png and <name>.pdf to ../Figures.
%   image_output_special({'S 4', 'M 9'})  no window: these recordings with the settings below.
%   Data, time alignment and colon segments are exactly as in image_output.m (the helpers at the
%   bottom are copied from there; image_output.m itself is not used or changed).

%% ======================= SETTINGS =======================
here = fileparts(mfilename('fullpath'));
o = struct();
o.Default        = {'S 4', 'M 9', 'L 7', 'Mo 6'};   % selected when the window opens
o.FontName       = 'Calibri';
o.FontSize       = 8;           % pt (can be changed in the window)
o.Size           = [17.5 11];   % [width height] cm (can be changed in the window); A4 text width is about 16-18 cm
o.PressureLabel  = 'P (kPa)';
o.CommonCuts     = true;        % true: every column uses the reference cut positions (colon_cuts.json), so the
                                %   segment lines and bands match the segment names on the right
o.ColonLength    = 1.35;        % m
o.SegSmooth      = 1;           % s, moving median of the position before finding the segments
o.ZeroForce      = false;       % subtract the mean of the first 0.5 s of each force file
o.ForceSmooth    = 1;           % moving mean of the force, samples (1 = none)
o.Root           = fullfile(here, '..', 'Forcedata');
o.VideoDir       = fullfile(here, '..', 'compressedvideo');
o.CorrectedDir   = fullfile(here, '..', 'Corrected_video');
o.FigDir         = fullfile(here, '..', 'Figures');
o.Cuts           = fullfile(here, 'colon_cuts.json');
%% ========================================================

rootDir = canonical(o.Root);
videoDir = '';
if isfolder(o.VideoDir), videoDir = canonical(o.VideoDir); end
corrDir = o.CorrectedDir;
if isfolder(corrDir), corrDir = canonical(corrDir); end
if ~isfolder(o.FigDir), mkdir(o.FigDir); end
figDir = canonical(o.FigDir);

% go runs with a video track, in figure order (Small, Medium, Large, Endoscope, then test number)
REC = buildRecordings(rootDir, videoDir, corrDir);
REC = REC(arrayfun(@(r) ~isempty(r.csv) && strcmp(r.role, 'G'), REC));
if isempty(REC), error('image_output_special:noTracks', 'No go recordings with a video track.'); end
code = cell(1, numel(REC)); num = zeros(1, numel(REC));
for i = 1:numel(REC)
    t = parseVideoName(trackBase(REC(i).csv));
    code{i} = t{1}; num(i) = str2double(t{2});
end
[~, ord] = sortrows([groupRank(code)' num']);
REC = REC(ord); code = code(ord); num = num(ord);
items = arrayfun(@(i) sprintf('%s  %d   (%s)', groupTitle(code{i}), num(i), strtrim(trackBase(REC(i).csv))), ...
    1:numel(REC), 'UniformOutput', false);
keys = lower(arrayfun(@(i) sprintf('%s %d', code{i}, num(i)), 1:numel(code), 'UniformOutput', false));
sel = find(ismember(keys, lower(o.Default)));
autoName = @(k) ['special' sprintf('_%s', strjoin(arrayfun(@(i) sprintf('%s%d', code{i}, num(i)), k, 'UniformOutput', false), '_'))];

if nargin >= 1                     % no window
    k = find(ismember(keys, lower(pick)));
    o.Show = false;
    makeRow(loadRow(REC(k), code(k), o, rootDir, videoDir, corrDir, @(~) []), o, fullfile(figDir, autoName(k)));
    fprintf('%s.png / .pdf in %s\n', autoName(k), figDir);
    return;
end

% ---- window
w = uifigure('Name', 'image_output_special', 'Position', [100 100 520 560]);
g = uigridlayout(w, [7 2], 'RowHeight', {'1x', 26, 26, 26, 26, 26, 34}, 'ColumnWidth', {150, '1x'});
uilabel(g, 'Text', 'Recordings (Ctrl / Shift):', 'VerticalAlignment', 'top');
lb = uilistbox(g, 'Items', items, 'ItemsData', 1:numel(items), 'Multiselect', 'on', 'Value', sel);
uilabel(g, 'Text', 'Font size (pt):');
efs = uieditfield(g, 'numeric', 'Value', o.FontSize, 'Limits', [4 20]);
uilabel(g, 'Text', 'Width (cm):');
ew = uieditfield(g, 'numeric', 'Value', o.Size(1), 'Limits', [4 40]);
uilabel(g, 'Text', 'Height (cm):');
eh = uieditfield(g, 'numeric', 'Value', o.Size(2), 'Limits', [4 40]);
uilabel(g, 'Text', 'File name:');
ef = uieditfield(g, 'text', 'Value', '', 'Placeholder', 'auto, e.g. special_S4_M9_L7_Mo6');
uilabel(g, 'Text', '');
cbShow = uicheckbox(g, 'Text', 'Show the figure', 'Value', true);
uilabel(g, 'Text', '');
uibutton(g, 'Text', 'Make figure', 'ButtonPushedFcn', @(~, ~) onMake());

    function onMake()
        k = sort(lb.Value);
        if isempty(k), uialert(w, 'Select at least one recording.', 'image_output_special'); return; end
        oo = o;
        oo.FontSize = efs.Value;
        oo.Size = [ew.Value eh.Value];
        oo.Show = cbShow.Value;
        name = strtrim(ef.Value);
        if isempty(name), name = autoName(k); end
        d = uiprogressdlg(w, 'Title', 'image_output_special', 'Indeterminate', 'on', 'Message', 'Loading ...');
        try
            R = loadRow(REC(k), code(k), oo, rootDir, videoDir, corrDir, @(m) set(d, 'Message', m));
            d.Message = 'Drawing ...';
            makeRow(R, oo, fullfile(figDir, name));
            close(d);
            uialert(w, sprintf('%s.png and .pdf written to\n%s', name, figDir), 'Done', 'Icon', 'success');
        catch err
            close(d);
            uialert(w, err.message, 'Error');
        end
    end
end

function R = loadRow(REC, code, o, rootDir, videoDir, corrDir, say)
%LOADROW Data, track and segments of each recording -> what makeRow needs.
R = struct('P', {}, 'SG', {}, 'title', {});
for j = 1:numel(REC)
    rec = REC(j);
    say(sprintf('Loading %s', strtrim(trackBase(rec.csv))));
    D = loadTest(rec.folder, rootDir);
    files = guessTrackFiles(rec.csv);
    TK = loadTrack(rec, D, videoDir, corrDir);
    C = cutsFor(files.csv, o.Cuts);
    [cb, cc] = firstCurves(files.curves);
    SG = segInfo(TK, C, cb, cc, o);
    if o.CommonCuts && SG.has, SG = commonSegments(SG, TK, o); end
    R(end + 1) = struct('P', panelData(D, TK, SG, o), 'SG', SG, 'title', groupTitle(code{j})); %#ok<AGROW>
end
end

function SG = commonSegments(SG, TK, o)
%COMMONSEGMENTS Segment edges = the reference cut fractions (the same for every video); tip segment as in segInfo.
d = jsondecode(fileread(o.Cuts));
SG.edges = [0, cummax(min(max(double(d.frac_anatomical(:))', 0), 1)), 1];
w = max(1, round(o.SegSmooth / median(diff(TK.t), 'omitnan')));
p = movmedian(SG.frac, w, 'omitnan');
p = fillmissing(fillmissing(p, 'previous'), 'next');
m = max(3, round(0.1 * numel(p)));
if median(p(end - m + 1:end)) >= median(p(1:m)), env = cummax(p); else, env = cummin(p); end
SG.lab = segOf(env, SG.edges);
end

%% ======================= groups =======================
function r = groupRank(code)
r = cellfun(@(c) find(strcmpi(c, {'S', 'M', 'L', 'Mo'})), code);
end

function s = groupTitle(c)
s = containers.Map({'s', 'm', 'l', 'mo'}, {'Small', 'Medium', 'Large', 'Endoscope'});
s = s(lower(c));
end

%% ======================= figure =======================
function makeRow(R, o, base)
%MAKEROW One column per recording: |F|, P, tip position. Every row on the same y range, no gaps between the
%   panels, a dark line between the columns. Y labels on the first column, segment names of the position axis
%   on the last one; each column keeps its own time axis.
[~, short, cols0] = segNames();
cols = 0.4 * cols0 + 0.6;           % light backgrounds
fs = o.FontSize;
n = numel(R);

yF = []; yP = [];
for k = 1:n
    p = R(k).P;
    yF = [yF; p.Fm(p.inF)]; %#ok<AGROW>
    if p.hasPw, yP = [yP; p.P1(p.tP >= p.tLo & p.tP <= p.tHi)]; end %#ok<AGROW>
end

fig = figure('Color', 'w', 'Units', 'centimeters', 'Position', [2 2 o.Size], 'Visible', onOff(o.Show), ...
    'DefaultAxesFontName', o.FontName, 'DefaultTextFontName', o.FontName, 'DefaultAxesFontSize', fs, ...
    'DefaultTextFontSize', fs);
tl = tiledlayout(fig, 3, n, 'TileSpacing', 'none', 'Padding', 'compact');
for k = 1:n
    p = R(k).P;
    ax = gobjects(1, 3);
    for r = 1:3, ax(r) = nexttile(tl, (r - 1) * n + k); end

    plot(ax(1), p.tF, p.Fm, '-', 'Color', [0.30 0.16 0.52], 'LineWidth', 0.7);
    setYRange(ax(1), yF, 0.08);
    if p.hasPw
        plot(ax(2), p.tP, p.P1, '-', 'Color', [0.70 0.22 0.10], 'LineWidth', 0.9);
    else
        text(ax(2), 0.5, 0.5, 'n/a', 'Units', 'normalized', 'HorizontalAlignment', 'center', ...
            'Color', [0.45 0.45 0.45], 'FontSize', fs, 'FontAngle', 'italic', 'FontName', o.FontName);
    end
    if isempty(yP), ylim(ax(2), [0 1]); else, setYRange(ax(2), yP, 0.08); end
    plot(ax(3), p.tT, p.pos, '-', 'Color', [0.05 0.38 0.45], 'LineWidth', 1.1);
    ylim(ax(3), [0 o.ColonLength]);

    hold(ax, 'on');
    linkaxes(ax, 'x');
    xlim(ax(1), [p.tLo p.tHi]);
    set(ax, 'Box', 'on', 'Layer', 'top', 'FontSize', fs, 'FontName', o.FontName, 'XColor', 'k', 'YColor', 'k', ...
        'TickDir', 'in', 'TickLength', [0.015 0.015], 'XGrid', 'off', 'YGrid', 'off', 'LineWidth', 0.6);
    % panels touch: drop tick labels that would run into the neighbouring panel
    if k < n, dropEndTicks(ax, 'X', 0.13); end
    for r = 2:3, dropEndTicks(ax(r), 'Y', 0.07); end
    set(ax(1:2), 'XTickLabel', []);
    if k == 1
        ylabel(ax(1), '|F| (N)');
        ylabel(ax(2), o.PressureLabel);
        ylabel(ax(3), 'Tip position (m)');
    else
        set(ax, 'YTickLabel', []);
    end
    title(ax(1), R(k).title, 'FontSize', fs + 1, 'FontWeight', 'bold', 'Color', 'k', 'FontName', o.FontName);

    SG = R(k).SG;
    if SG.has
        for a = ax, drawTimeBands(a, p.bands, cols); end
        if ~isempty(SG.edges)
            drawLengthBands(ax(3), SG.edges * o.ColonLength, short, fs - 1, k == n, cols0);
        end
    end
    if k < n                           % dark line between this column and the next
        for a = ax
            yl = ylim(a);
            plot(a, p.tHi * [1 1], yl, '-', 'Color', 'k', 'LineWidth', 1.4, 'Clipping', 'off', ...
                'HandleVisibility', 'off');
        end
    end
end
xlabel(tl, 'Test time (s)', 'FontSize', fs + 1, 'FontName', o.FontName, 'Color', 'k');

savePng(fig, [base '.png'], 600);
warning('off', 'MATLAB:print:ContentTypeImageSuggested');
exportgraphics(fig, [base '.pdf'], 'ContentType', 'vector');
if ~o.Show, close(fig); end
end

function dropEndTicks(ax, which, frac)
%DROPENDTICKS Remove ticks within frac of the upper end of the axis (X: right, Y: top).
for a = ax
    lim = get(a, [which 'Lim']);
    t = get(a, [which 'Tick']);
    set(a, [which 'Tick'], t(t <= lim(2) - frac * diff(lim)));
end
end

function drawLengthBands(ax, edges, names, fs, showNames, cols)
%DRAWLENGTHBANDS Segment boundaries on the position axis (thin dashed lines). With showNames: the names on the
%   right and a strip in the segment colours along the right edge (the key to the background colours).
xl = xlim(ax); yl = ylim(ax);
for k = 2:numel(edges) - 1
    if edges(k) > edges(k - 1)
        yline(ax, edges(k), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 0.4, 'HandleVisibility', 'off');
    end
end
xlim(ax, xl); ylim(ax, yl);
if ~showNames, return; end
x2 = xl(2); x1 = x2 - 0.035 * diff(xl);
for k = 1:numel(edges) - 1
    if edges(k + 1) > edges(k)
        patch(ax, [x1 x2 x2 x1], edges([k k k + 1 k + 1]), cols(k, :), 'EdgeColor', 'w', 'LineWidth', 0.3, ...
            'HandleVisibility', 'off');
    end
end
c = (edges(1:end - 1) + edges(2:end)) / 2;
vis = c >= yl(1) & c <= yl(2) & diff(edges) > 0;
yyaxis(ax, 'right');
ylim(ax, yl);
set(ax, 'YTick', c(vis), 'YTickLabel', names(vis));
ax.YAxis(2).Color = 'k';
ax.YAxis(2).FontSize = fs;
yyaxis(ax, 'left');
ax.YAxis(1).Color = 'k';
end

function P = panelData(D, TK, SG, o)
%PANELDATA The curves of one recording on its own time window (as makeFigure in image_output.m).
tF = []; Fm = [];
for k = TK.forceIdx
    fr = D.force(k);
    Fk = fr.F;
    if o.ZeroForce
        n0 = max(1, find(fr.T <= fr.T(1) + 0.5, 1, 'last'));
        Fk = Fk - mean(Fk(1:n0, :), 1);
    end
    if o.ForceSmooth > 1, Fk = movmean(Fk, round(o.ForceSmooth), 1); end
    tF = [tF; fr.T - fr.T(1) + fr.ts; nan];  %#ok<AGROW>
    Fm = [Fm; vecnorm(Fk, 2, 2); nan];        %#ok<AGROW>
end
if isempty(tF), error('no force file for this phase'); end
hasP = ~isempty(D.press);
tP = []; P1 = [];
if hasP
    tP = D.press.t - D.press.t(1) + D.press.ts;
    P1 = D.press.P1;
end
tT = TK.t;
pos = SG.frac * o.ColonLength;
% time window = overlap of video track, force and pressure (the shortest record decides each end)
spans = {[tT(1), tT(end)], [min(tF), max(tF)]};
if hasP, spans{3} = [tP(1), tP(end)]; end
[tLo, tHi, used] = overlapWindow(spans);
hasPw = hasP && used(3);
t0 = tLo;
tF = tF - t0; tT = tT - t0;
if hasP, tP = tP - t0; end
tLo = 0; tHi = tHi - t0;
P = struct('tF', tF, 'Fm', Fm, 'inF', tF >= tLo & tF <= tHi, 'hasPw', hasPw, 'tP', tP, 'P1', P1, ...
    'tT', tT, 'pos', pos, 'tLo', tLo, 'tHi', tHi);
P.bands = segmentBands(tT, SG.lab, tLo, tHi);
end

function s = onOff(tf)
if tf, s = 'on'; else, s = 'off'; end
end

%% ======================= copied from image_output.m (unchanged) =======================
function [names, short, cols] = segNames()
names = {'Rectum', 'Sigmoid', 'Descending colon', 'Splenic flexure', 'Transverse colon', ...
    'Hepatic flexure', 'Ascending colon', 'Cecum'};
short = {'Rect', 'Sig', 'Desc', 'SF', 'Trans', 'HF', 'Asc', 'Cec'};
cols = [0.80 0.80 0.80;    % rectum
        0.99 0.75 0.55;    % sigmoid
        0.98 0.90 0.50;    % descending
        0.60 0.60 0.60;    % splenic flexure
        0.65 0.87 0.60;    % transverse
        0.60 0.60 0.60;    % hepatic flexure
        0.60 0.78 0.96;    % ascending
        0.80 0.68 0.94];   % cecum
end

function SG = segInfo(TK, C, bnd, ctr, o)
%SEGINFO Cuts on this video's centerline, orientation, position on the anatomical axis, tip segment.
SG = struct('has', ~isempty(C.cut_px), 'reversed', false, 'orientTxt', '', 'fitTxt', '', ...
    'src', C.src, 'frac', TK.frac, 'edges', [], 'lab', [], 'ctrS', [], 'ctrLab', [], 'bnd', bnd);
if ~SG.has
    SG.reversed = strcmpi(TK.role, 'R');
    if SG.reversed
        SG.orientTxt = 'no cuts: R video assumed reversed';
        SG.frac = 1 - TK.frac;
    end
    return;
end
if isempty(ctr)
    f = C.frac(:)';
    SG.reversed = strcmpi(TK.role, 'R');
    SG.orientTxt = 'no centerline file: reference cut fractions used, R video assumed reversed';
    SG.fitTxt = 'not fitted';
else
    [pts, SG.fitTxt] = transferCuts(C, bnd, ctr);
    c = resamplePolyline(double(ctr), 400);
    f = zeros(1, size(pts, 1));
    for k = 1:numel(f), f(k) = projectToPolyline(c, pts(k, :)); end
    SG.reversed = f(end) < f(1);
    if SG.reversed
        c = flipud(c); f = 1 - f;
        SG.orientTxt = 'H at the cecum end: tip_frac flipped';
    else
        SG.orientTxt = 'H at the anus end';
    end
    if any(diff(f) < 0), SG.fitTxt = [SG.fitTxt '   CUTS OUT OF ORDER - check']; end
    N = size(c, 1);
    SG.ctrS = c;
    f = min(max(f, 0), 1);
    SG.edges = [0, cummax(f), 1];
    SG.ctrLab = segOf((0:N - 1)' / (N - 1), SG.edges);
end
if isempty(SG.edges), SG.edges = [0, cummax(min(max(f, 0), 1)), 1]; end
if SG.reversed, SG.frac = 1 - TK.frac; end

% segment of the tip: its position against the cuts, furthest point reached so far
w = max(1, round(o.SegSmooth / median(diff(TK.t), 'omitnan')));
p = movmedian(SG.frac, w, 'omitnan');
p = fillmissing(fillmissing(p, 'previous'), 'next');
m = max(3, round(0.1 * numel(p)));
if median(p(end - m + 1:end)) >= median(p(1:m)), env = cummax(p); else, env = cummin(p); end
SG.lab = segOf(env, SG.edges);
end

function lab = segOf(p, edges)
%SEGOF Segment index (1..8) of positions p (fractions) given the 9 boundaries.
lab = 1 + sum(p(:) >= edges(2:end - 1), 2);
lab = min(lab, numel(edges) - 1);
end

function [s, e] = runs(lab)
d = [true; diff(lab(:)) ~= 0];
s = find(d);
e = [s(2:end) - 1; numel(lab)];
end

function bands = segmentBands(t, lab, tLo, tHi)
bands = struct('k', {}, 't1', {}, 't2', {});
if isempty(lab), return; end
[s, e] = runs(lab);
for j = 1:numel(s)
    t1 = t(s(j));
    if j < numel(s), t2 = t(s(j + 1)); else, t2 = t(e(j)); end
    t1 = max(t1, tLo); t2 = min(t2, tHi);
    if t2 > t1 && isfinite(lab(s(j)))
        bands(end + 1) = struct('k', lab(s(j)), 't1', t1, 't2', t2); %#ok<AGROW>
    end
end
end

function [lo, hi, used] = overlapWindow(spans)
%OVERLAPWINDOW Intersection of time spans {[t0 t1], ...}, starting from the first (the video track).
%   A span that does not overlap the current window is skipped (used = false) instead of emptying it.
lo = spans{1}(1); hi = spans{1}(2);
used = true(1, 3);
used(numel(spans) + 1:end) = false;
for k = 2:numel(spans)
    a = max(lo, spans{k}(1)); b = min(hi, spans{k}(2));
    if b > a
        lo = a; hi = b;
    else
        used(k) = false;
    end
end
end

function setYRange(ax, y, headTop)
y = y(isfinite(y));
if isempty(y), return; end
lo = min(y); hi = max(y);
if hi <= lo, hi = lo + 1; end
pad = 0.05 * (hi - lo);
ylim(ax, [lo - pad, hi + pad + headTop * (hi - lo)]);
end

function drawTimeBands(ax, bands, cols)
yl = ylim(ax);
ylim(ax, yl);
hold(ax, 'on');
h = gobjects(0);
for b = 1:numel(bands)
    h(end + 1) = patch(ax, [bands(b).t1 bands(b).t2 bands(b).t2 bands(b).t1], ...
        yl([1 1 2 2]), cols(bands(b).k, :), 'EdgeColor', 'none', 'HandleVisibility', 'off'); %#ok<AGROW>
end
if ~isempty(h), uistack(h, 'bottom'); end
end

function labelTimeBands(ax, bands, short, fs)
%LABELTIMEBANDS Segment names inside the top of the panel. Each name goes in the first row (of 3) where it
%   does not overlap the previous name of that row, using the real text width.
yl = ylim(ax); xl = xlim(ax);
rowY = yl(2) - (0.03 + 0.11 * (0:2)) * diff(yl);
rowRight = -inf(1, 3);
gap = 0.01 * diff(xl);
for b = 1:numel(bands)
    xc = (bands(b).t1 + bands(b).t2) / 2;
    h = text(ax, xc, rowY(1), short{bands(b).k}, 'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'top', 'FontSize', fs, 'Color', 'k', 'Clipping', 'on', 'Units', 'data');
    e = get(h, 'Extent');                     % [x y w h] in data units
    left = xc - e(3) / 2; right = xc + e(3) / 2;
    r = find(left > rowRight + gap, 1);
    if isempty(r), [~, r] = min(rowRight); end
    h.Position(2) = rowY(r);
    rowRight(r) = right;
end
end

function C = cutsFor(csv, globalFile)
%CUTSFOR Cuts of this video ('<csv>_cuts.json') or the global file, with the reference shape.
C = struct('cut_px', [], 'frac', [], 'refB', [], 'refC', [], 'src', 'no segment cuts');
f = localCutsPath(csv);
if ~isfile(f), f = globalFile; end
if ~isfile(f), return; end
d = jsondecode(fileread(f));
C.cut_px = reshape(double(d.cut_px), [], 2);
C.frac = double(d.frac_anatomical(:))';
C.refB = reshape(double(d.ref_boundary), [], 2);
C.refC = reshape(double(d.ref_centerline), [], 2);
[~, nm, ext] = fileparts(f);
C.src = sprintf('cuts: %s%s (set on %s)', nm, ext, d.source);
end

function f = localCutsPath(csv)
[folder, base] = fileparts(csv);
f = fullfile(folder, [base '_cuts.json']);
end

function [pts, txt] = transferCuts(C, bnd, ctr)
%TRANSFERCUTS Move the reference cut points onto this video (similarity fit + ICP on outline / centerline).
A = resamplePolyline(C.refC, 200);
B = resamplePolyline(double(ctr), 200);
[T1, e1] = similarity(A, B);
[T2, e2] = similarity(A, flipud(B));
if e2 < e1, T = T2; B = flipud(B); else, T = T1; end
err = min(e1, e2);
if ~isempty(C.refB) && ~isempty(bnd)
    P = densify(C.refB);
    Q = densify(double(bnd));
    for it = 1:60
        Pm = applyT(T, P);
        [~, j] = min(pdist2local(Pm, Q), [], 2);             % outline: nearest points
        [~, jc] = min(pdist2local(applyT(T, A), B), [], 2);  % centerline: nearest points too
        Tn = similarity([P; A], [Q(j, :); B(jc, :)]);
        moved = max(vecnorm(applyT(Tn, P) - Pm, 2, 2));
        T = Tn;
        if moved < 0.05, break; end
    end
    err = sqrt(mean(min(pdist2local(applyT(T, P), Q), [], 2) .^ 2));
end
pts = applyT(T, C.cut_px);
txt = sprintf('cuts fitted to this video: scale %.3f, rot %.1f deg, rms %.1f px', ...
    T.s, atan2d(T.R(2, 1), T.R(1, 1)), err);
end

function [T, err] = similarity(A, B)
%SIMILARITY Least-squares x -> s*R*x + t mapping rows of A onto rows of B (no reflection).
muA = mean(A, 1); muB = mean(B, 1);
A0 = A - muA; B0 = B - muB;
[U, Sg, V] = svd(A0' * B0);
D = diag([1, sign(det(V * U'))]);
R = V * D * U';
s = trace(Sg * D) / sum(A0(:) .^ 2);
T = struct('s', s, 'R', R, 't', muB - s * muA * R');
err = sqrt(mean(sum((applyT(T, A) - B) .^ 2, 2)));
end

function X = applyT(T, X)
X = T.s * X * T.R' + T.t;
end

function q = resamplePolyline(P, n)
s = [0; cumsum(vecnorm(diff(P), 2, 2))];
[s, u] = unique(s);
P = P(u, :);
q = interp1(s, P, linspace(0, s(end), n)');
end

function q = densify(xy)
P = [xy; xy(1, :)];
L = sum(vecnorm(diff(P), 2, 2));
q = resamplePolyline(P, max(50, ceil(L / 3)));
end

function D = pdist2local(A, B)
D = sqrt(max(sum(A .^ 2, 2) + sum(B .^ 2, 2)' - 2 * (A * B'), 0));
end

function [B, C] = firstCurves(jsonl)
%FIRSTCURVES Boundary and centerline of the first tracked frame (original pixels); [] when missing.
B = []; C = [];
if isempty(jsonl) || ~isfile(jsonl), return; end
info = dir(jsonl);
[~, nm] = fileparts(jsonl);
cache = fullfile(tempdir, sprintf('fv2_%s_%d.mat', matlab.lang.makeValidName(nm), info.bytes));
if isfile(cache)       % cache written by force_viewer_v2 / v3
    m = matfile(cache);
    B = double(m.B(:, :, 1)); C = double(m.C(:, :, 1));
    return;
end
src = jsonl;
if endsWith(jsonl, '.gz', 'IgnoreCase', true)
    tmp = tempname;
    mkdir(tmp);
    rmTmp = onCleanup(@() removeTemp(tmp)); %#ok<NASGU>
    out = gunzip(jsonl, tmp);
    src = out{1};
end
fid = fopen(src, 'r');
l = fgetl(fid);
fclose(fid);
d = jsondecode(l);
B = double(d.boundary); C = double(d.centerline);
end

function [f, q] = projectToPolyline(P, p)
%PROJECTTOPOLYLINE Nearest point q on polyline P to p, and its arc-length fraction f.
a = P(1:end - 1, :); b = P(2:end, :);
ab = b - a;
L2 = max(sum(ab .^ 2, 2), eps);
t = min(max(sum((p - a) .* ab, 2) ./ L2, 0), 1);
Q = a + t .* ab;
[~, i] = min(sum((Q - p) .^ 2, 2));
q = Q(i, :);
segL = sqrt(L2);
s = [0; cumsum(segL)];
f = (s(i) + t(i) * segL(i)) / s(end);
end

function D = loadTest(folder, rootDir)
fF = dir(fullfile(folder, 'Force_data_*.mat'));
fP = dir(fullfile(folder, 'Pressure_data_*.mat'));
fr = struct('name', {}, 'T', {}, 'F', {}, 'tEnd', {}, 'tStart', {}, 'ts', {}, 'role', {});
for i = 1:numel(fF)
    S = load(fullfile(folder, fF(i).name), 'dataTable');
    tb = S.dataTable;
    fr(i).name = fF(i).name;
    fr(i).T = tb.Time(:);
    fr(i).F = [tb.Fx(:) tb.Fy(:) tb.Fz(:)];
    fr(i).tEnd = stampOf(fF(i).name);
    fr(i).tStart = fr(i).tEnd - seconds(fr(i).T(end) - fr(i).T(1));
end
if isempty(fr), error('no Force_data_*.mat in %s', folder); end
[~, o] = sort([fr.tEnd]);
fr = fr(o);

p = [];
if ~isempty(fP)
    [~, o] = sort({fP.name});
    fP = fP(o);
    S = load(fullfile(folder, fP(1).name));
    p.t = S.time_log(:);
    p.P1 = S.P1_log(:);
    p.P1d = getf(S, 'P1_des_log', numel(p.t));
    p.tEnd = stampOf(fP(1).name);
    p.tStart = p.tEnd - seconds(p.t(end) - p.t(1));
end

starts = [fr.tStart];
if ~isempty(p), starts = [starts p.tStart]; end
t0 = min(starts);
n = numel(fr);
for k = 1:n
    fr(k).ts = seconds(fr(k).tStart - t0);
    if n >= 2 && k == n, fr(k).role = 'retraction'; else, fr(k).role = 'go'; end
end
if ~isempty(p), p.ts = seconds(p.tStart - t0); end
D = struct('folder', folder, 't0', t0, 'force', fr, 'press', p);
D.label = strrep(erase(folder, [rootDir filesep]), filesep, ' / ');
end

function TK = loadTrack(rec, D, videoDir, corrDir)
%LOADTRACK Track on test time: corrected copy if saved by force_viewer_v3, else automatic placement.
tb = readtable(rec.csv);
[~, base] = fileparts(rec.csv);
TK.name = base(1:end - 6);
TK.role = upper(rec.role);
n = numel(D.force);
if strcmp(TK.role, 'R') && n >= 1
    anchor = D.force(n).ts;
    TK.forceIdx = n;
else
    if ~isempty(D.press), anchor = D.press.ts; else, anchor = D.force(1).ts; end
    TK.forceIdx = find(strcmp({D.force.role}, 'go'));
end
out = correctedPath(rec.csv, videoDir, corrDir);
if csvIsSynced(out)
    tb = readtable(out);
    TK.t = tb.time_s;
    TK.sync = 'synced (Corrected_video)';
elseif ismember('video_time_s', tb.Properties.VariableNames)
    TK.t = tb.time_s;
    TK.sync = 'synced';
else
    TK.t = tb.time_s + anchor;
    TK.sync = 'NOT synced (automatic placement, offset 0)';
end
TK.frac = tb.tip_frac;
TK.tip = [tb.tip_x tb.tip_y];
TK.frame = tb.frame;
end

function savePng(fig, file, res)
%SAVEPNG exportgraphics to a temp file, then move it in place. If the target is locked (open in an
%   image viewer), the figure goes to '<name>_new.png' instead of being lost.
tmp = [tempname '.png'];
exportgraphics(fig, tmp, 'Resolution', res);
[ok, msg] = movefile(tmp, file, 'f');
if ~ok
    [p, n] = fileparts(file);
    alt = fullfile(p, [n '_new.png']);
    [ok2, msg2] = movefile(tmp, alt, 'f');
    if ok2
        fprintf(2, '   %s is locked (open in another program?): saved as %s\n', [n '.png'], [n '_new.png']);
    else
        error('cannot write %s (%s; %s)', file, msg, msg2);
    end
end
end

function b = trackBase(csv)
[~, b] = fileparts(csv);
b = b(1:end - 6);                 % drop '_track'
end

function REC = buildRecordings(rootDir, videoDir, outDir)
files = dir(fullfile(rootDir, '**', '*_data_*.mat'));
REC = struct('folder', {}, 'label', {}, 'csv', {}, 'role', {}, 'synced', {});
if isempty(files), return; end
folders = unique({files.folder});
labs = erase(folders, [rootDir filesep]);
grp = cell(size(labs)); num = zeros(size(labs));
for i = 1:numel(labs)
    parts = strsplit(labs{i}, filesep);
    grp{i} = lower(strtrim(parts{1}));
    n = str2double(regexp(parts{end}, '\d+', 'match', 'once'));
    if isnan(n), n = 0; end
    num(i) = n;
end
key = cellfun(@(a, b) sprintf('%s|%05d', a, b), grp, num2cell(num), 'UniformOutput', false);
[~, ord] = sort(key);
folders = folders(ord); labs = labs(ord); grp = grp(ord); num = num(ord);

tracks = struct('csv', {}, 'name', {}, 'folder', {}, 'role', {});
if ~isempty(videoDir)
    tc = dir(fullfile(videoDir, '**', '*_track.csv'));
    for i = 1:numel(tc)
        [~, base] = fileparts(tc(i).name);
        vname = base(1:end - 6);
        tok = parseVideoName(vname);
        fi = [];
        if ~isempty(tok)
            fi = find(sizeMatches(grp, tok{1}) & num == str2double(tok{2}), 1);
        end
        if isempty(fi)
            fprintf(2, 'image_output: no test folder for track "%s"\n', tc(i).name);
            continue;
        end
        tracks(end + 1) = struct('csv', fullfile(tc(i).folder, tc(i).name), 'name', vname, ...
            'folder', folders{fi}, 'role', tok{3}); %#ok<AGROW>
    end
end

for i = 1:numel(folders)
    lab = strrep(labs{i}, filesep, ' / ');
    k = find(strcmp({tracks.folder}, folders{i}));
    if isempty(k)
        REC(end + 1) = struct('folder', folders{i}, 'label', sprintf('%s   —   (no video track)', lab), ...
            'csv', '', 'role', '', 'synced', false); %#ok<AGROW>
        continue;
    end
    [~, o] = sort(cellfun(@(r, n) sprintf('%d|%s', r == 'R', n), {tracks(k).role}, {tracks(k).name}, ...
        'UniformOutput', false));
    for j = k(o)
        tr = tracks(j);
        if tr.role == 'R', rn = 'retraction'; else, rn = 'go'; end
        syn = csvIsSynced(correctedPath(tr.csv, videoDir, outDir)) || csvIsSynced(tr.csv);
        lb = sprintf('%s   —   %s  %s   (%s)', lab, tr.role, rn, strtrim(tr.name));
        if syn, lb = [lb '   [synced]']; end %#ok<AGROW>
        REC(end + 1) = struct('folder', folders{i}, 'label', lb, 'csv', tr.csv, ...
            'role', tr.role, 'synced', syn); %#ok<AGROW>
    end
end
end

function tok = parseVideoName(vname)
tok = regexp(vname, '(?<![A-Za-z])(Mo|MO|mo|L|M|S)\s*(\d+)\s*([GRgr])(?![A-Za-z])', 'tokens', 'once');
if ~isempty(tok), tok{3} = upper(tok{3}); end
end

function tf = sizeMatches(grp, code)
switch lower(code)
    case 'mo', tf = strcmp(grp, 'mo') | startsWith(grp, 'mo ');
    case 'l',  tf = startsWith(grp, 'large');
    case 'm',  tf = startsWith(grp, 'med');
    case 's',  tf = startsWith(grp, 'small');
    otherwise, tf = false(size(grp));
end
end

function out = correctedPath(csv, videoDir, outDir)
[folder, base, ext] = fileparts(csv);
rel = '';
if ~isempty(videoDir) && startsWith(lower(folder), lower(videoDir))
    rel = regexprep(folder(numel(videoDir) + 1:end), '^[\\/]+', '');
end
out = fullfile(outDir, rel, [base ext]);
end

function tf = csvIsSynced(csv)
tf = false;
fid = fopen(csv, 'r');
if fid < 0, return; end
h = fgetl(fid);
fclose(fid);
tf = ischar(h) && contains(h, 'video_time_s');
end

function p = guessTrackFiles(csv)
[folder, base] = fileparts(csv);
vbase = base(1:end - 6);
p.csv = csv;
p.curves = existing(fullfile(folder, [base '_curves.jsonl.gz']));
if isempty(p.curves), p.curves = existing(fullfile(folder, [base '_curves.jsonl'])); end
p.video = '';
for ext = {'.mp4', '.MP4', '.avi', '.mov', '.MOV'}
    p.video = existing(fullfile(folder, [vbase ext{1}]));
    if ~isempty(p.video), return; end
end
squash = @(s) lower(regexprep(strtrim(s), '\s+', ' '));
v = [dir(fullfile(folder, '*.mp4')); dir(fullfile(folder, '*.avi')); dir(fullfile(folder, '*.mov'))];
for i = 1:numel(v)
    [~, nm] = fileparts(v(i).name);
    if strcmp(squash(nm), squash(vbase))
        p.video = fullfile(folder, v(i).name);
        return;
    end
end
end

function removeTemp(d)
if isfolder(d)
    [~, ~] = rmdir(d, 's');
end
end

function f = existing(f)
if ~isfile(f), f = ''; end
end

function d = canonical(d)
d = dir(d);
d = d(1).folder;
end

function dt = stampOf(name)
tok = regexp(name, '(\d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2})', 'tokens', 'once');
dt = datetime(tok{1}, 'InputFormat', 'yyyy_MM_dd_HH_mm_ss');
end

function v = getf(S, field, n)
if isfield(S, field), v = S.(field)(:); else, v = nan(n, 1); end
end
