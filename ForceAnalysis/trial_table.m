function T = trial_table(varargin)
%TRIAL_TABLE One row per trial (S1..S9, M, L, Mo ...): position, force, pressure and timing.
%
%   T = trial_table()     writes ../Figures/trial_table.csv and .xlsx and returns the table
%
%   Uses exactly the same loading, time alignment and colon segmentation as
%   image_output.m (cuts from colon_cuts.json, carried over to every video).
%
%   Columns
%     Trial                 S1..S9, M1, L1, Mo1 ... (size group + test number)
%     MaxPosition           furthest tip position in the go video, e.g. '1.18 m (Ascending colon)'
%     MaxF_Sigmoid_N        max |F| while the tip is in the sigmoid           (go)
%     MaxF_N                max |F|                                           (go)
%     MaxP1_Sigmoid         max P1 while the tip is in the sigmoid            (go)
%     MaxP1                 max P1                                            (go)
%     TimeToMaxPosition_s   from the start of motion (tip > MoveThresh beyond its start position)
%                           to the first time it is within ReachTol of the max position
%     MaxRetractionF_N      max |F| of the retraction force file (last force file of the test),
%                           limited to the R video when there is one
%     RetractionTime_s      R video: from the start of the retraction (tip > MoveThresh back from its
%                           start position) to the first time within ReachTol of its final (minimum) position
%     PosAtMaxF_m           tip position (furthest so far) when MaxF_N happens  (go)
%     SegAtMaxF             its segment
%     SegFracAtMaxF         how far into that segment, 0 = start, 1 = end
%     Notes                 anything that makes a value missing or less reliable
%
%   Go force / pressure values use the same time window as the go figure of
%   image_output (overlap of video, force and pressure); "in the
%   sigmoid" = the sigmoid band of that figure. Positions and times use the
%   whole video track.
%
%   Options (name-value): Root, VideoDir, CorrectedDir, OutDir, Cuts, ColonLength (1.35),
%   SegSmooth (1 s), ZeroForce (false), ForceSmooth (1 sample), MoveThresh (0.01 m),
%   ReachTol (0.005 m)

here = fileparts(mfilename('fullpath'));
ip = inputParser;
ip.addParameter('Root', fullfile(here, '..', 'Forcedata'));
ip.addParameter('VideoDir', fullfile(here, '..', 'compressedvideo'));
ip.addParameter('CorrectedDir', fullfile(here, '..', 'Corrected_video'));
ip.addParameter('OutDir', fullfile(here, '..', 'Figures'));
ip.addParameter('Cuts', fullfile(here, 'colon_cuts.json'));
ip.addParameter('ColonLength', 1.35);
ip.addParameter('SegSmooth', 1);
ip.addParameter('ZeroForce', false);
ip.addParameter('ForceSmooth', 1);
ip.addParameter('MoveThresh', 0.01);
ip.addParameter('ReachTol', 0.005);
ip.parse(varargin{:});
o = ip.Results;

rootDir = canonical(o.Root);
videoDir = '';
if isfolder(o.VideoDir), videoDir = canonical(o.VideoDir); end
corrDir = o.CorrectedDir;
if isfolder(corrDir), corrDir = canonical(corrDir); end
if ~isfolder(o.OutDir), mkdir(o.OutDir); end
outDir = canonical(o.OutDir);
if ~isfile(o.Cuts)
    warning('trial_table:noCuts', 'No %s: run image_output(''Mark'', true) first. Sigmoid columns will be empty.', o.Cuts);
end
names = segNames();

