function out = force_viewer_v3(rootDir, videoDir, outDir)
%FORCE_VIEWER_V3 Force / pressure / video-track viewer with automatic matching.
%   force_viewer_v3()                  data in ../Forcedata, videos in ../compressedvideo
%   force_viewer_v3(rootDir, videoDir, outDir)   outDir default ../Corrected_video
%
%   Matching
%     A track '<...> L 01 G_track.csv' belongs to 'large size/test 1'
%     (L = large, M = Medim, S = small, Mo = Mo; G = go, R = retraction).
%     Pick it in the "Recording" list and everything is loaded and aligned.
%
%   One time axis per test ("test time")
%     t = 0 at the start of the earliest Force / Pressure record of the test.
%     A record's start = file-name stamp (= save time = end) - its duration.
%     All force files of the test are drawn on this axis; the last one (by
%     time) is the retraction, the earlier ones are the go phase.
%
%   Video placement
%     G video: video start = pressure start (no pressure: first force start)
%     R video: video start = start of the last force file
%     "Video offset" is a small correction on top of that (normally < 20 s).
%
%   "Save corrected" writes a corrected copy to outDir (same sub-folder as in
%   videoDir, e.g. Corrected_video/Eversion/...); the originals are not touched:
%     <name>_track.csv          time_s = test time, video_time_s = original time
%     <name>_track_curves.jsonl.gz   each line gets "time_s" (test time) after "frame"
%   When a corrected CSV exists, its alignment is used the next time.

here = fileparts(mfilename('fullpath'));
if nargin < 1 || isempty(rootDir),  rootDir  = fullfile(here, '..', 'Forcedata'); end
if nargin < 2 || isempty(videoDir), videoDir = fullfile(here, '..', 'compressedvideo'); end
rootDir = canonical(rootDir);
if isfolder(videoDir), videoDir = canonical(videoDir); else, videoDir = ''; end
if nargin < 3 || isempty(outDir), outDir = fullfile(here, '..', 'Corrected_video'); end
if ~isfolder(outDir), mkdir(outDir); end
outDir = canonical(outDir);

REC = buildRecordings(rootDir, videoDir, outDir);
if isempty(REC)
    error('force_viewer:noData', 'No *_data_*.mat files under %s', rootDir);
end

colF   = [0.85 0.33 0.10; 0.30 0.65 0.15; 0.00 0.45 0.74; 0.58 0.40 0.74];
compNm = {'Fx', 'Fy', 'Fz', '|F|'};
colTip = [0.10 0.75 0.75];
colEv  = [1.00 0.35 0.35];
OFF_RANGE = 20;     % default video-offset slider range (s)

D = struct('folder', '');   % loaded test
T = []; F = []; Fm = []; seg = [];   % all force files on test time, NaN rows between files
tP = [];            % pressure time (test time)
TR = [];            % video track
pos = []; spd = []; % tip position (m) and speed (mm/s)
viewWin = [];       % default x range for the current recording
hSegLines = gobjects(0);
lastVidFrame = -1;
vidNext = -1;
vidCache = containers.Map('KeyType', 'double', 'ValueType', 'any');
vidCacheKeys = [];
VID_DECIM = 3;
VID_CACHE_N = 200;
playTimer = [];

%% ---------------- UI ----------------
fig = uifigure('Name', 'Force / Pressure / Video Viewer v3', 'Position', [40 40 1600 960]);
fig.CloseRequestFcn = @onClose;
fig.WindowKeyPressFcn = @onKey;

g = uigridlayout(fig, [5 1]);
g.RowHeight = {'fit', 'fit', '1x', 'fit', 'fit'};

% --- top controls
gc = uigridlayout(g, [2 10]);
gc.RowHeight = {'fit', 'fit'};
gc.ColumnWidth = {'fit', 520, 50, 50, 50, 50, 'fit', 'fit', 'fit', '1x'};
gc.Padding = [0 0 0 0];

uilabel(gc, 'Text', 'Recording:', 'FontWeight', 'bold');
ddRec = uidropdown(gc, 'Items', {REC.label}, 'ItemsData', 1:numel(REC), ...
    'ValueChangedFcn', @(~, ~) selectRecording());
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

