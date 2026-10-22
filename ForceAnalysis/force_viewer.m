function out = force_viewer(rootDir)
%FORCE_VIEWER Interactive viewer for Force_data / Pressure_data recordings.
%   force_viewer()          scans ../Forcedata (relative to this file)
%   force_viewer(rootDir)   scans rootDir recursively for test folders
%
%   - Drag the timeline slider (or press Play / arrow keys) to scrub time.
%   - Fx / Fy / Fz / |F| toggle buttons show each component alone or together.
%   - Left: 3D force vectors (components + resultant) and the resultant-tip
%     trajectory. Right: force curves and pressure curves with a time cursor.
%
%   Force and pressure are aligned using the timestamps in the file names
%   (= save time, i.e. end of recording). Use "P offset" to fine-tune.

if nargin < 1
    rootDir = fullfile(fileparts(mfilename('fullpath')), '..', 'Forcedata');
end
rootDir = dir(rootDir); rootDir = rootDir(1).folder;   % canonical path

files = dir(fullfile(rootDir, '**', '*_data_*.mat'));
if isempty(files)
    error('force_viewer:noData', 'No *_data_*.mat files under %s', rootDir);
end
testFolders = unique({files.folder});
testLabels  = erase(testFolders, [rootDir filesep]);

colF   = [0.85 0.33 0.10; 0.30 0.65 0.15; 0.00 0.45 0.74; 0.58 0.40 0.74];
compNm = {'Fx', 'Fy', 'Fz', '|F|'};

D = struct();       % loaded data of the current test
F = []; Fm = [];    % processed force (n x 3) and magnitude
T = []; tP = [];    % force time, pressure time (in force time frame)
playTimer = [];

%% ---------------- UI ----------------
fig = uifigure('Name', 'Force / Pressure Viewer', 'Position', [80 60 1400 820]);
fig.CloseRequestFcn = @onClose;
fig.WindowKeyPressFcn = @onKey;

g = uigridlayout(fig, [3 1]);
g.RowHeight = {'fit', '1x', 'fit'};

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
for k = 1:4
    btn(k) = uibutton(gc, 'state', 'Text', compNm{k}, 'Value', true, ...
        'FontWeight', 'bold', 'FontColor', colF(k, :), ...
        'ValueChangedFcn', @(~, ~) applyVisibility());
end
cbVec  = uicheckbox(gc, 'Text', 'Vectors 3D', 'Value', true, 'ValueChangedFcn', @(~, ~) applyVisibility());
cbTraj = uicheckbox(gc, 'Text', 'Trajectory', 'Value', true, 'ValueChangedFcn', @(~, ~) applyVisibility());
cbProj = uicheckbox(gc, 'Text', 'Projections', 'Value', true, 'ValueChangedFcn', @(~, ~) applyVisibility());

uilabel(gc, 'Text', '');
lblInfo = uilabel(gc, 'Text', '', 'FontColor', [0.4 0.4 0.4]);
lblInfo.Layout.Column = [2 4];
gOpt = uigridlayout(gc, [1 8]);
gOpt.Layout.Column = [5 12];
gOpt.Padding = [0 0 0 0];
gOpt.ColumnWidth = {'fit', 'fit', 'fit', 60, 'fit', 70, 'fit', 'fit'};
cbZero = uicheckbox(gOpt, 'Text', 'Zero at start', 'Value', false, 'ValueChangedFcn', @(~, ~) processForce());
cbFull = uicheckbox(gOpt, 'Text', 'Full pressure range', 'Value', false, 'ValueChangedFcn', @(~, ~) updateRange());
uilabel(gOpt, 'Text', 'Smooth (samples):');
spSmooth = uispinner(gOpt, 'Limits', [1 501], 'Step', 2, 'Value', 1, 'ValueChangedFcn', @(~, ~) processForce());
uilabel(gOpt, 'Text', 'P offset (s):');
efOff = uieditfield(gOpt, 'numeric', 'Value', 0, 'ValueChangedFcn', @(~, ~) alignPressure());
uilabel(gOpt, 'Text', 'Pressure:');
gP = uigridlayout(gOpt, [1 3]); gP.Padding = [0 0 0 0]; gP.ColumnWidth = {'fit', 'fit', 'fit'};
cbP1  = uicheckbox(gP, 'Text', 'P1', 'Value', true,  'ValueChangedFcn', @(~, ~) applyVisibility());
cbP1d = uicheckbox(gP, 'Text', 'P1 des', 'Value', true, 'ValueChangedFcn', @(~, ~) applyVisibility());
cbP2  = uicheckbox(gP, 'Text', 'P2', 'Value', false, 'ValueChangedFcn', @(~, ~) applyVisibility());

% --- plots
gp = uigridlayout(g, [2 2]);
gp.ColumnWidth = {'1x', '1.3x'};
gp.RowHeight = {'1.2x', '1x'};
gp.Padding = [0 0 0 0];

ax3 = uiaxes(gp); ax3.Layout.Row = [1 2]; ax3.Layout.Column = 1;
axF = uiaxes(gp); axF.Layout.Row = 1; axF.Layout.Column = 2;
axP = uiaxes(gp); axP.Layout.Row = 2; axP.Layout.Column = 2;

