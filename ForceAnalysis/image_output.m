function S = image_output(varargin)
%IMAGE_OUTPUT Paper figures: |F|, P1 and tip position on one test-time axis, with colon segments,
%   plus a colon silhouette per recording to check the segmentation.
%
%   image_output()                       every recording that has a video track
%   image_output('Recordings', 'pick')   choose from a list
%   image_output('Recordings', 'L 01')   recordings whose label contains this text
%   image_output('Mark', true)           set / edit the segment cuts first
%
%
%   All settings are in the SETTINGS block right below; edit there and run  image_output.
%   How it works: see the comment block after SETTINGS.


%% ======================= SETTINGS - edit here, then just run  image_output =======================
% (a name-value argument, e.g. image_output('FontSize', 12), still overrides a value for one run)
here = fileparts(mfilename('fullpath'));
S0 = struct();
% ---- what to export
S0.Recordings     = 'all';      % 'all' | 'pick' (list dialog) | text in the label, e.g. 'L 01' | indices
S0.Silhouette     = true;       % also export <recording>_colon.png (slower; false = only the curve figures)
S0.Reference      = true;       % also export colon_reference.png: the reference video's colon with the segments (for the paper)
S0.Show           = false;      % keep the figures open on screen
S0.Mark           = false;      % set / edit the segment cuts first
% ---- figure look
S0.FigSize        = [8.5 11];   % [width height] in cm; three side by side fit on a page
S0.FontSize       = 10;         % pt
S0.FontName       = 'Calibri';
S0.ShowInfo       = false;      % small info lines under the title (video, sync, cuts, direction)
S0.ShowP1des      = false;      % also draw P1 desired
S0.PressureLabel  = 'P (kPa)';       % y label of the pressure panel
S0.FullLengthAxis = true;       % position panel always 0 .. ColonLength
S0.TileSpacing    = 'none';    % gap between the three panels: 'none' | 'tight' | 'compact' | 'loose'
S0.Padding        = 'tight';    % margin around the whole figure: 'tight' | 'compact' | 'loose'
% ---- data
S0.ColonLength    = 1.35;       % m
S0.SegSmooth      = 1;          % s, moving median of the position before finding the segments
S0.ZeroForce      = false;      % subtract the mean of the first 0.5 s of each force file
S0.ForceSmooth    = 1;          % moving mean of the force, samples (1 = none)
% ---- folders
S0.Root           = fullfile(here, '..', 'Forcedata');
S0.VideoDir       = fullfile(here, '..', 'compressedvideo');
S0.CorrectedDir   = fullfile(here, '..', 'Corrected_video');
S0.FigDir         = fullfile(here, '..', 'Figures');
S0.Cuts           = fullfile(here, 'colon_cuts.json');
%% ==================================================================================================

%% ---------------------------------------------------------------- how it works
%   Figure (<recording>.png): three panels sharing the x axis (test time, s)
%     1. |F| = sqrt(Fx^2 + Fy^2 + Fz^2)  (N)
%     2. Pressure P1
%     3. Tip position along the colon (m), 0 = anus, ColonLength = cecum
%   The x range is the overlap of video track, force and pressure: the shortest
%   record decides each end (start and end may come from different records).
%   A record that does not overlap at all (e.g. the pressure of a retraction
%   video: the pressure record covers the go phase only) is left out and its
%   panel says so, instead of the figure being skipped.
%   The same segment bands are drawn in all three panels; panel 3 also shows
%   the cut positions as dashed lines.
%
%   Silhouette (<recording>_colon.png): first tracked video frame with the
%   colon cut into its segments, the cut lines, the centerline (anus and cecum
%   ends marked) and the tip path, to check the segmentation of that video.
%
%   Colon segments
%     The colon is cut by lines perpendicular to the centerline. You set the
%     7 cuts once, on one video frame, by clicking on the centerline:
%       rectum|sigmoid, sigmoid|descending, descending|splenic flexure,
%       splenic flexure|transverse, transverse|hepatic flexure,
%       hepatic flexure|ascending, ascending|cecum
%     Each click is projected onto the centerline and its cut line (clipped
%     to the colon outline) is drawn at once. Saved in colon_cuts.json (here)
%     with that frame's colon outline and centerline.
%     - Other videos: the outline + centerline of the reference frame are
%       fitted to the video's first frame (shift, rotation, scale; both
%       centerline directions tried; refined by ICP), the cut points are
%       moved with that fit and projected onto the video's own centerline.
%       The silhouette shows the fit and its rms error (px). A
%       '<video>_track_cuts.json' ("only this video") overrides the global file.
%     - Direction: if the cuts come out in decreasing order along the video's
%       centerline (H at the cecum, as in the retraction videos), tip_frac is
%       flipped (1 - tip_frac), so position is always 0 at the anus.
%     - Segment of the tip = its position against the cuts, using the
%       furthest point reached so far (running max of the position after a
%       SegSmooth-s moving median; running min when the tip moves back). So
%       every segment is entered once, in order. The silhouette colours each
%       pixel of the colon by its nearest centerline point, which is the same
%       rule drawn as an area.
%
%   Time alignment: as force_viewer_v3 (corrected CSV in Corrected_video if
%   saved, else automatic placement with offset 0 and the figure says so).
%
%   Outputs in FigDir (default ../Figures): the PNGs and segment_summary.csv
%   (one row per recording and segment: entry / exit time, duration, mean and
%   max |F|, mean P1).

