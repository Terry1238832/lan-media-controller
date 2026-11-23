using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using LanMediaController.Models;
using LanMediaController.Services;

namespace LanMediaController;

public partial class MainWindow : Window
{
    private readonly SyncEngine _engine = new();
    private readonly DispatcherTimer _uiTimer;
    private readonly Dictionary<string, PlayerCardWidget> _cards = new();
    private System.Windows.Forms.NotifyIcon? _trayIcon;
    private bool _reallyExiting;

    public MainWindow()
    {
        InitializeComponent();

        DeviceNameBox.Text = _engine.DeviceName;
        _engine.StateUpdated += () => Dispatcher.BeginInvoke(RefreshUI);

        _uiTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _uiTimer.Tick += (_, _) => UpdateCardTimelinesOnly();
        _uiTimer.Start();

        SetupTrayIcon();
        Loaded += async (_, _) =>
        {
            RefreshUI();
            await _engine.StartAsync();
            RefreshUI();
        };
    }

    private void SetupTrayIcon()
    {
        try
        {
            var exePath = Environment.ProcessPath;
            System.Drawing.Icon? appIcon = !string.IsNullOrEmpty(exePath) ? System.Drawing.Icon.ExtractAssociatedIcon(exePath) : null;
            _trayIcon = new System.Windows.Forms.NotifyIcon
            {
                Text = "四端局域网媒体控制器",
                Icon = appIcon ?? System.Drawing.SystemIcons.Application,
                Visible = true
            };
            var menu = new System.Windows.Forms.ContextMenuStrip();
            menu.Items.Add("打开主窗口", null, (_, _) => Dispatcher.Invoke(ShowFromTray));
            menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            menu.Items.Add("退出程序", null, (_, _) => Dispatcher.Invoke(ExitCompletely));
            _trayIcon.ContextMenuStrip = menu;
            _trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowFromTray);
        }
        catch { }
    }

    private void ShowFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private void ExitCompletely()
    {
        _reallyExiting = true;
        _uiTimer.Stop();
        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayIcon = null;
        }
        _engine.Dispose();
        System.Windows.Application.Current.Shutdown();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_reallyExiting && _trayIcon != null)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnClosing(e);
    }

    private void SaveNameBtn_Click(object sender, RoutedEventArgs e)
    {
        _engine.SaveDeviceName(DeviceNameBox.Text);
    }

    private void CreateRoomBtn_Click(object sender, RoutedEventArgs e)
    {
        _engine.CreateRoom();
    }

    private void JoinRoomBtn_Click(object sender, RoutedEventArgs e)
    {
        _engine.JoinRoom(JoinCodeBox.Text);
        JoinCodeBox.Text = "";
    }

    private void JoinCodeBox_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            _engine.JoinRoom(JoinCodeBox.Text);
            JoinCodeBox.Text = "";
        }
    }

    private void CopyCodeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_engine.CurrentRoomCode)) return;
        System.Windows.Clipboard.SetText(_engine.CurrentRoomCode);
        CopyCodeBtn.Content = "已复制";
        var reset = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        reset.Tick += (_, _) => { CopyCodeBtn.Content = "复制"; reset.Stop(); };
        reset.Start();
    }

    private void LeaveRoomBtn_Click(object sender, RoutedEventArgs e)
    {
        _engine.LeaveRoom();
    }

    private void RefreshUI()
    {
        LanNameText.Text = _engine.DisplayedLanName;

        bool inRoom = !string.IsNullOrEmpty(_engine.CurrentRoomCode);
        LobbyPanel.Visibility = inRoom ? Visibility.Collapsed : Visibility.Visible;
        ActiveRoomPanel.Visibility = inRoom ? Visibility.Visible : Visibility.Collapsed;
        RoomCodeText.Text = inRoom ? _engine.CurrentRoomCode : "----";

        var rooms = _engine.GetDiscoveredRoomsSnapshot();
        if (!inRoom && rooms.Count > 0)
        {
            DiscoveredRoomsPanel.Visibility = Visibility.Visible;
            DiscoveredRoomsPanel.Children.Clear();
            DiscoveredRoomsPanel.Children.Add(new TextBlock
            {
                Text = "局域网房间：",
                FontSize = 12,
                Foreground = BrushFromHex("#94A3B8"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 6, 4)
            });
            foreach (var code in rooms)
            {
                var btn = new System.Windows.Controls.Button
                {
                    Content = $"#{code}",
                    Style = (Style)FindResource("DarkButtonStyle"),
                    Background = BrushFromHex("#1E3A5F"),
                    Foreground = BrushFromHex("#60A5FA"),
                    FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                    FontSize = 12,
                    Padding = new Thickness(10, 4, 10, 4),
                    Margin = new Thickness(0, 0, 6, 4)
                };
                var roomCodeCopy = code;
                btn.Click += (_, _) => _engine.JoinRoom(roomCodeCopy);
                DiscoveredRoomsPanel.Children.Add(btn);
            }
        }
        else
        {
            DiscoveredRoomsPanel.Visibility = Visibility.Collapsed;
        }

        var peers = _engine.GetRoomPeersSnapshot();
        SectionTitleText.Text = inRoom ? "房间内设备播放器" : "本机媒体播放器";
        DeviceCountText.Text = inRoom ? $"共 {1 + peers.Count} 台设备在线" : "未加入房间";

        var desired = new List<(string id, string name, string platform, string connMode, PlayerState player)>
        {
            (_engine.DeviceId, _engine.DeviceName, "windows", "本机", _engine.GetLocalPlayerSnapshot())
        };
        foreach (var p in peers)
            desired.Add((p.DeviceId, p.DeviceName, p.Platform, p.ConnectionMode, p.Player));

        var desiredIds = desired.Select(d => d.id).ToHashSet();
        var toRemove = _cards.Keys.Where(k => !desiredIds.Contains(k)).ToList();
        foreach (var id in toRemove)
        {
            PlayersContainer.Children.Remove(_cards[id].Root);
            _cards.Remove(id);
        }

        var now = ProtocolJson.NowMillis();
        for (int i = 0; i < desired.Count; i++)
        {
            var item = desired[i];
            if (!_cards.TryGetValue(item.id, out var card))
            {
                card = new PlayerCardWidget(
                    item.id,
                    (Style)FindResource("DarkButtonStyle"),
                    (action, pos) => _engine.SendCommand(item.id, action, pos));
                _cards[item.id] = card;
                PlayersContainer.Children.Add(card.Root);
            }
            card.Update(item.name, item.platform, item.connMode, item.player, now);
        }
    }

    private void UpdateCardTimelinesOnly()
    {
        var now = ProtocolJson.NowMillis();
        foreach (var card in _cards.Values)
            card.TickTimeline(now);
    }

    internal static SolidColorBrush BrushFromHex(string hex) =>
        (SolidColorBrush)new BrushConverter().ConvertFromString(hex)!;
}