gOpt = uigridlayout(gc, [1 8]);
gOpt.Layout.Column = [1 10];
gOpt.Padding = [0 0 0 0];
gOpt.ColumnWidth = {'fit', 'fit', 60, 'fit', 70, 'fit', 'fit', '1x'};
cbZero  = uicheckbox(gOpt, 'Text', 'Zero at start', 'Value', false, 'ValueChangedFcn', @(~, ~) processForce());
uilabel(gOpt, 'Text', 'Smooth (samples):');
spSmooth = uispinner(gOpt, 'Limits', [1 501], 'Step', 2, 'Value', 1, 'ValueChangedFcn', @(~, ~) processForce());
uilabel(gOpt, 'Text', 'P offset (s):');
efOff = uieditfield(gOpt, 'numeric', 'Value', 0, 'ValueChangedFcn', @(~, ~) alignPressure());
uilabel(gOpt, 'Text', 'Pressure:');
gP = uigridlayout(gOpt, [1 3]); gP.Padding = [0 0 0 0]; gP.ColumnWidth = {'fit', 'fit', 'fit'};
cbP1  = uicheckbox(gP, 'Text', 'P1', 'Value', true,  'ValueChangedFcn', @(~, ~) applyVisibility());
cbP1d = uicheckbox(gP, 'Text', 'P1 des', 'Value', true, 'ValueChangedFcn', @(~, ~) applyVisibility());
cbP2  = uicheckbox(gP, 'Text', 'P2', 'Value', false, 'ValueChangedFcn', @(~, ~) applyVisibility());
uilabel(gOpt, 'Text', '');

% --- info row
gi = uigridlayout(g, [1 2]);
gi.ColumnWidth = {'1x', 'fit'};
gi.Padding = [0 0 0 0];
lblInfo = uilabel(gi, 'Text', '', 'FontColor', [0.45 0.45 0.45], 'FontName', 'Consolas');
lblSync = uilabel(gi, 'Text', '', 'FontWeight', 'bold');

% --- plots
gp = uigridlayout(g, [3 2]);
gp.ColumnWidth = {'1x', '1.25x'};
gp.RowHeight = {'1x', '1x', '1x'};
gp.Padding = [0 0 0 0];

ax3 = uiaxes(gp);   ax3.Layout.Row = [1 2]; ax3.Layout.Column = 1;
axC = uiaxes(gp);   axC.Layout.Row = 3;     axC.Layout.Column = 1;
axF = uiaxes(gp);   axF.Layout.Row = 1;     axF.Layout.Column = 2;
axP = uiaxes(gp);   axP.Layout.Row = 2;     axP.Layout.Column = 2;
axT = uiaxes(gp);   axT.Layout.Row = 3;     axT.Layout.Column = 2;

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

hold(axC, 'on'); axis(axC, 'equal'); axC.YDir = 'reverse';
axC.XTick = []; axC.YTick = []; box(axC, 'on');
hImg  = image(axC, 'CData', zeros(2, 2, 3, 'uint8'), 'Visible', 'off');
hBnd  = plot(axC, nan, nan, '-', 'Color', [0.95 0.80 0.20], 'LineWidth', 1.2);
hCtr  = plot(axC, nan, nan, '--', 'Color', [0.6 0.6 0.6], 'LineWidth', 1);
hEv   = plot(axC, nan, nan, '-', 'Color', colEv, 'LineWidth', 3.5);
hCTip = plot(axC, nan, nan, 'o', 'MarkerFaceColor', colEv, 'MarkerEdgeColor', 'w', 'MarkerSize', 9);
title(axC, 'Colon (no video track)');

hold(axF, 'on'); grid(axF, 'on'); box(axF, 'on');
ylabel(axF, 'Force (N)');
hF = gobjects(1, 4);
for q = 1:4
    hF(q) = plot(axF, nan, nan, 'Color', colF(q, :), 'LineWidth', 1 + 0.5 * (q == 4), 'DisplayName', compNm{q});
end
hCurF = xline(axF, 0, '-', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.2, 'HandleVisibility', 'off');
hDotF = plot(axF, nan(1, 4), nan(1, 4), 'ko', 'MarkerFaceColor', 'y', 'HandleVisibility', 'off');
legend(axF, 'Location', 'northwest');

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

hold(axT, 'on'); grid(axT, 'on'); box(axT, 'on');
yyaxis(axT, 'left'); ylabel(axT, 'Tip position (m)');
hPos = plot(axT, nan, nan, '-', 'Color', colTip, 'LineWidth', 1.6, 'DisplayName', 'position');
hDotT = plot(axT, nan, nan, 'ko', 'MarkerFaceColor', 'y', 'HandleVisibility', 'off');
yyaxis(axT, 'right'); ylabel(axT, 'Speed (mm/s)');
hSpd = plot(axT, nan, nan, '-', 'Color', [0.85 0.55 0.20 0.7], 'LineWidth', 0.8, 'DisplayName', 'speed');
axT.YAxis(1).Color = colTip; axT.YAxis(2).Color = [0.85 0.55 0.20];
yyaxis(axT, 'left');
hCurT = xline(axT, 0, '-', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.2, 'HandleVisibility', 'off');
xlabel(axT, 'Test time (s)');
legend(axT, 'Location', 'northwest');
linkaxes([axF axP axT], 'x');

