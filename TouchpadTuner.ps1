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

# ---------------------------------------------------------------------
# 单实例控制：若已有窗口，则把旧窗口带到前台后退出
# ---------------------------------------------------------------------
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\TouchpadTunerApp')
$script:firstInstance = $false
try { $script:firstInstance = $script:mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:firstInstance = $true }

if (-not $script:firstInstance) {
    [void][TouchpadApi]::ActivateWindow('触摸板调速器')
    exit
}

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
        Width="600" Height="540"
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
  </Window.Resources>

  <Grid Margin="28,22,28,20">
    <Grid.RowDefinitions>
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

    <!-- 输入行 -->
    <Grid Grid.Row="2" Margin="0,16,0,0">
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
    <TextBlock x:Name="TxtStatus" Grid.Row="3" Text="" FontSize="12.5" Foreground="#16A34A"
               Margin="2,14,0,0" TextWrapping="Wrap"/>

    <!-- 底部信息 -->
    <Grid Grid.Row="5" Margin="2,0,2,0">
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
    <Grid Grid.Row="6" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Button x:Name="BtnSettings" Grid.Column="0" Content="打开 Windows 触摸板设置"
              Style="{StaticResource LinkButton}" HorizontalAlignment="Left" VerticalAlignment="Center"/>
      <Button x:Name="BtnClose" Grid.Column="1" Content="关闭"
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

$script:applyTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:applyTimer.Interval = [TimeSpan]::FromMilliseconds(140)
$script:syncTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:syncTimer.Interval = [TimeSpan]::FromSeconds(1.2)
$script:hintTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:hintTimer.Interval = [TimeSpan]::FromMilliseconds(2200)

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

$script:window.Add_KeyDown({
    if ($args[1].Key -eq [System.Windows.Input.Key]::Escape) {
        $script:window.Close()
    }
})

$script:window.Add_Closed({
    $script:closing = $true
    $script:applyTimer.Stop()
    $script:syncTimer.Stop()
    $script:hintTimer.Stop()
    try { $script:mutex.ReleaseMutex() } catch { }
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

Update-MouseLabel
$script:window.Add_Loaded({
    if ($script:currentNative -ge 1) {
        Update-SliderVisual $script:Multipliers[$script:currentNative - 1]
    }
})

[void]$script:window.ShowDialog()
