function out = force_viewer_v2(rootDir, trackCsv)
%FORCE_VIEWER_V2 Force / pressure viewer + video tip track and colon shape.
%   force_viewer_v2()                    scans ../Forcedata, no video track
%   force_viewer_v2(rootDir)             scans rootDir for test folders
%   force_viewer_v2(rootDir, trackCsv)   also loads '<video>_track.csv'
%                                        (+ '_track_curves.jsonl', '.mp4',
%                                        '_track_sync.json' of the same name)
%   "Load track..." opens a dialog where each file is chosen by hand.
%
%   Everything is shown on one "experiment time" axis = force-sensor time.
%     pressure time = from file-name stamps (+ "P offset")
%     video time    = experiment time - "Video offset"
%   Drag the Video offset slider and watch the tip-position curve (right axis
%   of the pressure plot) to line the video up with force / pressure.
%   "Save sync..." stores the offsets in a JSON file of your choice;
%   "Load sync..." applies one again.
%
%   Tip position = tip_frac * colon length (editable, default 1.5 m).

if nargin < 1 || isempty(rootDir)
    rootDir = fullfile(fileparts(mfilename('fullpath')), '..', 'Forcedata');
end
if nargin < 2, trackCsv = ''; end
rootDir = dir(rootDir); rootDir = rootDir(1).folder;   % canonical path

files = dir(fullfile(rootDir, '**', '*_data_*.mat'));
if isempty(files)
    error('force_viewer:noData', 'No *_data_*.mat files under %s', rootDir);
end
testFolders = unique({files.folder});
testLabels  = erase(testFolders, [rootDir filesep]);

colF   = [0.85 0.33 0.10; 0.30 0.65 0.15; 0.00 0.45 0.74; 0.58 0.40 0.74];
compNm = {'Fx', 'Fy', 'Fz', '|F|'};
colTip = [0.10 0.75 0.75];
colEv  = [1.00 0.35 0.35];

D = struct();       % loaded data of the current test
F = []; Fm = [];    % processed force (n x 3) and magnitude
T = []; tP = [];    % force time, pressure time (in force time frame)
TR = [];            % video track
pos = []; spd = []; % tip position (m) and speed (mm/s)
lastVidFrame = -1;  % frame currently shown
vidNext = -1;       % frame the reader returns next (-1 = unknown)
vidCache = containers.Map('KeyType', 'double', 'ValueType', 'any');
vidCacheKeys = [];  % insertion order, oldest first
VID_DECIM = 3;      % display every 3rd pixel (1920x1080 -> 640x360)
VID_CACHE_N = 200;  % ~140 MB of decoded frames
playTimer = [];

%% ---------------- UI ----------------
fig = uifigure('Name', 'Force / Pressure / Video Viewer', 'Position', [40 40 1600 940]);
fig.CloseRequestFcn = @onClose;
fig.WindowKeyPressFcn = @onKey;

g = uigridlayout(fig, [4 1]);
g.RowHeight = {'fit', '1x', 'fit', 'fit'};

% --- top controls
gc = uigridlayout(g, [2 12]);
gc.RowHeight = {'fit', 'fit'};
gc.ColumnWidth = {'fit', 180, 'fit', 300, 50, 50, 50, 50, 'fit', 'fit', 'fit', '1x'};
gc.Padding = [0 0 0 0];

uilabel(gc, 'Text', 'Test:');
ddTest = uidropdown(gc, 'Items', testLabels, 'ItemsData', testFolders, ...
    'ValueChangedFcn', @(~, ~) loadTest());
uilabel(gc, 'Text', 'Force file:');
ddForce = uidropdown(gc, 'Items', {'-'}, 'ValueChangedFcn', @(~, ~) selectForce());

btn = gobjects(1, 4);
for q = 1:4
    btn(q) = uibutton(gc, 'state', 'Text', compNm{q}, 'Value', true, ...
        'FontWeight', 'bold', 'FontColor', colF(q, :), ...
        'ValueChangedFcn', @(~, ~) applyVisibility());
end
cbVec  = uicheckbox(gc, 'Text', 'Vectors 3D', 'Value', true, 'ValueChangedFcn', @(~, ~) applyVisibility());
cbTraj = uicheckbox(gc, 'Text', 'Trajectory', 'Value', true, 'ValueChangedFcn', @(~, ~) applyVisibility());
cbProj = uicheckbox(gc, 'Text', 'Projections', 'Value', true, 'ValueChangedFcn', @(~, ~) applyVisibility());

uilabel(gc, 'Text', '');
lblInfo = uilabel(gc, 'Text', '', 'FontColor', [0.5 0.5 0.5]);
lblInfo.Layout.Column = [2 4];
gOpt = uigridlayout(gc, [1 8]);
gOpt.Layout.Column = [5 12];
gOpt.Padding = [0 0 0 0];
gOpt.ColumnWidth = {'fit', 'fit', 'fit', 60, 'fit', 70, 'fit', 'fit'};
cbZero = uicheckbox(gOpt, 'Text', 'Zero at start', 'Value', false, 'ValueChangedFcn', @(~, ~) processForce());
cbFull = uicheckbox(gOpt, 'Text', 'Full range (pressure + video)', 'Value', false, 'ValueChangedFcn', @(~, ~) updateRange());
uilabel(gOpt, 'Text', 'Smooth (samples):');
spSmooth = uispinner(gOpt, 'Limits', [1 501], 'Step', 2, 'Value', 1, 'ValueChangedFcn', @(~, ~) processForce());
uilabel(gOpt, 'Text', 'P offset (s):');
efOff = uieditfield(gOpt, 'numeric', 'Value', 0, 'ValueChangedFcn', @(~, ~) alignPressure());
uilabel(gOpt, 'Text', 'Pressure:');
gP = uigridlayout(gOpt, [1 3]); gP.Padding = [0 0 0 0]; gP.ColumnWidth = {'fit', 'fit', 'fit'};
cbP1  = uicheckbox(gP, 'Text', 'P1', 'Value', true,  'ValueChangedFcn', @(~, ~) applyVisibility());
cbP1d = uicheckbox(gP, 'Text', 'P1 des', 'Value', true, 'ValueChangedFcn', @(~, ~) applyVisibility());
cbP2  = uicheckbox(gP, 'Text', 'P2', 'Value', false, 'ValueChangedFcn', @(~, ~) applyVisibility());