% --- main timeline
gt = uigridlayout(g, [1 5]);
gt.ColumnWidth = {70, '1x', 'fit', 70, 420};
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
gs = uigridlayout(g, [1 16]);
gs.ColumnWidth = {'fit', 'fit', 'fit', '1x', 35, 35, 75, 35, 35, 'fit', 'fit', 'fit', 55, 'fit', 70, 'fit'};
gs.Padding = [0 0 0 0];
uibutton(gs, 'Text', 'Load track...', 'ButtonPushedFcn', @(~, ~) pickTrack());
cbVideo = uicheckbox(gs, 'Text', 'Video frame', 'Value', true, 'ValueChangedFcn', @(~, ~) videoToggled());
uilabel(gs, 'Text', 'Video offset (s):', 'FontWeight', 'bold');
slOff = uislider(gs, 'Limits', [-OFF_RANGE OFF_RANGE], 'Value', 0, ...
    'MajorTicks', -OFF_RANGE:5:OFF_RANGE, 'MinorTicks', -OFF_RANGE:1:OFF_RANGE, ...
    'ValueChangingFcn', @(~, e) dragOffset(e.Value), ...
    'ValueChangedFcn',  @(s, ~) setVideoOffset(s.Value));
uibutton(gs, 'Text', '-1',   'ButtonPushedFcn', @(~, ~) nudgeOffset(-1));
uibutton(gs, 'Text', '-0.1', 'ButtonPushedFcn', @(~, ~) nudgeOffset(-0.1));
efVOff = uieditfield(gs, 'numeric', 'Value', 0, 'ValueDisplayFormat', '%.2f', ...
    'ValueChangedFcn', @(s, ~) setVideoOffset(s.Value));
uibutton(gs, 'Text', '+0.1', 'ButtonPushedFcn', @(~, ~) nudgeOffset(+0.1));
uibutton(gs, 'Text', '+1',   'ButtonPushedFcn', @(~, ~) nudgeOffset(+1));
uibutton(gs, 'Text', 'Offset = 0', 'ButtonPushedFcn', @(~, ~) setVideoOffset(0));
uibutton(gs, 'Text', 'Save corrected', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) saveSync());
uilabel(gs, 'Text', 'Colon L (m):');
efLen = uieditfield(gs, 'numeric', 'Value', 1.5, 'Limits', [0.01 100], ...
    'ValueChangedFcn', @(~, ~) updateTrackCurves());
uilabel(gs, 'Text', 'Speed smooth (s):');
spSpd = uispinner(gs, 'Limits', [0.02 20], 'Step', 0.5, 'Value', 1, 'ValueDisplayFormat', '%.2f', ...
    'ValueChangedFcn', @(~, ~) updateTrackCurves());
lblVid = uilabel(gs, 'Text', 'no video track', 'FontName', 'Consolas', 'FontColor', [0.5 0.5 0.5]);

first = find(~cellfun(@isempty, {REC.csv}), 1);
if isempty(first), first = 1; end
ddRec.Value = first;
selectRecording();
if nargout > 0, out = fig; end

%% ---------------- recordings ----------------
    function selectRecording()
        stopPlay();
        r = REC(ddRec.Value);
        if ~strcmp(r.folder, D.folder)
            loadTest(r.folder);
        end
        if isempty(r.csv)
            clearTrack();
        else
            loadTrack(guessTrackFiles(r.csv), r.role);
        end
        applyVisibility();
    end