internal sealed class PlayerCardWidget
{
    public Border Root { get; }
    private readonly Border _platformBadge;
    private readonly TextBlock _platformText;
    private readonly TextBlock _deviceNameText;
    private readonly Border _connBadge;
    private readonly TextBlock _connText;
    private readonly Border _appBadge;
    private readonly TextBlock _appText;
    private readonly Ellipse _statusDot;
    private readonly TextBlock _trackText;
    private readonly Slider _slider;
    private readonly TextBlock _posText;
    private readonly TextBlock _durText;
    private readonly System.Windows.Controls.Button _toggleBtn;

    private PlayerState _lastPlayer = new();
    private bool _isDragging;

    public PlayerCardWidget(string deviceId, Style buttonStyle, Action<string, double> onCommand)
    {
        _platformText = new TextBlock { FontSize = 11, FontWeight = FontWeights.Bold };
        _platformBadge = new Border { CornerRadius = new CornerRadius(7), Padding = new Thickness(9, 3, 9, 3), Margin = new Thickness(0, 0, 8, 0), Child = _platformText };

        _deviceNameText = new TextBlock
        {
            FontSize = 15,
            FontWeight = FontWeights.Bold,
            Foreground = MainWindow.BrushFromHex("#F8FAFC"),
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis
        };

        _connText = new TextBlock { FontSize = 10, FontWeight = FontWeights.SemiBold };
        _connBadge = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(7, 2, 7, 2), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Child = _connText };