% --- plots: left = 3D force + colon, right = force / pressure / tip position
gp = uigridlayout(g, [3 2]);
gp.ColumnWidth = {'1x', '1.25x'};
gp.RowHeight = {'1x', '1x', '1x'};
gp.Padding = [0 0 0 0];

ax3 = uiaxes(gp);   ax3.Layout.Row = [1 2]; ax3.Layout.Column = 1;
axC = uiaxes(gp);   axC.Layout.Row = 3;     axC.Layout.Column = 1;
axF = uiaxes(gp);   axF.Layout.Row = 1;     axF.Layout.Column = 2;
axP = uiaxes(gp);   axP.Layout.Row = 2;     axP.Layout.Column = 2;
axT = uiaxes(gp);   axT.Layout.Row = 3;     axT.Layout.Column = 2;

% 3D axes
hold(ax3, 'on'); grid(ax3, 'on'); box(ax3, 'on');
view(ax3, 35, 22); axis(ax3, 'equal');
xlabel(ax3, 'Fx (N)'); ylabel(ax3, 'Fy (N)'); zlabel(ax3, 'Fz (N)');
hTrajAll = plot3(ax3, nan, nan, nan, '-', 'Color', [0.6 0.6 0.6 0.35], 'LineWidth', 0.5);
hTraj    = plot3(ax3, nan, nan, nan, '-', 'Color', [colF(4, :) 0.9], 'LineWidth', 1.2);
hProj    = plot3(ax3, nan, nan, nan, ':', 'Color', [0.5 0.5 0.5], 'LineWidth', 1);
hQ = gobjects(1, 4);
for q = 1:4
    hQ(q) = quiver3(ax3, 0, 0, 0, 0, 0, 0, 0, 'Color', colF(q, :), ...
        'LineWidth', 2 + (q == 4), 'MaxHeadSize', 0.4, 'AutoScale', 'off');
end
hTip = plot3(ax3, nan, nan, nan, 'o', 'MarkerFaceColor', colF(4, :), 'MarkerEdgeColor', 'w', 'MarkerSize', 7);
plot3(ax3, 0, 0, 0, '.', 'Color', [0.5 0.5 0.5], 'MarkerSize', 14);

% colon view (image coordinates)
hold(axC, 'on'); axis(axC, 'equal'); axC.YDir = 'reverse';
axC.XTick = []; axC.YTick = []; box(axC, 'on');
hImg  = image(axC, 'CData', zeros(2, 2, 3, 'uint8'), 'Visible', 'off');
hBnd  = plot(axC, nan, nan, '-', 'Color', [0.95 0.80 0.20], 'LineWidth', 1.2);
hCtr  = plot(axC, nan, nan, '--', 'Color', [0.6 0.6 0.6], 'LineWidth', 1);
hEv   = plot(axC, nan, nan, '-', 'Color', colEv, 'LineWidth', 3.5);
hCTip = plot(axC, nan, nan, 'o', 'MarkerFaceColor', colEv, 'MarkerEdgeColor', 'w', 'MarkerSize', 9);
title(axC, 'Colon (load a track)');

% force time series
hold(axF, 'on'); grid(axF, 'on'); box(axF, 'on');
ylabel(axF, 'Force (N)');
hF = gobjects(1, 4);
for q = 1:4
    hF(q) = plot(axF, nan, nan, 'Color', colF(q, :), 'LineWidth', 1 + 0.5 * (q == 4), 'DisplayName', compNm{q});
end
hCurF = xline(axF, 0, '-', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.2, 'HandleVisibility', 'off');
hDotF = plot(axF, nan(1, 4), nan(1, 4), 'ko', 'MarkerFaceColor', 'y', 'HandleVisibility', 'off');
legend(axF, 'Location', 'northwest');

% pressure (left) + tip position overlay for syncing (right)
hold(axP, 'on'); grid(axP, 'on'); box(axP, 'on');
yyaxis(axP, 'left'); ylabel(axP, 'Pressure');
hP1  = plot(axP, nan, nan, '-',  'Color', [0.49 0.18 0.56], 'LineWidth', 1.3, 'DisplayName', 'P1');
hP1d = plot(axP, nan, nan, '--', 'Color', [0.93 0.69 0.13], 'LineWidth', 1.2, 'DisplayName', 'P1 des');
hP2  = plot(axP, nan, nan, '-',  'Color', [0.30 0.75 0.93], 'LineWidth', 1.0, 'DisplayName', 'P2');
hDotP = plot(axP, nan, nan, 'ko', 'MarkerFaceColor', 'y', 'HandleVisibility', 'off');
yyaxis(axP, 'right'); ylabel(axP, 'Tip pos (m)');
hPosP = plot(axP, nan, nan, '-', 'Color', colTip, 'LineWidth', 1.2, 'DisplayName', 'tip pos (video)');
axP.YAxis(1).Color = [0.49 0.18 0.56]; axP.YAxis(2).Color = colTip;
yyaxis(axP, 'left');
hCurP = xline(axP, 0, '-', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.2, 'HandleVisibility', 'off');
legend(axP, 'Location', 'northwest');