%% ---------------- force / pressure data ----------------
    function loadTest(folder)
        dlg = uiprogressdlg(fig, 'Title', 'Loading test', 'Message', folder, 'Indeterminate', 'on');
        cleanup = onCleanup(@() delete(dlg));
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
        if ~isempty(fr)
            [~, o] = sort([fr.tEnd]);
            fr = fr(o);
        end

        p = [];
        if ~isempty(fP)
            [~, o] = sort({fP.name});   % stamp format sorts by time
            fP = fP(o);
            S = load(fullfile(folder, fP(1).name));
            p.name = fP(1).name;
            p.t = S.time_log(:);
            p.P1 = S.P1_log(:);
            p.P1d = getf(S, 'P1_des_log', numel(p.t));
            p.P2 = getf(S, 'P2_log', numel(p.t));
            p.tEnd = stampOf(fP(1).name);
            p.tStart = p.tEnd - seconds(p.t(end) - p.t(1));
            p.nFiles = numel(fP);
        end

        starts = [fr.tStart];
        if ~isempty(p), starts = [starts p.tStart]; end
        t0 = min(starts);
        n = numel(fr);
        for k = 1:n
            fr(k).ts = seconds(fr(k).tStart - t0);
            if n >= 2 && k == n
                fr(k).role = 'retraction';
            else
                fr(k).role = 'go';
            end
        end
        if ~isempty(p), p.ts = seconds(p.tStart - t0); end

        D = struct('folder', folder, 't0', t0, 'force', fr, 'press', p);
        D.label = strrep(erase(folder, [rootDir filesep]), filesep, ' / ');

        % info text
        hh = @(d) char(string(d, 'HH:mm:ss'));
        parts = {sprintf('%s   t0 = %s', D.label, char(string(t0, 'yyyy-MM-dd HH:mm:ss')))};
        for k = 1:n
            parts{end + 1} = sprintf('F%d %s %s-%s (%.0f s)', k, fr(k).role, ...
                hh(fr(k).tStart), hh(fr(k).tEnd), seconds(fr(k).tEnd - fr(k).tStart)); %#ok<AGROW>
        end
        if isempty(p)
            parts{end + 1} = 'no pressure';
        else
            parts{end + 1} = sprintf('P %s-%s', hh(p.tStart), hh(p.tEnd));
            if p.nFiles > 1
                parts{end} = sprintf('%s (+%d more pressure file(s) ignored)', parts{end}, p.nFiles - 1);
            end
        end
        lblInfo.Text = strjoin(parts, '   |   ');
        xlabel(axT, sprintf('Test time (s)   [0 = %s]', hh(t0)));

        % mark the force files on the force plot
        delete(hSegLines);
        hSegLines = gobjects(0);
        for k = 1:n
            nm = fr(k).role;
            if n > 2 && strcmp(nm, 'go'), nm = sprintf('go %d', k); end
            hSegLines(end + 1) = xline(axF, fr(k).ts, ':', nm, 'Color', [0.4 0.4 0.4], ...
                'LabelVerticalAlignment', 'bottom', 'HandleVisibility', 'off'); %#ok<AGROW>
        end

        T = [];
        TR = [];   % the old track belongs to another test; loadTrack / clearTrack follow
        processForce(false);
        alignPressure(false);
    end

    function processForce(doRender)
        if nargin < 1, doRender = true; end
        Tc = []; Fc = []; sc = [];
        w = round(spSmooth.Value);
        ks = phaseIdx();   % G video: go files only, R video: retraction only
        for k = 1:numel(hSegLines)
            hSegLines(k).Visible = ismember(k, ks);
        end
        for k = ks
            fr = D.force(k);
            Fk = fr.F;
            if cbZero.Value
                n0 = max(1, find(fr.T <= fr.T(1) + 0.5, 1, 'last'));
                Fk = Fk - mean(Fk(1:n0, :), 1);
            end
            if w > 1, Fk = movmean(Fk, w, 1); end
            Tc = [Tc; fr.T - fr.T(1) + fr.ts; nan]; %#ok<AGROW>
            Fc = [Fc; Fk; nan(1, 3)];               %#ok<AGROW>
            sc = [sc; k * ones(numel(fr.T), 1); 0];  %#ok<AGROW>
        end
        T = Tc; F = Fc; seg = sc;
        Fm = vecnorm(F, 2, 2);

        for j = 1:3, set(hF(j), 'XData', T, 'YData', F(:, j)); end
        set(hF(4), 'XData', T, 'YData', Fm);
        set(hTrajAll, 'XData', F(:, 1), 'YData', F(:, 2), 'ZData', F(:, 3));

        lo = min([F; 0 0 0], [], 1);
        hi = max([F; 0 0 0], [], 1);
        pad = max([hi - lo, 0.05]) * 0.08;
        axis(ax3, reshape([lo - pad; hi + pad], 1, []));
        if doRender, applyVisibility(); end
    end

    function alignPressure(doRange)
        if nargin < 1, doRange = true; end
        if isempty(D.press)
            tP = [];
            set([hP1 hP1d hP2], 'XData', nan, 'YData', nan);
        else
            p = D.press;
            tP = p.t - p.t(1) + p.ts + efOff.Value;
            set(hP1,  'XData', tP, 'YData', p.P1);
            set(hP1d, 'XData', tP, 'YData', p.P1d);
            set(hP2,  'XData', tP, 'YData', p.P2);
        end
        if doRange, updateRange(); end
    end

    function ks = phaseIdx()
        if isempty(TR) || isempty(TR.forceIdx)
            ks = 1:numel(D.force);
        else
            ks = TR.forceIdx(:)';
        end
        ks = ks(ks >= 1 & ks <= numel(D.force));
    end

    function fitView()
        % x range = the force file(s) of this phase + the video, nothing else
        % (the pressure record can be 10 min long, so it is not included)
        if isempty(TR)
            idx = find(strcmp({D.force.role}, 'go'));
            if isempty(idx), idx = 1:numel(D.force); end
        else
            idx = TR.forceIdx;
        end
        sp = zeros(0, 2);
        for k = idx
            sp(end + 1, :) = D.force(k).ts + [0 D.force(k).T(end) - D.force(k).T(1)]; %#ok<AGROW>
        end
        if ~isempty(TR)
            sp(end + 1, :) = videoStart() + [TR.t(1) TR.t(end)];
        end
        if isempty(sp) && ~isempty(tP), sp = [tP(1) tP(end)]; end
        if isempty(sp), sp = [0 1]; end
        viewWin = [min(sp(:, 1)) - 3, max(sp(:, 2)) + 3];
    end

    function updateRange(v)
        if nargin < 1, v = slider.Value; end
        if isempty(viewWin), fitView(); end
        lim = viewWin;
        if ~(lim(2) > lim(1)), lim = [lim(1) lim(1) + 1]; end
        v = min(max(v, lim(1)), lim(2));
        slider.Limits = lim;
        slider.MajorTicks = round(linspace(lim(1), lim(2), 13), 1);
        slider.MinorTicks = [];
        slider.Value = v;
        xlim(axF, lim);
        render(v, true);
    end