ip = inputParser;
for f = fieldnames(S0)'
    ip.addParameter(f{1}, S0.(f{1}));
end
ip.parse(varargin{:});
o = ip.Results;

rootDir = canonical(o.Root);
videoDir = '';
if isfolder(o.VideoDir), videoDir = canonical(o.VideoDir); end
corrDir = o.CorrectedDir;
if isfolder(corrDir), corrDir = canonical(corrDir); end
if ~isfolder(o.FigDir), mkdir(o.FigDir); end
figDir = canonical(o.FigDir);

REC = buildRecordings(rootDir, videoDir, corrDir);
REC = REC(~cellfun(@isempty, {REC.csv}));
if isempty(REC)
    error('image_output:noTracks', 'No recordings with a video track (*_track.csv under %s).', videoDir);
end

% ---- segment cuts
if ~o.Mark && ~isfile(o.Cuts)
    a = questdlg(sprintf(['No segment cuts yet (%s).\n\nSet them now on a video frame ' ...
        '(7 clicks on the centerline, done once)?\nOtherwise the figures have no segments.'], ...
        o.Cuts), 'Colon segments', 'Set now', 'No segments', 'Set now');
    o.Mark = strcmp(a, 'Set now');
end
if o.Mark
    markCuts(REC, o.Cuts);
end

if o.Reference
    try
        makeReference(REC, o, figDir);
    catch err
        fprintf(2, 'colon_reference.png not made: %s\n', err.message);
    end
end

REC = chooseRecordings(REC, o.Recordings);
if isempty(REC), S = []; return; end

% ---- one figure (+ silhouette) per recording
rows = {};
cacheFolder = ''; D = [];
for r = 1:numel(REC)
    rec = REC(r);
    fprintf('[%d/%d] %s\n', r, numel(REC), rec.label);
    try
        if ~strcmp(cacheFolder, rec.folder)
            D = loadTest(rec.folder, rootDir);
            cacheFolder = rec.folder;
        end
        files = guessTrackFiles(rec.csv);
        TK = loadTrack(rec, D, videoDir, corrDir);
        C = cutsFor(files.csv, o.Cuts);
        [cb, cc] = firstCurves(files.curves);
        SG = segInfo(TK, C, cb, cc, o);
        base = fileName(D.label, TK);

        [fig, st] = makeFigure(D, TK, SG, o);
        savePng(fig, fullfile(figDir, [base '.png']), 300);
        if ~o.Show, close(fig); end

        if o.Silhouette
            fig = makeSilhouette(files, TK, SG, sprintf('%s  —  %s', D.label, rec.label), o);
            savePng(fig, fullfile(figDir, [base '_colon.png']), 200);
            if ~o.Show, close(fig); end
        end

        for k = 1:numel(st)
            rows(end + 1, :) = {D.label, TK.role, TK.name, TK.sync, st(k).name, st(k).t1, st(k).t2, ...
                st(k).t2 - st(k).t1, st(k).Fmean, st(k).Fmax, st(k).Pmean}; %#ok<AGROW>
        end
    catch err
        where = '';
        if ~isempty(err.stack), where = sprintf(' (%s, line %d)', err.stack(1).name, err.stack(1).line); end
        fprintf(2, '   skipped: %s%s\n', err.message, where);
    end
end

S = cell2table(rows, 'VariableNames', {'test', 'role', 'video', 'sync', 'segment', ...
    't_enter_s', 't_exit_s', 'duration_s', 'F_mean_N', 'F_max_N', 'P1_mean'});
if ~isempty(rows)
    writetable(S, fullfile(figDir, 'segment_summary.csv'));
end
fprintf('Figures and segment_summary.csv in %s\n', figDir);
end

%% ======================= segments =======================
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

function c = cutNames()
c = {'Rectum | Sigmoid', 'Sigmoid | Descending', 'Descending | Splenic flexure (start of the bend)', ...
    'Splenic flexure | Transverse (end of the bend)', 'Transverse | Hepatic flexure (start of the bend)', ...
    'Hepatic flexure | Ascending (end of the bend)', 'Ascending | Cecum'};
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

%% ======================= figure =======================
function makeReference(REC, o, figDir)
%MAKEREFERENCE colon_reference.png: frame of the video the cuts were set on, colon cut into its segments,
%   white centerline, start point (anus) and end point (cecum). No tip path, no title (for the paper).
if ~isfile(o.Cuts), error('no %s yet', o.Cuts); end
d = jsondecode(fileread(o.Cuts));
C = struct('cut_px', reshape(double(d.cut_px), [], 2), 'refB', reshape(double(d.ref_boundary), [], 2), ...
    'refC', reshape(double(d.ref_centerline), [], 2));