        _appText = new TextBlock { FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = MainWindow.BrushFromHex("#FACC15") };
        _appBadge = new Border { Background = MainWindow.BrushFromHex("#2E2A16"), CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 3, 8, 3), HorizontalAlignment = System.Windows.HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Child = _appText };

        var topGrid = new Grid { Margin = new Thickness(0, 0, 0, 10) };
        topGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        Grid.SetColumn(_platformBadge, 0);
        Grid.SetColumn(_deviceNameText, 1);
        Grid.SetColumn(_connBadge, 2);
        Grid.SetColumn(_appBadge, 3);
        topGrid.Children.Add(_platformBadge);
        topGrid.Children.Add(_deviceNameText);
        topGrid.Children.Add(_connBadge);
        topGrid.Children.Add(_appBadge);

        _statusDot = new Ellipse { Width = 8, Height = 8, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };
        _trackText = new TextBlock { FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var trackRow = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(_statusDot, Dock.Left);
        trackRow.Children.Add(_statusDot);
        trackRow.Children.Add(_trackText);

        // Control 1: Progress Bar (Seek + Start Playing)
        _slider = new Slider
        {
            Minimum = 0,
            Maximum = 300,
            IsMoveToPointEnabled = true,
            Margin = new Thickness(0, 0, 0, 4)
        };
        _slider.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => _isDragging = true));
        _slider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) =>
        {
            if (_isDragging)
            {
                _isDragging = false;
                onCommand("seek", _slider.Value);
            }
        }));
        _slider.PreviewMouseLeftButtonDown += (_, _) => _isDragging = true;
        _slider.PreviewMouseLeftButtonUp += (_, _) =>
        {
            if (_isDragging)
            {
                _isDragging = false;
                onCommand("seek", _slider.Value);
            }
        };
        _slider.ValueChanged += (_, _) =>
        {
            if (_isDragging)
                _posText.Text = ProtocolJson.FormatSeconds(_slider.Value);
        };

        _posText = new TextBlock { FontFamily = new System.Windows.Media.FontFamily("Consolas"), FontSize = 11, Foreground = MainWindow.BrushFromHex("#94A3B8") };
        _durText = new TextBlock { FontFamily = new System.Windows.Media.FontFamily("Consolas"), FontSize = 11, Foreground = MainWindow.BrushFromHex("#94A3B8"), HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
        var timeGrid = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        timeGrid.Children.Add(_posText);
        timeGrid.Children.Add(_durText);

        // Controls 2, 3, 4: Previous, Play/Pause, Next (ONLY 4 controls total!)
        var prevBtn = new System.Windows.Controls.Button { Content = "⏮ 上一章", Style = buttonStyle, Background = MainWindow.BrushFromHex("#24334E"), Margin = new Thickness(0, 0, 8, 0) };
        prevBtn.Click += (_, _) => onCommand("prev", 0);

        _toggleBtn = new System.Windows.Controls.Button { Content = "▶ 播放", Style = buttonStyle, Background = MainWindow.BrushFromHex("#3B82F6"), FontSize = 14, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 8, 0) };
        _toggleBtn.Click += (_, _) => onCommand("toggle", 0);

        var nextBtn = new System.Windows.Controls.Button { Content = "⏭ 下一章", Style = buttonStyle, Background = MainWindow.BrushFromHex("#24334E") };
        nextBtn.Click += (_, _) => onCommand("next", 0);

        var btnGrid = new Grid();
        btnGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        btnGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.15, GridUnitType.Star) });
        btnGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(prevBtn, 0);
        Grid.SetColumn(_toggleBtn, 1);
        Grid.SetColumn(nextBtn, 2);
        btnGrid.Children.Add(prevBtn);
        btnGrid.Children.Add(_toggleBtn);
        btnGrid.Children.Add(nextBtn);

        var body = new StackPanel();
        body.Children.Add(topGrid);
        body.Children.Add(trackRow);
        body.Children.Add(_slider);
        body.Children.Add(timeGrid);
        body.Children.Add(btnGrid);

        Root = new Border
        {
            Background = MainWindow.BrushFromHex("#162036"),
            BorderBrush = MainWindow.BrushFromHex("#24334F"),
            BorderThickness = new Thickness(1.2),
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(16),
            Margin = new Thickness(0, 0, 0, 12),
            Child = body
        };
    }

    public void Update(string deviceName, string platform, string connMode, PlayerState player, long nowMs)
    {
        _lastPlayer = player.Clone();

        _platformText.Text = ProtocolJson.PlatformDisplayName(platform);
        var (badgeBg, badgeFg) = platform.ToLowerInvariant() switch
        {
            "windows" => ("#1E3A5F", "#60A5FA"),
            "macos" => ("#332152", "#C084FC"),
            "ios" => ("#4C1D3D", "#F472B6"),
            "android" => ("#143C33", "#34D399"),
            _ => ("#1E293B", "#CBD5E1")
        };
        _platformBadge.Background = MainWindow.BrushFromHex(badgeBg);
        _platformText.Foreground = MainWindow.BrushFromHex(badgeFg);

        _deviceNameText.Text = deviceName;

        _connText.Text = connMode;
        bool isLan = connMode == "局域网直连";
        _connBadge.Background = MainWindow.BrushFromHex(isLan ? "#143C33" : "#222E44");
        _connText.Foreground = MainWindow.BrushFromHex(isLan ? "#34D399" : "#94A3B8");

        if (!string.IsNullOrWhiteSpace(player.AppName))
        {
            _appText.Text = player.AppName;
            _appBadge.Visibility = Visibility.Visible;
        }
        else
        {
            _appBadge.Visibility = Visibility.Collapsed;
        }

        _statusDot.Fill = MainWindow.BrushFromHex(player.IsPlaying ? "#10B981" : "#64748B");
        _trackText.Text = player.DisplayTrackLine();
        _trackText.Foreground = MainWindow.BrushFromHex(player.HasMedia ? "#E2E8F0" : "#64748B");

        _toggleBtn.Content = player.IsPlaying ? "⏸ 暂停" : "▶ 播放";
        _toggleBtn.Background = MainWindow.BrushFromHex(player.IsPlaying ? "#10B981" : "#3B82F6");
        Root.BorderBrush = MainWindow.BrushFromHex(player.IsPlaying ? "#10B981" : "#24334F");

        TickTimeline(nowMs);
    }

    public void TickTimeline(long nowMs)
    {
        if (_isDragging) return;
        var maxDur = Math.Max(1.0, _lastPlayer.Duration > 0 ? _lastPlayer.Duration : 300.0);
        var pos = Math.Min(maxDur, _lastPlayer.LivePosition(nowMs));
        _slider.Maximum = maxDur;
        _slider.Value = pos;
        _posText.Text = ProtocolJson.FormatSeconds(pos);
        _durText.Text = _lastPlayer.Duration > 0 ? ProtocolJson.FormatSeconds(_lastPlayer.Duration) : "--:--";
    }
}