% tip position / speed
hold(axT, 'on'); grid(axT, 'on'); box(axT, 'on');
yyaxis(axT, 'left'); ylabel(axT, 'Tip position (m)');
hPos = plot(axT, nan, nan, '-', 'Color', colTip, 'LineWidth', 1.6, 'DisplayName', 'position');
hDotT = plot(axT, nan, nan, 'ko', 'MarkerFaceColor', 'y', 'HandleVisibility', 'off');
yyaxis(axT, 'right'); ylabel(axT, 'Speed (mm/s)');
hSpd = plot(axT, nan, nan, '-', 'Color', [0.85 0.55 0.20 0.7], 'LineWidth', 0.8, 'DisplayName', 'speed');
axT.YAxis(1).Color = colTip; axT.YAxis(2).Color = [0.85 0.55 0.20];
yyaxis(axT, 'left');
hCurT = xline(axT, 0, '-', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.2, 'HandleVisibility', 'off');
xlabel(axT, 'Experiment time (s)  [= force time]');
legend(axT, 'Location', 'northwest');
linkaxes([axF axP axT], 'x');

% --- main timeline
gt = uigridlayout(g, [1 5]);
gt.ColumnWidth = {70, '1x', 'fit', 70, 330};
gt.Padding = [0 0 0 0];
btnPlay = uibutton(gt, 'Text', 'Play', 'ButtonPushedFcn', @(~, ~) togglePlay());
slider = uislider(gt, 'Limits', [0 1], 'Value', 0, ...
    'ValueChangingFcn', @(~, e) render(e.Value, false), ...
    'ValueChangedFcn',  @(s, ~) render(s.Value, true));
uilabel(gt, 'Text', 'Speed:');
ddSpeed = uidropdown(gt, 'Items', {'0.25x', '0.5x', '1x', '2x', '5x', '10x'}, ...
    'ItemsData', [0.25 0.5 1 2 5 10], 'Value', 1);
lblTime = uilabel(gt, 'Text', 't = 0.00 s', 'FontName', 'Consolas', 'FontSize', 13);

% --- video track + sync row
gs = uigridlayout(g, [1 17]);
gs.ColumnWidth = {'fit', 'fit', 'fit', '1x', 35, 35, 75, 35, 35, 'fit', 'fit', 'fit', 'fit', 55, 'fit', 70, 'fit'};
gs.Padding = [0 0 0 0];
uibutton(gs, 'Text', 'Load track...', 'ButtonPushedFcn', @(~, ~) pickTrack());
cbVideo = uicheckbox(gs, 'Text', 'Video frame', 'Value', true, 'ValueChangedFcn', @(~, ~) videoToggled());
uilabel(gs, 'Text', 'Video offset (s):', 'FontWeight', 'bold');
slOff = uislider(gs, 'Limits', [-300 300], 'Value', 0, ...
    'ValueChangingFcn', @(~, e) setVideoOffset(e.Value), ...
    'ValueChangedFcn',  @(s, ~) setVideoOffset(s.Value));
uibutton(gs, 'Text', '-1',   'ButtonPushedFcn', @(~, ~) setVideoOffset(efVOff.Value - 1));
uibutton(gs, 'Text', '-0.1', 'ButtonPushedFcn', @(~, ~) setVideoOffset(efVOff.Value - 0.1));
efVOff = uieditfield(gs, 'numeric', 'Value', 0, 'ValueDisplayFormat', '%.2f', ...
    'ValueChangedFcn', @(s, ~) setVideoOffset(s.Value));
uibutton(gs, 'Text', '+0.1', 'ButtonPushedFcn', @(~, ~) setVideoOffset(efVOff.Value + 0.1));
uibutton(gs, 'Text', '+1',   'ButtonPushedFcn', @(~, ~) setVideoOffset(efVOff.Value + 1));
uibutton(gs, 'Text', 'Video start = pressure start', 'ButtonPushedFcn', @(~, ~) autoAlign());
uibutton(gs, 'Text', 'Load sync...', 'ButtonPushedFcn', @(~, ~) pickSync());
uibutton(gs, 'Text', 'Save sync...', 'ButtonPushedFcn', @(~, ~) saveSync());
uilabel(gs, 'Text', 'Colon L (m):');
efLen = uieditfield(gs, 'numeric', 'Value', 1.5, 'Limits', [0.01 100], ...
    'ValueChangedFcn', @(~, ~) updateTrackCurves());
uilabel(gs, 'Text', 'Speed smooth (s):');
spSpd = uispinner(gs, 'Limits', [0.02 20], 'Step', 0.5, 'Value', 1, 'ValueDisplayFormat', '%.2f', ...
    'ValueChangedFcn', @(~, ~) updateTrackCurves());
lblVid = uilabel(gs, 'Text', 'no video track', 'FontName', 'Consolas', 'FontColor', [0.5 0.5 0.5]);

loadTest();
if ~isempty(trackCsv), loadTrack(guessTrackFiles(trackCsv)); end
if nargout > 0, out = fig; end   % do not clear fig: callbacks share it

