# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Ecstasy (https://github.com/xfhrv)

# =====================================================================
#  触摸板调速器 (Touchpad Tuner)
#  单独调节 Windows Precision Touchpad 的指针速度，鼠标指针速度保持不变。
#
#  实现方式：SystemParametersInfo(SPI_GET/SETTOUCHPADPARAMETERS)
#  - 只影响触摸板光标速度，不修改全局鼠标速度
#  - 设置会写入当前用户设置并立即生效
#  - 不使用驱动、不需要管理员权限
# =====================================================================

param([switch]$Background)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
try { Add-Type -AssemblyName System.Drawing } catch { }
try { Add-Type -AssemblyName System.Windows.Forms } catch { }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class TouchpadApi
{
    public const uint SPI_GETMOUSESPEED = 0x0070;
    public const uint SPI_GETTOUCHPADPARAMETERS = 0x00AE;
    public const uint SPI_SETTOUCHPADPARAMETERS = 0x00AF;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    public static string LastError = "";
    public static string ModeName = "";
    public static int Mode = 0;

    private struct Spec
    {
        public int Mode;
        public uint UiParam;
        public int Size;
        public int SpeedOffset;
        public int SensitivityOffset;
        public int Version;
    }

    private static readonly Spec[] Specs = new Spec[]
    {
        new Spec { Mode = 1, UiParam = 24, Size = 24, SpeedOffset = 16, SensitivityOffset = 8,  Version = 0 },
        new Spec { Mode = 2, UiParam = 44, Size = 44, SpeedOffset = 24, SensitivityOffset = 20, Version = 1 },
        new Spec { Mode = 3, UiParam = 48, Size = 48, SpeedOffset = 24, SensitivityOffset = 20, Version = 2 }
    };

    public static void TryEnableDpiAwareness()
    {
        try { SetProcessDPIAware(); } catch { }
    }

    public static bool ActivateWindow(string title)
    {
        try
        {
            IntPtr h = FindWindowW(null, title);
            if (h == IntPtr.Zero) return false;
            ShowWindow(h, 9);
            return SetForegroundWindow(h);
        }
        catch { return false; }
    }

    private static bool Detect(out Spec spec, out byte[] raw)
    {
        raw = null;
        spec = new Spec();
        for (int i = 0; i < Specs.Length; i++)
        {
            Spec s = Specs[i];
            IntPtr buffer = Marshal.AllocHGlobal(256);
            try
            {
                for (int b = 0; b < 256; b++) Marshal.WriteByte(buffer, b, 0);
                Marshal.WriteInt32(buffer, 0, s.Version);
                if (!SystemParametersInfoW(SPI_GETTOUCHPADPARAMETERS, s.UiParam, buffer, 0)) continue;

                byte[] bytes = new byte[s.Size];
                Marshal.Copy(buffer, bytes, 0, s.Size);
                raw = bytes;
                spec = s;
                Mode = s.Mode;
                ModeName = s.Mode == 1 ? "Windows 11 22H2/23H2 接口"
                         : (s.Mode == 2 ? "Windows 11 24H2 接口" : "Windows 11 24H2+ 接口");
                LastError = "";
                return true;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        Mode = 0;
        ModeName = "";
        LastError = "当前系统未提供触摸板独立调速接口（需要 Windows 11 并连接精密触摸板）。";
        return false;
    }

    public static int GetSpeed()
    {
        Spec spec;
        byte[] raw;
        if (!Detect(out spec, out raw)) return -1;
        return BitConverter.ToInt32(raw, spec.SpeedOffset);
    }

    public static bool SetSpeed(int speed, out int actual)
    {
        actual = -1;
        Spec spec;
        byte[] raw;
        if (!Detect(out spec, out raw))
        {
            return false;
        }

        byte[] modified = (byte[])raw.Clone();
        Array.Copy(BitConverter.GetBytes(speed), 0, modified, spec.SpeedOffset, 4);

        IntPtr buffer = Marshal.AllocHGlobal(256);
        try
        {
            for (int b = 0; b < 256; b++) Marshal.WriteByte(buffer, b, 0);
            Marshal.Copy(modified, 0, buffer, modified.Length);
            if (!SystemParametersInfoW(SPI_SETTOUCHPADPARAMETERS, spec.UiParam, buffer, 3))
            {
                LastError = "系统拒绝了本次修改（错误码 " + Marshal.GetLastWin32Error() + "）。";
                return false;
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }

        actual = GetSpeed();
        LastError = "";
        return actual == speed;
    }

    public static int GetMouseSpeed()
    {
        IntPtr buffer = Marshal.AllocHGlobal(8);
        try
        {
            Marshal.WriteInt32(buffer, 0, 10);
            if (SystemParametersInfoW(SPI_GETMOUSESPEED, 0, buffer, 0)) return Marshal.ReadInt32(buffer);
            return -1;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@

[TouchpadApi]::TryEnableDpiAwareness()

# 三指拖曳引擎（可选组件；缺少 DLL 时功能自动禁用，不影响调速功能）
$script:tfdReady = $false
$script:tfdLoadError = ''
try {
    $helperDll = Join-Path $PSScriptRoot 'TouchpadTuner.Helper.dll'
    $helperSrc = Join-Path $PSScriptRoot 'src\ThreeFingerDrag.cs'
    if (Test-Path $helperDll) {
        Add-Type -Path $helperDll
        $script:tfdReady = $true
    } elseif (Test-Path $helperSrc) {
        Add-Type -Path $helperSrc
        $script:tfdReady = $true
    } else {
        $script:tfdLoadError = '未找到 TouchpadTuner.Helper.dll'
    }
} catch {
    $script:tfdLoadError = $_.Exception.Message
}

# ---------------------------------------------------------------------
# 单实例控制：若已有窗口，则把旧窗口带到前台后退出
# ---------------------------------------------------------------------
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\TouchpadTunerApp')
$script:firstInstance = $false
try { $script:firstInstance = $script:mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:firstInstance = $true }

if (-not $script:firstInstance) {
    try {
        $showEvent = [System.Threading.EventWaitHandle]::OpenExisting('Local\TouchpadTunerShowWindow')
        [void]$showEvent.Set()
        $showEvent.Dispose()
    } catch {
        [void][TouchpadApi]::ActivateWindow('触摸板调速器')
    }
    exit
}
$script:showWindowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\TouchpadTunerShowWindow')

# ---------------------------------------------------------------------
# 系统档位 <-> 倍率
# Windows 指针速度档位 1-20 对应一条非线性曲线（默认 10 = 1.0x），
# 触摸板光标速度使用同一曲线。0.5x-2.5x 对应档位 6-16。
# ---------------------------------------------------------------------
$script:Multipliers = @(
    0.03125, 0.0625, 0.125, 0.25, 0.375,
    0.5, 0.625, 0.75, 0.875, 1.0,
    1.25, 1.5, 1.75, 2.0, 2.25,
    2.5, 2.75, 3.0, 3.25, 3.5
)
$script:MinNative = 6
$script:MaxNative = 16
$script:SnapMultipliers = @()
for ($i = $script:MinNative; $i -le $script:MaxNative; $i++) {
    $script:SnapMultipliers += $script:Multipliers[$i - 1]
}

function Get-MultiplierText([double]$value) {
    if ([Math]::Abs($value - [Math]::Round($value)) -lt 1e-9) {
        return $value.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + [char]0x00D7
    }
    return $value.ToString('0.0##', [System.Globalization.CultureInfo]::InvariantCulture) + [char]0x00D7
}

function Get-InputText([double]$value) {
    return $value.ToString('0.00##', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-SnapIndex([double]$value) {
    $best = 0
    $bestDiff = [double]::MaxValue
    for ($i = 0; $i -lt $script:SnapMultipliers.Count; $i++) {
        $diff = [Math]::Abs($script:SnapMultipliers[$i] - $value)
        if ($diff -lt $bestDiff) { $bestDiff = $diff; $best = $i }
    }
    return $best
}

# ---------------------------------------------------------------------
# 界面
# ---------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="触摸板调速器"
        Width="600" Height="780"
        ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen"
        Background="#F4F6F9"
        FontFamily="Microsoft YaHei UI"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F3F4F6"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E5E7EB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="LinkButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#2F6FED"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}">
              <TextBlock x:Name="Tb" Text="{TemplateBinding Content}"
                         Foreground="{TemplateBinding Foreground}" FontSize="{TemplateBinding FontSize}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Tb" Property="TextDecorations" Value="Underline"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="InputBox" TargetType="TextBox">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" CornerRadius="8" BorderBrush="#D1D5DB" BorderThickness="1" Background="White">
              <ScrollViewer x:Name="PART_ContentHost" Margin="6,0" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#2F6FED"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SwitchStyle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Track" Width="46" Height="24" CornerRadius="12" Background="#D1D5DB">
              <Ellipse x:Name="Knob" Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#2F6FED"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="28,22,28,20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 标题 -->
    <StackPanel Grid.Row="0">
      <TextBlock Text="触摸板调速器" FontSize="26" FontWeight="Bold" Foreground="#111827"/>
      <TextBlock Text="单独调节触摸板指针速度，鼠标保持系统原速不变"
                 FontSize="12" Foreground="#6B7280" Margin="0,7,0,0"/>
    </StackPanel>

    <!-- 主卡片 -->
    <Border Grid.Row="1" Margin="0,18,0,0" CornerRadius="14"
            Background="White" BorderBrush="#E5E7EB" BorderThickness="1" Padding="24,20,24,18">
      <StackPanel>
        <TextBlock Text="触摸板当前速度" FontSize="12" Foreground="#6B7280"/>
        <TextBlock x:Name="TxtValue" Text="1.0×" FontSize="44" FontWeight="Bold"
                   Foreground="#2F6FED" Margin="0,2,0,0"/>
        <Grid Margin="0,2,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="TxtRange" Grid.Column="0" Text="可调范围 0.50× – 2.50×"
                     FontSize="12" Foreground="#6B7280" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtNative" Grid.Column="1" Text="系统档位 10 / 20"
                     FontSize="12" Foreground="#6B7280" VerticalAlignment="Center"/>
        </Grid>

        <!-- 自定义滑块 -->
        <Grid x:Name="SliderHost" Height="46" Background="Transparent" Cursor="Hand" Margin="0,12,0,0">
          <Border x:Name="SliderTrackBg" Height="6" CornerRadius="3" Background="#E3E7EE"
                  VerticalAlignment="Center" Margin="12,0,12,0"/>
          <Border x:Name="SliderFill" Height="6" CornerRadius="3" Background="#2F6FED"
                  VerticalAlignment="Center" HorizontalAlignment="Left" Margin="12,0,0,0"/>
          <Canvas x:Name="TickCanvas" Height="9" VerticalAlignment="Bottom" Margin="12,0,12,3" ClipToBounds="False"/>
          <Ellipse x:Name="SliderKnob" Width="22" Height="22" Fill="White" Stroke="#2F6FED"
                   StrokeThickness="3" HorizontalAlignment="Left" VerticalAlignment="Center">
            <Ellipse.Effect>
              <DropShadowEffect BlurRadius="8" ShadowDepth="1" Opacity="0.22" Color="#1F2937"/>
            </Ellipse.Effect>
          </Ellipse>
        </Grid>

        <Grid Margin="0,1,0,0">
          <TextBlock Text="0.5× 更慢" FontSize="11" Foreground="#9CA3AF" HorizontalAlignment="Left"/>
          <TextBlock Text="更快 2.5×" FontSize="11" Foreground="#9CA3AF" HorizontalAlignment="Right"/>
        </Grid>
      </StackPanel>
    </Border>

    <!-- 三指拖曳 -->
    <Border Grid.Row="2" Margin="0,14,0,0" CornerRadius="14"
            Background="White" BorderBrush="#E5E7EB" BorderThickness="1" Padding="24,16,24,16">
      <StackPanel>
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="三指拖曳" FontSize="14" FontWeight="SemiBold" Foreground="#111827" VerticalAlignment="Center"/>
            <TextBlock Text="macOS 风格：三指按住并移动，即可拖动窗口 / 选中文字"
                       FontSize="11" Foreground="#9CA3AF" Margin="12,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <CheckBox x:Name="ChkThreeFinger" Style="{StaticResource SwitchStyle}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Grid Margin="0,10,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="拖曳速度" FontSize="12" Foreground="#6B7280"
                     VerticalAlignment="Center" Margin="0,0,12,0"/>
          <Slider x:Name="SldDragSens" Grid.Column="1" Minimum="40" Maximum="200" Value="100"
                  VerticalAlignment="Center" Height="26" Margin="0,0,12,0"/>
          <TextBlock x:Name="TxtDragSens" Grid.Column="2" Text="1.0×" FontSize="12" Foreground="#111827"
                     VerticalAlignment="Center" MinWidth="44" TextAlignment="Right"/>
        </Grid>
        <TextBlock x:Name="TxtTfdStatus" Margin="0,8,0,0" Text="三指拖曳已关闭"
                   FontSize="11" Foreground="#9CA3AF" TextWrapping="Wrap"/>
        <Button x:Name="BtnMigrateGestures" Margin="0,6,0,0"
                Content="一键把 Windows 三指手势迁移到四指（三指→无，四指→切换应用并显示桌面）"
                Style="{StaticResource LinkButton}" HorizontalAlignment="Left"/>
        <CheckBox x:Name="ChkAutoStart" Margin="0,8,0,0"
                  Content="开机自动启动（后台运行，三指拖曳随时可用）"
                  FontSize="11" Foreground="#6B7280"/>
      </StackPanel>
    </Border>

    <!-- 输入行 -->
    <Grid Grid.Row="3" Margin="0,16,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="输入倍率" FontSize="13" Foreground="#111827"
                 VerticalAlignment="Center" Margin="2,0,12,0"/>
      <TextBox x:Name="TxtInput" Grid.Column="1" Text="1.00" Width="88" Height="38"
               Style="{StaticResource InputBox}" VerticalContentAlignment="Center"/>
      <TextBlock Grid.Column="2" Text="×" FontSize="16" Foreground="#6B7280"
                 VerticalAlignment="Center" Margin="8,0,0,0"/>
      <TextBlock Grid.Column="3" Text="0.50 – 2.50，回车生效" FontSize="11" Foreground="#9CA3AF"
                 VerticalAlignment="Center" Margin="10,0,0,0"/>
      <Button x:Name="BtnReset" Grid.Column="5" Content="恢复 1.0×" Style="{StaticResource SecondaryButton}"
              Height="38" MinWidth="96" VerticalAlignment="Center"/>
    </Grid>

    <!-- 状态 -->
    <TextBlock x:Name="TxtStatus" Grid.Row="4" Text="" FontSize="12.5" Foreground="#16A34A"
               Margin="2,14,0,0" TextWrapping="Wrap"/>

    <!-- 底部信息 -->
    <Grid Grid.Row="6" Margin="2,0,2,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="TxtMouse" Grid.Column="0" Text="鼠标指针速度：10（未修改）"
                 FontSize="11" Foreground="#9CA3AF" VerticalAlignment="Center"/>
      <TextBlock x:Name="TxtMode" Grid.Column="1" Text=""
                 FontSize="11" Foreground="#9CA3AF" VerticalAlignment="Center"/>
    </Grid>

    <!-- 底部按钮 -->
    <Grid Grid.Row="7" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Button x:Name="BtnSettings" Grid.Column="0" Content="打开 Windows 触摸板设置"
              Style="{StaticResource LinkButton}" HorizontalAlignment="Left" VerticalAlignment="Center"/>
      <Button x:Name="BtnClose" Grid.Column="1" Content="隐藏到托盘"
              ToolTip="关闭窗口=隐藏到托盘，三指拖曳继续可用。右键托盘图标可选择「退出界面（后台继续）」或「完全退出」。"
              Style="{StaticResource SecondaryButton}" Height="36" MinWidth="88" VerticalAlignment="Center"/>
    </Grid>
  </Grid>
</Window>
'@

$script:window = [System.Windows.Markup.XamlReader]::Parse($xaml)

# 引用控件
$script:TxtValue  = $script:window.FindName('TxtValue')
$script:TxtRange  = $script:window.FindName('TxtRange')
$script:TxtNative = $script:window.FindName('TxtNative')
$script:TxtInput  = $script:window.FindName('TxtInput')
$script:TxtStatus = $script:window.FindName('TxtStatus')
$script:TxtMouse  = $script:window.FindName('TxtMouse')
$script:TxtMode   = $script:window.FindName('TxtMode')
$script:SliderHost    = $script:window.FindName('SliderHost')
$script:SliderTrackBg = $script:window.FindName('SliderTrackBg')
$script:SliderFill    = $script:window.FindName('SliderFill')
$script:SliderKnob    = $script:window.FindName('SliderKnob')
$script:TickCanvas    = $script:window.FindName('TickCanvas')
$script:BtnReset    = $script:window.FindName('BtnReset')
$script:BtnSettings = $script:window.FindName('BtnSettings')
$script:BtnClose    = $script:window.FindName('BtnClose')
$script:ChkThreeFinger = $script:window.FindName('ChkThreeFinger')
$script:SldDragSens    = $script:window.FindName('SldDragSens')
$script:TxtDragSens    = $script:window.FindName('TxtDragSens')
$script:TxtTfdStatus   = $script:window.FindName('TxtTfdStatus')
$script:BtnMigrateGestures = $script:window.FindName('BtnMigrateGestures')
$script:ChkAutoStart = $script:window.FindName('ChkAutoStart')

# 图标
try {
    $iconPath = Join-Path $PSScriptRoot 'app.ico'
    if (Test-Path $iconPath) {
        $icon = New-Object System.Drawing.Icon($iconPath)
        $script:window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $icon.Handle,
            (New-Object System.Windows.Int32Rect(0, 0, $icon.Width, $icon.Height)),
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    }
} catch { }

# 刻度点
$script:tickDots = @()
for ($i = 0; $i -lt $script:SnapMultipliers.Count; $i++) {
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 4
    $dot.Height = 4
    $dot.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(203, 208, 216))
    [void]$script:TickCanvas.Children.Add($dot)
    $script:tickDots += $dot
}

# ---------------------------------------------------------------------
# 状态与逻辑
# ---------------------------------------------------------------------
$script:currentNative = -1
$script:apiReady = $false
$script:dragging = $false
$script:pendingMultiplier = $null
$script:closing = $false
$script:exiting = $false
$script:exitInProgress = $false
$script:suppressAutoStartEvent = $false
$script:silentBackground = $false
$script:notifyIcon = $null
$script:trayTfdItem = $null

$script:applyTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:applyTimer.Interval = [TimeSpan]::FromMilliseconds(140)
$script:syncTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:syncTimer.Interval = [TimeSpan]::FromSeconds(1.2)
$script:hintTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:hintTimer.Interval = [TimeSpan]::FromMilliseconds(2200)
$script:tfdTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:tfdTimer.Interval = [TimeSpan]::FromMilliseconds(300)

function Set-Status([string]$text, [bool]$success) {
    $script:TxtStatus.Text = $text
    if ($success) {
        $script:TxtStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(22, 163, 74))
    } else {
        $script:TxtStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(220, 38, 38))
    }
}

function Update-MouseLabel {
    $ms = [TouchpadApi]::GetMouseSpeed()
    if ($ms -gt 0) {
        $script:TxtMouse.Text = "鼠标指针速度：" + $ms + "（未修改）"
    } else {
        $script:TxtMouse.Text = "鼠标指针速度：未知"
    }
}

# ---------------------------------------------------------------------
# 三指拖曳
# ---------------------------------------------------------------------
$script:settingsKey = 'HKCU:\Software\TouchpadTuner'

function Get-AppSetting([string]$name, [int]$default) {
    try {
        $item = Get-ItemProperty -Path $script:settingsKey -Name $name -ErrorAction Stop
        return [int]$item.$name
    } catch {
        return $default
    }
}

function Set-AppSetting([string]$name, [int]$value) {
    try {
        if (-not (Test-Path $script:settingsKey)) {
            New-Item -Path $script:settingsKey -Force | Out-Null
        }
        New-ItemProperty -Path $script:settingsKey -Name $name -Value $value -PropertyType DWord -Force | Out-Null
    } catch { }
}

function Set-TfdStatusText([string]$message, [int]$kind) {
    $script:TxtTfdStatus.Text = $message
    $color = [System.Windows.Media.Color]::FromRgb(156, 163, 175)
    if ($kind -eq 1) { $color = [System.Windows.Media.Color]::FromRgb(22, 163, 74) }
    elseif ($kind -eq 2) { $color = [System.Windows.Media.Color]::FromRgb(220, 38, 38) }
    elseif ($kind -eq 3) { $color = [System.Windows.Media.Color]::FromRgb(47, 111, 237) }
    $script:TxtTfdStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush($color)
}

function Update-TfdStatus {
    if ($script:tfdMessageOverride -and (Get-Date) -lt $script:tfdMessageUntil) {
        Set-TfdStatusText $script:tfdMessageOverride $script:tfdMessageOverrideKind
        return
    }
    if (-not $script:tfdReady) {
        Set-TfdStatusText ("三指拖曳不可用：" + $script:tfdLoadError) 2
        return
    }
    $engine = [TouchpadTuner.Helper.ThreeFingerDragEngine]
    if (-not $engine::IsRunning) {
        Set-TfdStatusText ("三指拖曳引擎未运行：" + $engine::Error) 2
        return
    }
    if (-not $engine::Enabled) {
        if ((Get-AppSetting 'GestureMigrated' 0) -eq 1) {
            Set-TfdStatusText "已关闭 · 打开开关即可使用三指拖曳（macOS 风格）" 0
        } else {
            Set-TfdStatusText "已关闭 · 打开开关即可使用三指拖曳；首次使用请先点下方「一键把 Windows 三指手势迁移到四指」" 0
        }
        return
    }
    $contacts = $engine::ContactCount
    if ($engine::IsDragging) {
        Set-TfdStatusText ("拖曳中：左键已按下，移动三指即可拖动（检测到 " + $contacts + " 指）") 2
    } elseif ($contacts -ge 3) {
        Set-TfdStatusText ("检测到 " + $contacts + " 指，请移动三指开始拖曳") 3
    } else {
        Set-TfdStatusText ("已开启 · 三指按住并移动即可拖动窗口/选中文字（检测到 " + $contacts + " 指）") 1
    }
    if (-not $engine::TouchpadFound) {
        Set-TfdStatusText "已开启，但暂未找到精密触摸板设备" 2
    }
}

function Set-TfdEnabled([bool]$enabled) {
    if (-not $script:tfdReady) { return }
    $engine = [TouchpadTuner.Helper.ThreeFingerDragEngine]
    if ($enabled) {
        if (-not $engine::IsRunning) {
            $started = $engine::Start()
            if (-not $started) {
                $script:ChkThreeFinger.IsChecked = $false
                Set-TfdStatusText ("三指拖曳启动失败：" + $engine::Error) 2
                return
            }
        }
        $engine::Sensitivity = $script:SldDragSens.Value / 100.0
        $engine::Enabled = $true
        Set-AppSetting 'ThreeFingerDragEnabled' 1
    } else {
        $engine::Enabled = $false
        Set-AppSetting 'ThreeFingerDragEnabled' 0
    }
    Update-TfdStatus
}

$script:tfdMessageOverride = $null
$script:tfdMessageUntil = [DateTime]::MinValue

function Show-TfdMessage([string]$message, [int]$kind, [int]$seconds) {
    $script:tfdMessageOverride = $message
    $script:tfdMessageOverrideKind = $kind
    $script:tfdMessageUntil = (Get-Date).AddSeconds($seconds)
    Set-TfdStatusText $message $kind
}

# ---- Windows 设置手势自动化（UI Automation）----
function Get-SettingsWindowElement {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $kids = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($k in $kids) {
        try {
            if ($k.Current.ClassName -eq 'ApplicationFrameWindow' -and ($k.Current.Name -eq '设置' -or $k.Current.Name -eq 'Settings')) {
                return $k
            }
        } catch { }
    }
    return $null
}

function Wait-SettingsWindow([int]$timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $w = Get-SettingsWindowElement
        if ($w) { return $w }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Ensure-GestureSectionExpanded($win, [string]$groupName) {
    $nameCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $groupName)
    $groups = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $nameCond)
    $group = $null
    foreach ($g in $groups) {
        if ($g.Current.ControlType.ProgrammaticName -eq 'ControlType.Group') { $group = $g; break }
    }
    if (-not $group) { throw ("未找到设置分组：" + $groupName) }
    try {
        $scroll = $group.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern)
        $scroll.ScrollIntoView()
        Start-Sleep -Milliseconds 200
    } catch { }
    $gr = $group.Current.BoundingRectangle
    $btnCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $btns = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
    foreach ($b in $btns) {
        try {
            $r = $b.Current.BoundingRectangle
            if ($r.Y -ge ($gr.Y - 12) -and $r.Y -le ($gr.Y + $gr.Height + 12) -and $r.X -gt ($gr.X + $gr.Width - 100)) {
                $ec = $b.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                if ($ec -and $ec.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Expanded) {
                    $ec.Expand()
                    Start-Sleep -Milliseconds 700
                }
                return
            }
        } catch { }
    }
    throw ("未找到设置分组的展开按钮：" + $groupName)
}

function Find-ComboById($win, [string]$automationId) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $automationId)
    return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Get-ComboSelectionText($combo) {
    try {
        $sp = $combo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
        $names = @()
        foreach ($s in $sp.Current.GetSelection()) { if ($s.Current.Name) { $names += $s.Current.Name } }
        return ($names -join ',')
    } catch { return '' }
}

function Select-ComboItem($combo, [string[]]$nameKeywords) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $ec = $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($ec.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Expanded) {
        $ec.Expand()
        Start-Sleep -Milliseconds 700
    }
    $itemCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $items = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCond)
    $target = $null
    foreach ($it in $items) {
        try {
            $n = $it.Current.Name
            if (-not $n) { continue }
            foreach ($kw in $nameKeywords) {
                if ($n -like ('*' + $kw + '*')) { $target = $it; break }
            }
            if ($target) { break }
        } catch { }
    }
    if (-not $target) {
        try { $ec.Collapse() } catch { }
        throw ("下拉选项未找到：" + ($nameKeywords -join ' / '))
    }
    $si = $target.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $si.Select()
    Start-Sleep -Milliseconds 700
    try { $ec.Collapse() } catch { }
}