REC = buildRecordings(rootDir, videoDir, corrDir);
folders = unique({REC.folder}, 'stable');
rows = cell(0, 14);
key = cell(0, 1);
for fi = 1:numel(folders)
    folder = folders{fi};
    recs = REC(strcmp({REC.folder}, folder));
    notes = {};
    try
        D = loadTest(folder, rootDir);
        [trial, key{end + 1, 1}] = trialName(D.label); %#ok<AGROW>
        fprintf('%-6s %s\n', trial, D.label);

        nF = numel(D.force);
        goIdx = find(strcmp({D.force.role}, 'go'));
        hasP = ~isempty(D.press);
        if hasP
            tP = D.press.t - D.press.t(1) + D.press.ts;
            P1 = D.press.P1;
        else
            notes{end + 1} = 'no pressure'; %#ok<AGROW>
        end
        [tF, Fm] = forceSeries(D, goIdx, o);

        % ---------------- go ----------------
        gRec = recs(strcmp({recs.role}, 'G'));
        maxPos = ''; tReach = nan; FsigMax = nan; PsigMax = nan;
        spans = [min(tF), max(tF)];
        if hasP, spans(end + 1, :) = [tP(1), tP(end)]; end
        if isempty(gRec)
            notes{end + 1} = 'no go video'; %#ok<AGROW>
        else
            if numel(gRec) > 1
                notes{end + 1} = sprintf('%d go videos, first used', numel(gRec)); %#ok<AGROW>
            end
            gRec = gRec(1);
            files = guessTrackFiles(gRec.csv);
            TK = loadTrack(gRec, D, videoDir, corrDir);
            if ~startsWith(TK.sync, 'synced'), notes{end + 1} = 'go video not synced'; end %#ok<AGROW>
            [cb, cc] = firstCurves(files.curves);
            SG = segInfo(TK, cutsFor(files.csv, o.Cuts), cb, cc, o);
            spans(end + 1, :) = [TK.t(1), TK.t(end)];

            ps = smoothPos(SG.frac * o.ColonLength, TK.t, o.SegSmooth);
            pmax = max(ps);
            seg = '';
            if SG.has, seg = sprintf(' (%s)', names{segOf(pmax / o.ColonLength, SG.edges)}); end
            maxPos = sprintf('%.2f m%s', pmax, seg);
            i0 = find(ps > ps(1) + o.MoveThresh, 1);
            i1 = find(ps >= pmax - o.ReachTol, 1);
            if ~isempty(i0) && ~isempty(i1) && i1 >= i0, tReach = TK.t(i1) - TK.t(i0); end
        end
        % same window as the go figure of image_output: overlap of video, force and pressure;
        % a record that does not overlap at all is left out
        if isempty(gRec), sp = {[min(tF), max(tF)]}; else, sp = {[TK.t(1), TK.t(end)], [min(tF), max(tF)]}; end
        if hasP, sp{end + 1} = [tP(1), tP(end)]; end
        [tLo, tHi, used] = overlapWindow(sp);
        if ~isempty(gRec) && ~used(2), notes{end + 1} = 'force does not overlap the go video'; end %#ok<AGROW>
        if hasP && ~used(numel(sp)), notes{end + 1} = 'pressure does not overlap'; hasP = false; end %#ok<AGROW>
        Fmax = maxIn(tF, Fm, tLo, tHi);
        Pmax = nan;
        if hasP, Pmax = maxIn(tP, P1, tLo, tHi); end
        % tip position when the go peak force happens (furthest point so far, as for the segment bands)
        posPk = nan; segPk = ''; fPk = nan;
        if ~isempty(gRec) && SG.has && isfinite(Fmax)
            in = find(tF >= tLo & tF <= tHi);
            [~, im] = max(Fm(in));
            [~, j] = min(abs(TK.t - tF(in(im))));
            posPk = max(ps(1:j));
            u = posPk / o.ColonLength;
            k = segOf(u, SG.edges);
            segPk = names{k};
            fPk = (u - SG.edges(k)) / max(SG.edges(k + 1) - SG.edges(k), eps);
        end
        if ~isempty(gRec) && SG.has
            bands = segmentBands(TK.t, SG.lab, tLo, tHi);
            sig = bands([bands.k] == 2);
            if isempty(sig)
                notes{end + 1} = 'tip not in the sigmoid within the window'; %#ok<AGROW>
            else
                FsigMax = maxIn(tF, Fm, sig(1).t1, sig(end).t2);
                if hasP, PsigMax = maxIn(tP, P1, sig(1).t1, sig(end).t2); end
            end
        elseif ~isempty(gRec)
            notes{end + 1} = 'no segment cuts'; %#ok<AGROW>
        end

        % ---------------- retraction ----------------
        FRmax = nan; tRet = nan;
        if nF >= 2
            [tR, FR] = forceSeries(D, nF, o);
            wLo = min(tR); wHi = max(tR);
            rRec = recs(strcmp({recs.role}, 'R'));
            if isempty(rRec)
                notes{end + 1} = 'no retraction video: force over the whole file, no retraction time'; %#ok<AGROW>
            else
                rRec = rRec(1);
                files = guessTrackFiles(rRec.csv);
                TKr = loadTrack(rRec, D, videoDir, corrDir);
                if ~startsWith(TKr.sync, 'synced'), notes{end + 1} = 'retraction video not synced'; end %#ok<AGROW>
                [cb, cc] = firstCurves(files.curves);
                SGr = segInfo(TKr, cutsFor(files.csv, o.Cuts), cb, cc, o);
                if max(TKr.t(1), wLo) < min(TKr.t(end), wHi)
                    wLo = max(TKr.t(1), wLo); wHi = min(TKr.t(end), wHi);
                else
                    notes{end + 1} = 'retraction video outside the force file'; %#ok<AGROW>
                end
                ps = smoothPos(SGr.frac * o.ColonLength, TKr.t, o.SegSmooth);
                pmin = min(ps);
                i0 = find(ps < ps(1) - o.MoveThresh, 1);
                i1 = find(ps <= pmin + o.ReachTol, 1);
                if ~isempty(i0) && ~isempty(i1) && i1 >= i0, tRet = TKr.t(i1) - TKr.t(i0); end
            end
            FRmax = maxIn(tR, FR, wLo, wHi);
        else
            notes{end + 1} = 'no retraction force file'; %#ok<AGROW>
        end

        rows(end + 1, :) = {trial, maxPos, round(FsigMax, 3), round(Fmax, 3), round(PsigMax, 2), ...
            round(Pmax, 2), round(tReach, 1), round(FRmax, 3), round(tRet, 1), ...
            round(posPk, 3), segPk, round(fPk, 3), strjoin(notes, '; '), D.label}; %#ok<AGROW>
    catch err
        where = '';
        if ~isempty(err.stack), where = sprintf(' (%s, line %d)', err.stack(1).name, err.stack(1).line); end
        fprintf(2, '   skipped %s: %s%s\n', folder, err.message, where);
        if numel(key) > size(rows, 1), key(end) = []; end
    end