%% ---------------- force / pressure data ----------------
    function loadTest()
        stopPlay();
        folder = ddTest.Value;
        fF = dir(fullfile(folder, 'Force_data_*.mat'));
        fP = dir(fullfile(folder, 'Pressure_data_*.mat'));

        D = struct('force', struct('name', {}, 'T', {}, 'F', {}, 'tEnd', {}), 'press', []);
        for i = 1:numel(fF)
            S = load(fullfile(folder, fF(i).name), 'dataTable');
            tb = S.dataTable;
            D.force(i).name = fF(i).name;
            D.force(i).T = tb.Time(:);
            D.force(i).F = [tb.Fx(:) tb.Fy(:) tb.Fz(:)];
            D.force(i).tEnd = stampOf(fF(i).name);
        end
        if ~isempty(fP)
            S = load(fullfile(folder, fP(1).name));
            p.name = fP(1).name;
            p.t = S.time_log(:);
            p.P1 = S.P1_log(:);
            p.P1d = getf(S, 'P1_des_log', numel(p.t));
            p.P2 = getf(S, 'P2_log', numel(p.t));
            p.tEnd = stampOf(fP(1).name);
            D.press = p;
        end

        % label each force file with its peak and overlap with the pressure record
        items = cell(1, numel(D.force));
        score = zeros(1, numel(D.force));
        for i = 1:numel(D.force)
            fr = D.force(i);
            peak = max(vecnorm(fr.F, 2, 2));
            ov = 0;
            if ~isempty(D.press)
                fs = fr.tEnd - seconds(fr.T(end) - fr.T(1));
                ps = D.press.tEnd - seconds(D.press.t(end) - D.press.t(1));
                ov = max(0, seconds(min(fr.tEnd, D.press.tEnd) - max(fs, ps)));
            end
            items{i} = sprintf('%s  (peak %.2f N, overlap %.0f s)', ...
                erase(erase(fr.name, 'Force_data_'), '.mat'), peak, ov);
            score(i) = ov * 1e3 + peak;
        end
        ddForce.Items = items;
        ddForce.ItemsData = 1:numel(items);
        [~, best] = max(score);
        ddForce.Value = best;
        selectForce();
    end

    function selectForce()
        fr = D.force(ddForce.Value);
        T = fr.T;
        tP = [];   % re-aligned below; avoid rendering with stale pressure
        msg = sprintf('%d samples, %.1f s', numel(T), T(end) - T(1));
        if ~isempty(D.press)
            msg = sprintf('%s  |  %s', msg, D.press.name);
        else
            msg = sprintf('%s  |  no pressure file', msg);
        end
        lblInfo.Text = msg;
        processForce();
        alignPressure();
    end

    function processForce()
        fr = D.force(ddForce.Value);
        F = fr.F;
        if cbZero.Value
            n0 = max(1, find(T <= T(1) + 0.5, 1, 'last'));
            F = F - mean(F(1:n0, :), 1);
        end
        w = round(spSmooth.Value);
        if w > 1
            F = movmean(F, w, 1);
        end
        Fm = vecnorm(F, 2, 2);

        for j = 1:3, set(hF(j), 'XData', T, 'YData', F(:, j)); end
        set(hF(4), 'XData', T, 'YData', Fm);
        set(hTrajAll, 'XData', F(:, 1), 'YData', F(:, 2), 'ZData', F(:, 3));

        % fit the box to the data (always including the origin)
        lo = min([F; 0 0 0], [], 1);
        hi = max([F; 0 0 0], [], 1);
        pad = max([hi - lo, 0.05]) * 0.08;
        axis(ax3, reshape([lo - pad; hi + pad], 1, []));
        applyVisibility();
    end

    function alignPressure()
        if isempty(D.press)
            tP = [];
            set([hP1 hP1d hP2], 'XData', nan, 'YData', nan);
        else
            fr = D.force(ddForce.Value);
            p = D.press;
            % wall clock -> force frame (file stamps = end of each recording)
            tP = p.t - p.t(end) + seconds(p.tEnd - fr.tEnd) + T(end) + efOff.Value;
            set(hP1,  'XData', tP, 'YData', p.P1);
            set(hP1d, 'XData', tP, 'YData', p.P1d);
            set(hP2,  'XData', tP, 'YData', p.P2);
        end
        updateRange();
    end

    function updateRange()
        lim = [T(1) T(end)];
        if cbFull.Value
            if ~isempty(tP), lim = [min(lim(1), tP(1)) max(lim(2), tP(end))]; end
            if ~isempty(TR)
                tv = TR.t + efVOff.Value;
                lim = [min(lim(1), tv(1)) max(lim(2), tv(end))];
            end
        end
        v = min(max(slider.Value, lim(1)), lim(2));
        slider.Limits = lim;
        slider.MajorTicks = round(linspace(lim(1), lim(2), 13), 1);
        slider.MinorTicks = [];
        slider.Value = v;
        xlim(axF, lim);
        render(v, true);
    end