k = find(arrayfun(@(r) ~isempty(r.csv) && strcmp(squashName(trackBase(r.csv)), squashName(d.source)), REC), 1);
if isempty(k), error('reference video "%s" not found', d.source); end
files = guessTrackFiles(REC(k).csv);
[names, short, cols] = segNames();

% the reference shape itself, cuts as fractions along its centerline (anus -> cecum)
c = resamplePolyline(C.refC, 400);
bnd = C.refB;
fr = zeros(1, size(C.cut_px, 1));
for j = 1:numel(fr), fr(j) = projectToPolyline(c, C.cut_px(j, :)); end
if fr(end) < fr(1), c = flipud(c); fr = 1 - fr; end
edges = [0, cummax(min(max(fr, 0), 1)), 1];

fig = figure('Color', 'w', 'Units', 'centimeters', 'Position', [2 2 17 9.5], 'Visible', onOff(o.Show), ...
    'DefaultAxesFontName', o.FontName, 'DefaultTextFontName', o.FontName, 'DefaultLegendFontName', o.FontName);
ax = axes(fig);
hold(ax, 'on');
im = [];
if ~isempty(files.video)
    vr = VideoReader(files.video);
    vr.CurrentTime = min(double(d.frame) / vr.FrameRate, vr.Duration - 1 / vr.FrameRate);
    im = readFrame(vr);
    image(ax, im);
end
drawSegmentArea(ax, bnd, c, edges, cols, 0.45);
for j = 2:numel(edges) - 1
    if edges(j) > edges(j - 1) || j == 2
        drawCut(ax, bnd, c, edges(j), '');
    end
end
plot(ax, bnd([1:end 1], 1), bnd([1:end 1], 2), '-', 'Color', [0.95 0.80 0.20], 'LineWidth', 1);
plot(ax, c(:, 1), c(:, 2), '-', 'Color', [1 1 1 0.85], 'LineWidth', 1);
plot(ax, c(1, 1), c(1, 2), 'o', 'MarkerSize', 8, 'MarkerFaceColor', 'w', 'MarkerEdgeColor', 'k');
plot(ax, c(end, 1), c(end, 2), 's', 'MarkerSize', 8, 'MarkerFaceColor', 'w', 'MarkerEdgeColor', 'k');
axis(ax, 'image');
ax.YDir = 'reverse';
ax.XTick = []; ax.YTick = [];
if ~isempty(im), axis(ax, [0.5 size(im, 2) + 0.5 0.5 size(im, 1) + 0.5]); end
% segment names: drawn after the centerline so they sit on top of it; black, no box
for j = 1:numel(edges) - 1
    if edges(j + 1) <= edges(j), continue; end
    q = pointAt(c, (edges(j) + edges(j + 1)) / 2);
    text(ax, q(1), q(2), short{j}, 'Color', 'k', 'FontWeight', 'bold', 'FontSize', o.FontSize, ...
        'HorizontalAlignment', 'center');
end
% start / end labels outside the colon outline (white box), kept inside the image
endLabel(ax, bnd, c, 0.01, 'Start point', o.FontSize);
endLabel(ax, bnd, c, 0.99, 'End point', o.FontSize);
hl = gobjects(1, numel(names));   % legend entries only
for j = 1:numel(names)
    hl(j) = plot(ax, nan, nan, 's', 'MarkerSize', 9, 'MarkerFaceColor', cols(j, :), ...
        'MarkerEdgeColor', 'none', 'DisplayName', names{j});
end
legend(ax, hl, 'Location', 'eastoutside', 'Box', 'off', 'FontSize', o.FontSize, 'TextColor', 'k');
savePng(fig, fullfile(figDir, 'colon_reference.png'), 300);
if ~o.Show, close(fig); end
fprintf('colon_reference.png (cuts set on %s)\n', d.source);
end

function endLabel(ax, bnd, c, f, str, fs)
%ENDLABEL Label near a centerline end, just outside the colon outline on the side away from the colon centre.
[q, t] = pointAt(c, f);
L = cutLine(bnd, q, t);                       % the two outline points across the colon at f
ctr = mean(bnd, 1);
[~, j] = max(vecnorm(L - ctr, 2, 2));
n = L(j, :) - q;
n = n / max(norm(n), eps);
p = L(j, :) + 12 * n;                         % 12 px outside the outline
if abs(n(2)) >= abs(n(1))                     % mostly up / down (image y points down)
    if n(2) < 0, va = 'bottom'; else, va = 'top'; end
    ha = 'center';
else
    if n(1) < 0, ha = 'right'; else, ha = 'left'; end
    va = 'middle';
end
plot(ax, [q(1) p(1)], [q(2) p(2)], '-', 'Color', 'k', 'LineWidth', 0.8);   % thin leader line
h = text(ax, p(1), p(2), str, 'Color', 'k', 'FontWeight', 'bold', 'FontSize', fs, 'HorizontalAlignment', ha, ...
    'VerticalAlignment', va, 'BackgroundColor', [1 1 1 0.75], 'Margin', 1);
