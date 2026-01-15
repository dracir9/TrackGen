classdef TrackGen < matlab.apps.AppBase

    % Properties that correspond to app components
    properties (Access = public)
        UIFigure             matlab.ui.Figure
        GridLayout           matlab.ui.container.GridLayout
        LeftPanel            matlab.ui.container.Panel
        SidePanelGrid        matlab.ui.container.GridLayout
        GenerateButton       matlab.ui.control.Button
        SaveButton           matlab.ui.control.Button
        LoadButton           matlab.ui.control.Button
        TabGroup             matlab.ui.container.TabGroup
        Tab_Add              matlab.ui.container.Tab
        RightPanel           matlab.ui.container.Panel
        TabGroup2            matlab.ui.container.TabGroup
        TrajectoryPlotTab    matlab.ui.container.Tab
        LocalKinematicsTab   matlab.ui.container.Tab
        startTimeField       matlab.ui.control.NumericEditField
        timeSlider           matlab.ui.control.RangeSlider
        endTimeField         matlab.ui.control.NumericEditField
        TrajectoryAxes       matlab.graphics.axis.Axes
        JerkAxes             matlab.graphics.axis.Axes
        AccelAxes            matlab.graphics.axis.Axes
        VelocityAxes         matlab.graphics.axis.Axes
        WheelVelAxes         matlab.graphics.axis.Axes
    end

    % Private properties that store app data
    properties (Access = private)
        onePanelWidth = 500;
        isDarkMode = false;

        plotColors      (:,3)   double = []; % RGB colors for plotting trajectories

        trajectories        struct = struct('ID', {}, 'Tab', [], 'Grid', [], 'Settings', [], ...
                'CommandBox', [], 'Commands', [], ...
                'Plots', [], ...
                'AddButton', [], 'RemoveButton', []);

        sampleTime = 0.005; % Sample time for simulation (s)

        timeVector  (:,1)   double = []; % Time vector for simulation (s)
        simulationData      struct  = struct('globalState', {}, 'wheelVelocities', {}); % Structure to hold simulation data

        % Omnidirectional robot parameters
        wheelRadius     (1,3)   double  = [0.15, 0.15, 0.15];       % Wheel radii (m)
        robotRadius     (1,3)   double  = [0.195, 0.195, 0.195];    % Distance from robot center to wheel (m)
        wheelAngles     (1,3)   double  = [150, 270, 30];           % Wheel angles (degrees)
        IK              (3,3)   double                              % Inverse kinematics matrix
    end

    % Callbacks that handle component events
    methods (Access = private)

        % Selection change function: TabGroup
        function TabGroupSelectionChanged(app, event)
            if event.NewValue.Title == '+'
                app.addTrajectoryTab();

                if strcmp(app.TabGroup.SelectedTab.Title, '+')
                    app.TabGroup.SelectedTab = event.OldValue;
                end
            end
        end

        function toggleJerkSettings(app, tab)
            % Toggle enable/disable of jerk ratio based on checkbox state
            
            trajectoryID = tab.UserData;
            if ~isempty(app.trajectories(trajectoryID))
                settings = app.trajectories(trajectoryID).Settings;
                if settings.EnableJerkCheckBox.Value
                    settings.JerkRatioLabel.Enable = 'on';
                    settings.JerkRatioEditField.Enable = 'on';
                else
                    settings.JerkRatioLabel.Enable = 'off';
                    settings.JerkRatioEditField.Enable = 'off';
                end
            end
        end

        function toggleAccelSettings(app, tab)
            % Toggle enable/disable of acceleration time based on checkbox state
            
            trajectoryID = tab.UserData;
            if ~isempty(app.trajectories(trajectoryID))
                settings = app.trajectories(trajectoryID).Settings;
                if settings.EnableAccelCheckBox.Value
                    settings.EnableJerkCheckBox.Enable = 'on';
                    if settings.EnableJerkCheckBox.Value
                        settings.JerkRatioLabel.Enable = 'on';
                        settings.JerkRatioEditField.Enable = 'on';
                    end
                    settings.AccelTimeLabel.Enable = 'on';
                    settings.AccelTimeEditField.Enable = 'on';
                else
                    settings.EnableJerkCheckBox.Enable = 'off';
                    settings.JerkRatioLabel.Enable = 'off';
                    settings.JerkRatioEditField.Enable = 'off';
                    settings.AccelTimeLabel.Enable = 'off';
                    settings.AccelTimeEditField.Enable = 'off';
                end
            end
        end

        % Button pushed function: GenerateButton
        function GenerateButtonPushed(app, ~)
            try
                app.timeVector = [];

                % Generate trajectories for all trajectory tabs
                for i = 1:length(app.trajectories)
                    if ~isempty(app.trajectories(i))
                        app.generateTrajectory(i);
                    end
                end

                % Update time window
                app.updateTimeWindow();

                % Update plots
                app.updatePlots();
            catch ME
                report = getReport(ME);
                uialert(app.UIFigure, sprintf('Error generating trajectory:\n%s', report), ...
                    'Generation Error', 'Interpreter', 'html');
            end
        end

        % Button pushed function: SaveButton
        function SaveButtonPushed(app, ~)
            try
                app.saveTrajectoryToFile();
            catch ME
                report = getReport(ME);
                uialert(app.UIFigure, sprintf('Error saving trajectory:\n%s', report), ...
                    'Save Error', 'Interpreter', 'html');
            end
        end

        % Button pushed function: LoadButton
        function LoadButtonPushed(app, ~)
            try
                app.loadTrajectoryFromFile();
            catch ME
                report = getReport(ME);
                uialert(app.UIFigure, sprintf('Error loading trajectory:\n%s', report), ...
                    'Load Error', 'Interpreter', 'html');
            end
        end

        function changeCommandType(app, panel)
            trajectoryID = panel.UserData(1);
            commandID = panel.UserData(2);

            command = app.trajectories(trajectoryID).Commands{commandID};

            % Remove existing fields and grid
            if isfield(command, 'Grid') && isvalid(command.Grid)
                delete(command.Grid);
            end

            if isfield(command, 'Fields')
                command.Fields = struct();
            end

            % Recreate command panel based on new type
            cmdType = command.TypeDropDown.Value;
            command = app.createCmdFields(command, cmdType);

            app.trajectories(trajectoryID).Commands{commandID} = command;
        end

        % Changes arrangement of the app based on UIFigure width
        function updateAppLayout(app, ~)
            currentFigureWidth = app.UIFigure.Position(3);
            if(currentFigureWidth <= app.onePanelWidth)
                % Change to a 2x1 grid
                app.GridLayout.RowHeight = {711, 711};
                app.GridLayout.ColumnWidth = {'1x'};
                app.RightPanel.Layout.Row = 2;
                app.RightPanel.Layout.Column = 1;
            else
                % Change to a 1x2 grid
                app.GridLayout.RowHeight = {'1x'};
                app.GridLayout.ColumnWidth = {427, '1x'};
                app.RightPanel.Layout.Row = 1;
                app.RightPanel.Layout.Column = 2;
            end
        end

        function updateAspectRatios(app)
            if isempty(app.TrajectoryAxes)
                return;
            end

            % Reset to auto aspect ratio
            app.TrajectoryAxes.DataAspectRatioMode = 'auto';
            app.TrajectoryAxes.PlotBoxAspectRatioMode = 'auto';

            % Reset limits to auto to get correct aspect ratio
            app.TrajectoryAxes.XLimMode = 'auto';
            app.TrajectoryAxes.YLimMode = 'auto';

            % Get new aspect ratio
            newRatio = app.TrajectoryAxes.PlotBoxAspectRatio;

            % Reactivate axis equal
            app.TrajectoryAxes.DataAspectRatio = [1 1 1];
            app.TrajectoryAxes.PlotBoxAspectRatio = newRatio;
        end

        function updateKinematicMatrix(app)
            epsilon = app.wheelAngles + pi/2;
            app.IK = [cos(epsilon(1)) * 60/(2*pi*app.wheelRadius(1)), sin(epsilon(1)) * 60/(2*pi*app.wheelRadius(1)), app.robotRadius(1) * 60/(2*pi*app.wheelRadius(1));
                      cos(epsilon(2)) * 60/(2*pi*app.wheelRadius(2)), sin(epsilon(2)) * 60/(2*pi*app.wheelRadius(2)), app.robotRadius(2) * 60/(2*pi*app.wheelRadius(2));
                      cos(epsilon(3)) * 60/(2*pi*app.wheelRadius(3)), sin(epsilon(3)) * 60/(2*pi*app.wheelRadius(3)), app.robotRadius(3) * 60/(2*pi*app.wheelRadius(3))];
        end

        function updateTimeFieldsFromSlider(app, updatePlot)
            app.startTimeField.Value = app.timeSlider.Value(1);
            app.endTimeField.Value = app.timeSlider.Value(2);

            if updatePlot
                app.updatePlots();
            end
        end

        function updateTimeSliderFromFields(app)
            minTime = round(app.startTimeField.Value/0.1)*0.1;
            maxTime = round(app.endTimeField.Value/0.1)*0.1;

            if app.startTimeField.Value > app.timeSlider.Value(2)
                maxTime = minTime;
            end
            if app.endTimeField.Value < app.timeSlider.Value(1)
                minTime = maxTime;
            end
            app.timeSlider.Value = [minTime, maxTime];

            app.startTimeField.Value = minTime;
            app.endTimeField.Value = maxTime;

            app.updatePlots();
        end
    end

    % Component initialization
    methods (Access = private)

        % Create UIFigure and components
        function createComponents(app)

            % Create UIFigure and hide until all components are created
            app.UIFigure = uifigure('Visible', 'on'); % TODO: Set to 'on' for testing. Change to 'off' for final.
            app.UIFigure.AutoResizeChildren = 'off';
            % If system has multiple monitors, position the figure on the second monitor
            screens = get(0, 'MonitorPositions');
            if size(screens, 1) > 1
                app.UIFigure.Position = [screens(2,1) + 100 screens(2,2) + 100 1280 720];
                app.UIFigure.WindowState = "maximized";
            else
                app.UIFigure.Position = [100 100 1280 720];
            end
            app.UIFigure.Name = 'TrackGen App';
            app.UIFigure.SizeChangedFcn = createCallbackFcn(app, @updateAppLayout, true);

            if strcmp(theme(app.UIFigure).BaseColorStyle, 'dark')
                app.isDarkMode = true;
            end

            if app.isDarkMode
                app.plotColors = orderedcolors("glow12");
            else
                app.plotColors = orderedcolors("gem12");
            end

            % Create GridLayout
            app.GridLayout = uigridlayout(app.UIFigure);
            app.GridLayout.ColumnWidth = {400, '1x'};
            app.GridLayout.RowHeight = {'1x'};
            app.GridLayout.ColumnSpacing = 0;
            app.GridLayout.RowSpacing = 0;
            app.GridLayout.Padding = [0 0 0 0];
            app.GridLayout.Scrollable = 'on';

            % Create LeftPanel
            app.LeftPanel = uipanel(app.GridLayout);
            app.LeftPanel.Layout.Row = 1;
            app.LeftPanel.Layout.Column = 1;

            % Create SidePanelGrid
            app.SidePanelGrid = uigridlayout(app.LeftPanel);
            app.SidePanelGrid.ColumnWidth = {'1x', '1x'};
            app.SidePanelGrid.RowHeight = {'1x', 50, 50};
            app.SidePanelGrid.Padding = [5 5 5 5];

            % Create TabGroup
            app.TabGroup = uitabgroup(app.SidePanelGrid);
            app.TabGroup.Layout.Row = 1;
            app.TabGroup.Layout.Column = [1 2];
            app.TabGroup.SelectionChangedFcn = createCallbackFcn(app, @TabGroupSelectionChanged, true);

            % Create Tab_Add
            app.Tab_Add = uitab(app.TabGroup);
            app.Tab_Add.Title = '+';

            % Create GenerateButton
            app.GenerateButton = uibutton(app.SidePanelGrid, 'push');
            app.GenerateButton.Text = 'Generate';
            app.GenerateButton.Layout.Row = 2;
            app.GenerateButton.Layout.Column = [1 2];
            app.GenerateButton.ButtonPushedFcn = createCallbackFcn(app, @GenerateButtonPushed, true);

            % Create SaveButton
            app.SaveButton = uibutton(app.SidePanelGrid, 'push');
            app.SaveButton.Text = 'Save Trajectory';
            app.SaveButton.Layout.Row = 3;
            app.SaveButton.Layout.Column = 1;
            app.SaveButton.ButtonPushedFcn = createCallbackFcn(app, @SaveButtonPushed, true);

            % Create LoadButton
            app.LoadButton = uibutton(app.SidePanelGrid, 'push');
            app.LoadButton.Text = 'Load Trajectory';
            app.LoadButton.Layout.Row = 3;
            app.LoadButton.Layout.Column = 2;
            app.LoadButton.ButtonPushedFcn = createCallbackFcn(app, @LoadButtonPushed, true);

            % Create RightPanel
            app.RightPanel = uipanel(app.GridLayout);
            app.RightPanel.Layout.Row = 1;
            app.RightPanel.Layout.Column = 2;

            % Create FillGrid2
            fillGrid = uigridlayout(app.RightPanel);
            fillGrid.ColumnWidth = {'1x'};
            fillGrid.RowHeight = {'1x'};
            fillGrid.Padding = [5 5 5 5];

            % Create TabGroup2
            app.TabGroup2 = uitabgroup(fillGrid);
            app.TabGroup2.Layout.Row = 1;
            app.TabGroup2.Layout.Column = 1;

            % Create TrajectoryTab
            app.TrajectoryPlotTab = uitab(app.TabGroup2);
            app.TrajectoryPlotTab.Title = 'Trajectory';

            % Create LocalKinematicsTab
            app.LocalKinematicsTab = uitab(app.TabGroup2);
            app.LocalKinematicsTab.Title = 'Local Kinematics';

            % Create axes and tabs
            app.createAxes();

            % Add the first trajectory tab
            app.addTrajectoryTab();

            % Show the figure after all components are created
            app.UIFigure.Visible = 'on';
        end

        function createAxes(app)
            % Create TrajectoryAxes
            trajctoryGrid = uigridlayout(app.TrajectoryPlotTab);
            trajctoryGrid.ColumnWidth = {50, '1x', 50};
            trajctoryGrid.RowHeight = {'1x', 'fit'};
            trajctoryGrid.Padding = [5 5 5 5];

            % Create TrajectoryAxes
            app.TrajectoryAxes = uiaxes(trajctoryGrid);
            app.TrajectoryAxes.Layout.Row = 1;
            app.TrajectoryAxes.Layout.Column = [1 3];
            title(app.TrajectoryAxes, 'Trajectory Plot')
            xlabel(app.TrajectoryAxes, 'X [m]')
            ylabel(app.TrajectoryAxes, 'Y [m]')
            grid(app.TrajectoryAxes, 'on');
            grid(app.TrajectoryAxes, 'minor');
            box(app.TrajectoryAxes, 'on');
            axis(app.TrajectoryAxes, 'equal');
            % addlistener(app.TrajectoryAxes, 'OuterPositionChanged', @(src, evt) app.updateAspectRatios());

            app.startTimeField = uieditfield(trajctoryGrid, 'numeric');
            app.startTimeField.Layout.Row = 2;
            app.startTimeField.Layout.Column = 1;
            app.startTimeField.Value = 0;
            app.startTimeField.Limits = [0 10];
            app.startTimeField.UpperLimitInclusive = 'off';
            app.startTimeField.ValueDisplayFormat = '%11.4g s';
            app.startTimeField.ValueChangedFcn = @(s,e) app.updateTimeSliderFromFields();

            app.timeSlider = uislider(trajctoryGrid, "range");
            app.timeSlider.Layout.Row = 2;
            app.timeSlider.Layout.Column = 2;
            app.timeSlider.Limits = [0 10];
            app.timeSlider.Step = 0.05;
            app.timeSlider.ValueChangedFcn = @(s,e) app.updateTimeFieldsFromSlider(true);
            app.timeSlider.ValueChangingFcn = @(s,e) app.updateTimeFieldsFromSlider(false);

            app.endTimeField = uieditfield(trajctoryGrid, 'numeric');
            app.endTimeField.Layout.Row = 2;
            app.endTimeField.Layout.Column = 3;
            app.endTimeField.Value = 10;
            app.endTimeField.Limits = [0 10];
            app.endTimeField.LowerLimitInclusive = 'off';
            app.endTimeField.ValueDisplayFormat = '%11.4g s';
            app.endTimeField.ValueChangedFcn = @(s,e) app.updateTimeSliderFromFields();

            % Create grid for Local Kinematics tab
            kinematicsGrid = uigridlayout(app.LocalKinematicsTab);
            kinematicsGrid.ColumnWidth = {'1x'};
            kinematicsGrid.RowHeight = {'1x'};
            kinematicsGrid.Padding = [0 0 0 10];

            % Create dummy panel for proper padding
            layoutPanel = uipanel(kinematicsGrid);
            layoutPanel.BorderType = 'none';

            % Create layout for kinematics plots
            t1 = tiledlayout(layoutPanel, 4, 1, 'padding', 'compact', 'TileSpacing', 'compact');

            % Jerk Axes
            app.JerkAxes = nexttile(t1);
            ylabel(app.JerkAxes, 'Jerk [m/s^3]')
            grid(app.JerkAxes, 'on');
            grid(app.JerkAxes, 'minor');
            box(app.JerkAxes, 'on');
            app.JerkAxes.XTickLabel = [];
            axColor = app.JerkAxes.YAxis.Color;
            yyaxis(app.JerkAxes, 'right');
            ylabel(app.JerkAxes, 'Jerk [rad/s^3]')
            app.JerkAxes.YAxis(1).Color = axColor;
            app.JerkAxes.YAxis(2).Color = axColor;

            % Acceleration Axes
            app.AccelAxes = nexttile(t1);
            ylabel(app.AccelAxes, 'Acceleration [m/s^2]')
            grid(app.AccelAxes, 'on');
            grid(app.AccelAxes, 'minor');
            box(app.AccelAxes, 'on');
            app.AccelAxes.XTickLabel = [];
            yyaxis(app.AccelAxes, 'right');
            ylabel(app.AccelAxes, 'Acceleration [rad/s^2]')
            app.AccelAxes.YAxis(1).Color = axColor;
            app.AccelAxes.YAxis(2).Color = axColor;

            % Velocity Axes
            app.VelocityAxes = nexttile(t1);
            ylabel(app.VelocityAxes, 'Velocity [m/s]')
            grid(app.VelocityAxes, 'on');
            grid(app.VelocityAxes, 'minor');
            box(app.VelocityAxes, 'on');
            app.VelocityAxes.XTickLabel = [];
            yyaxis(app.VelocityAxes, 'right');
            ylabel(app.VelocityAxes, 'Velocity [rad/s]')
            app.VelocityAxes.YAxis(1).Color = axColor;
            app.VelocityAxes.YAxis(2).Color = axColor;

            % Wheel Velocities Axes
            app.WheelVelAxes = nexttile(t1);
            ylabel(app.WheelVelAxes, 'Wheel Velocities [rpm]')
            grid(app.WheelVelAxes, 'on');
            grid(app.WheelVelAxes, 'minor');
            box(app.WheelVelAxes, 'on');

            linkaxes([app.JerkAxes, app.AccelAxes, app.VelocityAxes, app.WheelVelAxes], 'x');

            % Create legend for trajectory axes
            legend(app.TrajectoryAxes, 'show', 'Location', 'northeast');

            % Create legend for trajctory colors
            TrajLgd = legend(app.JerkAxes, 'Location', 'northoutside', 'Orientation', 'horizontal');
            TrajLgd.IconColumnWidth = TrajLgd.FontSize *2;

            % Create legend for X/Y/Orientation line styles
            AxisLgd = legend(app.AccelAxes, 'Orientation', 'horizontal');
            AxisLgd.Layout.Tile = 'north';

            legend(app.WheelVelAxes, 'Location', 'southoutside', 'Orientation', 'horizontal');

            % Determine legend icon color for line style indicators (X/Y/Orientation)
            % Use white in dark mode or dark gray in light mode to ensure the legend
            % icons don't match any trajectory color and remain visible
            if app.isDarkMode
                lgdColor = [1 1 1]; % Dark mode
            else
                lgdColor = [0.15 0.15 0.15]; % Light mode
            end

            % Add hidden placeholder plots to legend to explain line style convention
            % These dummy plots (using NaN data) create legend entries that indicate:
            % - Solid line (─) represents X axis data
            % - Dashed line (--) represents Y axis data  
            % - Dotted line (:) represents Orientation data
            % The line color matches each trajectory, but these legend entries use
            % a neutral color (lgdColor) that doesn't conflict with trajectory colors
            hold(app.AccelAxes, 'on');
            plot(app.AccelAxes, NaN, NaN, 'Color', lgdColor, 'LineWidth', 2, 'LineStyle', '-', 'DisplayName', 'X axis');
            plot(app.AccelAxes, NaN, NaN, 'Color', lgdColor, 'LineWidth', 2, 'LineStyle', '--', 'DisplayName', 'Y axis');
            plot(app.AccelAxes, NaN, NaN, 'Color', lgdColor, 'LineWidth', 2, 'LineStyle', ':', 'DisplayName', 'Orientation');
            hold(app.AccelAxes, 'off');

            hold(app.WheelVelAxes, 'on');
            plot(app.WheelVelAxes, NaN, NaN, 'Color', lgdColor, 'LineWidth', 2, 'LineStyle', '-', 'DisplayName', 'Wheel A');
            plot(app.WheelVelAxes, NaN, NaN, 'Color', lgdColor, 'LineWidth', 2, 'LineStyle', '--', 'DisplayName', 'Wheel B');
            plot(app.WheelVelAxes, NaN, NaN, 'Color', lgdColor, 'LineWidth', 2, 'LineStyle', ':', 'DisplayName', 'Wheel C');
            hold(app.WheelVelAxes, 'off');
        end

        function ID = addTrajectoryTab(app)
            if length(app.trajectories) >= 12
                uialert(app.UIFigure, 'Maximum number of trajectories reached (12).', 'Limit Reached');

                if nargout > 0
                    ID = -1;
                end
                return;
            end

            tab = struct('ID', [], 'Tab', [], 'Grid', [], 'Settings', [], ...
                'CommandBox', [], 'Commands', {{}}, ...
                'Plots', [], ...
                'AddButton', [], 'RemoveButton', []);
            
            % Tab ID
            tab.ID = length(app.trajectories) + 1;

            % Create Tab
            tab.Tab = app.Tab_Add;
            app.Tab_Add = uitab(app.TabGroup);
            app.Tab_Add.Title = '+';
            tab.Tab.Title = ['Trajectory ' num2str(tab.ID)];
            tab.Tab.UserData = tab.ID;

            % Create GridLayout
            tab.Grid = uigridlayout(tab.Tab);
            tab.Grid.ColumnWidth = {'1x'};
            tab.Grid.RowHeight = {50, 'fit', 'fit', 50};
            tab.Grid.Scrollable = 'on';

            % Create RemoveButton
            tab.RemoveButton = uibutton(tab.Grid, 'push');
            tab.RemoveButton.Text = 'Remove Trajectory';
            tab.RemoveButton.FontWeight = 'bold';
            tab.RemoveButton.Layout.Row = 1;
            tab.RemoveButton.Layout.Column = 1;
            tab.RemoveButton.ButtonPushedFcn = @(btn,event) app.removeTrajectory(tab.Tab);

            % Settings Panel
            tab.Settings = app.createSettingPanel(tab);

            % Create Commands Panel
            commandPanel = uipanel(tab.Grid);
            commandPanel.FontWeight = 'bold';
            commandPanel.Title = 'Commands';
            commandPanel.Layout.Row = 3;
            commandPanel.Layout.Column = 1;
            commandPanel.BorderType = 'none';

            % Create CommandBox
            tab.CommandBox = uigridlayout(commandPanel);
            tab.CommandBox.ColumnWidth = {'1x'};
            tab.CommandBox.RowHeight = {100};
            tab.CommandBox.Padding = [2 2 2 2];

            % Create AddCommandButton
            tab.AddButton = uibutton(tab.Grid, 'push');
            tab.AddButton.Text = 'Add Command';
            tab.AddButton.Layout.Row = 4;
            tab.AddButton.Layout.Column = 1;
            tab.AddButton.ButtonPushedFcn = @(btn,event) app.addCommandPanel(tab.Tab);

            % Initialize plots
            tab.Plots = initializePlots(app, tab.ID);

            % Store trajectory tab
            app.trajectories(tab.ID) = tab;

            % Create Commands Panel
            app.addCommandPanel(tab.Tab);
            
            % Update remove button states
            app.updateRemoveButtonStates();

            if nargout > 0
                ID = tab.ID;
            end
        end

        function settings = createSettingPanel(app, tab)
            settings.Panel = uipanel(tab.Grid);
            settings.Panel.FontWeight = 'bold';
            settings.Panel.Title = 'Settings';
            settings.Panel.Layout.Row = 2;
            settings.Panel.Layout.Column = 1;

            % Create Settings VBox
            settings.VBox = uigridlayout(settings.Panel);
            settings.VBox.ColumnWidth = {10, '1x'};
            settings.VBox.RowHeight = {'fit', 'fit', 'fit', 'fit', 'fit', 'fit'};
            settings.VBox.ColumnSpacing = 0;

            % Create StartPoseLabel
            settings.StartPoseLabel = uilabel(settings.VBox);
            settings.StartPoseLabel.HorizontalAlignment = 'left';
            settings.StartPoseLabel.Layout.Row = 1;
            settings.StartPoseLabel.Layout.Column = [1 2];
            settings.StartPoseLabel.Text = 'Start Pose:';

            % Create Grid for Start Pose inputs
            settings.StartPoseGrid = uigridlayout(settings.VBox);
            settings.StartPoseGrid.ColumnWidth = {'fit', '1x', 'fit', '1x', 'fit', '1x'};
            settings.StartPoseGrid.RowHeight = {'fit'};
            settings.StartPoseGrid.Layout.Row = 2;
            settings.StartPoseGrid.Layout.Column = 2;
            settings.StartPoseGrid.ColumnSpacing = 0;
            settings.StartPoseGrid.Padding = [0 0 0 0];

            % Create StartPoseXLabel
            settings.StartPoseXLabel = uilabel(settings.StartPoseGrid);
            settings.StartPoseXLabel.HorizontalAlignment = 'right';
            settings.StartPoseXLabel.Layout.Column = 1;
            settings.StartPoseXLabel.Interpreter = 'tex';
            settings.StartPoseXLabel.Text = 'x_i =';
            settings.StartPoseXLabel.FontSize = 14;

            % Create StartPoseXEditField
            settings.StartPoseXEditField = uieditfield(settings.StartPoseGrid, 'numeric');
            settings.StartPoseXEditField.Layout.Column = 2;
            settings.StartPoseXEditField.ValueDisplayFormat = '%11.4g m';

            % Create StartPoseYLabel
            settings.StartPoseYLabel = uilabel(settings.StartPoseGrid);
            settings.StartPoseYLabel.HorizontalAlignment = 'right';
            settings.StartPoseYLabel.Layout.Column = 3;
            settings.StartPoseYLabel.Interpreter = 'tex';
            settings.StartPoseYLabel.Text = ' y_i =';
            settings.StartPoseYLabel.FontSize = 14;

            % Create StartPoseYEditField
            settings.StartPoseYEditField = uieditfield(settings.StartPoseGrid, 'numeric');
            settings.StartPoseYEditField.Layout.Column = 4;
            settings.StartPoseYEditField.ValueDisplayFormat = '%11.4g m';

            % Create StartPoseThetaLabel
            settings.StartPoseThetaLabel = uilabel(settings.StartPoseGrid);
            settings.StartPoseThetaLabel.HorizontalAlignment = 'right';
            settings.StartPoseThetaLabel.Layout.Column = 5;
            settings.StartPoseThetaLabel.Interpreter = 'tex';
            settings.StartPoseThetaLabel.Text = ' \theta_i =';
            settings.StartPoseThetaLabel.FontSize = 14;

            % Create StartPoseThetaEditField
            settings.StartPoseThetaEditField = uieditfield(settings.StartPoseGrid, 'numeric');
            settings.StartPoseThetaEditField.Layout.Column = 6;
            settings.StartPoseThetaEditField.ValueDisplayFormat = '%11.4g °';

            % Create Jerk Settings label
            settings.JerkSettingsLabel = uilabel(settings.VBox);
            settings.JerkSettingsLabel.HorizontalAlignment = 'left';
            settings.JerkSettingsLabel.Layout.Row = 3;
            settings.JerkSettingsLabel.Layout.Column = [1 2];
            settings.JerkSettingsLabel.Text = 'Jerk Settings:';

            % Create Grid for Jerk Settings
            settings.JerkSettingsGrid = uigridlayout(settings.VBox);
            settings.JerkSettingsGrid.ColumnWidth = {'fit', '1x', 'fit', '1x'};
            settings.JerkSettingsGrid.RowHeight = {'fit'};
            settings.JerkSettingsGrid.Layout.Row = 4;
            settings.JerkSettingsGrid.Layout.Column = 2;
            settings.JerkSettingsGrid.Padding = [0 0 0 0];

            % Create EnableJerkCheckBox
            settings.EnableJerkCheckBox = uicheckbox(settings.JerkSettingsGrid);
            settings.EnableJerkCheckBox.Layout.Column = 1;
            settings.EnableJerkCheckBox.Text = 'Enable';
            settings.EnableJerkCheckBox.Layout.Column = 1;
            settings.EnableJerkCheckBox.Value = true;
            settings.EnableJerkCheckBox.ValueChangedFcn = @(s, e) app.toggleJerkSettings(tab.Tab);

            % Create JerkRatioLabel
            settings.JerkRatioLabel = uilabel(settings.JerkSettingsGrid);
            settings.JerkRatioLabel.HorizontalAlignment = 'right';
            settings.JerkRatioLabel.Layout.Column = 3;
            settings.JerkRatioLabel.Text = 'Jerk ratio';

            % Create JerkRatioEditField
            settings.JerkRatioEditField = uieditfield(settings.JerkSettingsGrid, 'numeric');
            settings.JerkRatioEditField.Layout.Column = 4;
            settings.JerkRatioEditField.Value = 10;
            settings.JerkRatioEditField.ValueDisplayFormat = '%11.4g %%';
            settings.JerkRatioEditField.Limits = [0 50];

            % Create Acceleration Settings label
            settings.AccelSettingsLabel = uilabel(settings.VBox);
            settings.AccelSettingsLabel.HorizontalAlignment = 'left';
            settings.AccelSettingsLabel.Layout.Row = 5;
            settings.AccelSettingsLabel.Layout.Column = [1 2];
            settings.AccelSettingsLabel.Text = 'Acceleration Settings:';

            % Create Grid for Acceleration Settings
            settings.AccelSettingsGrid = uigridlayout(settings.VBox);
            settings.AccelSettingsGrid.ColumnWidth = {'fit', '1x', 'fit', '1x'};
            settings.AccelSettingsGrid.RowHeight = {'fit'};
            settings.AccelSettingsGrid.Layout.Row = 6;
            settings.AccelSettingsGrid.Layout.Column = 2;
            settings.AccelSettingsGrid.ColumnSpacing = 0;
            settings.AccelSettingsGrid.Padding = [0 0 0 0];

            % Create EnableAccelCheckBox
            settings.EnableAccelCheckBox = uicheckbox(settings.AccelSettingsGrid);
            settings.EnableAccelCheckBox.Layout.Column = 1;
            settings.EnableAccelCheckBox.Text = 'Enable';
            settings.EnableAccelCheckBox.Value = true;
            settings.EnableAccelCheckBox.ValueChangedFcn = @(s, e) app.toggleAccelSettings(tab.Tab);

            % Create AccelTimeLabel
            settings.AccelTimeLabel = uilabel(settings.AccelSettingsGrid);
            settings.AccelTimeLabel.HorizontalAlignment = 'right';
            settings.AccelTimeLabel.Layout.Column = 3;
            settings.AccelTimeLabel.Interpreter = 'tex';
            settings.AccelTimeLabel.Text = ' t_{acc} =';
            settings.AccelTimeLabel.FontSize = 14;

            % Create AccelTimeEditField
            settings.AccelTimeEditField = uieditfield(settings.AccelSettingsGrid, 'numeric');
            settings.AccelTimeEditField.Layout.Column = 4;
            settings.AccelTimeEditField.ValueDisplayFormat = '%11.4g s';
            settings.AccelTimeEditField.Value = 1;
            settings.AccelTimeEditField.Limits = [0 Inf];
            settings.AccelTimeEditField.UpperLimitInclusive = 'off';
        end

        function ID = addCommandPanel(app, tab, type, varargin)
            arguments
                app     (1,1)   TrackGen
                tab     (1,1)   matlab.ui.container.Tab
                type    {mustBeTextScalar} = 'Move Command'
            end
            
            arguments (Repeating)
                varargin
            end

            trajectoryID = tab.UserData;

            % Command ID
            command.ID = length(app.trajectories(trajectoryID).Commands) + 1;

            % Create Panel
            command.Panel = uipanel(app.trajectories(trajectoryID).CommandBox);
            command.Panel.UserData = [trajectoryID command.ID];
            app.trajectories(trajectoryID).CommandBox.RowHeight{end} = 80;

            % Create GridLayout
            command.VBox = uigridlayout(command.Panel);
            command.VBox.ColumnWidth = {25, 'fit', 'fit', '1x', 40};
            command.VBox.RowHeight = {'1x', '1x'};
            command.VBox.Padding = [5 5 5 5];

            % Create TypeDropDownLabel
            command.IDLabel = uilabel(command.VBox);
            command.IDLabel.HorizontalAlignment = 'left';
            command.IDLabel.Layout.Row = 1;
            command.IDLabel.Layout.Column = 2;
            command.IDLabel.Text = sprintf('%d:', command.ID);
            command.IDLabel.FontWeight = 'bold';
            command.IDLabel.FontSize = 16;

            % Create TypeDropDownLabel
            command.TypeDropDownLabel = uilabel(command.VBox);
            command.TypeDropDownLabel.HorizontalAlignment = 'right';
            command.TypeDropDownLabel.Layout.Row = 1;
            command.TypeDropDownLabel.Layout.Column = 3;
            command.TypeDropDownLabel.Text = 'Type';

            % Create TypeDropDown
            command.TypeDropDown = uidropdown(command.VBox);
            command.TypeDropDown.Items = {'Move Command', 'Position Command by time'};
            command.TypeDropDown.Layout.Row = 1;
            command.TypeDropDown.Layout.Column = 4;
            if ismember(type, command.TypeDropDown.Items)
                command.TypeDropDown.Value = type;
            end
            command.TypeDropDown.ValueChangedFcn = @(s,e) app.changeCommandType(command.Panel);

            % Create RemoveCommandButton
            command.RemoveCommandButton = uibutton(command.VBox, 'push');
            command.RemoveCommandButton.Text = 'X';
            command.RemoveCommandButton.Layout.Row = 1;
            command.RemoveCommandButton.Layout.Column = 5;
            if app.isDarkMode
                command.RemoveCommandButton.BackgroundColor = [.5 .1 0.1];
            else
                command.RemoveCommandButton.BackgroundColor = [.9 0.3 0.3];
            end
            command.RemoveCommandButton.ButtonPushedFcn = @(btn,event) app.removeCommand(command.Panel);
            if command.ID == 1
                command.RemoveCommandButton.Visible = 'off';
            else
                app.trajectories(trajectoryID).Commands{1}.RemoveCommandButton.Visible = 'on';
            end

            % Create UpButton
            command.UpButton = uibutton(command.VBox, 'push');
            command.UpButton.Text = '↑';
            command.UpButton.Layout.Row = 1;
            command.UpButton.Layout.Column = 1;
            command.UpButton.ButtonPushedFcn = @(btn,event) app.moveCommandUp(command.Panel);
            if command.ID == 1
                command.UpButton.Enable = 'off';
            end

            % Create DownButton
            command.DownButton = uibutton(command.VBox, 'push');
            command.DownButton.Text = '↓';
            command.DownButton.Layout.Row = 2;
            command.DownButton.Layout.Column = 1;
            command.DownButton.ButtonPushedFcn = @(btn,event) app.moveCommandDown(command.Panel);
            if command.ID > 1
                app.trajectories(trajectoryID).Commands{command.ID-1}.DownButton.Enable = 'on';
            end
            command.DownButton.Enable = 'off';
            
            % Create command specific UI
            command = app.createCmdFields(command, type, varargin{:});

            % Store command panel
            app.trajectories(trajectoryID).Commands{command.ID} = command;

            if nargout > 0
                ID = command.ID;
            end
        end

        function command = createCmdFields(app, command, type, varargin)
            switch type
                case 'Move Command'
                    command = app.createMoveCmd(command, varargin{:});
                case 'Position Command by time'
                    command = app.createPositionByTimeCmd(command, varargin{:});
                otherwise
                    error('Unknown command type: %s', type);
            end
        end

        function command = createMoveCmd(~, command, config)
            arguments
                ~
                command         (1,1)   struct
                config.velocity (1,1)   double  {mustBeNonnegative, mustBeFinite}   = 0
                config.alpha    (1,1)   double  {mustBeFinite}                      = 0
                config.omega    (1,1)   double  {mustBeFinite}                      = 0
                config.time     (1,1)   double  {mustBeNonnegative, mustBeFinite}   = 1
            end

            % Create GridLayout
            command.Grid = uigridlayout(command.VBox);
            command.Grid.Layout.Row = 2;
            command.Grid.Layout.Column = [2 5];
            command.Grid.ColumnWidth = {'fit', '1x', 'fit', '1x', 'fit', '1x', 'fit', '1x'};
            command.Grid.RowHeight = {'1x'};
            command.Grid.ColumnSpacing = 0;
            command.Grid.Padding = [0 0 0 0];

            % Create velocityLabel
            command.Fields.velocityLabel = uilabel(command.Grid);
            command.Fields.velocityLabel.HorizontalAlignment = 'right';
            command.Fields.velocityLabel.Layout.Row = 1;
            command.Fields.velocityLabel.Layout.Column = 1;
            command.Fields.velocityLabel.Interpreter = 'tex';
            command.Fields.velocityLabel.Text = ' v =';

            % Create velocityField
            command.Fields.velocityField = uieditfield(command.Grid, 'numeric');
            command.Fields.velocityField.Layout.Row = 1;
            command.Fields.velocityField.Layout.Column = 2;
            command.Fields.velocityField.ValueDisplayFormat = '%11.4g m/s';
            command.Fields.velocityField.Limits = [0 Inf];
            command.Fields.velocityField.UpperLimitInclusive = 'off';
            command.Fields.velocityField.Value = config.velocity;

            % Create alphaLabel
            command.Fields.alphaLabel = uilabel(command.Grid);
            command.Fields.alphaLabel.HorizontalAlignment = 'right';
            command.Fields.alphaLabel.Layout.Row = 1;
            command.Fields.alphaLabel.Layout.Column = 3;
            command.Fields.alphaLabel.Interpreter = 'tex';
            command.Fields.alphaLabel.Text = ' \alpha =';

            % Create alphaField
            command.Fields.alphaField = uieditfield(command.Grid, 'numeric');
            command.Fields.alphaField.Layout.Row = 1;
            command.Fields.alphaField.Layout.Column = 4;
            command.Fields.alphaField.ValueDisplayFormat = '%11.4g °';
            command.Fields.alphaField.Limits = [-360 360];
            command.Fields.alphaField.Value = config.alpha;

            % Create omegaLabel
            command.Fields.omegaLabel = uilabel(command.Grid);
            command.Fields.omegaLabel.HorizontalAlignment = 'right';
            command.Fields.omegaLabel.Layout.Row = 1;
            command.Fields.omegaLabel.Layout.Column = 5;
            command.Fields.omegaLabel.Interpreter = 'tex';
            command.Fields.omegaLabel.Text = ' \omega =';

            % Create omegaField
            command.Fields.omegaField = uieditfield(command.Grid, 'numeric');
            command.Fields.omegaField.Layout.Row = 1;
            command.Fields.omegaField.Layout.Column = 6;
            command.Fields.omegaField.ValueDisplayFormat = '%11.4g rad/s';
            command.Fields.omegaField.UpperLimitInclusive = 'off';
            command.Fields.omegaField.LowerLimitInclusive = 'off';
            command.Fields.omegaField.Value = config.omega;

            % Create timeLabel
            command.Fields.timeLabel = uilabel(command.Grid);
            command.Fields.timeLabel.HorizontalAlignment = 'right';
            command.Fields.timeLabel.Layout.Row = 1;
            command.Fields.timeLabel.Layout.Column = 7;
            command.Fields.timeLabel.Interpreter = 'tex';
            command.Fields.timeLabel.Text = ' t =';

            % Create timeField
            command.Fields.timeField = uieditfield(command.Grid, 'numeric');
            command.Fields.timeField.Layout.Row = 1;
            command.Fields.timeField.Layout.Column = 8;
            command.Fields.timeField.ValueDisplayFormat = '%11.4g s';
            command.Fields.timeField.Limits = [0 Inf];
            command.Fields.timeField.UpperLimitInclusive = 'off';
            command.Fields.timeField.Value = config.time;
        end

        function command = createPositionByTimeCmd(~, command, config)
            arguments
                ~
                command         (1,1)   struct
                config.xPos     (1,1)   double  {mustBeFinite}                      = 0
                config.yPos     (1,1)   double  {mustBeFinite}                      = 0
                config.theta    (1,1)   double  {mustBeFinite}                      = 0
                config.time     (1,1)   double  {mustBeNonnegative, mustBeFinite}   = 1
            end

            % Create GridLayout
            command.Grid = uigridlayout(command.VBox);
            command.Grid.Layout.Row = 2;
            command.Grid.Layout.Column = [2 5];
            command.Grid.ColumnWidth = {'fit', '1x', 'fit', '1x', 'fit', '1x', 'fit', '1x'};
            command.Grid.RowHeight = {'1x'};
            command.Grid.ColumnSpacing = 0;
            command.Grid.Padding = [0 0 0 0];

            % Create xPosLabel
            command.Fields.xPosLabel = uilabel(command.Grid);
            command.Fields.xPosLabel.HorizontalAlignment = 'right';
            command.Fields.xPosLabel.Layout.Row = 1;
            command.Fields.xPosLabel.Layout.Column = 1;
            command.Fields.xPosLabel.Interpreter = 'tex';
            command.Fields.xPosLabel.Text = ' x =';

            % Create xPosField
            command.Fields.xPosField = uieditfield(command.Grid, 'numeric');
            command.Fields.xPosField.Layout.Row = 1;
            command.Fields.xPosField.Layout.Column = 2;
            command.Fields.xPosField.ValueDisplayFormat = '%11.4g m';
            command.Fields.xPosField.UpperLimitInclusive = 'off';
            command.Fields.xPosField.LowerLimitInclusive = 'off';
            command.Fields.xPosField.Value = config.xPos;

            % Create yPosLabel
            command.Fields.yPosLabel = uilabel(command.Grid);
            command.Fields.yPosLabel.HorizontalAlignment = 'right';
            command.Fields.yPosLabel.Layout.Row = 1;
            command.Fields.yPosLabel.Layout.Column = 3;
            command.Fields.yPosLabel.Interpreter = 'tex';
            command.Fields.yPosLabel.Text = ' y =';

            % Create yPosField
            command.Fields.yPosField = uieditfield(command.Grid, 'numeric');
            command.Fields.yPosField.Layout.Row = 1;
            command.Fields.yPosField.Layout.Column = 4;
            command.Fields.yPosField.ValueDisplayFormat = '%11.4g m';
            command.Fields.yPosField.UpperLimitInclusive = 'off';
            command.Fields.yPosField.LowerLimitInclusive = 'off';
            command.Fields.yPosField.Value = config.yPos;

            % Create thetaLabel
            command.Fields.thetaLabel = uilabel(command.Grid);
            command.Fields.thetaLabel.HorizontalAlignment = 'right';
            command.Fields.thetaLabel.Layout.Row = 1;
            command.Fields.thetaLabel.Layout.Column = 5;
            command.Fields.thetaLabel.Interpreter = 'tex';
            command.Fields.thetaLabel.Text = ' \theta =';

            % Create thetaField
            command.Fields.thetaField = uieditfield(command.Grid, 'numeric');
            command.Fields.thetaField.Layout.Row = 1;
            command.Fields.thetaField.Layout.Column = 6;
            command.Fields.thetaField.ValueDisplayFormat = '%11.4g °';
            command.Fields.thetaField.Limits = [-360 360];
            command.Fields.thetaField.Value = config.theta;

            % Create timeLabel
            command.Fields.timeLabel = uilabel(command.Grid);
            command.Fields.timeLabel.HorizontalAlignment = 'right';
            command.Fields.timeLabel.Layout.Row = 1;
            command.Fields.timeLabel.Layout.Column = 7;
            command.Fields.timeLabel.Interpreter = 'tex';
            command.Fields.timeLabel.Text = ' t =';

            % Create timeField
            command.Fields.timeField = uieditfield(command.Grid, 'numeric');
            command.Fields.timeField.Layout.Row = 1;
            command.Fields.timeField.Layout.Column = 8;
            command.Fields.timeField.ValueDisplayFormat = '%11.4g s';
            command.Fields.timeField.Limits = [0 Inf];
            command.Fields.timeField.UpperLimitInclusive = 'off';
            command.Fields.timeField.Value = config.time;
        end

        function removeTrajectory(app, tab)
            trajectoryID = tab.UserData;
            
            % Don't allow removal of the last trajectory (button should be disabled)
            if isscalar(app.trajectories)
                return;
            end
            
            % Delete the tab
            delete(tab);

            % Delete associated plots
            deletePlots(app, trajectoryID);
            
            % Remove trajectory from array
            app.trajectories(trajectoryID) = [];
            
            % Renumber remaining trajectories
            for i = trajectoryID:length(app.trajectories)
                if isempty(app.trajectories(i))
                    % Should not happen! Send warning
                    warning('Empty trajectory tab found during renumbering in position %d.', i);
                    continue;
                end
                app.trajectories(i).ID = i;
                app.trajectories(i).Tab.Title = sprintf('Trajectory %d', i);
                app.trajectories(i).Tab.UserData = i;

                % Update plot DisplayNames
                app.trajectories(i).Plots.TrajRefPlot.DisplayName = sprintf('Trajectory %d', i);
                app.trajectories(i).Plots.JerkRefPlot.DisplayName = sprintf('Trajectory %d', i);
                
                % Update command panel UserData to reflect new trajectory ID
                for j = 1:length(app.trajectories(i).Commands)
                    if ~isempty(app.trajectories(i).Commands{j})
                        app.trajectories(i).Commands{j}.Panel.UserData = [i j];
                    else
                        warning('Empty command panel found during trajectory renumbering in trajectory %d, command %d.', i, j);
                    end
                end
            end
            
            % Select the first trajectory tab after removal
            if ~isempty(app.trajectories)
                app.TabGroup.SelectedTab = app.trajectories(min(trajectoryID, length(app.trajectories))).Tab;
            end
            
            % Update remove button states
            app.updateRemoveButtonStates();
        end
        
        function updateRemoveButtonStates(app)
            % Enable/disable remove buttons based on number of trajectories
            if isscalar(app.trajectories)
                % Only one trajectory - disable remove button
                app.trajectories(1).RemoveButton.Enable = 'off';
            else
                % Multiple trajectories - enable all remove buttons
                for i = 1:length(app.trajectories)
                    if ~isempty(app.trajectories(i))
                        app.trajectories(i).RemoveButton.Enable = 'on';
                    end
                end
            end
        end

        function removeCommand(app, commandPanel)
            trajectoryID = commandPanel.UserData(1);
            commandID = commandPanel.UserData(2);

            command = app.trajectories(trajectoryID).Commands{commandID};
            delete(command.Panel);
            app.trajectories(trajectoryID).Commands(command.ID) = [];

            % Renumber remaining commands
            for i = commandID:length(app.trajectories(trajectoryID).Commands)
                if isempty(app.trajectories(trajectoryID).Commands{i})
                    % Should not happen! Send warning
                    warning('Empty command panel found during renumbering in trajectory %d, command %d.', trajectoryID, i);
                    continue;
                end
                app.trajectories(trajectoryID).Commands{i}.Panel.UserData = [trajectoryID i];
                app.trajectories(trajectoryID).Commands{i}.ID = i;
                app.trajectories(trajectoryID).Commands{i}.IDLabel.Text = sprintf('%d:', i);
                app.trajectories(trajectoryID).Commands{i}.Panel.Layout.Row = i;
            end

            % Adjust Button States
            if ~isempty(app.trajectories(trajectoryID).Commands)
                app.trajectories(trajectoryID).Commands{1}.UpButton.Enable = 'off';
                if isscalar(app.trajectories(trajectoryID).Commands)
                    app.trajectories(trajectoryID).Commands{1}.RemoveCommandButton.Visible = 'off';
                    app.trajectories(trajectoryID).Commands{1}.DownButton.Enable = 'off';
                else
                    app.trajectories(trajectoryID).Commands{1}.DownButton.Enable = 'on';
                    app.trajectories(trajectoryID).Commands{end}.DownButton.Enable = 'off';
                    app.trajectories(trajectoryID).Commands{1}.RemoveCommandButton.Visible = 'on';
                end
            end

            % Adjust RowHeight of CommandBox
            app.trajectories(trajectoryID).CommandBox.RowHeight(end) = [];
        end

        function moveCommandUp(app, commandPanel)
            trajectoryID = commandPanel.UserData(1);
            commandID = commandPanel.UserData(2);

            % Can't move the first command up
            if commandID <= 1
                return;
            end

            % Swap the command with the one above it
            temp = app.trajectories(trajectoryID).Commands{commandID - 1};
            app.trajectories(trajectoryID).Commands{commandID - 1} = app.trajectories(trajectoryID).Commands{commandID};
            app.trajectories(trajectoryID).Commands{commandID} = temp;

            % Update IDs and labels
            app.trajectories(trajectoryID).Commands{commandID - 1}.ID = commandID - 1;
            app.trajectories(trajectoryID).Commands{commandID - 1}.Panel.UserData = [trajectoryID commandID - 1];
            app.trajectories(trajectoryID).Commands{commandID - 1}.IDLabel.Text = sprintf('%d:', commandID - 1);
            app.trajectories(trajectoryID).Commands{commandID - 1}.Panel.Layout.Row = commandID - 1;

            app.trajectories(trajectoryID).Commands{commandID}.ID = commandID;
            app.trajectories(trajectoryID).Commands{commandID}.Panel.UserData = [trajectoryID commandID];
            app.trajectories(trajectoryID).Commands{commandID}.IDLabel.Text = sprintf('%d:', commandID);
            app.trajectories(trajectoryID).Commands{commandID}.Panel.Layout.Row = commandID;

            % Update button states
            app.updateCommandButtonStates(trajectoryID);
        end

        function moveCommandDown(app, commandPanel)
            trajectoryID = commandPanel.UserData(1);
            commandID = commandPanel.UserData(2);

            % Can't move the last command down
            if commandID >= length(app.trajectories(trajectoryID).Commands)
                return;
            end

            % Swap the command with the one below it
            temp = app.trajectories(trajectoryID).Commands{commandID + 1};
            app.trajectories(trajectoryID).Commands{commandID + 1} = app.trajectories(trajectoryID).Commands{commandID};
            app.trajectories(trajectoryID).Commands{commandID} = temp;

            % Update IDs and labels
            app.trajectories(trajectoryID).Commands{commandID + 1}.ID = commandID + 1;
            app.trajectories(trajectoryID).Commands{commandID + 1}.Panel.UserData = [trajectoryID commandID + 1];
            app.trajectories(trajectoryID).Commands{commandID + 1}.IDLabel.Text = sprintf('%d:', commandID + 1);
            app.trajectories(trajectoryID).Commands{commandID + 1}.Panel.Layout.Row = commandID + 1;

            app.trajectories(trajectoryID).Commands{commandID}.ID = commandID;
            app.trajectories(trajectoryID).Commands{commandID}.Panel.UserData = [trajectoryID commandID];
            app.trajectories(trajectoryID).Commands{commandID}.IDLabel.Text = sprintf('%d:', commandID);
            app.trajectories(trajectoryID).Commands{commandID}.Panel.Layout.Row = commandID;

            % Update button states
            app.updateCommandButtonStates(trajectoryID);
        end

        function updateCommandButtonStates(app, trajectoryID)
            % Update up/down button states for all commands in the trajectory
            numCommands = length(app.trajectories(trajectoryID).Commands);
            
            for i = 1:numCommands
                % Up button
                if i == 1
                    app.trajectories(trajectoryID).Commands{i}.UpButton.Enable = 'off';
                else
                    app.trajectories(trajectoryID).Commands{i}.UpButton.Enable = 'on';
                end
                
                % Down button
                if i == numCommands
                    app.trajectories(trajectoryID).Commands{i}.DownButton.Enable = 'off';
                else
                    app.trajectories(trajectoryID).Commands{i}.DownButton.Enable = 'on';
                end
            end
        end

        function updateTimeWindow(app)
            if isempty(app.timeVector)
                app.timeSlider.Limits = [0 10];
                app.timeSlider.Value = [0 10];
            else
                newLimits = ceil([0 app.timeVector(end)]/0.01)*0.01; % Round up to nearest 0.01s
                

                if newLimits(2) ~= app.timeSlider.Limits(2)
                    app.timeSlider.Limits = newLimits;
                    app.timeSlider.Value = newLimits;

                    % Fix bug with auto major ticks between 20 and 29 seconds
                    if newLimits(2) >= 20 && newLimits(2) < 29
                        app.timeSlider.MajorTicks = 0:1:newLimits(2);
                    else
                        app.timeSlider.MajorTicksMode = 'auto';
                    end
                end
            end
            
            app.startTimeField.Limits = app.timeSlider.Limits;
            app.startTimeField.Value = app.timeSlider.Value(1);
            app.endTimeField.Limits = app.timeSlider.Limits;
            app.endTimeField.Value = app.timeSlider.Value(2);
        end

        function plots = initializePlots(app, trajectoryID)
            % Initialize plot handles for trajectory visualization
            hold(app.TrajectoryAxes, 'on');
            plots.TrajRefPlot = plot(app.TrajectoryAxes, NaN, NaN, 'Color', app.getFreePlotColor(), ...
                'LineWidth', 2, 'DisplayName', sprintf('Trajectory %d', trajectoryID));
            plots.TrajectoryPlot = plot(app.TrajectoryAxes, NaN, NaN, '-', 'Color', plots.TrajRefPlot.Color);
            plots.PositionPlot = plot(app.TrajectoryAxes, NaN, NaN, 'o', 'Color', plots.TrajRefPlot.Color); 
            plots.OrientationPlot = plot(app.TrajectoryAxes, NaN, NaN, '-', 'Color', plots.TrajRefPlot.Color, 'LineWidth', 2);
            hold(app.TrajectoryAxes, 'off');
            plots.TrajectoryPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';     % Hide from legend
            plots.PositionPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';       % Hide from legend
            plots.OrientationPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';    % Hide from legend

            % Initialize plots for trajectory jerk
            hold(app.JerkAxes, 'on');
            yyaxis(app.JerkAxes, 'left');
            plots.JerkRefPlot = plot(app.JerkAxes, NaN, NaN, 'Color', plots.TrajRefPlot.Color, ...
                'Marker', 'none', 'LineStyle', '-', 'LineWidth', 2, 'DisplayName', sprintf('Trajectory %d', trajectoryID));
            plots.JerkXPlot = stairs(app.JerkAxes, NaN, NaN, 'Color', plots.JerkRefPlot.Color, 'Marker', 'none', 'LineStyle', '-');
            plots.JerkYPlot = stairs(app.JerkAxes, NaN, NaN, 'Color', plots.JerkRefPlot.Color, 'Marker', 'none', 'LineStyle', '--');
            yyaxis(app.JerkAxes, 'right');
            plots.JerkOPlot = stairs(app.JerkAxes, NaN, NaN, 'Color', plots.JerkRefPlot.Color, 'Marker', 'none', 'LineStyle', ':');
            hold(app.JerkAxes, 'off');
            plots.JerkXPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';          % Hide from legend
            plots.JerkYPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';          % Hide from legend
            plots.JerkOPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';          % Hide from legend

            % Initialize plots for trajectory acceleration
            hold(app.AccelAxes, 'on');
            yyaxis(app.AccelAxes, 'left');
            plots.AccelXPlot = plot(app.AccelAxes, NaN, NaN, 'Color', plots.TrajRefPlot.Color, 'Marker', 'none', 'LineStyle', '-');
            plots.AccelYPlot = plot(app.AccelAxes, NaN, NaN, 'Color', plots.AccelXPlot.Color, 'Marker', 'none', 'LineStyle', '--');
            yyaxis(app.AccelAxes, 'right');
            plots.AccelOPlot = plot(app.AccelAxes, NaN, NaN, 'Color', plots.AccelXPlot.Color, 'Marker', 'none', 'LineStyle', ':');
            hold(app.AccelAxes, 'off');
            plots.AccelXPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';         % Hide from legend
            plots.AccelYPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';         % Hide from legend
            plots.AccelOPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';         % Hide from legend

            % Initialize plots for trajectory velocity
            hold(app.VelocityAxes, 'on');
            yyaxis(app.VelocityAxes, 'left');
            plots.VelocityXPlot = plot(app.VelocityAxes, NaN, NaN, 'Color', plots.TrajRefPlot.Color, 'Marker', 'none', 'LineStyle', '-');
            plots.VelocityYPlot = plot(app.VelocityAxes, NaN, NaN, 'Color', plots.VelocityXPlot.Color, 'Marker', 'none', 'LineStyle', '--');
            yyaxis(app.VelocityAxes, 'right');
            plots.VelocityOPlot = plot(app.VelocityAxes, NaN, NaN, 'Color', plots.VelocityXPlot.Color, 'Marker', 'none', 'LineStyle', ':');
            hold(app.VelocityAxes, 'off');

            % Initialize plots for trajectory wheel velocities
            hold(app.WheelVelAxes, 'on');
            plots.WheelAPlot = plot(app.WheelVelAxes, NaN, NaN, 'Color', plots.TrajRefPlot.Color);
            plots.WheelBPlot = plot(app.WheelVelAxes, NaN, NaN, 'Color', plots.WheelAPlot.Color, 'LineStyle', '--');
            plots.WheelCPlot = plot(app.WheelVelAxes, NaN, NaN, 'Color', plots.WheelAPlot.Color, 'LineStyle', ':');
            hold(app.WheelVelAxes, 'off');
            plots.WheelAPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';         % Hide from legend
            plots.WheelBPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';         % Hide from legend
            plots.WheelCPlot.Annotation.LegendInformation.IconDisplayStyle = 'off';         % Hide from legend
        end

        function updatePlots(app)
            for ii = 1:length(app.trajectories)
                if isempty(app.trajectories(ii).Plots) || ii > length(app.simulationData)
                    continue;
                end

                plots = app.trajectories(ii).Plots;
                data = app.simulationData(ii);
                stateData = data.globalState;
                wheelData = data.wheelVelocities;
                time = app.timeVector(1:size(stateData, 1));

                drawIdx = time > app.timeSlider.Value(1) & time < app.timeSlider.Value(2);

                % Update trajectory plots
                set(plots.TrajectoryPlot, 'XData', stateData(drawIdx, 1, 1), 'YData', stateData(drawIdx, 2, 1));
                [xp, yp, xdir, ydir] = drawOrientation(stateData(drawIdx, :, 1), stateData(drawIdx, 1:2, 2), time(drawIdx), 0.5, 0.05, 0.1);
                set(plots.PositionPlot, 'XData', xp, 'YData', yp);
                set(plots.OrientationPlot, 'XData', xdir, 'YData', ydir);
                axis(app.TrajectoryAxes, 'equal');

                % Update jerk plots
                set(plots.JerkXPlot, 'XData', time(drawIdx), 'YData', stateData(drawIdx, 1, 4));
                set(plots.JerkYPlot, 'XData', time(drawIdx), 'YData', stateData(drawIdx, 2, 4));
                set(plots.JerkOPlot, 'XData', time(drawIdx), 'YData', stateData(drawIdx, 3, 4));
                homeAxis(app.JerkAxes, [nan, 0]);
                zoom(app.JerkAxes, 'reset');

                % Update acceleration plots
                set(plots.AccelXPlot, 'XData', time(drawIdx), 'YData', stateData(drawIdx, 1, 3));
                set(plots.AccelYPlot, 'XData', time(drawIdx), 'YData', stateData(drawIdx, 2, 3));
                set(plots.AccelOPlot, 'XData', time(drawIdx), 'YData', stateData(drawIdx, 3, 3));
                homeAxis(app.AccelAxes, [nan, 0]);
                zoom(app.AccelAxes, 'reset');

                % Update velocity plots
                set(plots.VelocityXPlot, 'XData', time(drawIdx), 'YData', stateData(drawIdx, 1, 2));
                set(plots.VelocityYPlot, 'XData', time(drawIdx), 'YData', stateData(drawIdx, 2, 2));
                set(plots.VelocityOPlot, 'XData', time(drawIdx), 'YData', stateData(drawIdx, 3, 2));
                homeAxis(app.VelocityAxes, [nan, 0]);
                zoom(app.VelocityAxes, 'reset');

                % Update wheel velocity plots
                set(plots.WheelAPlot, 'XData', time(drawIdx), 'YData', wheelData(drawIdx, 1));
                set(plots.WheelBPlot, 'XData', time(drawIdx), 'YData', wheelData(drawIdx, 2));
                set(plots.WheelCPlot, 'XData', time(drawIdx), 'YData', wheelData(drawIdx, 3));
                homeAxis(app.WheelVelAxes);
                zoom(app.WheelVelAxes, 'reset');
            end

            function [xi, yi, x, y] = drawOrientation(pose, velocity, time, Ts, minLen, scale)
                % Draw orientation arrows at sample time intervals
                time = reshape(time, [], 1);
                targetTimes = 0:Ts:time(end);

                [~, I] = min(abs(time-targetTimes));

                % Extract positions and orientations
                xi = pose(I, 1);
                yi = pose(I, 2);
                o = pose(I, 3);
                v = hypot(velocity(I, 1), velocity(I, 2));
                len = v * scale;

                [x, y] = drawArrow(xi, yi, o, len, minLen);
            end
        end

        function deletePlots(app, trajectoryID)
            plots = app.trajectories(trajectoryID).Plots;

            app.releasePlotColor(plots.TrajRefPlot.Color);
            delete(plots.TrajRefPlot);
            delete(plots.TrajectoryPlot);
            delete(plots.PositionPlot);
            delete(plots.OrientationPlot);

            delete(plots.JerkRefPlot);
            delete(plots.JerkXPlot);
            delete(plots.JerkYPlot);
            delete(plots.JerkOPlot);

            delete(plots.AccelXPlot);
            delete(plots.AccelYPlot);
            delete(plots.AccelOPlot);

            delete(plots.VelocityXPlot);
            delete(plots.VelocityYPlot);
            delete(plots.VelocityOPlot);

            delete(plots.WheelAPlot);
            delete(plots.WheelBPlot);
            delete(plots.WheelCPlot);
        end

        function color = getFreePlotColor(app)
            if size(app.plotColors, 1) > 0
                color = app.plotColors(1, :);
                app.plotColors(1, :) = []; % Remove used color
            else
                % If all colors are used, return black
                color = [0 0 0];
            end
        end

        function releasePlotColor(app, color)
            app.plotColors(end+1, :) = color;
        end

        function saveTrajectoryToFile(app)
            % Save only the active trajectory to a .mat file
            
            % Get the currently selected trajectory
            selectedTab = app.TabGroup.SelectedTab;
            if strcmp(selectedTab.Title, '+')
                uialert(app.UIFigure, 'Please select a trajectory to save.', 'No Trajectory Selected', 'Icon', 'warning');
                return;
            end
            
            % Find the trajectory ID from the selected tab
            trajectoryID = selectedTab.UserData;
            if isempty(trajectoryID) || isempty(app.trajectories(trajectoryID))
                uialert(app.UIFigure, 'Invalid trajectory selected.', 'Error', 'Icon', 'error');
                return;
            end
            
            % Prepare data structure for saving
            savedData = struct();
            savedData.version = '2.0';
            savedData.sampleTime = app.sampleTime;
            savedData.wheelRadius = app.wheelRadius;
            savedData.robotRadius = app.robotRadius;
            savedData.wheelAngles = app.wheelAngles;
            
            % Extract settings and commands from the active trajectory
            traj = struct();
            
            % Save settings
            settings = app.trajectories(trajectoryID).Settings;
            traj.settings.startPoseX = settings.StartPoseXEditField.Value;
            traj.settings.startPoseY = settings.StartPoseYEditField.Value;
            traj.settings.startPoseTheta = settings.StartPoseThetaEditField.Value;
            traj.settings.enableAccel = settings.EnableAccelCheckBox.Value;
            traj.settings.accelTime = settings.AccelTimeEditField.Value;
            traj.settings.enableJerk = settings.EnableJerkCheckBox.Value;
            traj.settings.jerkRatio = settings.JerkRatioEditField.Value;
            
            % Save commands
            traj.commands = [];
            for j = 1:length(app.trajectories(trajectoryID).Commands)
                if isempty(app.trajectories(trajectoryID).Commands{j})
                    continue;
                end
                
                cmd = app.trajectories(trajectoryID).Commands{j};
                cmdData = struct();
                cmdData.type = cmd.TypeDropDown.Value;
                fields = fieldnames(cmd.Fields);

                for fieldIdx = 1:length(fields)
                    fieldName = fields{fieldIdx};
                    if endsWith(fieldName, 'Field')
                        shortName = extractBefore(fieldName, 'Field');
                        cmdData.Fields.(shortName) = cmd.Fields.(fieldName).Value;
                    end
                end
                
                traj.commands = [traj.commands, cmdData];
            end
            
            savedData.trajectory = traj;
            
            % Open save dialog
            defaultPath = [getFilePath() ,'Trajectories\' util.countingName('Track')];
            filter = {'*.mat', 'MATLAB Data Files (*.mat)'; ...
                      '*.json', 'JSON Files (*.json)'};
            [filename, pathname] = uiputfile(filter, 'Save Trajectory', defaultPath);
            
            if filename == 0
                return; % User cancelled
            end
            
            fullpath = fullfile(pathname, filename);
            
            % Check file extension and save accordingly
            [~, ~, ext] = fileparts(filename);
            if strcmpi(ext, '.json')
                % Save as JSON
                jsonText = jsonencode(savedData, 'PrettyPrint', true);
                fid = fopen(fullpath, 'w');
                if fid == -1
                    error('Cannot create file %s', fullpath);
                end
                fwrite(fid, jsonText, 'char');
                fclose(fid);
            else
                % Save as MAT file
                save(fullpath, 'savedData');
            end
            
            % Show success message
            uialert(app.UIFigure, sprintf('Trajectory saved to:\n%s', fullpath), 'Save Success', 'Icon', 'success');
        end

        function loadTrajectoryFromFile(app)
            % Load a trajectory from a .mat or .json file and add it to existing trajectories
            
            % Open load dialog
            defaultPath = [getFilePath() ,'Trajectories\'];
            [filename, pathname] = uigetfile({'*.mat;*.json', 'Trajectory Files (*.mat;*.json)'; ...
                                             '*.*', 'All Files (*.*)'}, ...
                                             'Load Trajectory', ...
                                             defaultPath);
            
            if filename == 0
                return; % User cancelled
            end
            
            fullpath = fullfile(pathname, filename);
            
            % Load data based on file extension
            [~, ~, ext] = fileparts(filename);
            if strcmpi(ext, '.json')
                % Load from JSON
                fid = fopen(fullpath, 'r');
                if fid == -1
                    error('Cannot open file %s', fullpath);
                end
                jsonText = fread(fid, '*char')';
                fclose(fid);
                savedData = jsondecode(jsonText);
            else
                % Load from MAT file
                data = load(fullpath);
                if ~isfield(data, 'savedData')
                    error('Invalid trajectory file format.');
                end
                savedData = data.savedData;
            end
            
            % Validate data version
            if ~isfield(savedData, 'version')
                warning('Loading trajectory file without version information.');
            end
            
            % Apply robot configuration if present
            if isfield(savedData, 'wheelRadius')
                app.wheelRadius = savedData.wheelRadius;
            end
            if isfield(savedData, 'robotRadius')
                app.robotRadius = savedData.robotRadius;
            end
            if isfield(savedData, 'wheelAngles')
                app.wheelAngles = savedData.wheelAngles;
            end
            app.updateKinematicMatrix();
            
            % Load trajectory
            if isfield(savedData, 'trajectory')
                trajData = savedData.trajectory;
            else
                error('Invalid trajectory file format: no trajectory data found.');
            end
            
            % Load trajectory
            app.loadTrajectory(trajData);
            
            % Show success message
            uialert(app.UIFigure, sprintf('Trajectory loaded from:\n%s', fullpath), 'Load Success', 'Icon', 'success');
        end

        function loadTrajectory(app, trajData)
            % Helper method to load a single trajectory

            % Get the currently selected trajectory
            selectedTab = app.TabGroup.SelectedTab;
            if strcmp(selectedTab.Title, '+')
                uialert(app.UIFigure, 'Please select a trajectory to save.', 'No Trajectory Selected', 'Icon', 'warning');
                return;
            end
            
            % Find the trajectory ID from the selected tab
            trajectoryID = selectedTab.UserData;
            if isempty(trajectoryID) || isempty(app.trajectories(trajectoryID))
                uialert(app.UIFigure, 'Invalid trajectory selected.', 'Error', 'Icon', 'error');
                return;
            end
            
            % Apply settings
            if isfield(trajData, 'settings')
                settings = app.trajectories(trajectoryID).Settings;
                if isfield(trajData.settings, 'startPoseX')
                    settings.StartPoseXEditField.Value = trajData.settings.startPoseX;
                end
                if isfield(trajData.settings, 'startPoseY')
                    settings.StartPoseYEditField.Value = trajData.settings.startPoseY;
                end
                if isfield(trajData.settings, 'startPoseTheta')
                    settings.StartPoseThetaEditField.Value = trajData.settings.startPoseTheta;
                end
                if isfield(trajData.settings, 'enableAccel')
                    settings.EnableAccelCheckBox.Value = trajData.settings.enableAccel;
                end
                if isfield(trajData.settings, 'accelTime')
                    settings.AccelTimeEditField.Value = trajData.settings.accelTime;
                end
                if isfield(trajData.settings, 'enableJerk')
                    settings.EnableJerkCheckBox.Value = trajData.settings.enableJerk;
                end
                if isfield(trajData.settings, 'jerkRatio')
                    settings.JerkRatioEditField.Value = trajData.settings.jerkRatio;
                end
            end
            
            % Remove existing commands and add loaded commands
            for i = length(app.trajectories(trajectoryID).Commands):-1:1
                if ~isempty(app.trajectories(trajectoryID).Commands{i})
                    app.removeCommand(app.trajectories(trajectoryID).Commands{i}.Panel);
                end
            end
            
            % Add commands
            if isfield(trajData, 'commands')
                for j = 1:length(trajData.commands)
                    cmdData = trajData.commands(j);

                    % Get command type if available
                    if isfield(cmdData, 'type')
                        cmdType = cmdData.type;
                        config = cmdData.Fields;
                    else
                        % Old format without type field - use default
                        cmdType = 'Move Command';
                        config.velocity = cmdData.v;
                        config.alpha = cmdData.alpha;
                        config.omega = cmdData.omega;
                        config.time = cmdData.t;
                    end
                    
                    % Add command
                    argsCell = namedargs2cell(config);
                    app.addCommandPanel(app.trajectories(trajectoryID).Tab, cmdType, argsCell{:});
                end
            end
        end
    end

    % Trajectory simulation and plotting
    methods (Access = public)
        function generateTrajectory(app, trajectoryID)
            % Generate trajectory based on commands and update plots
            %
            % VELOCITY PROFILE WITH JERK (S-curve transitions):
            %
            %   Velocity                              With Jerk (Rounded S-curves)
            %        ^
            %    Vmax|                
            %        |             ⡠⠒⠊⠉⠉⠉⠉⠉⠉⠉⠉⠉⠑⠒⢄     
            %        |            ⡈|   |          |   |⢁
            %        |           ⡈ |   |          |   | ⢁
            %        |          ⡈  |   |          |   |  ⢁
            %        |         ⡈   |   |          |   |   ⢁
            %        |        ⡈    |   |          |   |    ⢁
            %        |       ⡈     |   |          |   |     ⢁
            %        |      ⡈      |   |          |   |      ⢁
            %        |     ⡈       |   |          |   |       ⢁
            %      0 |⣀⡠⠤⠊____________________________________⠑⠤⢄⣀____> Time
            %        |     |       |   |          |   |        |     |
            %        |  A  |   B   | C |    D     | E |   F    |  G  |
            %        |     |       |   |          |   |        |     |
            %        0    T1      T2  T3         T4  T5       T6    T7
            %
            %  Phase Details:
            %    A: Jerk Phase Accel    (0 → T1)    - J = J_a (constant), a increases linearly 0 → a_max
            %    B: Constant Accel      (T1 → T2)   - J = 0, a = a_max (constant acceleration)
            %    C: Jerk Phase Decel    (T2 → T3)   - J = J_c (constant), a decreases linearly a_max → 0
            %    D: Constant Velocity   (T3 → T4)   - J = 0, a = 0, v = Vmax
            %    E: Jerk Phase Decel    (T4 → T5)   - J = J_e (constant), a decreases linearly 0 → -a_max
            %    F: Constant Decel      (T5 → T6)   - J = 0, a = -a_max (constant deceleration)
            %    G: Jerk Phase Accel    (T6 → T7)   - J = J_f (constant), a increases linearly -a_max → 0
            %
            %  Key Variables:
            %    Tj, Tj     = Jerk phase durations
            %    Tacc       = Total acceleration/deceleration times
            %    Tc         = Constant velocity duration (cruise time)
            %    J_a, J_c   = Jerk values (acceleration and deceleration)
            %    a_max      = Maximum acceleration magnitude
            %    Vmax       = Maximum/target velocity
            %

            settings = app.trajectories(trajectoryID).Settings;

            % Get initial position
            initPos(1) = settings.StartPoseXEditField.Value;
            initPos(2) = settings.StartPoseYEditField.Value;
            initPos(3) = deg2rad(settings.StartPoseThetaEditField.Value);

            % Determine acceleration and jerk times
            if settings.EnableAccelCheckBox.Value
                Tacc = round(settings.AccelTimeEditField.Value / app.sampleTime) * app.sampleTime;

                if settings.EnableJerkCheckBox.Value
                    jerkRatio = settings.JerkRatioEditField.Value / 100;
                    minCmdTime = 4 * app.sampleTime;
                    Tacc = max(Tacc, app.sampleTime * 2); % Ensure minimum time for jerk profile
                    Tj = max(round(jerkRatio * Tacc / app.sampleTime) * app.sampleTime, app.sampleTime); % Ensure minimum time for jerk
                else
                    minCmdTime = 2 * app.sampleTime;
                    Tacc = max(Tacc, app.sampleTime); % Ensure minimum time for acceleration
                    Tj = 0;
                end
            else
                minCmdTime = app.sampleTime;
                Tacc = 0;
                Tj = 0;
            end

            % Extract commands
            commands = app.extractCommands(trajectoryID, initPos, Tacc, Tj, minCmdTime);

            % Generate setpoints
            setpoints = app.generateSetpoints(commands, Tacc, Tj);

            % Simulate trajectory
            [timeVec, stateVec, wheelVelVec] = app.simulateTrajectory(setpoints, initPos);

            % Store simulation data
            app.simulationData(trajectoryID).globalState = stateVec;
            app.simulationData(trajectoryID).wheelVelocities = wheelVelVec;

            % Merge time vector
            if length(timeVec) > length(app.timeVector)
                app.timeVector = timeVec;
            end
        end

        function commands = extractCommands(app, trajectoryID, initPos, Tacc, Tj, minCmdTime)
            commandStruct = app.trajectories(trajectoryID).Commands;

            v_i = [0, 0, 0]; % Initial velocity
            A = [0, 0, 0]; % Initial acceleration

            numCommands = length(commandStruct);
            commands = zeros(numCommands, 4); % [vx, vy, omega, time]
            for i = 1:numCommands
                cmd = commandStruct{i};

                switch cmd.TypeDropDown.Value
                    case 'Move Command'
                        % Move Command
                        vel = cmd.Fields.velocityField.Value;
                        alpha = deg2rad(cmd.Fields.alphaField.Value);
                        
                        commands(i, 1) = vel * cos(alpha);
                        commands(i, 2) = vel * sin(alpha);
                        commands(i, 3) = cmd.Fields.omegaField.Value;
                        commands(i, 4) = round(cmd.Fields.timeField.Value / app.sampleTime) * app.sampleTime;

                        % Calculate final position after this command
                        [Tacc_cmd, Tj_cmd] = getAdjustedTimes(app.sampleTime, commands(i, 4), Tacc, Tacc, Tj);
                        initPos = getProfileFinalPose(initPos, v_i, A, commands(i, 1:3), A, commands(i, 1:3), Tacc_cmd, 0, Tj_cmd, 0, commands(i, 4));
                        v_i = commands(i, 1:3); % Update initial velocity for next command
                    case 'Position Command by time'
                        % Position Command by time
                        xf = cmd.Fields.xPosField.Value;
                        yf = cmd.Fields.yPosField.Value;
                        theta = deg2rad(cmd.Fields.thetaField.Value);
                        t = round(cmd.Fields.timeField.Value / app.sampleTime) * app.sampleTime;

                        % Get motion command to reach desired position in given time
                        if i < numCommands
                            [Tacc_cmd, Tj_cmd] = getAdjustedTimes(app.sampleTime, t, Tacc, Tacc, Tj);
                            [v, a, w] = getMotionCommandByTime(t, initPos, [xf, yf, theta], ...
                                        v_i, A, v_i, A, Tacc_cmd, 0, Tj_cmd, 0, rotationDirection='free');
                        else
                            [Tacc_cmd, Tj_cmd] = getAdjustedTimes(app.sampleTime, t, Tacc*2, Tacc, Tj);
                            [v, a, w] = getMotionCommandByTime(t, initPos, [xf, yf, theta], ...
                                        v_i, A, [0 0 0], A, Tacc_cmd, Tacc_cmd, Tj_cmd, Tj_cmd, rotationDirection='free');
                        end
                        initPos = [xf, yf, theta];
                        v_i = [v * cos(a), v * sin(a), w]; % Update initial velocity for next command
                        
                        commands(i, 1) = v_i(1);
                        commands(i, 2) = v_i(2);
                        commands(i, 3) = v_i(3);
                        commands(i, 4) = t;
                    otherwise
                        commands(i, :) = 0; % Unknown command type, set to zero
                end
                commands(i, 4) = max(commands(i, 4), minCmdTime);
            end
        end
        
        function setpoints = generateSetpoints(app, commands, Tacc, Tj)
            numCommands = size(commands, 1);
            numSetpoints = 4 + numCommands * 4; % Start ramp + 4 per command
            setpoints = zeros(numSetpoints, 10); % [vx, vy, omega, ax, ay, alpha, jx, jy, psi, time]

            Vi = [0 0 0]; % Initial velocity
            Ti = 0; % Initial time
            for i = 1:numCommands
                % Get command parameters
                t_span = commands(i, 4);
                V = commands(i, 1:3);

                if i < numCommands
                    t_lim = Tacc;
                else
                    t_lim = Tacc * 2;
                end

                % Adjust times if command time is shorter than acceleration
                [Tacc_cmd, Tj_cmd] = getAdjustedTimes(app.sampleTime, t_span, t_lim, Tacc, Tj);
                % Calculate setpoints for acceleration phase
                [A_b, J_a, J_c, V_ib, V_ic] = computeTransitionParams(Vi, V, Tacc_cmd, Tj_cmd);

                setpoints(4*(i-1) + 1, :) = [Vi, 0, 0, 0, J_a, Ti];                     % Start from constant velocity, initial jerk phase
                setpoints(4*(i-1) + 2, :) = [V_ib, A_b, 0, 0, 0, Ti + Tj_cmd];          % End of initial jerk phase -> constant acceleration
                setpoints(4*(i-1) + 3, :) = [V_ic, A_b, J_c, Ti + Tacc_cmd - Tj_cmd];   % End of constant acceleration -> start of deceleration jerk
                setpoints(4*(i-1) + 4, :) = [V, 0, 0, 0, 0, 0, 0, Ti + Tacc_cmd];       % End of deceleration jerk -> constant velocity

                Vi = V; % Initial velocity for next command
                Ti = Ti + t_span; % Initial time for next command
            end
            Ti = Ti-Tacc_cmd; % Adjust time for final transition

            % Final transition from last command to rest

            % Calculate setpoints for acceleration phase
            [A_b, J_a, J_c, V_ib, V_ic] = computeTransitionParams(Vi, [0, 0, 0], Tacc_cmd, Tj_cmd);

            i = numCommands;
            setpoints(4*i + 1, :) = [Vi, 0, 0, 0, J_a, Ti];                     % Start from constant velocity, initial jerk phase
            setpoints(4*i + 2, :) = [V_ib, A_b, 0, 0, 0, Ti + Tj_cmd];          % End of initial jerk phase -> constant acceleration
            setpoints(4*i + 3, :) = [V_ic, A_b, J_c, Ti + Tacc_cmd - Tj_cmd];   % End of constant acceleration -> start of deceleration jerk
            setpoints(4*i + 4, :) = [0, 0, 0, 0, 0, 0, 0, 0, 0, Ti + Tacc_cmd]; % End of deceleration jerk -> rest

            function [A_b, J_a, J_c, V_ib, V_ic] = computeTransitionParams(Vi, Vf, Tacc_cmd, Tj_cmd)
                if Tacc_cmd == 0
                    A_b = zeros(size(Vf));
                    J_a = zeros(size(Vf));
                    J_c = zeros(size(Vf));
                    V_ib = Vi;
                    V_ic = Vi;
                elseif Tj_cmd == 0
                    A_b = (Vf - Vi) ./ Tacc_cmd;
                    J_a = zeros(size(Vf));
                    J_c = zeros(size(Vf));
                    V_ib = Vi;
                    V_ic = Vi + A_b .* Tacc_cmd;
                else
                    A_b = (Vf - Vi) ./ (Tacc_cmd - Tj_cmd);
                    J_a = A_b ./ Tj_cmd;
                    J_c = -A_b ./ Tj_cmd;
                    V_ib = Vi + J_a .* (Tj_cmd^2 / 2);
                    V_ic = V_ib + A_b .* (Tacc_cmd - Tj_cmd * 2);
                end
            end
        end
        
        function [timeVec, stateVec, wheelVelVec] = simulateTrajectory(app, setpoints, initPos)
            % Simulate trajectory based on setpoints using Euler integration

            Ts = app.sampleTime;

            numSteps = round(setpoints(end, end) / Ts) + 1;
            timeVec = (0:Ts:(numSteps-1)*Ts)';

            stateVec = zeros(numSteps, 3, 4); % [x/y/theta, vx/vy/omega, ax/ay/alpha, jx/jy/psi]
            
            % Shift times to center of sample period to avoid rounding errors
            refTime = setpoints(:, end) - Ts/2; 
            for i = 1:size(setpoints, 1) - 1
                idx = timeVec >= refTime(i) & timeVec < refTime(i+1);

                if ~any(idx)
                    continue;
                end

                sectionTime = timeVec(idx) - timeVec(find(idx, 1));
                Tend = sectionTime(end) + Ts;

                stateVec(idx, 1, 4) = setpoints(i, 7); % jx
                stateVec(idx, 2, 4) = setpoints(i, 8); % jy
                stateVec(idx, 3, 4) = setpoints(i, 9); % psi

                stateVec(idx, :, 3) = setpoints(i, 4:6) + setpoints(i, 7:9) .* sectionTime; % ax, ay, alpha

                stateVec(idx, :, 2) = setpoints(i, 1:3) + setpoints(i, 4:6) .* sectionTime + setpoints(i, 7:9) .* sectionTime.^2/2; % vx, vy, omega

                stateVec(idx, 3, 1) = initPos(3) + setpoints(i, 3) .* sectionTime + setpoints(i, 6) .* sectionTime.^2/2 + setpoints(i, 9) .* sectionTime.^3/6; % theta

                % Final orientation after this segment
                theta_f = initPos(3) + setpoints(i, 3) * Tend + setpoints(i, 6) * Tend^2 / 2 + setpoints(i, 9) * Tend^3 / 6;
                
                % Compute global velocities
                Vg_ini = globalVelocity(0, stateVec(idx, 3, 1), stateVec(idx, :, 2), stateVec(idx, :, 3), stateVec(idx, :, 4));
                Vg_mp = globalVelocity(Ts/2, stateVec(idx, 3, 1), stateVec(idx, :, 2), stateVec(idx, :, 3), stateVec(idx, :, 4));
                Vg_end = globalVelocity(Ts, stateVec(idx, 3, 1), stateVec(idx, :, 2), stateVec(idx, :, 3), stateVec(idx, :, 4));

                % Average global velocity using Simpson's rule
                Vg_avg = (Vg_ini + 4 * Vg_mp + Vg_end) / 6;

                % Integrate global velocity to get position
                xg = initPos(1) + cumsum([0; Vg_avg(:, 1)]) * Ts; % x
                yg = initPos(2) + cumsum([0; Vg_avg(:, 2)]) * Ts; % y

                stateVec(idx, 1, 1) = xg(1:end-1);
                stateVec(idx, 2, 1) = yg(1:end-1);

                initPos = [xg(end), yg(end), theta_f]; % Update initial position for next segment
            end

            stateVec(end, :, 1) = initPos; % Set final position

            wheelVelVec = app.inverseKinematics(stateVec(:, :, 2)')'; % Compute wheel velocities
        end

        function [Wa, Wb, Wc] = inverseKinematics(app, Vx, Vy, Omega)
            % Inverse kinematics for three-wheeled omnidirectional robot

            if nargin == 4
                W = app.IK * [Vx; Vy; Omega];
                Wa = W(1, :);
                Wb = W(2, :);
                Wc = W(3, :);
            elseif nargin == 2
                Wa = app.IK * Vx;
            else
                error('Invalid number of input arguments for inverseKinematics.');
            end
        end
    end

    % App creation and deletion
    methods (Access = public)

        % Construct app
        function app = TrackGen

            app.updateKinematicMatrix();

            % Create UIFigure and components
            createComponents(app)

            % Register the app with App Designer
            registerApp(app, app.UIFigure)

            if nargout == 0
                clear app
            end
        end

        % Code that executes before app deletion
        function delete(app)

            % Delete UIFigure when app is deleted
            delete(app.UIFigure)
        end
    end
end

function x = clamp(x, lower, upper)
    x = min(max(x, lower), upper);
end

function homeAxis(ax, pos)
    persistent recursed
    xbound = [Inf, -Inf];
    ybound = [Inf, -Inf];

    % Check for double Y axes
    if numel(ax.YAxis) > 1 && isempty(recursed)
        prevLocation = ax.YAxisLocation; 
        
        recursed = true;
        yyaxis(ax, 'left');
        homeAxis(ax, pos)

        yyaxis(ax, 'right');
        homeAxis(ax, pos)

        yyaxis(ax, prevLocation);

        recursed = [];
        return
    end

    % Calculate minimum and maximum bounds of all axes childs
    for ii = 1:numel(ax.Children)
        child = ax.Children(ii);
        if isprop(child, 'XData') && ~isempty(child.XData)
            xbound(1) = min(min(child.XData), xbound(1));
            xbound(2) = max(max(child.XData), xbound(2));
            ybound(1) = min(min(child.YData), ybound(1));
            ybound(2) = max(max(child.YData), ybound(2));
        elseif isprop(child, 'Position')
            xbound(1) = min(child.Position(1), xbound(1));
            xbound(2) = max(child.Position(1), xbound(2));
            ybound(1) = min(child.Position(2), ybound(1));
            ybound(2) = max(child.Position(2), ybound(2));
        end
    end
    
    xbound(isinf(xbound)) = 0;
    ybound(isinf(ybound)) = 0;

    if nargin < 2
        pos(1) = sum(xbound)/2;
        pos(2) = sum(ybound)/2;
    else
        if isnan(pos(1))
            pos(1) = sum(xbound)/2;
        end
        if isnan(pos(2))
            pos(2) = sum(ybound)/2;
        end
    end
    
    % Calculate max distance from center
    xmax = clamp(max(abs(xbound - pos(1))), 1e-3, 1e6); % Minimum allowed distance is 1 mm
    ymax = clamp(max(1.1*abs(ybound - pos(2))), 1e-3, 1e6);

    range = [2*xmax 2*ymax];

    if ax.PlotBoxAspectRatioMode == "auto"
        ax.XLim = [-xmax xmax] + pos(1);
        ax.YLim = [-ymax ymax] + pos(2);
    else
        % Compute aspect ratio
        boxAr = ax.PlotBoxAspectRatio(1)/ax.PlotBoxAspectRatio(2); % Actual axes AR
        reqAr = range(1)/range(2); % AR of bounding box
    
        % Set axes limits
        if boxAr > reqAr
            ax.YLim = [-ymax ymax];
            ax.XLim = ax.YLim*boxAr + pos(1);
            ax.YLim = ax.YLim + pos(2);
        else
            ax.XLim = [-xmax xmax];
            ax.YLim = ax.XLim/boxAr + pos(2);
            ax.XLim = ax.XLim + pos(1);
        end
    end
end

function [x, y] = drawArrow(xi, yi, o, headLen, shaftLen)
    % Draw arrows at specified positions and orientations
    numArrows = length(xi);
    shaftLen = reshape(shaftLen, 1, []);
    headLen = reshape(headLen, 1, []);
    arrowLen = shaftLen + headLen;
    xref = reshape([zeros(1, numArrows); arrowLen .* ones(1, numArrows); shaftLen .* ones(1, numArrows); nan(1, numArrows); ...
                    shaftLen .* ones(1, numArrows); arrowLen .* ones(1, numArrows); nan(1, numArrows)], [], 1);
    yref = reshape([zeros(1, numArrows); zeros(1, numArrows); headLen/4 .* ones(1, numArrows); nan(1, numArrows); ...
                    -headLen/4 .* ones(1, numArrows); zeros(1, numArrows); nan(1, numArrows)], [], 1);

    % Rotate arrows
    o = reshape(repmat(o', 7, 1), [], 1);
    x = cos(o) .* xref - sin(o) .* yref;
    y = sin(o) .* xref + cos(o) .* yref;

    % Translate arrows
    x = x + reshape(repmat(xi', 7, 1), [], 1);
    y = y + reshape(repmat(yi', 7, 1), [], 1);
end

function fpath = getFilePath()
    path = mfilename('fullpath');
    idx = find(path == '\', 1, 'last');
    fpath = path(1:idx);
end

function [Tacc_cmd, Tj_cmd] = getAdjustedTimes(Ts, t_span, t_lim, Tacc, Tj)
    if t_span < t_lim && Tacc > 0
        % Adjust acceleration times
        scale = t_span / t_lim;
        if Tj > 0
            Tacc_cmd = max(round(Tacc * scale / Ts) * Ts, Ts*2);
            Tj_cmd = max(round(Tj * scale / Ts) * Ts, Ts);
        else
            Tacc_cmd = max(round(Tacc * scale / Ts) * Ts, Ts);
            Tj_cmd = 0;
        end
    else
        Tacc_cmd = Tacc;
        Tj_cmd = Tj;
    end
end

function [vel, alpha, omega, t, d] = getMotionCommand(vel, pIni, pEnd, angVelocity, rotDir)
%GETMOTIONCOMMAND Calculate the required motion command to reach the target in a single move.
%   Syntax:
%   [vel, alpha, omega, t, lineTime] = GETMOTIONCOMMAND(vel,initialPos,finalPos,defaultOmega)
%
%   [vel, alpha, omega, t, lineTime] = GETMOTIONCOMMAND(vel,initialPos,finalPos,defaultOmega,rotationDirection)
%
% Inputs:
%   vel                 - Linear velocity
%   initialPos          - Initial robot position expressed as a 3-element
%                           vector representing the X, Y and theta coordinates
%   finalPos            - Desired final position
%   defaultOmega        - Default omega used for rotation only movements.
%                           It can be defined as a 2 element vector
%                           containing [defaultOmega, maximumOmega]
%   rotationDirection   - Can be either 'clockwise' or 'counterclockwise'.
%                           If ommitted the shortest rotation is used.
%
% Outputs:
%   vel     - Linear velocity (in m/s)
%   alpha   - Movement direction (in rad)
%   omega   - Rotational velocity (in rad/s)
%   t       - Movement duration (in seconds)
%   d       - Distance to target in a straight line

    beta = rem(pEnd(3)-pIni(3), 2*pi);

    % Parse input
    % If no rotation direction is specified choose the shortest
    if nargin < 5
        if beta > pi
            beta = beta-2*pi;
        elseif beta < -pi
            beta = beta+2*pi;
        end
        if beta > 0
            rotDir = 'counterclockwise';
        else
            rotDir = 'clockwise';
        end
    end

    % Rotation only
    if abs(pEnd(1) - pIni(1)) < 1e-3 && abs(pEnd(2) - pIni(2)) < 1e-3
        omega = abs(angVelocity(1))*sign(beta);
        alpha = 0;
        vel = 0;
    else
    % Rotation + translation
        switch lower(rotDir)
            case 'clockwise'
                if beta > 0
                    beta = beta-2*pi;
                end
                vel = -abs(vel);
            case 'counterclockwise'
                if beta < 0
                    beta = beta+2*pi;
                end
                vel = abs(vel);
            otherwise
                error(['Unknown rotation direction ''%s''. It must be either ' ...
                    '''clockwise'' or ''counterclockwise'''], rotDir)
        end
        
        % Radius of arc
        % For beta == 0 -> R = Inf
        R = sqrt(((pEnd(1)-pIni(1))^2 + (pEnd(2)-pIni(2))^2)/(2*(1-cos(beta))));
        % Division by Inf results in 0
        omega = vel/R;
        alpha = atan2(pEnd(2)-pIni(2), pEnd(1)-pIni(1)) - pIni(3) - beta/2;
        alpha = mod(alpha + pi, 2*pi) - pi; % Normalize between -pi and +pi (-180º to 180º)

        if numel(angVelocity) > 1 && abs(omega) > angVelocity(2)
            omega = abs(angVelocity(2))*sign(omega);
            vel = abs(omega*R);
        else
            vel = abs(vel);
        end
    end

    d = hypot(pEnd(1)-pIni(1), pEnd(2)-pIni(2));
    if abs(omega) < 1e-3
        t = d/vel;
    else
        t = beta/omega;
    end
    assert(t >= 0, 'Invalid time')
end

function [vel, alpha, omega] = getMotionCommandByTime(t_mov, pIni, pEnd, v_i, a_i, v_f, a_f, t_acc, t_dec, t_j_A, t_j_D, options)
%GETMOTIONCOMMANDBYTIME Calculate the required motion command to reach the target in a single move in the specified time.
%   Syntax:
%   [vel, alpha, omega, t, lineTime] = GETMOTIONCOMMANDBYTIME(t,initialPos,finalPos,)
%
%   [vel, alpha, omega, t, lineTime] = GETMOTIONCOMMANDBYTIME(t,initialPos,finalPos,rotationDirection)
%
% Inputs:
%   t                   - Movement duration (in seconds)
%   initialPos          - Initial robot position expressed as a 3-element
%                           vector representing the X, Y and theta coordinates
%   finalPos            - Desired final position
%   rotationDirection   - Can be either 'clockwise' or 'counterclockwise'.
%                           If ommitted the shortest rotation is used.
%
% Outputs:
%   vel     - Linear velocity (in m/s)
%   alpha   - Movement direction (in rad)
%   omega   - Rotational velocity (in rad/s)
%   t       - Movement duration (in seconds)
%   d       - Distance to target in a straight line

    arguments
        t_mov   (1,1)   double  {mustBeNonnegative}
        pIni    (1,3)   double
        pEnd    (1,3)   double
        v_i     (1,3)   double = [0,0,0]
        a_i     (1,3)   double = [0,0,0]
        v_f     (1,3)   double = [0,0,0]
        a_f     (1,3)   double = [0,0,0]
        t_acc   (1,1)   double = 0
        t_dec   (1,1)   double = 0
        t_j_A   (1,1)   double = 0
        t_j_D   (1,1)   double = 0
        options.rotationDirection {mustBeTextScalar} = 'shortest'
    end

    % Parse input
    switch lower(options.rotationDirection)
        case 'clockwise'
            beta = rem(pEnd(3)-pIni(3), 2*pi);
            if beta > 0
                beta = beta-2*pi;
            end
        case 'counterclockwise'
            beta = rem(pEnd(3)-pIni(3), 2*pi);
            if beta < 0
                beta = beta+2*pi;
            end
        case 'shortest'
            beta = rem(pEnd(3)-pIni(3), 2*pi);
            if beta > pi
                beta = beta-2*pi;
            elseif beta < -pi
                beta = beta+2*pi;
            end
        case 'free'
            beta = pEnd(3)-pIni(3);
        otherwise
            error(['Unknown rotation direction ''%s''. It must be either ' ...
                '''clockwise'', ''counterclockwise'', ''shortest'' or ''free'''], options.rotationDirection)
    end

    % Calculate required omega
    omega = (- 2*a_i(3)*t_j_A^2 + 3*a_i(3)*t_acc*t_j_A + 2*a_f(3)*t_j_D^2 - 3*a_f(3)*t_dec*t_j_D - 12*beta + 6*t_acc*v_i(3) + 6*t_dec*v_f(3))/(6*(t_acc + t_dec - 2*t_mov));

    dist = hypot(pEnd(1)-pIni(1), pEnd(2)-pIni(2));
    % Rotation only
    if dist < 1e-3
        alpha = 0;
        vel = 0;
    else
    % Rotation + translation
        beta = rem(beta, 2*pi);
        % Ideal motion with instant acceleration
        % Radius of arc
        % For beta == 0 -> R = Inf
        R = sqrt(((pEnd(1)-pIni(1))^2 + (pEnd(2)-pIni(2))^2)/(2*(1-cos(beta))));

        vel = abs(omega*R);

        if isnan(vel) || isinf(vel)
            vel = dist/t_mov;
        end

        alpha = atan2(pEnd(2)-pIni(2), pEnd(1)-pIni(1)) - pIni(3) - beta/2;
        alpha = mod(alpha + pi, 2*pi) - pi; % Normalize between -pi and +pi (-180º to 180º)

        if t_acc + t_dec > 0
            % Motion profile with acceleration and deceleration
            % Uses ideal motion as initial guess
            vx_i = vel * cos(alpha);
            vy_i = vel * sin(alpha);

            opts = optimoptions("fsolve", "Display", "off");
            V_cr = fsolve(@fun, [vx_i, vy_i], opts);

            vel = hypot(V_cr(1), V_cr(2));
            alpha = atan2(V_cr(2), V_cr(1));
        end
    end

    function ret = fun(V)
        tmp = getProfileFinalPose(pIni, v_i, a_i, v_f, a_f, [V(1), V(2), omega], t_acc, t_dec, t_j_A, t_j_D, t_mov) - pEnd;
        ret = [tmp(1); tmp(2)];
    end
end

function pose = getProfileFinalPose(iniPose, v_i, a_i, v_f, a_f, v_cr, t_acc, t_dec, t_j_A, t_j_D, t_mov)
    arguments
        iniPose (1,3) double
        v_i     (1,3) double
        a_i     (1,3) double
        v_f     (1,3) double
        a_f     (1,3) double
        v_cr    (1,3) double
        t_acc   (1,1) double
        t_dec   (1,1) double
        t_j_A   (1,1) double
        t_j_D   (1,1) double
        t_mov   (1,1) double
    end

    t_A = t_j_A;
    t_B = t_acc - 2*t_j_A;
    t_C = t_A;
    t_D = t_mov - t_acc - t_dec;
    t_E = t_j_D;
    t_F = t_dec - 2*t_j_D;
    t_G = t_E;

    % Initial ramp
    if t_acc > 0
        v_iB = v_i + a_i.*t_j_A - (t_j_A.*(a_i + (v_i - v_cr + (a_i.*t_j_A)/2)./(t_acc - t_j_A)))/2;
        v_iC = (4*t_acc.*v_cr - 6*t_j_A.*v_cr + 2*t_j_A.*v_i + a_i.*t_j_A.^2)./(4*(t_acc - t_j_A));

        a_B = -(v_i - v_cr + (a_i.*t_j_A)/2)/(t_acc - t_j_A);
        
        j_A = -(a_i + (v_i - v_cr + (a_i.*t_j_A)/2)/(t_acc - t_j_A))/t_j_A;
        j_C = (v_i - v_cr + (a_i.*t_j_A)/2)/(t_j_A*(t_acc - t_j_A));

        poseA = getFinalPose(iniPose, v_i, a_i, j_A, t_A); % Phase A
        poseB = getFinalPose(poseA, v_iB, a_B, [0,0,0], t_B); % Phase B
        poseC = getFinalPose(poseB, v_iC, a_B, j_C, t_C); % Phase C
    else
        poseC = iniPose;
    end

    % Constant velocity phase
    poseD = getFinalPose(poseC, v_cr, [0,0,0], [0,0,0], t_D); % Phase D

    % Final ramp
    if t_dec > 0
        a_F = -(v_cr - v_f + (a_f.*t_j_D)/2)/(t_dec - t_j_D);

        j_E = -(v_cr - v_f + (a_f.*t_j_D)/2)/(t_j_D*(t_dec - t_j_D));
        j_G = (a_f + (v_cr - v_f + (a_f.*t_j_D)/2)/(t_dec - t_j_D))/t_j_D;

        v_iF = v_cr - (t_j_D.*(v_cr - v_f + (a_f.*t_j_D)/2))./(2*(t_dec - t_j_D));
        v_iG = (4*t_dec.*v_f + 2*t_j_D.*v_cr - 6*t_j_D.*v_f + 3*a_f.*t_j_D.^2 - 2*a_f.*t_dec.*t_j_D)./(4*(t_dec - t_j_D));

        poseE = getFinalPose(poseD, v_cr, [0,0,0], j_E, t_E); % Phase E
        poseF = getFinalPose(poseE, v_iF, a_F, [0,0,0], t_F); % Phase F
        pose = getFinalPose(poseF, v_iG, a_F, j_G, t_G); % Phase G
    else
        pose = poseD;
    end
end

function pose = getFinalPose(iniPose, V, A, J, t)
    if V(3) == 0 && A(3) == 0 && J(3) == 0
        % No rotation
        pose(1) = iniPose(1) + (V(1)*cos(iniPose(3)) - V(2)*sin(iniPose(3)))*t + (A(1)*cos(iniPose(3)) - A(2)*sin(iniPose(3)))*t^2/2 + (J(1)*cos(iniPose(3)) - J(2)*sin(iniPose(3)))*t^3/6;
        pose(2) = iniPose(2) + (V(1)*sin(iniPose(3)) + V(2)*cos(iniPose(3)))*t + (A(1)*sin(iniPose(3)) + A(2)*cos(iniPose(3)))*t^2/2 + (J(1)*sin(iniPose(3)) + J(2)*cos(iniPose(3)))*t^3/6;
        pose(3) = iniPose(3);
    elseif A(3) == 0 && J(3) == 0
        % Constant angular velocity
        theta_i = iniPose(3);
        v_x_i = V(1);
        v_y_i = V(2);
        omega = V(3);
        a_x = A(1);
        a_y = A(2);
        j_x = J(1);
        j_y = J(2);
        K1 = iniPose(1) + (sin(theta_i)*(- v_x_i*omega^2 + a_y*omega + j_x))/omega^3 - (cos(theta_i)*(v_y_i*omega^2 + a_x*omega - j_y))/omega^3;
        K2 = iniPose(2) - (cos(theta_i)*(- v_x_i*omega^2 + a_y*omega + j_x))/omega^3 - (sin(theta_i)*(v_y_i*omega^2 + a_x*omega - j_y))/omega^3;
        pose(1) = K1 - (sin(theta_i + omega*t)*(- v_x_i*omega^2 + a_y*omega + j_x))/omega^3 + (cos(theta_i + omega*t)*(v_y_i*omega^2 + a_x*omega - j_y))/omega^3 + ...
            (t*cos(theta_i + omega*t)*(j_x + a_y*omega))/omega^2 - (t*sin(theta_i + omega*t)*(j_y - a_x*omega))/omega^2 + (j_y*t^2*cos(theta_i + omega*t))/(2*omega) + ...
            (j_x*t^2*sin(theta_i + omega*t))/(2*omega);
        pose(2) = K2 + (cos(theta_i + omega*t)*(- v_x_i*omega^2 + a_y*omega + j_x))/omega^3 + (sin(theta_i + omega*t)*(v_y_i*omega^2 + a_x*omega - j_y))/omega^3 + ...
            (t*cos(theta_i + omega*t)*(j_y - a_x*omega))/omega^2 + (t*sin(theta_i + omega*t)*(j_x + a_y*omega))/omega^2 - (j_x*t^2*cos(theta_i + omega*t))/(2*omega) + ...
            (j_y*t^2*sin(theta_i + omega*t))/(2*omega);
        pose(3) = iniPose(3) + omega * t;
    elseif all(A == 0) && all(J == 0)
        % Constant velocity
        k1 = iniPose(1) - (V(1)*sin(iniPose(3)) + V(2)*cos(iniPose(3)))/V(3);
        k2 = iniPose(2) - (-V(1)*cos(iniPose(3)) + V(2)*sin(iniPose(3)))/V(3);
        pose(1) = k1 + (V(1)*sin(iniPose(3) + V(3)*t) + V(2)*cos(iniPose(3) + V(3)*t))/V(3);
        pose(2) = k2 + (-V(1)*cos(iniPose(3) + V(3)*t) + V(2)*sin(iniPose(3) + V(3)*t))/V(3);
        pose(3) = iniPose(3) + V(3) * t;
    else
        % General case with acceleration and/or jerk
        pose(1:2) = integral(@(x) globalVelocity(x, iniPose(3), V, A, J), 0, t, 'ArrayValued', true) + iniPose(1:2);
        pose(3) = iniPose(3) + V(3) * t + A(3) * t^2 / 2 + J(3) * t^3 / 6;
    end
end

function Vg = globalVelocity(t, theta_i, V, A, J)
    theta = theta_i + V(:,3) .* t + A(:,3) .* t.^2 / 2 + J(:,3) .* t.^3 / 6;
    vx = V(:,1) + A(:,1) .* t + J(:,1) .* t.^2 / 2;
    vy = V(:,2) + A(:,2) .* t + J(:,2) .* t.^2 / 2;
    Vg = [vx .* cos(theta) - vy .* sin(theta), vx .* sin(theta) + vy .* cos(theta)];
end