%% ---------------- video track ----------------
    function pickTrack()
        start = videoDir;
        if ~isempty(TR), start = TR.files.csv; end
        [f, p] = uigetfile({'*_track.csv', 'Track CSV (*_track.csv)'}, 'Load track', start);
        figure(fig);
        if isequal(f, 0), return; end
        csv = fullfile(p, f);
        k = find(strcmpi({REC.csv}, csv), 1);
        if ~isempty(k)
            ddRec.Value = k;   % known recording: same as picking it in the list
            selectRecording();
            return;
        end
        [~, base] = fileparts(csv);
        role = 'G';
        tok = parseVideoName(base(1:end - 6));
        if ~isempty(tok), role = tok{3}; end
        uialert(fig, sprintf(['"%s" does not match a test folder.\n' ...
            'It is shown against the current test (%s) as a %s video.'], f, D.label, role), ...
            'Load track', 'Icon', 'warning');
        loadTrack(guessTrackFiles(csv), role);
    end

    function clearTrack()
        TR = [];
        processForce(false);   % no video: show all force files
        viewWin = [];
        resetVideoCache();
        hImg.Visible = 'off';
        set([hBnd hCtr hEv hCTip hPos hPosP hSpd hDotT], 'XData', nan, 'YData', nan);
        title(axC, 'Colon (no video track for this test)');
        title(axT, 'Tip position  —  (no video track)');
        lblVid.Text = 'no video track';
        lblSync.Text = '';
        updateRange();
    end

    function loadTrack(files, role)
        stopPlay();
        dlg = uiprogressdlg(fig, 'Title', 'Loading track', 'Message', 'Reading CSV...');
        cleanup = onCleanup(@() delete(dlg));

        tb = readtable(files.csv);
        files.out = correctedPath(files.csv, videoDir, outDir);
        tr.files = files;
        [~, base] = fileparts(files.csv);
        tr.name = base(1:end - 6);
        tr.role = upper(role);
        tr.frame = tb.frame;
        tr.frac = tb.tip_frac;
        tr.arclen = tb.tip_arclen_px;
        tr.tip = [tb.tip_x tb.tip_y];
        tr.savedStart = [];
        if ismember('video_time_s', tb.Properties.VariableNames)
            % original already carries a sync (saved by an earlier v3 build)
            tr.t = tb.video_time_s;
            tr.savedStart = tb.time_s(1) - tb.video_time_s(1);
        else
            tr.t = tb.time_s;
        end
        if csvIsSynced(files.out)
            try
                tc = readtable(files.out);
                tr.savedStart = tc.time_s(1) - tc.video_time_s(1);
            catch
            end
        end

        % automatic placement
        n = numel(D.force);
        if strcmp(tr.role, 'R') && n >= 1
            tr.anchor = D.force(n).ts;
            tr.anchorTxt = 'start of last force file (retraction)';
            tr.forceIdx = n;
        elseif ~isempty(D.press)
            tr.anchor = D.press.ts;
            tr.anchorTxt = 'pressure start';
            tr.forceIdx = find(strcmp({D.force.role}, 'go'));
        else
            tr.anchor = D.force(1).ts;
            tr.anchorTxt = 'start of first force file';
            tr.forceIdx = find(strcmp({D.force.role}, 'go'));
        end

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
        processForce(false);   % only the force file(s) of this phase
        pos = TR.frac * efLen.Value;
        spd = zeros(size(pos));
        resetVideoCache();

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

        if isempty(TR.savedStart)
            off = 0;
        else
            off = TR.savedStart - TR.anchor;
        end
        setVideoOffset(off, false);
        fitView();
        updateRange(TR.anchor + off);   % start the cursor at the video start
        videoToggled();
    end

    function vs = videoStart()
        vs = TR.anchor + efVOff.Value;
    end

    function updateTrackCurves()
        if isempty(TR), return; end
        pos = TR.frac * efLen.Value;
        w = max(1, round(spSpd.Value / median(diff(TR.t))));
        spd = movmean(gradient(movmean(pos, w)) ./ gradient(TR.t) * 1000, w);
        tv = TR.t + videoStart();
        set(hPos,  'XData', tv, 'YData', pos);
        set(hPosP, 'XData', tv, 'YData', pos);
        set(hSpd,  'XData', tv, 'YData', spd);
        render(slider.Value, true);
    end

    function dragOffset(v)
        % while the offset slider is dragged: never write back to the slider
        % (that fights the mouse and makes it jitter), no range change and
        % no video decoding - only move the curves. Release -> setVideoOffset.
        efVOff.Value = round(v, 2);
        if isempty(TR), return; end
        tv = TR.t + videoStart();
        set(hPos,  'XData', tv);
        set(hPosP, 'XData', tv);
        set(hSpd,  'XData', tv);
        render(slider.Value, false);
    end

    function nudgeOffset(d)
        % reads the edit field at call time (an anonymous function made before
        % efVOff existed cannot see it)
        setVideoOffset(efVOff.Value + d);
    end

    function setVideoOffset(v, doDraw, refit)
        if nargin < 2, doDraw = true; end
        if nargin < 3, refit = true; end   % false while the slider is being dragged
        v = round(v, 2);
        efVOff.Value = v;
        lim = [-OFF_RANGE OFF_RANGE];
        if abs(v) > OFF_RANGE
            lim = [-1 1] * ceil(abs(v) + 5);   % unusual: widen the slider for this value
        end
        if ~isequal(slOff.Limits, lim)
            slOff.Limits = lim;
            if lim(2) == OFF_RANGE
                slOff.MajorTicks = -OFF_RANGE:5:OFF_RANGE;
                slOff.MinorTicks = -OFF_RANGE:1:OFF_RANGE;
            else
                slOff.MajorTicks = round(linspace(lim(1), lim(2), 9));
                slOff.MinorTicks = [];
            end
        end
        slOff.Value = v;
        updateSyncLabel();
        if isempty(TR) || ~doDraw, return; end
        if refit
            fitView();
            updateRange();
        end
        updateTrackCurves();
    end

    function updateSyncLabel()
        if isempty(TR)
            lblSync.Text = '';
            return;
        end
        a = sprintf('%s video placed at %s', TR.role, TR.anchorTxt);
        if isempty(TR.savedStart)
            lblSync.Text = [a '   |   not saved yet'];
            lblSync.FontColor = [0.85 0.45 0.05];
        elseif abs(TR.savedStart - videoStart()) < 0.005
            lblSync.Text = [a '   |   saved in Corrected_video'];
            lblSync.FontColor = [0.15 0.55 0.15];
        else
            lblSync.Text = sprintf('%s   |   changed (saved offset %.2f s)', a, TR.savedStart - TR.anchor);
            lblSync.FontColor = [0.85 0.45 0.05];
        end
    end

    function videoToggled()
        hImg.Visible = cbVideo.Value && ~isempty(TR) && ~isempty(TR.vr);
        lastVidFrame = -1;
        updateTrackCurves();
    end

    function saveSync()
        if isempty(TR)
            uialert(fig, 'No video track loaded.', 'Save corrected');
            return;
        end
        vs = videoStart();
        out = TR.files.out;
        dlg = uiprogressdlg(fig, 'Title', 'Save corrected', 'Message', 'Writing CSV...', 'Indeterminate', 'on');
        cleanup = onCleanup(@() delete(dlg));
        try
            if ~isfolder(fileparts(out)), mkdir(fileparts(out)); end
            tb = readtable(TR.files.csv);
            if ~ismember('video_time_s', tb.Properties.VariableNames)
                tb = addvars(tb, tb.time_s, 'After', 'time_s', 'NewVariableNames', 'video_time_s');
            end
            tb.time_s = round(tb.video_time_s + vs, 4);
            writetable(tb, out);
            outCurves = '';
            if ~isempty(TR.files.curves)
                dlg.Message = 'Writing colon curves with time...';
                [~, cb] = fileparts(out);
                outCurves = fullfile(fileparts(out), [cb '_curves.jsonl.gz']);
                writeCurvesWithTime(TR.files.curves, outCurves, tb.frame, tb.time_s);
            end
        catch err
            uialert(fig, sprintf('Cannot write %s:\n%s', out, err.message), 'Save corrected');
            return;
        end
        TR.savedStart = vs;
        k = find(strcmpi({REC.csv}, TR.files.csv), 1);
        if ~isempty(k) && ~REC(k).synced
            REC(k).synced = true;
            REC(k).label = [REC(k).label '   [synced]'];
            ddRec.Items = {REC.label};
        end
        updateSyncLabel();
        msg = sprintf('%s', out);
        if ~isempty(outCurves), msg = sprintf('%s\n%s', msg, outCurves); end
        uialert(fig, sprintf(['%s\n\ntime_s = test time of %s (0 = %s);\n' ...
            'video time 0 = test time %.2f s (offset %.2f s).\n' ...
            'Original video time kept in column video_time_s. Originals not changed.'], ...
            msg, D.label, char(string(D.t0, 'HH:mm:ss')), vs, efVOff.Value), ...
            'Corrected files saved', 'Icon', 'success');
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
        if isempty(T) && isempty(tP), return; end
        set([hCurF hCurP hCurT], 'Value', t);

        i = 0;
        if ~isempty(T)
            [d, i] = min(abs(T - t));
            if isnan(d) || d > 0.05, i = 0; end
        end
        if i > 0
            f = F(i, :);
            m = Fm(i);
            k = seg(i);
            i0 = find(seg == k, 1);
            set(hTraj, 'XData', F(i0:i, 1), 'YData', F(i0:i, 2), 'ZData', F(i0:i, 3));
        else
            f = nan(1, 3); m = nan; k = 0;
            set(hTraj, 'XData', nan, 'YData', nan, 'ZData', nan);
        end

        set(hQ(1), 'UData', f(1), 'VData', 0, 'WData', 0);
        set(hQ(2), 'UData', 0, 'VData', f(2), 'WData', 0);
        set(hQ(3), 'UData', 0, 'VData', 0, 'WData', f(3));
        set(hQ(4), 'UData', f(1), 'VData', f(2), 'WData', f(3));
        set(hTip, 'XData', f(1), 'YData', f(2), 'ZData', f(3));
        px = [f(1) f(1) nan f(1) f(1) nan f(1) 0    nan f(1) f(1) nan 0    f(1) nan 0    0   ];
        py = [f(2) f(2) nan f(2) 0    nan 0    0    nan f(2) 0    nan f(2) f(2) nan f(2) 0   ];
        pz = [f(3) 0    nan 0    0    nan 0    0    nan f(3) f(3) nan 0    0    nan 0    0   ];
        set(hProj, 'XData', px, 'YData', py, 'ZData', pz);

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

        if k > 0
            fname = sprintf('F%d %s', k, D.force(k).role);
            title(ax3, sprintf('t = %.2f s   |F| = %.3f N   (%s)', t, m, fname));
            title(axF, sprintf('Fx = %+.3f   Fy = %+.3f   Fz = %+.3f   |F| = %.3f N   [%s]', f, m, fname));
        else
            title(ax3, sprintf('t = %.2f s   (no force record)', t));
            title(axF, 'Force  —  (no data at this time)');
        end
        lblTime.Text = sprintf('t = %7.2f s  (%s)%s', t, ...
            char(string(D.t0 + seconds(t), 'HH:mm:ss.SS')), pStr);

        renderTrack(t, final);
        drawnow limitrate;
    end

    function renderTrack(t, final)
        if isempty(TR), return; end
        tv = t - videoStart();
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
            case 'period',     v = slider.Value + 0.02;
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