% keep the label inside the axes (image): shift it back if it sticks out
e = get(h, 'Extent');
xl = xlim(ax); yl = ylim(ax); m = 0.01 * diff(xl);
x1 = e(1); x2 = e(1) + e(3);
y1 = min(e(2), e(2) + e(4)); y2 = max(e(2), e(2) + e(4));
dx = max(0, xl(1) + m - x1) - max(0, x2 - (xl(2) - m));
dy = max(0, yl(1) + m - y1) - max(0, y2 - (yl(2) - m));
h.Position(1:2) = h.Position(1:2) + [dx dy];
end

function b = trackBase(csv)
[~, b] = fileparts(csv);
b = b(1:end - 6);                 % drop '_track'
end

function s = squashName(s)
s = lower(regexprep(strtrim(s), '\s+', ' '));
end

function [fig, st] = makeFigure(D, TK, SG, o)
[names, short, cols] = segNames();
cols = 0.55 * cols + 0.45;          % lighter for backgrounds

% ---- force (the force file(s) of this phase)
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
if hasP
    tP = D.press.t - D.press.t(1) + D.press.ts;
    P1 = D.press.P1;
    P1d = D.press.P1d;
end

tT = TK.t;
pos = SG.frac * o.ColonLength;

% ---- time window = overlap of video track, force and pressure (the shortest record decides each end).
%      A record that does not overlap the others at all (e.g. the pressure of a retraction video, which
%      covers the go phase only) is left out of the overlap and its panel says so.
isR = strcmpi(TK.role, 'R');      % retraction: no pressure panel (the pressure record covers the go phase)
spans = {[tT(1), tT(end)], [min(tF), max(tF)]};
if hasP && ~isR, spans{3} = [tP(1), tP(end)]; end
[tLo, tHi, used] = overlapWindow(spans);
hasF = used(2);
hasPw = hasP && ~isR && used(3);
noP = ~hasPw;                     % no pressure in this window (retraction, Mo without a pressure record,
                                  % or no overlap): the pressure panel is left out
% the figure starts at 0 s: shift every record by the start of the window
t0 = tLo;
tF = tF - t0; tT = tT - t0;
if hasP, tP = tP - t0; end
tLo = 0; tHi = tHi - t0;
inF = tF >= tLo & tF <= tHi;
bands = segmentBands(tT, SG.lab, tLo, tHi);

nPan = 3 - noP;
figSize = o.FigSize;
if noP, figSize(2) = o.FigSize(2) * 0.7; end   % same panel height with one panel less
fig = figure('Color', 'w', 'Units', 'centimeters', 'Position', [2 2 figSize], 'Visible', onOff(o.Show), ...
    'DefaultAxesFontName', o.FontName, 'DefaultTextFontName', o.FontName, ...
    'DefaultAxesFontSize', o.FontSize, 'DefaultLegendFontName', o.FontName);
tl = tiledlayout(fig, nPan, 1, 'TileSpacing', o.TileSpacing, 'Padding', o.Padding);
ax = gobjects(1, 3);

ax(1) = nexttile(tl);
plot(ax(1), tF, Fm, '-', 'Color', [0.58 0.40 0.74], 'LineWidth', 1.1);
ylabel(ax(1), '|F| (N)');
if hasF
    setYRange(ax(1), Fm(inF), 0.32);   % headroom for the segment names
else
    ylim(ax(1), [0 1]);
    text(ax(1), 0.5, 0.5, 'force record does not overlap this video', 'Units', 'normalized', ...
        'HorizontalAlignment', 'center', 'Color', 'k', 'FontSize', o.FontSize - 1);
end

if ~noP
ax(2) = nexttile(tl);
if hasPw
    plot(ax(2), tP, P1, '-', 'Color', [0.49 0.18 0.56], 'LineWidth', 1.1, 'DisplayName', 'P1');
    yy = P1(tP >= tLo & tP <= tHi);
    if o.ShowP1des
        hold(ax(2), 'on');
        plot(ax(2), tP, P1d, '--', 'Color', [0.93 0.69 0.13], 'LineWidth', 1.0, 'DisplayName', 'P1 des');
        legend(ax(2), 'Location', 'northwest', 'Box', 'off');
        yy = [yy; P1d(tP >= tLo & tP <= tHi)];
    end
    setYRange(ax(2), yy, 0.08);
else
    ylim(ax(2), [0 1]);
    if hasP, msg = 'pressure record does not overlap this video'; else, msg = 'no pressure record'; end
    text(ax(2), 0.5, 0.5, msg, 'Units', 'normalized', ...
        'HorizontalAlignment', 'center', 'Color', 'k', 'FontSize', o.FontSize - 1);
end
ylabel(ax(2), o.PressureLabel);
end