%% ---------------- video track ----------------
    function pickTrack()
        if isempty(TR)
            files = struct('csv', '', 'curves', '', 'video', '', 'sync', '');
        else
            files = TR.files;
        end
        files = askTrackFiles(fig, files);
        if ~isempty(files), loadTrack(files); end
    end

    function loadTrack(files)
        stopPlay();
        dlg = uiprogressdlg(fig, 'Title', 'Loading track', 'Message', 'Reading CSV...');
        cleanup = onCleanup(@() delete(dlg));

        tb = readtable(files.csv);
        tr.files = files;
        [~, base] = fileparts(files.csv);
        tr.name = erase(base, '_track');
        tr.frame = tb.frame;
        tr.t = tb.time_s;
        tr.frac = tb.tip_frac;
        tr.arclen = tb.tip_arclen_px;
        tr.tip = [tb.tip_x tb.tip_y];

        tr.B = []; tr.C = [];
        if ~isempty(files.curves)
            [tr.B, tr.C] = loadCurves(files.curves, dlg);
        end

        tr.vr = [];
        if ~isempty(files.video)
            dlg.Message = 'Opening video...';
            try
                tr.vr = VideoReader(files.video);
            catch err
                uialert(fig, sprintf('Cannot open video:\n%s', err.message), 'Video');
            end
        end
        TR = tr;
        pos = TR.frac * efLen.Value;   % needed before the first render below
        spd = zeros(size(pos));
        resetVideoCache();

        % colon view limits: whole video frame, or the outline / tip extent
        if ~isempty(TR.vr)
            W = TR.vr.Width; H = TR.vr.Height;
            set(hImg, 'XData', [1 W], 'YData', [1 H]);
            axis(axC, [0.5 W + 0.5 0.5 H + 0.5]);
        elseif ~isempty(TR.B)
            bx = TR.B(:, 1, :); by = TR.B(:, 2, :);
            axis(axC, [min(bx(:)) max(bx(:)) min(by(:)) max(by(:))] + [-20 20 -20 20]);
        else
            axis(axC, [min(TR.tip(:, 1)) max(TR.tip(:, 1)) min(TR.tip(:, 2)) max(TR.tip(:, 2))] + [-50 50 -50 50]);
        end
        if isempty(TR.B)
            set([hBnd hCtr hEv], 'XData', nan, 'YData', nan);
        end

        if ~isempty(files.sync) && isfile(files.sync)
            applySync(files.sync);
        elseif ~isempty(tP)
            autoAlign();
        else
            setVideoOffset(0);
        end
        videoToggled();
    end

    function updateTrackCurves()
        if isempty(TR), return; end
        pos = TR.frac * efLen.Value;
        % speed: smooth position, differentiate, smooth again (window in s)
        w = max(1, round(spSpd.Value / median(diff(TR.t))));
        spd = movmean(gradient(movmean(pos, w)) ./ gradient(TR.t) * 1000, w);
        tv = TR.t + efVOff.Value;
        set(hPos,  'XData', tv, 'YData', pos);
        set(hPosP, 'XData', tv, 'YData', pos);
        set(hSpd,  'XData', tv, 'YData', spd);
        render(slider.Value, true);
    end

    function setVideoOffset(v)
        v = round(v, 2);
        efVOff.Value = v;
        if v < slOff.Limits(1) || v > slOff.Limits(2)
            slOff.Limits = sort([min(slOff.Limits(1), v - 10) max(slOff.Limits(2), v + 10)]);
        end
        slOff.MajorTicks = round(linspace(slOff.Limits(1), slOff.Limits(2), 5));
        slOff.MinorTicks = [];
        slOff.Value = v;
        if isempty(TR)
            return;
        end
        if cbFull.Value
            updateRange();   % range depends on the video span
        end
        updateTrackCurves();
    end

    function autoAlign()
        if isempty(TR) || isempty(tP), return; end
        setVideoOffset(tP(1) - TR.t(1));
    end

    function videoToggled()
        hImg.Visible = cbVideo.Value && ~isempty(TR) && ~isempty(TR.vr);
        lastVidFrame = -1;
        render(slider.Value, true);
    end

    function pickSync()
        if isempty(TR)
            uialert(fig, 'Load a video track first.', 'Load sync');
            return;
        end
        [f, p] = uigetfile({'*.json', 'Sync JSON (*.json)'}, 'Load sync', defaultSyncPath());
        figure(fig);
        if isequal(f, 0), return; end
        applySync(fullfile(p, f));
    end

    function applySync(file)
        try
            s = jsondecode(fileread(file));
        catch err
            uialert(fig, sprintf('Cannot read %s:\n%s', file, err.message), 'Load sync');
            return;
        end
        k = find(strcmp(testLabels, s.test), 1);
        if ~isempty(k)
            ddTest.Value = testFolders{k};
            loadTest();
            j = find(strcmp({D.force.name}, s.force_file), 1);
            if ~isempty(j), ddForce.Value = j; end
        else
            uialert(fig, sprintf('Test "%s" not found under the data folder; keeping the current test.', s.test), ...
                'Load sync', 'Icon', 'warning');
        end
        efOff.Value = s.pressure_offset_s;
        efLen.Value = s.colon_length_m;
        selectForce();
        setVideoOffset(s.video_offset_s);
        TR.files.sync = file;
    end

    function f = defaultSyncPath()
        f = TR.files.sync;
        if isempty(f)
            [folder, base] = fileparts(TR.files.csv);
            f = fullfile(folder, [base '_sync.json']);
        end
    end

    function saveSync()
        if isempty(TR)
            uialert(fig, 'Load a video track first.', 'Save sync');
            return;
        end
        [f, p] = uiputfile({'*.json', 'Sync JSON (*.json)'}, 'Save sync as', defaultSyncPath());
        figure(fig);
        if isequal(f, 0), return; end
        file = fullfile(p, f);
        s.test = testLabels{strcmp(testFolders, ddTest.Value)};
        s.force_file = D.force(ddForce.Value).name;
        s.video_offset_s = efVOff.Value;
        s.pressure_offset_s = efOff.Value;
        s.colon_length_m = efLen.Value;
        s.track_csv = TR.files.csv;
        s.curves_jsonl = TR.files.curves;
        s.video = TR.files.video;
        s.note = 'experiment time = force time; video time = experiment time - video_offset_s';
        fid = fopen(file, 'w');
        if fid < 0
            uialert(fig, sprintf('Cannot write %s', file), 'Save sync');
            return;
        end
        fwrite(fid, jsonencode(s, 'PrettyPrint', true));
        fclose(fid);
        TR.files.sync = file;
        uialert(fig, sprintf('Saved to\n%s', file), 'Save sync', 'Icon', 'success');
    end