%% ======================= helpers =======================
function REC = buildRecordings(rootDir, videoDir, outDir)
%BUILDRECORDINGS One entry per (test folder, track CSV); tests without a track get one entry.
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
            fprintf(2, 'force_viewer_v3: no test folder for track "%s"\n', tc(i).name);
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
%PARSEVIDEONAME 'Mvi 1385  L 01 G' -> {'L', '01', 'G'}; {} when it does not match.
tok = regexp(vname, '(?<![A-Za-z])(Mo|MO|mo|L|M|S)\s*(\d+)\s*([GRgr])(?![A-Za-z])', 'tokens', 'once');
if ~isempty(tok), tok{3} = upper(tok{3}); end
end

function tf = sizeMatches(grp, code)
%SIZEMATCHES Folder names (lower case) that belong to a size code.
switch lower(code)
    case 'mo', tf = strcmp(grp, 'mo') | startsWith(grp, 'mo ');
    case 'l',  tf = startsWith(grp, 'large');
    case 'm',  tf = startsWith(grp, 'med');
    case 's',  tf = startsWith(grp, 'small');
    otherwise, tf = false(size(grp));
end
end

function out = correctedPath(csv, videoDir, outDir)
%CORRECTEDPATH Where the corrected copy of a track CSV goes (same sub-folder under outDir).
[folder, base, ext] = fileparts(csv);
rel = '';
if ~isempty(videoDir) && startsWith(lower(folder), lower(videoDir))
    rel = regexprep(folder(numel(videoDir) + 1:end), '^[\\/]+', '');