ax(3) = nexttile(tl);
plot(ax(3), tT, pos, '-', 'Color', [0.10 0.50 0.55], 'LineWidth', 1.4);
ylabel(ax(3), 'Tip position (m)');
xlabel(ax(3), 'Test time (s)');
if o.FullLengthAxis
    ylim(ax(3), [0 o.ColonLength]);
else
    setYRange(ax(3), pos(tT >= tLo & tT <= tHi), 0.05);
end

if noP, ax = ax([1 3]); end       % the panels that exist, top to bottom
linkaxes(ax, 'x');
xlim(ax(1), [tLo tHi]);
for a = ax
    set(a, 'Box', 'on', 'Layer', 'top', 'FontSize', o.FontSize, 'FontName', o.FontName, 'XColor', 'k', ...
        'YColor', 'k', 'TickDir', 'out', 'XGrid', 'on', 'YGrid', 'on', ...
        'GridAlpha', 0.12);
end
set(ax(1:end - 1), 'XTickLabel', []);

if SG.has
    for a = ax, drawTimeBands(a, bands, cols); end   % same bands in all panels
    labelTimeBands(ax(1), bands, short, o.FontSize - 2);
    for a = ax
        for b = 2:numel(bands)
            xline(a, bands(b).t1, ':', 'Color', [0.35 0.35 0.35], 'LineWidth', 0.6, 'HandleVisibility', 'off');
        end
    end
    if ~isempty(SG.edges)
        drawLengthBands(ax(end), SG.edges * o.ColonLength, short, o.FontSize - 1);
    end
end

title(tl, sprintf('%s  —  %s', D.label, roleName(TK.role)), ...
    'Interpreter', 'none', 'FontSize', o.FontSize + 1, 'FontWeight', 'bold', 'FontName', o.FontName, 'Color', 'k');
if SG.has, segTxt = SG.src; else, segTxt = 'no segment cuts'; end
if o.ShowInfo
    subtitle(tl, {sprintf('%s   |   t = 0 at %s', strtrim(TK.name), char(string(D.t0, 'yyyy-MM-dd HH:mm:ss'))), ...
        sprintf('video: %s', TK.sync), segTxt, SG.orientTxt}, ...
        'Interpreter', 'none', 'FontSize', o.FontSize - 3, 'FontName', o.FontName, 'Color', 'k');
end

st = struct('name', {}, 't1', {}, 't2', {}, 'Fmean', {}, 'Fmax', {}, 'Pmean', {});
for b = 1:numel(bands)
    t1 = bands(b).t1; t2 = bands(b).t2;
    f = Fm(tF >= t1 & tF < t2);
    s.name = names{bands(b).k};
    s.t1 = t1 + t0; s.t2 = t2 + t0;     % segment_summary.csv stays on test time
    s.Fmean = mean(f, 'omitnan');
    s.Fmax = max([f; nan], [], 'omitnan');
    s.Pmean = nan;
    if hasPw, s.Pmean = mean(P1(tP >= t1 & tP < t2), 'omitnan'); end
    st(end + 1) = s; %#ok<AGROW>
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

function drawLengthBands(ax, edges, names, fs)
%DRAWLENGTHBANDS Segment boundaries on the position axis (thin dashed lines) and names on the right.
xl = xlim(ax); yl = ylim(ax);
for k = 2:numel(edges) - 1
    if edges(k) > edges(k - 1)
        yline(ax, edges(k), '--', 'Color', [0.45 0.45 0.45], 'LineWidth', 0.5, 'HandleVisibility', 'off');
    end
end
xlim(ax, xl); ylim(ax, yl);

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

%% ======================= silhouette =======================
function fig = makeSilhouette(files, TK, SG, ttl, o)
[names, short, cols] = segNames();
fig = figure('Color', 'w', 'Units', 'centimeters', 'Position', [2 2 19 14], 'Visible', onOff(o.Show), ...
    'DefaultAxesFontName', o.FontName, 'DefaultTextFontName', o.FontName, 'DefaultLegendFontName', o.FontName);
ax = axes(fig);
hold(ax, 'on');
im = [];
if ~isempty(files.video)
    try
        vr = VideoReader(files.video);
        vr.CurrentTime = min(TK.frame(1) / vr.FrameRate, vr.Duration - 1 / vr.FrameRate);
        im = readFrame(vr);
    catch
    end
end
if ~isempty(im)
    image(ax, im);
else
    ax.Color = [0.15 0.15 0.15];
end
bnd = SG.bnd;
c = SG.ctrS;
if ~isempty(c) && ~isempty(bnd)
    drawSegmentArea(ax, bnd, c, SG.edges, cols, 0.45);
    for k = 2:numel(SG.edges) - 1
        if SG.edges(k) > SG.edges(k - 1) || k == 2
            drawCut(ax, bnd, c, SG.edges(k), '');
        end
    end
    % segment names at the middle of each segment
    for k = 1:numel(SG.edges) - 1
        if SG.edges(k + 1) <= SG.edges(k), continue; end
        q = pointAt(c, (SG.edges(k) + SG.edges(k + 1)) / 2);
        text(ax, q(1), q(2), short{k}, 'Color', 'w', 'FontWeight', 'bold', 'FontSize', 8, ...
            'HorizontalAlignment', 'center', 'BackgroundColor', [0 0 0 0.45], 'Margin', 1);
    end