%% ---------------- drawing ----------------
    function applyVisibility()
        on = [btn.Value];
        for j = 1:4
            hF(j).Visible = on(j);
            hQ(j).Visible = on(j) && cbVec.Value;
        end
        hTip.Visible  = on(4) && cbVec.Value;
        hProj.Visible = cbProj.Value && cbVec.Value;
        hTraj.Visible = cbTraj.Value;
        hTrajAll.Visible = cbTraj.Value;
        hP1.Visible  = cbP1.Value;
        hP1d.Visible = cbP1d.Value;
        hP2.Visible  = cbP2.Value;
        render(slider.Value, true);
    end

    function render(t, final)
        if isempty(T), return; end
        set([hCurF hCurP hCurT], 'Value', t);

        inForce = t >= T(1) && t <= T(end);
        if inForce
            [~, i] = min(abs(T - t));
            f = F(i, :);
            m = Fm(i);
        else
            i = 0; f = nan(1, 3); m = nan;
        end

        % component arrows from origin, resultant from origin to tip
        set(hQ(1), 'UData', f(1), 'VData', 0, 'WData', 0);
        set(hQ(2), 'UData', 0, 'VData', f(2), 'WData', 0);
        set(hQ(3), 'UData', 0, 'VData', 0, 'WData', f(3));
        set(hQ(4), 'UData', f(1), 'VData', f(2), 'WData', f(3));
        set(hTip, 'XData', f(1), 'YData', f(2), 'ZData', f(3));
        % box edges from the tip back to the component axes
        px = [f(1) f(1) nan f(1) f(1) nan f(1) 0    nan f(1) f(1) nan 0    f(1) nan 0    0   ];
        py = [f(2) f(2) nan f(2) 0    nan 0    0    nan f(2) 0    nan f(2) f(2) nan f(2) 0   ];
        pz = [f(3) 0    nan 0    0    nan 0    0    nan f(3) f(3) nan 0    0    nan 0    0   ];
        set(hProj, 'XData', px, 'YData', py, 'ZData', pz);
        if i > 0
            set(hTraj, 'XData', F(1:i, 1), 'YData', F(1:i, 2), 'ZData', F(1:i, 3));
        else
            set(hTraj, 'XData', nan, 'YData', nan, 'ZData', nan);
        end

        on = [btn.Value];
        v4 = [f m];
        v4(~on) = nan;
        set(hDotF, 'XData', t * ones(1, 4), 'YData', v4);

        pStr = '';
        if ~isempty(tP) && t >= tP(1) && t <= tP(end)
            pv = interp1(tP, D.press.P1, t);
            pd = interp1(tP, D.press.P1d, t);
            set(hDotP, 'XData', t, 'YData', pv);
            pStr = sprintf('  P1 = %.2f', pv);
            title(axP, sprintf('Pressure  —  P1 = %.2f, P1 des = %.2f', pv, pd));
        else
            set(hDotP, 'XData', nan, 'YData', nan);
            title(axP, 'Pressure  —  (no data at this time)');
        end

        if inForce
            title(ax3, sprintf('t = %.2f s   |F| = %.3f N', t, m));
            title(axF, sprintf('Fx = %+.3f   Fy = %+.3f   Fz = %+.3f   |F| = %.3f N', f, m));
        else
            title(ax3, sprintf('t = %.2f s   (outside force record)', t));
            title(axF, 'Force  —  (no data at this time)');
        end
        lblTime.Text = sprintf('t = %7.2f s%s', t, pStr);

        renderTrack(t, final);
        drawnow limitrate;
    end

    function renderTrack(t, final)
        if isempty(TR), return; end
        tv = t - efVOff.Value;
        if tv < TR.t(1) || tv > TR.t(end)
            set([hBnd hCtr hEv hCTip], 'XData', nan, 'YData', nan);
            set(hDotT, 'XData', nan, 'YData', nan);
            title(axC, sprintf('%s   video t = %.2f s  (outside track)', TR.name, tv));
            title(axT, 'Tip position  —  (no video data at this time)');
            lblVid.Text = sprintf('video t = %7.2f s', tv);
            showVideoFrame(tv, final);
            return;
        end
        [~, k] = min(abs(TR.t - tv));

        if ~isempty(TR.B)
            c = min(k, size(TR.B, 3));
            b = TR.B(:, :, c);
            ctr = TR.C(:, :, c);
            set(hBnd, 'XData', [b(:, 1); b(1, 1)], 'YData', [b(:, 2); b(1, 2)]);
            set(hCtr, 'XData', ctr(:, 1), 'YData', ctr(:, 2));
            % everted part = centerline up to the tip arc length
            s = [0; cumsum(vecnorm(diff(double(ctr)), 2, 2))];
            L = TR.arclen(k);
            n = find(s <= L, 1, 'last');
            ev = double(ctr(1:n, :));
            if n < numel(s) && L > s(n)
                a = (L - s(n)) / (s(n + 1) - s(n));
                ev(end + 1, :) = (1 - a) * double(ctr(n, :)) + a * double(ctr(n + 1, :));
            end
            set(hEv, 'XData', ev(:, 1), 'YData', ev(:, 2));
        end
        set(hCTip, 'XData', TR.tip(k, 1), 'YData', TR.tip(k, 2));
        set(hDotT, 'XData', t, 'YData', pos(k));

        title(axC, sprintf('%s   video t = %.2f s   frame %d   tip %.1f %%', ...
            TR.name, tv, TR.frame(k), 100 * TR.frac(k)));
        title(axT, sprintf('Tip position = %.3f m  (%.1f %% of %.2f m)   speed = %.1f mm/s', ...
            pos(k), 100 * TR.frac(k), efLen.Value, spd(k)));
        lblVid.Text = sprintf('video t = %7.2f s  frame %d', tv, TR.frame(k));
        showVideoFrame(tv, final);
    end

    function showVideoFrame(tv, final)
        if ~strcmp(hImg.Visible, 'on'), return; end
        vr = TR.vr;
        fr = round(tv * vr.FrameRate);
        fr = min(max(fr, 0), floor(vr.Duration * vr.FrameRate) - 1);
        if fr == lastVidFrame, return; end
        if isKey(vidCache, fr)
            hImg.CData = vidCache(fr);
            lastVidFrame = fr;
            return;
        end
        % Seeking an H.264 frame costs ~0.3 s, reading the next one ~6 ms:
        % don't decode while the slider is being dragged, and read forward
        % sequentially when the target is a little ahead (playback, arrows).
        if ~final, return; end
        try
            d = fr - vidNext;
            if vidNext < 0 || d < 0 || d > 75
                vr.CurrentTime = fr / vr.FrameRate;
                d = 0;
            end
            for j = 1:d
                cacheFrame(vidNext, readFrame(vr));
                vidNext = vidNext + 1;
            end
            im = cacheFrame(fr, readFrame(vr));
            vidNext = fr + 1;
            hImg.CData = im;
            lastVidFrame = fr;
        catch
            vidNext = -1;
        end
    end

    function im = cacheFrame(fr, im)
        im = im(1:VID_DECIM:end, 1:VID_DECIM:end, :);
        if ~isKey(vidCache, fr)
            vidCacheKeys(end + 1) = fr;
            if numel(vidCacheKeys) > VID_CACHE_N
                remove(vidCache, vidCacheKeys(1));
                vidCacheKeys(1) = [];
            end
        end
        vidCache(fr) = im;
    end

    function resetVideoCache()
        vidCache = containers.Map('KeyType', 'double', 'ValueType', 'any');
        vidCacheKeys = [];
        vidNext = -1;
        lastVidFrame = -1;
    end