end
out = fullfile(outDir, rel, [base ext]);
end

function writeCurvesWithTime(src, dst, frames, tvals)
%WRITECURVESWITHTIME Copy a curves .jsonl[.gz] and put "time_s" after "frame" on every line.
tmp = tempname;
mkdir(tmp);
rmTmp = onCleanup(@() removeTemp(tmp));
if endsWith(src, '.gz', 'IgnoreCase', true)
    f = gunzip(src, tmp);
    src = f{1};
end
lines = splitlines(fileread(src));
lines(cellfun('isempty', lines)) = [];
lines = regexprep(lines, ',"time_s":[^,]*', '', 'once');      % re-save: drop an old time
fr = regexp(lines, '^\{"frame":(-?\d+)', 'tokens', 'once');
fr = cellfun(@(c) c{1}, fr, 'UniformOutput', false);
[ok, loc] = ismember(str2double(fr), frames);
tt = repmat({'null'}, size(lines));
tt(ok) = compose('%.4f', tvals(loc(ok)));
rest = regexprep(lines, '^\{"frame":-?\d+', '', 'once');
lines = strcat('{"frame":', fr, ',"time_s":', tt, rest);
[~, nm] = fileparts(dst);          % '<base>_curves.jsonl'
plain = fullfile(tmp, 'out', nm);
mkdir(fileparts(plain));
fid = fopen(plain, 'w', 'n', 'UTF-8');
fprintf(fid, '%s\n', lines{:});
fclose(fid);
gzip(plain, fileparts(dst));
end