end
if ~isempty(bnd)
    plot(ax, bnd([1:end 1], 1), bnd([1:end 1], 2), '-', 'Color', [0.95 0.80 0.20], 'LineWidth', 1);
end
if ~isempty(c)
    plot(ax, c(:, 1), c(:, 2), '-', 'Color', [1 1 1 0.7], 'LineWidth', 0.8);
    plot(ax, c(1, 1), c(1, 2), 'o', 'MarkerSize', 8, 'MarkerFaceColor', 'w', 'MarkerEdgeColor', 'k');
    text(ax, c(1, 1), c(1, 2), '  anus (0 m)', 'Color', 'w', 'FontWeight', 'bold', 'FontSize', 9);
    plot(ax, c(end, 1), c(end, 2), 's', 'MarkerSize', 8, 'MarkerFaceColor', 'w', 'MarkerEdgeColor', 'k');
    text(ax, c(end, 1), c(end, 2), sprintf('  cecum (%.2f m)', o.ColonLength), 'Color', 'w', ...
        'FontWeight', 'bold', 'FontSize', 9);
end
% tip path, coloured by the segment it was assigned to
tip = TK.tip;
if ~isempty(SG.lab)
    [s, e] = runs(SG.lab);
    for j = 1:numel(s)
        ii = s(j):e(j);
        plot(ax, tip(ii, 1), tip(ii, 2), '.', 'Color', 0.55 * cols(SG.lab(s(j)), :), 'MarkerSize', 6);
    end
else
    plot(ax, tip(:, 1), tip(:, 2), 'r.', 'MarkerSize', 6);