%% ---------------- playback / keys ----------------
    function togglePlay()
        if isempty(playTimer) || ~isvalid(playTimer) || strcmp(playTimer.Running, 'off')
            playTimer = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.05, ...
                'BusyMode', 'drop', 'TimerFcn', @(~, ~) step(0.05 * ddSpeed.Value));
            btnPlay.Text = 'Pause';
            if slider.Value >= slider.Limits(2), slider.Value = slider.Limits(1); end
            start(playTimer);
        else
            stopPlay();
        end
    end

    function step(dt)
        if ~isvalid(fig), stopPlay(); return; end
        v = slider.Value + dt;
        if v >= slider.Limits(2)
            v = slider.Limits(2);
            stopPlay();
        end
        slider.Value = v;
        render(v, true);
    end

    function stopPlay()
        if ~isempty(playTimer) && isvalid(playTimer)
            stop(playTimer); delete(playTimer);
        end
        playTimer = [];
        if isvalid(btnPlay), btnPlay.Text = 'Play'; end
    end

    function onKey(~, e)
        dt = 0.1;
        if any(strcmp(e.Modifier, 'shift')), dt = 1; end
        switch e.Key
            case 'rightarrow', v = slider.Value + dt;
            case 'leftarrow',  v = slider.Value - dt;
            case 'period',     v = slider.Value + 0.02;   % one video frame @ 50 fps
            case 'comma',      v = slider.Value - 0.02;
            case 'space', togglePlay(); return;
            otherwise, return;
        end
        slider.Value = min(max(v, slider.Limits(1)), slider.Limits(2));
        render(slider.Value, true);
    end

    function onClose(~, ~)
        stopPlay();
        delete(fig);
    end
end

function [B, C] = loadCurves(jsonl, dlg)
%LOADCURVES Read '<video>_track_curves.jsonl' (boundary + centerline per frame).
%   The parsed arrays are cached in tempdir, keyed by file name and size.
B = []; C = [];
if ~isfile(jsonl), return; end
info = dir(jsonl);
[~, nm] = fileparts(jsonl);
cache = fullfile(tempdir, sprintf('fv2_%s_%d.mat', matlab.lang.makeValidName(nm), info.bytes));
if isfile(cache)
    dlg.Message = 'Loading cached colon curves...';
    S = load(cache);
    B = S.B; C = S.C;
    return;
end