end

T = cell2table(rows, 'VariableNames', {'Trial', 'MaxPosition', 'MaxF_Sigmoid_N', 'MaxF_N', ...
    'MaxP1_Sigmoid', 'MaxP1', 'TimeToMaxPosition_s', 'MaxRetractionF_N', 'RetractionTime_s', ...
    'PosAtMaxF_m', 'SegAtMaxF', 'SegFracAtMaxF', 'Notes', 'Folder'});
[~, o2] = sort(key);
T = T(o2, :);
writetable(T, fullfile(outDir, 'trial_table.csv'));
try
    writetable(T, fullfile(outDir, 'trial_table.xlsx'), 'Sheet', 1, 'WriteMode', 'replacefile');
catch err
    warning('trial_table:xlsx', 'xlsx not written (%s); the csv is there.', err.message);
end
disp(T(:, 1:9));
fprintf('Written: %s\n', fullfile(outDir, 'trial_table.csv / .xlsx'));
end

function [name, key] = trialName(label)
%TRIALNAME 'small size / test 7' -> 'S7' (sort key orders S, M, L, Mo, others).
parts = strtrim(strsplit(label, '/'));
g = lower(parts{1});
n = str2double(regexp(parts{end}, '\d+', 'match', 'once'));
if startsWith(g, 'small'),     c = 'S';  r = 1;
elseif startsWith(g, 'med'),   c = 'M';  r = 2;
elseif startsWith(g, 'large'), c = 'L';  r = 3;
elseif startsWith(g, 'mo'),    c = 'Mo'; r = 4;
else,                          c = parts{1}; r = 5;
end
if isnan(n), name = c; n = 0; else, name = sprintf('%s%d', c, n); end
key = sprintf('%d|%s|%05d', r, c, n);
end

function [tF, Fm] = forceSeries(D, idx, o)
%FORCESERIES |F| of the given force files on test time (NaN between files), as in image_output.
tF = []; Fm = [];
for k = idx(:)'
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

function v = maxIn(t, y, t1, t2)
y = y(t >= t1 & t <= t2);
v = max([y(:); nan], [], 'omitnan');
end

function p = smoothPos(p, t, sec)
w = max(1, round(sec / median(diff(t), 'omitnan')));
p = movmedian(p, w, 'omitnan');
p = fillmissing(fillmissing(p, 'previous'), 'next');
end

%% ======================= shared with image_output.m (same code - keep in sync) =======================
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