function Invoke-GestureMigration {
    Show-TfdMessage "正在打开 Windows 设置并迁移手势，请稍候…" 3 20
    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        Start-Process 'ms-settings:devices-touchpad' | Out-Null
        $win = Wait-SettingsWindow 15
        if (-not $win) { throw "无法打开 Windows 设置窗口，请手动打开：设置 → 蓝牙和其他设备 → 触摸板" }
        Start-Sleep -Milliseconds 800
        Ensure-GestureSectionExpanded $win "三指手势"
        Ensure-GestureSectionExpanded $win "四指手势"
        Start-Sleep -Milliseconds 500

        $threeId = 'SystemSettings_Input_Touch_ThreeFingerSlideEnabled_ComboBox'
        $fourId = 'SystemSettings_Input_Touch_FourFingerSlideEnabled_ComboBox'
        $three = Find-ComboById $win $threeId
        $four = Find-ComboById $win $fourId
        if (-not $three -or -not $four) {
            throw "未找到三指/四指手势下拉框（Windows 版本或语言可能不兼容）"
        }
        Select-ComboItem $three @('无', 'Nothing')
        Select-ComboItem $four @('切换应用', 'Switch apps')
        Start-Sleep -Milliseconds 600

        $threeNow = Get-ComboSelectionText $three
        $fourNow = Get-ComboSelectionText $four
        if ($threeNow -like '*无*' -and $fourNow -like '*切换应用*') {
            Set-AppSetting 'GestureMigrated' 1
            Show-TfdMessage ("✓ 已设置：三指手势 = 无；四指手势 = " + $fourNow + "（四指左右切换应用、四指上任务视图、四指下显示桌面）") 1 12
        } else {
            throw ("设置未生效（三指：" + $threeNow + "，四指：" + $fourNow + "）")
        }
    } catch {
        $msg = "手势迁移失败：" + $_.Exception.Message + "。也可以手动设置：三指手势 → 无；四指手势 → 切换应用并显示桌面。"
        Show-TfdMessage $msg 2 20
    }
}