end
ok = find(all(isfinite(tip), 2));
if ~isempty(ok)
    plot(ax, tip(ok(1), 1), tip(ok(1), 2), 'w^', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
    plot(ax, tip(ok(end), 1), tip(ok(end), 2), 'wv', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
end
axis(ax, 'image');
ax.YDir = 'reverse';
ax.XTick = []; ax.YTick = [];
if ~isempty(im), axis(ax, [0.5 size(im, 2) + 0.5 0.5 size(im, 1) + 0.5]); end
title(ax, ttl, 'Interpreter', 'none', 'FontSize', 10, 'Color', 'k');
subtitle(ax, {sprintf('frame %d   |   %s   |   %s', TK.frame(1), SG.orientTxt, SG.fitTxt), ...
    'colon cut perpendicular to the centerline; tip path dots coloured by assigned segment (green = first, red = last)'}, ...
    'Interpreter', 'none', 'FontSize', 8, 'Color', 'k');
hl = gobjects(1, numel(names));   % legend entries only
for k = 1:numel(names)
    hl(k) = plot(ax, nan, nan, 's', 'MarkerSize', 9, 'MarkerFaceColor', cols(k, :), ...
        'MarkerEdgeColor', 'none', 'DisplayName', names{k});
end
legend(ax, hl, 'Location', 'eastoutside', 'Box', 'off', 'FontSize', 9, 'TextColor', 'k');
end

function h = drawSegmentArea(ax, bnd, c, edges, cols, alpha)
%DRAWSEGMENTAREA Colour every pixel inside the colon outline by the segment of its nearest centerline point.
step = 2;
lo = floor(min(bnd, [], 1)); hi = ceil(max(bnd, [], 1));
xv = lo(1):step:hi(1); yv = lo(2):step:hi(2);
[X, Y] = meshgrid(xv, yv);
in = inpolygon(X, Y, bnd(:, 1), bnd(:, 2));
P = [X(in) Y(in)];
N = size(c, 1);
idx = zeros(size(P, 1), 1);
for i0 = 1:20000:size(P, 1)
    ii = i0:min(i0 + 19999, size(P, 1));
    [~, idx(ii)] = min(pdist2local(P(ii, :), c), [], 2);
end
lab = segOf((idx - 1) / (N - 1), edges);
L = zeros(size(X));
L(in) = lab;
rgb = ones([size(X) 3]);
for ch = 1:3
    m = ones(size(X));
    v = cols(:, ch);
    m(in) = v(lab);
    rgb(:, :, ch) = m;
end
h = image(ax, 'XData', xv([1 end]), 'YData', yv([1 end]), 'CData', rgb, 'AlphaData', alpha * (L > 0));
end

function h = drawCut(ax, bnd, c, f, lbl)
%DRAWCUT Cut line perpendicular to the centerline at fraction f, clipped to the colon outline.
[q, t] = pointAt(c, f);
L = cutLine(bnd, q, t);
h = gobjects(1, 3);
h(1) = plot(ax, L(:, 1), L(:, 2), '-', 'Color', 'k', 'LineWidth', 3.5);
h(2) = plot(ax, L(:, 1), L(:, 2), '-', 'Color', 'w', 'LineWidth', 1.8);
if ~isempty(lbl)
    h(3) = text(ax, L(2, 1), L(2, 2), ['  ' lbl], 'Color', 'w', 'FontWeight', 'bold', 'FontSize', 10, ...
        'BackgroundColor', [0 0 0 0.5], 'Margin', 1, 'Interpreter', 'none');
end
end

%% ======================= setting the cuts =======================
function markCuts(REC, globalFile)
%MARKCUTS Click the 7 segment cuts on the centerline of one video frame; save with the reference shape.
[names, ~, cols] = segNames();
cn = cutNames();
[i, ok] = listdlg('ListString', {REC.label}, 'SelectionMode', 'single', 'ListSize', [700 300], ...
    'Name', 'Colon segments', 'PromptString', 'Recording to set the cuts on (whole colon visible):');
if ~ok, return; end
files = guessTrackFiles(REC(i).csv);
tb = readtable(files.csv);
[bnd, ctr] = firstCurves(files.curves);
if isempty(ctr) || isempty(bnd)
    error('image_output:noCurves', 'No _track_curves file next to %s: the colon outline is needed.', files.csv);
end
c = resamplePolyline(ctr, 400);

f = figure('Name', 'Colon segments', 'Color', 'w', 'Units', 'normalized', 'Position', [0.03 0.05 0.9 0.85]);
ax = axes(f, 'Position', [0.01 0.02 0.98 0.9]);
hold(ax, 'on');
if ~isempty(files.video)
    vr = VideoReader(files.video);
    vr.CurrentTime = min(tb.frame(1) / vr.FrameRate, vr.Duration - 1 / vr.FrameRate);
    image(ax, readFrame(vr));
end
plot(ax, bnd([1:end 1], 1), bnd([1:end 1], 2), '-', 'Color', [0.95 0.80 0.20], 'LineWidth', 1.2);
plot(ax, c(:, 1), c(:, 2), '-', 'Color', [0 0.9 0.9], 'LineWidth', 1.2);
text(ax, c(1, 1), c(1, 2), '  H', 'Color', 'c', 'FontWeight', 'bold', 'FontSize', 12);
text(ax, c(end, 1), c(end, 2), '  T', 'Color', 'c', 'FontWeight', 'bold', 'FontSize', 12);
axis(ax, 'image'); ax.YDir = 'reverse'; ax.XTick = []; ax.YTick = [];

fr = nan(1, 7);                      % cut positions as fractions along this centerline (H -> T)
Cold = cutsFor(files.csv, globalFile);
if ~isempty(Cold.cut_px)
    a = questdlg(sprintf('Cuts exist (%s).', Cold.src), 'Colon segments', ...
        'Keep them, redo some', 'Set all new', 'Keep them, redo some');
    if startsWith(a, 'Keep')
        pts = transferCuts(Cold, bnd, ctr);
        for k = 1:7, fr(k) = projectToPolyline(c, pts(k, :)); end
    end
end
h = cell(1, 7);
k = 1;
while k <= 7
    if isfinite(fr(k))
        h{k} = drawCut(ax, bnd, c, fr(k), sprintf('%d', k));
        k = k + 1;
        continue;
    end
    [v, cmd] = clickCut(ax, c, sprintf('Cut %d/7:  %s', k, cn{k}));
    switch cmd
        case 'ok'
            fr(k) = v;
        case 'back'
            if k > 1
                k = k - 1;
                delete(h{k}(isgraphics(h{k})));
                fr(k) = nan;
            end
        case 'cancel'
            close(f); disp('Colon segments: cancelled'); return;
    end
end

hArea = [];
while true
    delete(hArea(isgraphics(hArea)));
    rev = fr(end) < fr(1);
    e = sort(fr); if rev, e = 1 - fliplr(e); end
    cc = c; if rev, cc = flipud(c); end
    hArea = [];
    if issorted(fr) || issorted(fliplr(fr))
        hArea = drawSegmentArea(ax, bnd, cc, [0 e 1], cols, 0.35);
        uistack(hArea, 'bottom');
        if ~isempty(files.video), uistack(hArea, 'up', 1); end   % just above the video frame
        msg = 'Segments OK?';
        title(ax, 'Check the segments', 'FontSize', 13);
    else
        msg = sprintf(['The cuts are not in order along the centerline (%s).\n' ...
            'Redo the ones in the wrong place.'], sprintf('%.2f ', fr));
    end
    a = questdlg(msg, 'Colon segments', 'Save', 'Redo one', 'Cancel', 'Save');
    if strcmp(a, 'Save') && (issorted(fr) || issorted(fliplr(fr))), break; end
    if strcmp(a, 'Cancel') || isempty(a), close(f); disp('Colon segments: cancelled'); return; end
    [k, ok] = listdlg('ListString', cn, 'SelectionMode', 'single', 'Name', 'Redo', ...
        'PromptString', 'Cut to redo:', 'ListSize', [350 150]);
    if ~ok, continue; end
    delete(h{k}(isgraphics(h{k})));
    v = []; cmd = 'back';
    while ~strcmp(cmd, 'ok') && ~strcmp(cmd, 'cancel')
        [v, cmd] = clickCut(ax, c, sprintf('Redo cut %d:  %s', k, cn{k}));
    end
    if strcmp(cmd, 'ok'), fr(k) = v; end
    h{k} = drawCut(ax, bnd, c, fr(k), sprintf('%d', k));
end
close(f);

a = questdlg('Use these cuts for:', 'Colon segments', 'All videos', 'Only this video', 'All videos');
if strcmp(a, 'Only this video'), file = localCutsPath(files.csv); else, file = globalFile; end
cutPx = zeros(7, 2);
for k = 1:7, cutPx(k, :) = pointAt(c, fr(k)); end
fa = fr; if fr(end) < fr(1), fa = 1 - fr; end
[~, nm] = fileparts(files.csv);
out = struct('source', nm(1:end - 6), 'frame', tb.frame(1), 'cuts', {cn}, ...
    'cut_px', round(cutPx, 2), 'frac_anatomical', round(fa(:), 4), ...
    'ref_boundary', round(bnd, 1), 'ref_centerline', round(ctr, 1), 'segments', {names});
fid = fopen(file, 'w', 'n', 'UTF-8');
fprintf(fid, '%s', jsonencode(out, 'PrettyPrint', true));
fclose(fid);
fprintf('Segment cuts saved to %s\n', file);
end

function [v, cmd] = clickCut(ax, c, what)
%CLICKCUT One click near the centerline -> fraction along it.
%   left click = place,  Backspace = back to the previous cut,  Esc = cancel
figure(ancestor(ax, 'figure'));
title(ax, sprintf('%s   —   click on the centerline (Backspace = previous cut, Esc = cancel)', what), ...
    'FontSize', 12, 'Interpreter', 'none');
v = nan;
while true
    [x, y, b] = ginput(1);
    if isempty(b), continue; end
    if b == 1
        v = projectToPolyline(c, [x y]);
        cmd = 'ok';
        return;
    elseif b == 8 || b == 127
        cmd = 'back';
        return;
    elseif b == 27
        cmd = 'cancel';
        return;
    end
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

%% ======================= geometry =======================
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

function [q, t] = pointAt(c, f)
%POINTAT Point and unit tangent at arc-length fraction f of polyline c.
s = [0; cumsum(vecnorm(diff(c), 2, 2))];
s = s / s(end);
f = min(max(f, 0), 1);
q = interp1(s, c, f);
i = find(s <= f, 1, 'last');
i = min(max(i, 1), size(c, 1) - 1);
j0 = max(1, i - 3); j1 = min(size(c, 1), i + 4);
t = c(j1, :) - c(j0, :);
t = t / max(norm(t), eps);
end

function L = cutLine(bnd, q, t)
%CUTLINE Segment through q perpendicular to t, from the colon outline on one side to the other.
n = [-t(2) t(1)];
P = [bnd; bnd(1, :)];
a = P(1:end - 1, :); d = diff(P);
cr = @(x, y) x(:, 1) .* y(:, 2) - x(:, 2) .* y(:, 1);
den = n(1) * d(:, 2) - n(2) * d(:, 1);
aq = a - q;
s = cr(aq, d) ./ den;
u = cr(aq, repmat(n, size(aq, 1), 1)) ./ den;
ok = abs(den) > eps & u >= 0 & u <= 1;
sp = min(s(ok & s > 0)); sn = max(s(ok & s < 0));
if isempty(sp), sp = 30; end
if isempty(sn), sn = -30; end
L = [q + sn * n; q + sp * n];
end

%% ======================= data =======================
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

function REC = chooseRecordings(REC, sel)
if isnumeric(sel)
    REC = REC(sel(sel >= 1 & sel <= numel(REC)));
elseif strcmpi(sel, 'pick')
    [i, ok] = listdlg('ListString', {REC.label}, 'ListSize', [700 400], 'Name', 'image_output', ...
        'PromptString', 'Recordings to export:');
    if ok, REC = REC(i); else, REC = REC([]); end
elseif ~strcmpi(sel, 'all')
    REC = REC(contains({REC.label}, sel, 'IgnoreCase', true));
    if isempty(REC), warning('image_output:noMatch', 'No recording label contains "%s".', sel); end
end
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

function s = fileName(label, TK)
s = sprintf('%s_%s', label, TK.role);
s = regexprep(s, '[\\/:*?"<>|]', '_');
s = regexprep(s, '\s*_\s*', '_');
s = regexprep(s, '\s+', ' ');
end

function s = roleName(r)
if strcmpi(r, 'R'), s = 'retraction'; else, s = 'go'; end
end

function s = onOff(tf)
if tf, s = 'on'; else, s = 'off'; end
end

%% ======================= helpers (same as force_viewer_v3) =======================
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