fid = fopen(jsonl, 'r');
closer = onCleanup(@() fclose(fid));
first = jsondecode(fgetl(fid));
nb = size(first.boundary, 1); nc = size(first.centerline, 1);
nEst = max(1, round(info.bytes / (numel(fgetl(fid)) + 1)));
frewind(fid);
B = zeros(nb, 2, nEst, 'single');
C = zeros(nc, 2, nEst, 'single');
fr = zeros(nEst, 1);
k = 0;
while true
    l = fgetl(fid);
    if ~ischar(l), break; end
    if isempty(l), continue; end
    d = jsondecode(l);
    k = k + 1;
    fr(k) = d.frame;
    B(:, :, k) = d.boundary;
    C(:, :, k) = d.centerline;
    if mod(k, 200) == 0
        dlg.Value = min(0.99, k / nEst);
        dlg.Message = sprintf('Parsing colon curves (first time only)... %d frames', k);
    end
end
B = B(:, :, 1:k); C = C(:, :, 1:k); fr = fr(1:k);
dlg.Message = 'Caching...';
save(cache, 'B', 'C', 'fr', '-v7.3');
end

function p = guessTrackFiles(csv)
%GUESSTRACKFILES Same-name files next to '<video>_track.csv' ('' when missing).
[folder, base] = fileparts(csv);
vbase = erase(base, '_track');
p.csv = csv;
p.curves = existing(fullfile(folder, [base '_curves.jsonl']));
p.video = '';
for ext = {'.mp4', '.MP4', '.avi', '.mov', '.MOV'}
    p.video = existing(fullfile(folder, [vbase ext{1}]));
    if ~isempty(p.video), break; end
end
p.sync = existing(fullfile(folder, [base '_sync.json']));
end

function f = existing(f)
if ~isfile(f), f = ''; end
end

function files = askTrackFiles(parent, files)
%ASKTRACKFILES Modal dialog to pick track CSV, curves JSONL, video and sync JSON.
%   Returns [] when cancelled.
rows = { ...
    'csv',    'Track CSV (required)',   {'*.csv', 'Track CSV (*.csv)'}; ...
    'curves', 'Colon curves (.jsonl)',  {'*.jsonl', 'Curves JSONL (*.jsonl)'}; ...
    'video',  'Video',                  {'*.mp4;*.avi;*.mov', 'Video (*.mp4, *.avi, *.mov)'}; ...
    'sync',   'Sync (.json, optional)', {'*.json', 'Sync JSON (*.json)'}};
pp = parent.Position;
d = uifigure('Name', 'Select track files', 'WindowStyle', 'modal', ...
    'Position', [pp(1) + pp(3) / 2 - 400, pp(2) + pp(4) / 2 - 120, 800, 240]);
gl = uigridlayout(d, [6 4]);
gl.ColumnWidth = {'fit', '1x', 70, 50};
gl.RowHeight = {'fit', 'fit', 'fit', 'fit', 'fit', 'fit'};
ef = gobjects(1, 4);
for i = 1:4
    uilabel(gl, 'Text', rows{i, 2});
    ef(i) = uieditfield(gl, 'text', 'Value', files.(rows{i, 1}));
    uibutton(gl, 'Text', 'Browse...', 'ButtonPushedFcn', @(~, ~) browse(i));
    uibutton(gl, 'Text', 'Clear', 'ButtonPushedFcn', @(~, ~) clearRow(i));
end
lbl = uilabel(gl, 'Text', ['Empty = skip (no colon outline / no video / auto offset). ' ...
    'Picking a CSV fills the empty fields with same-name files, if found.'], ...
    'FontColor', [0.5 0.5 0.5], 'WordWrap', 'on');
lbl.Layout.Column = [1 4];
gb = uigridlayout(gl, [1 3]); gb.Layout.Column = [1 4];
gb.ColumnWidth = {'1x', 90, 90}; gb.Padding = [0 0 0 0];
uilabel(gb, 'Text', '');
uibutton(gb, 'Text', 'OK', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) onOk());
uibutton(gb, 'Text', 'Cancel', 'ButtonPushedFcn', @(~, ~) uiresume(d));
d.CloseRequestFcn = @(~, ~) uiresume(d);

ok = false;
uiwait(d);
if ok
    for q = 1:4, files.(rows{q, 1}) = strtrim(ef(q).Value); end
else
    files = [];
end
delete(d);

    function browse(i)
        start = ef(i).Value;
        if isempty(start), start = ef(1).Value; end
        [f, p] = uigetfile(rows{i, 3}, ['Select ' rows{i, 2}], start);
        figure(d);
        if isequal(f, 0), return; end
        ef(i).Value = fullfile(p, f);
        if i == 1
            g = guessTrackFiles(ef(1).Value);
            for r = 2:4
                if isempty(ef(r).Value), ef(r).Value = g.(rows{r, 1}); end
            end
        end
    end

    function clearRow(i)
        ef(i).Value = '';
    end

    function onOk()
        for r = 1:4
            v = strtrim(ef(r).Value);
            if (r == 1 || ~isempty(v)) && ~isfile(v)
                uialert(d, sprintf('%s not found:\n%s', rows{r, 2}, v), 'Select track files');
                return;
            end
        end
        ok = true;
        uiresume(d);
    end
end

function dt = stampOf(name)
tok = regexp(name, '(\d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2})', 'tokens', 'once');
dt = datetime(tok{1}, 'InputFormat', 'yyyy_MM_dd_HH_mm_ss');
end

function v = getf(S, field, n)
if isfield(S, field), v = S.(field)(:); else, v = nan(n, 1); end
end