% 3D axes
hold(ax3, 'on'); grid(ax3, 'on'); box(ax3, 'on');
view(ax3, 35, 22); axis(ax3, 'equal');
xlabel(ax3, 'Fx (N)'); ylabel(ax3, 'Fy (N)'); zlabel(ax3, 'Fz (N)');
hTrajAll = plot3(ax3, nan, nan, nan, '-', 'Color', [0.6 0.6 0.6 0.35], 'LineWidth', 0.5);
hTraj    = plot3(ax3, nan, nan, nan, '-', 'Color', [colF(4, :) 0.9], 'LineWidth', 1.2);
hProj    = plot3(ax3, nan, nan, nan, ':', 'Color', [0.5 0.5 0.5], 'LineWidth', 1);
hQ = gobjects(1, 4);
for k = 1:4
    hQ(k) = quiver3(ax3, 0, 0, 0, 0, 0, 0, 0, 'Color', colF(k, :), ...
        'LineWidth', 2 + (k == 4), 'MaxHeadSize', 0.4, 'AutoScale', 'off');
end
hTip = plot3(ax3, nan, nan, nan, 'o', 'MarkerFaceColor', colF(4, :), 'MarkerEdgeColor', 'w', 'MarkerSize', 7);
plot3(ax3, 0, 0, 0, '.', 'Color', [0.5 0.5 0.5], 'MarkerSize', 14);

% force time series
hold(axF, 'on'); grid(axF, 'on'); box(axF, 'on');
ylabel(axF, 'Force (N)');
hF = gobjects(1, 4);
for k = 1:4
    hF(k) = plot(axF, nan, nan, 'Color', colF(k, :), 'LineWidth', 1 + 0.5 * (k == 4), 'DisplayName', compNm{k});
end
hCurF = xline(axF, 0, '-', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.2, 'HandleVisibility', 'off');
hDotF = plot(axF, nan(1, 4), nan(1, 4), 'ko', 'MarkerFaceColor', 'y', 'HandleVisibility', 'off');
legend(axF, 'Location', 'northeast');

% pressure time series
hold(axP, 'on'); grid(axP, 'on'); box(axP, 'on');
xlabel(axP, 'Time (s)'); ylabel(axP, 'Pressure');
hP1  = plot(axP, nan, nan, '-',  'Color', [0.49 0.18 0.56], 'LineWidth', 1.3, 'DisplayName', 'P1');
hP1d = plot(axP, nan, nan, '--', 'Color', [0.93 0.69 0.13], 'LineWidth', 1.2, 'DisplayName', 'P1 des');
hP2  = plot(axP, nan, nan, '-',  'Color', [0.30 0.75 0.93], 'LineWidth', 1.0, 'DisplayName', 'P2');
hCurP = xline(axP, 0, '-', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.2, 'HandleVisibility', 'off');
hDotP = plot(axP, nan, nan, 'ko', 'MarkerFaceColor', 'y', 'HandleVisibility', 'off');
legend(axP, 'Location', 'northeast');
linkaxes([axF axP], 'x');

% --- timeline
gt = uigridlayout(g, [1 5]);
gt.ColumnWidth = {70, '1x', 'fit', 70, 'fit'};
gt.Padding = [0 0 0 0];
btnPlay = uibutton(gt, 'Text', 'Play', 'ButtonPushedFcn', @(~, ~) togglePlay());
slider = uislider(gt, 'Limits', [0 1], 'Value', 0, ...
    'ValueChangingFcn', @(~, e) render(e.Value), ...
    'ValueChangedFcn',  @(s, ~) render(s.Value));
uilabel(gt, 'Text', 'Speed:');
ddSpeed = uidropdown(gt, 'Items', {'0.25x', '0.5x', '1x', '2x', '5x', '10x'}, ...
    'ItemsData', [0.25 0.5 1 2 5 10], 'Value', 1);
lblTime = uilabel(gt, 'Text', 't = 0.00 s', 'FontName', 'Consolas', 'FontSize', 13);

loadTest();
if nargout > 0, out = fig; end   % do not clear fig: callbacks share it

%% ---------------- data ----------------
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
        render(slider.Value);
    end

    function alignPressure()
        if isempty(D.press)
            tP = [];
            set([hP1 hP1d hP2], 'XData', nan, 'YData', nan);
            title(axP, 'no pressure file');
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
        if cbFull.Value && ~isempty(tP)
            lim = [min(lim(1), tP(1)) max(lim(2), tP(end))];
        end
        v = min(max(slider.Value, lim(1)), lim(2));
        slider.Limits = lim;
        slider.MajorTicks = round(linspace(lim(1), lim(2), 13), 1);
        slider.MinorTicks = [];
        slider.Value = v;
        xlim(axF, lim);
        render(v);
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
        render(slider.Value);
    end

    function render(t)
        if isempty(T), return; end
        lblTime.Text = sprintf('t = %7.2f s', t);
        hCurF.Value = t;
        hCurP.Value = t;

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
            pStr = sprintf('   P1 = %.2f  (des %.2f)', pv, pd);
            title(axP, sprintf('Pressure  —  P1 = %.2f, P1 des = %.2f', pv, pd));
        elseif ~isempty(tP)
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
        drawnow limitrate;
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
        render(v);
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
            case 'space', togglePlay(); return;
            otherwise, return;
        end
        slider.Value = min(max(v, slider.Limits(1)), slider.Limits(2));
        render(slider.Value);
    end

    function onClose(~, ~)
        stopPlay();
        delete(fig);
    end
end

function dt = stampOf(name)
tok = regexp(name, '(\d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2})', 'tokens', 'once');
dt = datetime(tok{1}, 'InputFormat', 'yyyy_MM_dd_HH_mm_ss');
end

function v = getf(S, field, n)
if isfield(S, field), v = S.(field)(:); else, v = nan(n, 1); end
end