function tf = csvIsSynced(csv)
tf = false;
fid = fopen(csv, 'r');
if fid < 0, return; end
h = fgetl(fid);
fclose(fid);
tf = ischar(h) && contains(h, 'video_time_s');
end

function [B, C] = loadCurves(jsonl, dlg)
%LOADCURVES Read '<video>_track_curves.jsonl[.gz]' (boundary + centerline per frame).
%   Cached in tempdir (same cache as force_viewer_v2).
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

if endsWith(jsonl, '.gz', 'IgnoreCase', true)
    dlg.Message = 'Unzipping colon curves...';
    tmp = tempname;
    mkdir(tmp);
    rmTmp = onCleanup(@() removeTemp(tmp));
    out = gunzip(jsonl, tmp);
    jsonl = out{1};
    info = dir(jsonl);
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
delete(closer);    % close the file now, so the temp folder can be removed
B = B(:, :, 1:k); C = C(:, :, 1:k); fr = fr(1:k); %#ok<NASGU>
dlg.Message = 'Caching...';
save(cache, 'B', 'C', 'fr', '-v7.3');
end

function p = guessTrackFiles(csv)
%GUESSTRACKFILES Same-name files next to '<video>_track.csv' ('' when missing).
%   The video may differ in spacing ('Mvi 1378 M 01 G' vs 'Mvi 1378  M 01 G.mp4').
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
% best effort: a left-over temp folder is harmless
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