# ---------------------------------------------------------------------
# 托盘 / 后台运行 / 开机启动
# ---------------------------------------------------------------------
function Show-MainWindow {
    if (-not $script:window) { return }
    try {
        $script:silentBackground = $false
        if ($script:notifyIcon) { $script:notifyIcon.Visible = $true }
        $script:window.ShowInTaskbar = $true
        $script:window.Show()
        $script:window.WindowState = [System.Windows.WindowState]::Normal
        $script:window.Activate()
        $script:window.Topmost = $true
        $script:window.Topmost = $false
    } catch { }
}

function Test-AutoStart {
    try {
        Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'TouchpadTuner' -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

function Set-AutoStart([bool]$enable) {
    try {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if ($enable) {
            $exe = Join-Path $PSScriptRoot 'TouchpadTuner.exe'
            New-ItemProperty -Path $runKey -Name 'TouchpadTuner' -Value ('"' + $exe + '" -Background') -PropertyType String -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $runKey -Name 'TouchpadTuner' -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Exit-Application {
    if ($script:exitInProgress) { return }
    $script:exitInProgress = $true
    $script:exiting = $true
    $script:closing = $true
    try { $script:applyTimer.Stop() } catch { }
    try { $script:syncTimer.Stop() } catch { }
    try { $script:hintTimer.Stop() } catch { }
    try { $script:tfdTimer.Stop() } catch { }
    if ($script:tfdReady) {
        try {
            [TouchpadTuner.Helper.ThreeFingerDragEngine]::Enabled = $false
            [TouchpadTuner.Helper.ThreeFingerDragEngine]::Stop()
        } catch { }
    }
    if ($script:notifyIcon) {
        try { $script:notifyIcon.Visible = $false; $script:notifyIcon.Dispose() } catch { }
        $script:notifyIcon = $null
    }
    try { $script:mutex.ReleaseMutex() } catch { }
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
}

function Enter-SilentBackground {
    # Hide the window and the tray icon, but keep the engine running so that
    # three-finger drag keeps working. Double-clicking TouchpadTuner.exe later
    # brings the window and the tray icon back.
    $script:silentBackground = $true
    try { $script:window.Hide() } catch { }
    if ($script:notifyIcon) {
        try { $script:notifyIcon.Visible = $false } catch { }
    }
}

function Initialize-TrayIcon {
    $ni = New-Object System.Windows.Forms.NotifyIcon
    try {
        $iconPath = Join-Path $PSScriptRoot 'app.ico'
        if (Test-Path $iconPath) { $ni.Icon = New-Object System.Drawing.Icon($iconPath) }
        else { $ni.Icon = [System.Drawing.SystemIcons]::Application }
    } catch { $ni.Icon = [System.Drawing.SystemIcons]::Application }
    $ni.Text = '触摸板调速器'
    $ni.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $itemOpen = New-Object System.Windows.Forms.ToolStripMenuItem('打开触摸板调速器')
    $itemOpen.Add_Click({ Show-MainWindow })
    [void]$menu.Items.Add($itemOpen)

    $itemTfd = New-Object System.Windows.Forms.ToolStripMenuItem('三指拖曳')
    $script:trayTfdItem = $itemTfd
    $itemTfd.Add_Click({
        if ($script:tfdReady) {
            $script:ChkThreeFinger.IsChecked = -not [TouchpadTuner.Helper.ThreeFingerDragEngine]::Enabled
        }
    })
    [void]$menu.Items.Add($itemTfd)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $itemSilent = New-Object System.Windows.Forms.ToolStripMenuItem('退出界面（三指拖曳继续后台运行）')
    $itemSilent.Add_Click({ Enter-SilentBackground })
    [void]$menu.Items.Add($itemSilent)

    $itemExit = New-Object System.Windows.Forms.ToolStripMenuItem('完全退出（停止三指拖曳）')
    $itemExit.Add_Click({ Exit-Application })
    [void]$menu.Items.Add($itemExit)

    $ni.ContextMenuStrip = $menu
    $ni.Add_DoubleClick({ Show-MainWindow })
    $script:notifyIcon = $ni
    try { $script:notifyIcon.Visible = $true } catch { }
}

function Update-SliderVisual([double]$mult) {
    $w = $script:SliderHost.ActualWidth
    if ($w -le 0) { return }
    $usable = $w - 24
    $f = ($mult - $script:SnapMultipliers[0]) / ($script:SnapMultipliers[$script:SnapMultipliers.Count - 1] - $script:SnapMultipliers[0])
    if ($f -lt 0) { $f = 0 }
    if ($f -gt 1) { $f = 1 }
    $script:SliderFill.Width = [Math]::Max(0, $f * $usable)
    $script:SliderKnob.Margin = New-Object System.Windows.Thickness(($f * $usable - 11), 0, 0, 0)

    $tickW = $script:TickCanvas.ActualWidth
    if ($tickW -gt 0) {
        for ($i = 0; $i -lt $script:tickDots.Count; $i++) {
            $tf = $i / [double]($script:tickDots.Count - 1)
            [System.Windows.Controls.Canvas]::SetLeft($script:tickDots[$i], ($tf * $tickW - 2))
            [System.Windows.Controls.Canvas]::SetTop($script:tickDots[$i], 1)
            if ($i -le (Get-SnapIndex $mult)) {
                $script:tickDots[$i].Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(47, 111, 237))
            } else {
                $script:tickDots[$i].Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(203, 208, 216))
            }
        }
    }
}

function Show-Speed([int]$native) {
    if ($native -lt 1) { $native = 1 }
    if ($native -gt 20) { $native = 20 }
    $script:currentNative = $native
    $mult = $script:Multipliers[$native - 1]
    $script:TxtValue.Text = Get-MultiplierText $mult
    $script:TxtInput.Text = Get-InputText $mult
    $script:TxtNative.Text = "系统档位 " + $native + " / 20"
    if ($native -ge $script:MinNative -and $native -le $script:MaxNative) {
        $script:TxtRange.Text = "可调范围 0.50× – 2.50×"
    } else {
        $script:TxtRange.Text = "当前速度超出快捷调节范围（0.50× – 2.50×）"
    }
    Update-SliderVisual $mult
}

function Apply-Speed([double]$multiplier) {
    if (-not $script:apiReady) { return }
    $idx = Get-SnapIndex $multiplier
    $native = $script:MinNative + $idx
    $actual = -1
    $ok = [TouchpadApi]::SetSpeed($native, [ref]$actual)
    if ($ok) {
        Show-Speed $actual
        Set-Status ("✓ 已应用：触摸板 " + (Get-MultiplierText $script:Multipliers[$actual - 1]) + "（系统档位 " + $actual + " / 20）") $true
    } else {
        Set-Status ("应用失败：" + [TouchpadApi]::LastError) $false
        $fallback = [TouchpadApi]::GetSpeed()
        if ($fallback -gt 0) { Show-Speed $fallback }
    }
    Update-MouseLabel
}

function Select-Multiplier([double]$multiplier) {
    $idx = Get-SnapIndex $multiplier
    $script:pendingMultiplier = $script:SnapMultipliers[$idx]
    Show-Speed ($script:MinNative + $idx)
    $script:applyTimer.Stop()
    $script:applyTimer.Start()
}

function Read-InputBox {
    if ($script:closing) { return }
    if (-not $script:apiReady) { return }
    $raw = $script:TxtInput.Text.Trim().Replace(',', '.')
    if ($raw.EndsWith('x') -or $raw.EndsWith('X') -or $raw.EndsWith('×')) { $raw = $raw.Substring(0, $raw.Length - 1).Trim() }
    if ($raw.EndsWith('%')) { $raw = $raw.Substring(0, $raw.Length - 1).Trim() }
    $value = 0.0
    $parsed = [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)
    if (-not $parsed -or $value -le 0) {
        Set-Status "请输入 0.50 – 2.50 之间的倍率，例如 1.25。" $false
        Show-Speed $script:currentNative
        return
    }
    if ($value -lt 0.5) { $value = 0.5 }
    if ($value -gt 2.5) { $value = 2.5 }
    $script:applyTimer.Stop()
    Apply-Speed $value
}

# ---------------------------------------------------------------------
# 事件
# ---------------------------------------------------------------------
$script:applyTimer.Add_Tick({
    $script:applyTimer.Stop()
    if ($null -ne $script:pendingMultiplier) {
        $m = $script:pendingMultiplier
        $script:pendingMultiplier = $null
        Apply-Speed $m
    }
})

$script:syncTimer.Add_Tick({
    if (-not $script:apiReady) { return }
    if ($script:dragging) { return }
    if ($script:TxtInput.IsKeyboardFocused) { return }
    if ($script:applyTimer.IsEnabled) { return }
    $fresh = [TouchpadApi]::GetSpeed()
    if ($fresh -gt 0 -and $fresh -ne $script:currentNative) {
        Show-Speed $fresh
        Set-Status ("已同步系统设置：触摸板 " + (Get-MultiplierText $script:Multipliers[$fresh - 1]) + "（系统档位 " + $fresh + " / 20）") $true
        $script:TxtMode.Text = "已同步系统设置"
        $script:hintTimer.Stop()
        $script:hintTimer.Start()
    }
    Update-MouseLabel
})

$script:hintTimer.Add_Tick({
    $script:hintTimer.Stop()
    $script:TxtMode.Text = [TouchpadApi]::ModeName
})

$script:tfdTimer.Add_Tick({
    if ($script:showWindowEvent) {
        try { if ($script:showWindowEvent.WaitOne(0)) { Show-MainWindow } } catch { }
    }
    if ($script:trayTfdItem) {
        try { $script:trayTfdItem.Checked = ($script:ChkThreeFinger.IsChecked -eq $true) } catch { }
    }
    if ($script:notifyIcon -and -not $script:silentBackground) {
        try {
            if ($script:ChkThreeFinger.IsChecked -eq $true) { $script:notifyIcon.Text = '触摸板调速器 · 三指拖曳已开启' }
            else { $script:notifyIcon.Text = '触摸板调速器 · 三指拖曳已关闭' }
        } catch { }
    }
    Update-TfdStatus
})

$script:window.Add_SizeChanged({
    if ($script:currentNative -ge 1) {
        Update-SliderVisual $script:Multipliers[$script:currentNative - 1]
    }
})

$script:SliderHost.Add_SizeChanged({
    if ($script:currentNative -ge 1) {
        Update-SliderVisual $script:Multipliers[$script:currentNative - 1]
    }
})

$script:SliderHost.Add_MouseLeftButtonDown({
    if (-not $script:apiReady) { return }
    if (-not $script:SliderHost.CaptureMouse()) { return }
    $script:dragging = $true
    $pos = $args[1].GetPosition($script:SliderHost)
    & $script:UpdateFromPosition $pos.X
})

$script:SliderHost.Add_MouseMove({
    if (-not $script:dragging) { return }
    $pos = $args[1].GetPosition($script:SliderHost)
    & $script:UpdateFromPosition $pos.X
})

$script:SliderHost.Add_MouseLeftButtonUp({
    if (-not $script:dragging) { return }
    $script:dragging = $false
    $script:SliderHost.ReleaseMouseCapture()
    $script:applyTimer.Stop()
    if ($null -ne $script:pendingMultiplier) {
        $m = $script:pendingMultiplier
        $script:pendingMultiplier = $null
        Apply-Speed $m
    }
})

$script:UpdateFromPosition = {
    param([double]$x)
    $w = $script:SliderHost.ActualWidth
    if ($w -le 0) { return }
    $usable = $w - 24
    if ($usable -le 0) { return }
    $f = ($x - 12) / $usable
    if ($f -lt 0) { $f = 0 }
    if ($f -gt 1) { $f = 1 }
    $min = $script:SnapMultipliers[0]
    $max = $script:SnapMultipliers[$script:SnapMultipliers.Count - 1]
    $value = $min + $f * ($max - $min)
    $snapped = $script:SnapMultipliers[(Get-SnapIndex $value)]
    if ($null -ne $script:pendingMultiplier -and [Math]::Abs($script:pendingMultiplier - $snapped) -lt 1e-9) { return }
    $script:pendingMultiplier = $snapped
    Show-Speed ($script:MinNative + (Get-SnapIndex $snapped))
    $script:applyTimer.Stop()
    $script:applyTimer.Start()
}

$script:TxtInput.Add_KeyDown({
    if ($args[1].Key -eq [System.Windows.Input.Key]::Enter) {
        $args[1].Handled = $true
        Read-InputBox
    } elseif ($args[1].Key -eq [System.Windows.Input.Key]::Escape) {
        $args[1].Handled = $true
        Show-Speed $script:currentNative
        Set-Status "已取消输入。" $true
    }
})

$script:TxtInput.Add_LostFocus({
    $script:applyTimer.Stop()
    if ($null -ne $script:pendingMultiplier) { $script:pendingMultiplier = $null }
    Read-InputBox
})

$script:BtnReset.Add_Click({
    if (-not $script:apiReady) { return }
    $script:applyTimer.Stop()
    $script:pendingMultiplier = $null
    Apply-Speed 1.0
})

$script:BtnSettings.Add_Click({
    try { Start-Process 'ms-settings:devices-touchpad' } catch { }
})

$script:BtnClose.Add_Click({
    $script:window.Close()
})

$script:ChkThreeFinger.Add_Checked({
    Set-TfdEnabled $true
})

$script:ChkThreeFinger.Add_Unchecked({
    Set-TfdEnabled $false
})

$script:BtnMigrateGestures.Add_Click({
    Invoke-GestureMigration
})

$script:SldDragSens.Add_ValueChanged({
    $value = [Math]::Round($script:SldDragSens.Value) / 100.0
    $script:TxtDragSens.Text = $value.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + '×'
    if ($script:tfdReady) {
        [TouchpadTuner.Helper.ThreeFingerDragEngine]::Sensitivity = $value
    }
    Set-AppSetting 'ThreeFingerDragSensitivity' ([int][Math]::Round($script:SldDragSens.Value))
})

$script:ChkAutoStart.Add_Checked({
    if (-not $script:suppressAutoStartEvent) { Set-AutoStart $true }
})

$script:ChkAutoStart.Add_Unchecked({
    if (-not $script:suppressAutoStartEvent) { Set-AutoStart $false }
})

$script:window.Add_KeyDown({
    if ($args[1].Key -eq [System.Windows.Input.Key]::Escape) {
        $script:window.Close()
    }
})

$script:window.Add_Closing({
    param($sender, $e)
    if (-not $script:exiting) {
        $e.Cancel = $true
        $script:window.Hide()
        if ($script:notifyIcon) {
            try {
                $script:notifyIcon.ShowBalloonTip(2500, '触摸板调速器',
                    '程序仍在后台运行，三指拖曳可继续使用。双击托盘图标可重新打开窗口。',
                    [System.Windows.Forms.ToolTipIcon]::Info)
            } catch { }
        }
    }
})

$script:window.Add_Closed({
    if ($script:exiting) { Exit-Application }
})

# ---------------------------------------------------------------------
# 初始化
# ---------------------------------------------------------------------
$script:apiReady = $false
$initSpeed = [TouchpadApi]::GetSpeed()
if ($initSpeed -gt 0) {
    $script:apiReady = $true
    $script:TxtMode.Text = [TouchpadApi]::ModeName
    Show-Speed $initSpeed
    Set-Status "已连接触摸板：可独立调节，鼠标速度不受影响。" $true
    $script:syncTimer.Start()
} else {
    Show-Speed 10
    Set-Status ([TouchpadApi]::LastError) $false
    $script:SliderHost.IsEnabled = $false
    $script:SliderHost.Opacity = 0.45
    $script:TxtInput.IsEnabled = $false
    $script:BtnReset.IsEnabled = $false
}

# 三指拖曳初始化
if ($script:tfdReady) {
    $savedSensitivity = Get-AppSetting 'ThreeFingerDragSensitivity' 100
    if ($savedSensitivity -lt 40) { $savedSensitivity = 40 }
    if ($savedSensitivity -gt 200) { $savedSensitivity = 200 }
    $script:SldDragSens.Value = $savedSensitivity
    $script:TxtDragSens.Text = ($savedSensitivity / 100.0).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + '×'
    $engine = [TouchpadTuner.Helper.ThreeFingerDragEngine]
    $engine::Sensitivity = $savedSensitivity / 100.0
    $engine::Start() | Out-Null
    if ((Get-AppSetting 'ThreeFingerDragEnabled' 0) -eq 1) {
        $script:ChkThreeFinger.IsChecked = $true
        $engine::Enabled = $true
    } else {
        $engine::Enabled = $false
    }
    $script:tfdTimer.Start()
}
Update-TfdStatus

# 开机自启复选框
$script:suppressAutoStartEvent = $true
$script:ChkAutoStart.IsChecked = Test-AutoStart
$script:suppressAutoStartEvent = $false
$script:silentBackground = $false

Update-MouseLabel
$script:window.Add_Loaded({
    if ($script:currentNative -ge 1) {
        Update-SliderVisual $script:Multipliers[$script:currentNative - 1]
    }
})

# 托盘图标（关闭窗口后程序仍后台运行）
Initialize-TrayIcon
try { $script:tfdTimer.Start() } catch { }

if ($Background) {
    $script:window.ShowInTaskbar = $false
    $script:window.Hide()
    if ($script:notifyIcon) {
        try {
            $script:notifyIcon.ShowBalloonTip(2500, '触摸板调速器',
                '已进入后台运行，三指拖曳随时可用。双击托盘图标可打开窗口。',
                [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    }
} else {
    $script:window.Show()
    try { $script:window.Activate() } catch { }
}

[System.Windows.Threading.Dispatcher]::Run()

# 调度器退出后的清理
if ($script:notifyIcon) {
    try { $script:notifyIcon.Visible = $false; $script:notifyIcon.Dispose() } catch { }
    $script:notifyIcon = $null
}
try { $script:mutex.ReleaseMutex() } catch { }
