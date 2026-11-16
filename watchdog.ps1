param(
    [switch]$NoElevate,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [int]$StopAfterSeconds = 0
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    if ($NoElevate) {
        Write-Host '未能获得管理员权限，无法读取 v2rayN 界面（v2rayN 以管理员运行）。' -ForegroundColor Red
        Read-Host '按回车退出'
        exit 1
    }
    Write-Host '需要管理员权限才能读取 v2rayN（它以管理员身份运行），正在申请提权...'
    # 用「当前正在跑的宿主」重新提权启动：Windows PowerShell 用 powershell.exe，PowerShell 7 用 pwsh.exe，
    # 否则用 pwsh 启动时提权后会掉回 5.1，颜色/性能都不一样
    $hostExe = 'powershell.exe'
    try {
        $p = (Get-Process -Id $PID).Path
        if ($p) { $hostExe = $p }
    } catch {}
    $argList = @('-NoProfile')
    if ((Split-Path -Leaf $hostExe) -ieq 'powershell.exe') { $argList += @('-ExecutionPolicy', 'Bypass') }
    $argList += @('-File', ('"{0}"' -f $PSCommandPath), '-ConfigPath', ('"{0}"' -f $ConfigPath))
    if ($StopAfterSeconds -gt 0) { $argList += @('-StopAfterSeconds', $StopAfterSeconds) }
    Write-Host ('   使用: {0}' -f $hostExe)
    try {
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $argList -ErrorAction Stop | Out-Null
    } catch {
        Write-Host '提权被取消，程序退出。' -ForegroundColor Red
        Read-Host '按回车退出'
    }
    exit 0
}

$script:LogFile = Join-Path $PSScriptRoot 'watchdog.log'
$script:consoleCols = 120
$script:consoleRows = 40
$script:chartSeconds = 300
$script:epoch0 = Get-Date                      # 图表时间轴原点（桶边界按它对齐到绝对时间）
$script:lastSampleE = -1.0
$script:pmaxCache = @{}                        # 面板名 -> 当前刻度上限（带粘性，避免每帧重新定标导致整图跳动）
$script:samples = New-Object System.Collections.Generic.List[object]
$script:events = New-Object System.Collections.Generic.List[object]
$script:uiState = '等待 v2rayN'
$script:lastUp = 0.0
$script:lastDown = 0.0
$script:totalRestarts = 0
$script:vtEnabled = $false
$script:rowCache = @{}
$script:frameSeq = 0
$script:cwCache = @{}          # 字符码位 -> 显示宽度 缓存（逐字符调用函数太慢，缓存后每帧省下上百毫秒）
$script:lastWinW = -1
$script:lastWinH = -1

function Write-Log([string]$msg, [string]$color = 'Gray') {
    $now = Get-Date
    $line = $now.ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
    $cc = switch ($color) {
        'Red' { [ConsoleColor]::Red }
        'Yellow' { [ConsoleColor]::Yellow }
        'Green' { [ConsoleColor]::Green }
        'Magenta' { [ConsoleColor]::Magenta }
        default { [ConsoleColor]::Gray }
    }
    $script:events.Add([pscustomobject]@{ T = $now.ToString('HH:mm:ss'); Msg = $msg; Color = $cc })
    if ($script:events.Count -gt 100) { $script:events.RemoveRange(0, $script:events.Count - 100) }
}

function ConvertFrom-Jsonc([string]$raw) {
    $text = [regex]::Replace($raw, '/\*[\s\S]*?\*/', '')
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in ($text -split "`r?`n")) {
        $cut = -1
        $inStr = $false
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if ($ch -eq '"') { $inStr = -not $inStr }
            elseif (-not $inStr) {
                if ($ch -eq '#') { $cut = $i; break }
                if ($ch -eq '/' -and $i + 1 -lt $line.Length -and $line[$i + 1] -eq '/') { $cut = $i; break }
            }
        }
        if ($cut -ge 0) { [void]$sb.AppendLine($line.Substring(0, $cut)) } else { [void]$sb.AppendLine($line) }
    }
    return ($sb.ToString() | ConvertFrom-Json)
}

$defaults = [ordered]@{
    ThresholdKBps          = 500.0
    LowDurationSeconds     = 5
    Direction              = 'up'
    ActivityFloorKBps      = 800.0
    ActivityWindowSeconds  = 60
    RestartGraceSeconds    = 20
    RecoverSeconds         = 10
    MaxConsecutiveRestarts = 3
    PollIntervalMs         = 1000
    AlarmBeepRounds        = 3
    ShowChart              = $true
    ChartSmoothSeconds     = 8.0
    ChartSeconds           = 300
    SampleSeconds          = 2.0
    ChartGlyphs            = 'auto'
}

$cfg = [ordered]@{}
foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }
$configError = ''
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $userCfg = ConvertFrom-Jsonc (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8)
        foreach ($k in $defaults.Keys) {
            $prop = $userCfg.PSObject.Properties[$k]
            if ($null -ne $prop -and $null -ne $prop.Value) { $cfg[$k] = $prop.Value }
        }
    } catch {
        $configError = $_.Exception.Message
    }
}

$direction = ([string]$cfg.Direction).ToLower()
if ($direction -notin @('up', 'down', 'updown')) { $direction = 'up' }
$threshold = [double]$cfg.ThresholdKBps
$lowDuration = [double]$cfg.LowDurationSeconds
$activityFloor = [double]$cfg.ActivityFloorKBps
$activityWindow = [double]$cfg.ActivityWindowSeconds
$graceSeconds = [double]$cfg.RestartGraceSeconds
$recoverSeconds = [double]$cfg.RecoverSeconds
$maxRestarts = [Math]::Max(1, [int]$cfg.MaxConsecutiveRestarts)
$pollMs = [Math]::Max(300, [int]$cfg.PollIntervalMs)
$intervalSec = $pollMs / 1000.0
$alarmRounds = [Math]::Max(1, [int]$cfg.AlarmBeepRounds)
$activityGuard = $activityFloor -gt 0
$showChart = [bool]$cfg.ShowChart
$chartSmooth = [Math]::Max(0.0, [double]$cfg.ChartSmoothSeconds)
$script:chartSeconds = [Math]::Min(86400, [Math]::Max(10, [int]$cfg.ChartSeconds))

# 采样间隔：采样比"一列代表的时间"还稀时不会断线（脚本会自动让一个采样点占多列），
# 所以这里只约束下限 = 读取间隔（读得没那么快，采得更密没有意义）。
$sampleSeconds = [double]$cfg.SampleSeconds
if ($sampleSeconds -le 0) { $sampleSeconds = 1.0 }
if ($sampleSeconds -lt $intervalSec) { $sampleSeconds = $intervalSec }
$sampleSeconds = [Math]::Round($sampleSeconds, 2)

# 仅用于启动日志：估算"一列代表多少秒"
$nominalBuckets = [Math]::Max(20, $script:consoleCols - 11)
$bucketDur0 = $script:chartSeconds / [double]$nominalBuckets

if (Test-Path -LiteralPath $script:LogFile) {
    try {
        if ((Get-Item -LiteralPath $script:LogFile).Length -gt 2MB) {
            Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.old') -Force
        }
    } catch {}
}

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WdWin32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref RECT pvParam, uint fWinIni);
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint mode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint mode);
}
'@

function Set-ConsoleLayout {
    $script:layoutOk = $false
    try {
        $hwnd = [WdWin32]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero -and [WdWin32]::IsZoomed($hwnd)) { [void][WdWin32]::ShowWindow($hwnd, 9) }
        $raw = $Host.UI.RawUI
        $curWin = $raw.WindowSize
        $bufW = [Math]::Max($script:consoleCols, [int]$curWin.Width)
        $bufH = [Math]::Max($script:consoleRows, [int]$curWin.Height)
        $raw.BufferSize = New-Object System.Management.Automation.Host.Size($bufW, $bufH)
        $raw.WindowSize = New-Object System.Management.Automation.Host.Size($script:consoleCols, $script:consoleRows)
        $raw.BufferSize = New-Object System.Management.Automation.Host.Size($script:consoleCols, $script:consoleRows)
        if ($hwnd -ne [IntPtr]::Zero) {
            $r = [WdWin32+RECT]::new()
            if ([WdWin32]::GetWindowRect($hwnd, [ref]$r)) {
                $wa = [WdWin32+RECT]::new()
                if ([WdWin32]::SystemParametersInfo(0x0030, 0, [ref]$wa, 0)) {
                    $w = $r.Right - $r.Left
                    $h = $r.Bottom - $r.Top
                    if ($w -gt 0 -and $h -gt 0) {
                        $x = $wa.Left + [int](($wa.Right - $wa.Left - $w) / 2)
                        $y = $wa.Top + [int](($wa.Bottom - $wa.Top - $h) / 2)
                        [void][WdWin32]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, 0, 0, 0x0001 -bor 0x0004)
                    }
                }
            }
        }
        $hIn = [WdWin32]::GetStdHandle(-10)
        $mode = [uint32]0
        if ([WdWin32]::GetConsoleMode($hIn, [ref]$mode)) {
            $newMode = (($mode -bor 0x0080) -band (-bnot 0x0040))
            [void][WdWin32]::SetConsoleMode($hIn, [uint32]$newMode)
        }
        $hOut = [WdWin32]::GetStdHandle(-11)
        $outMode = [uint32]0
        if ([WdWin32]::GetConsoleMode($hOut, [ref]$outMode)) {
            if ([WdWin32]::SetConsoleMode($hOut, [uint32]($outMode -bor 0x0004))) { $script:vtEnabled = $true }
        }
        $script:layoutOk = $true
    } catch {
        $script:layoutOk = $false
    }
    try { [Console]::CursorVisible = $false } catch {}
    try { $Host.UI.RawUI.WindowTitle = 'v2rayN 断流监控 (watchdog)' } catch {}
}

Set-ConsoleLayout
Clear-Host

function Get-CellWidth([char]$ch) {
    $code = [int]$ch
    if (($code -ge 0x1100 -and $code -le 0x115F) -or
        ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
        ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
        ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFE30 -and $code -le 0xFE4F) -or
        ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFFE0 -and $code -le 0xFFE6)) { return 2 }
    return 1
}

function Get-SegWidth($segs) {
    $w = 0
    foreach ($seg in $segs) {
        foreach ($ch in ([string]$seg.Text).ToCharArray()) {
            $code = [int]$ch
            $cw = $script:cwCache[$code]; if (-not $cw) { $cw = Get-CellWidth $ch; $script:cwCache[$code] = $cw }
            $w += $cw
        }
    }
    return $w
}

function Fit-Line([string]$s, [int]$maxWidth) {
    if ($maxWidth -le 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $w = 0
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        $cw = $script:cwCache[$code]; if (-not $cw) { $cw = Get-CellWidth $ch; $script:cwCache[$code] = $cw }
        if ($w + $cw -gt $maxWidth) { break }
        [void]$sb.Append($ch)
        $w += $cw
    }
    if ($w -lt $maxWidth) { [void]$sb.Append(' ' * ($maxWidth - $w)) }
    return $sb.ToString()
}

function New-Line {
    $l = New-Object System.Collections.Generic.List[object]
    return ,$l
}

function Add-Seg($line, [string]$text, [ConsoleColor]$color) {
    $line.Add([pscustomobject]@{ Text = $text; Color = $color })
}

function New-ContentLine($segs, [int]$contentWidth) {
    $out = New-Line
    Add-Seg $out '║ ' ([ConsoleColor]::DarkGray)
    # 超过 contentWidth 的部分直接截掉：宁可少显示，也不要让整行超宽触发终端换行把下一行糊掉
    $w = 0
    foreach ($s in $segs) {
        if ($w -ge $contentWidth) { break }
        $text = [string]$s.Text
        if ($text.Length -eq 0) { continue }
        $tw = 0
        $cut = -1
        $i = 0
        foreach ($ch in $text.ToCharArray()) {
            $code = [int]$ch
            $cw = $script:cwCache[$code]; if (-not $cw) { $cw = Get-CellWidth $ch; $script:cwCache[$code] = $cw }
            if ($w + $tw + $cw -gt $contentWidth) { $cut = $i; break }
            $tw += $cw
            $i++
        }
        if ($cut -ge 0) {
            if ($cut -gt 0) { Add-Seg $out $text.Substring(0, $cut) $s.Color; $w += $tw }
            break
        }
        Add-Seg $out $text $s.Color
        $w += $tw
    }
    if ($w -lt $contentWidth) { Add-Seg $out (' ' * ($contentWidth - $w)) ([ConsoleColor]::Gray) }
    Add-Seg $out ' ║' ([ConsoleColor]::DarkGray)
    return ,$out
}

function Write-FrameLine($segs, [int]$maxWidth, [bool]$newline) {
    $w = 0
    $stop = $false
    foreach ($seg in $segs) {
        if ($stop) { break }
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in ([string]$seg.Text).ToCharArray()) {
            $code = [int]$ch
            $cw = $script:cwCache[$code]; if (-not $cw) { $cw = Get-CellWidth $ch; $script:cwCache[$code] = $cw }
            if ($w + $cw -gt $maxWidth) { $stop = $true; break }
            [void]$sb.Append($ch)
            $w += $cw
        }
        if ($sb.Length -gt 0) {
            try { [Console]::ForegroundColor = $seg.Color } catch {}
            [Console]::Write($sb.ToString())
        }
    }
    if ($w -lt $maxWidth) {
        try { [Console]::ForegroundColor = [ConsoleColor]::Gray } catch {}
        [Console]::Write((' ' * ($maxWidth - $w)))
    }
    if ($newline) { [Console]::Write("`r`n") }
}

function Get-AnsiCode([ConsoleColor]$c) {
    switch ($c) {
        ([ConsoleColor]::Black) { return '30' }
        ([ConsoleColor]::DarkBlue) { return '34' }
        ([ConsoleColor]::DarkGreen) { return '32' }
        ([ConsoleColor]::DarkCyan) { return '36' }
        ([ConsoleColor]::DarkRed) { return '31' }
        ([ConsoleColor]::DarkMagenta) { return '35' }
        ([ConsoleColor]::DarkYellow) { return '33' }
        ([ConsoleColor]::Gray) { return '37' }
        ([ConsoleColor]::DarkGray) { return '90' }
        ([ConsoleColor]::Blue) { return '94' }
        ([ConsoleColor]::Green) { return '92' }
        ([ConsoleColor]::Cyan) { return '96' }
        ([ConsoleColor]::Red) { return '91' }
        ([ConsoleColor]::Magenta) { return '95' }
        ([ConsoleColor]::Yellow) { return '93' }
        ([ConsoleColor]::White) { return '97' }
    }
    return '37'
}

function Convert-LineToAnsi($segs, [int]$maxWidth) {
    $esc = [string][char]27
    $sb = New-Object System.Text.StringBuilder
    $w = 0
    $stop = $false
    foreach ($seg in $segs) {
        if ($stop) { break }
        $tsb = New-Object System.Text.StringBuilder
        foreach ($ch in ([string]$seg.Text).ToCharArray()) {
            $code = [int]$ch
            $cw = $script:cwCache[$code]; if (-not $cw) { $cw = Get-CellWidth $ch; $script:cwCache[$code] = $cw }
            if ($w + $cw -gt $maxWidth) { $stop = $true; break }
            [void]$tsb.Append($ch)
            $w += $cw
        }
        if ($tsb.Length -gt 0) {
            [void]$sb.Append($esc + '[' + (Get-AnsiCode $seg.Color) + 'm')
            [void]$sb.Append($tsb.ToString())
        }
    }
    if ($w -lt $maxWidth) {
        [void]$sb.Append($esc + '[37m')
        [void]$sb.Append(' ' * ($maxWidth - $w))
    }
    [void]$sb.Append($esc + '[0m')
    return $sb.ToString()
}

function Format-Speed([double]$kb) {
    if ($kb -ge 1048576) { return ('{0:N2} GB/s' -f ($kb / 1048576.0)) }
    if ($kb -ge 1024) { return ('{0:N1} MB/s' -f ($kb / 1024.0)) }
    return ('{0:N0} KB/s' -f $kb)
}

function Format-SpeedShort([double]$kb) {
    if ($kb -ge 1000000) { return ('{0:N1}G' -f ($kb / 1000000.0)) }
    if ($kb -ge 1000) { return ('{0:N1}M' -f ($kb / 1000.0)) }
    return ('{0:N0}K' -f $kb)
}

function Get-NiceCeil([double]$v) {
    if ($v -le 0) { return 100.0 }
    $p = [Math]::Pow(10, [Math]::Floor([Math]::Log10($v)))
    $n = $v / $p
    # 档位细一点，避免 1.02 直接跳到 2.0（否则图只有下半屏有内容）
    $steps = @(1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0)
    $nice = 10.0
    foreach ($s in $steps) {
        if ($n -le $s + 0.0000001) { $nice = $s; break }
    }
    return [double]($nice * $p)
}

# 时间轴刻度按 ChartSeconds 自适应：挑一个"步长 ≥ 窗口/6"的整秒数，于是 45 秒、2 分钟、
# 10 分钟、半小时都会有自己的标注，不再是写死的 -5m..-1m。
# 单位在整个轴上统一（秒/分钟/小时），不会出现 "-1m -40s -20s" 这种混着来的刻度。
function Build-AxisLine([int]$width, [double]$spanSeconds) {
    if ($width -le 0) { return '' }
    $slot = New-Object object[] $width
    if ($spanSeconds -lt 120) { $unit = 's'; $steps = @(1, 2, 5, 10, 15, 20, 30) }
    elseif ($spanSeconds -lt 7200) { $unit = 'm'; $steps = @(30, 60, 120, 180, 300, 600, 900, 1200, 1800) }
    else { $unit = 'h'; $steps = @(900, 1800, 3600, 7200, 14400, 28800) }
    $step = [double]$steps[$steps.Count - 1]
    foreach ($s in $steps) {
        if (($spanSeconds / [double]$s) -le 6.0) { $step = [double]$s; break }
    }
    $labels = New-Object System.Collections.Generic.List[object]
    $off = 0.0
    while ($off -le $spanSeconds + 0.001) {
        if ($off -lt 0.001) { $txt = '现在' }
        elseif ($unit -eq 's') { $txt = '-{0:0}s' -f $off }
        elseif ($unit -eq 'm') { $txt = '-{0:0.#}m' -f ($off / 60.0) }
        else { $txt = '-{0:0.#}h' -f ($off / 3600.0) }
        $labels.Add(@($off, $txt))
        $off += $step
    }
    # 从右往左画，先画"现在"，避免左边的刻度把它盖掉
    for ($i = $labels.Count - 1; $i -ge 0; $i--) {
        $offv = [double]$labels[$i][0]
        $txt = [string]$labels[$i][1]
        $dispW = 0
        foreach ($ch in $txt.ToCharArray()) { $dispW += Get-CellWidth $ch }
        $pos = $width - 1 - [int][Math]::Round(($offv / $spanSeconds) * ($width - 1)) - ($dispW - 1)
        if ($pos -lt 0) { $pos = 0 }
        if ($pos + $dispW -gt $width) { $pos = $width - $dispW }
        $cursor = $pos
        foreach ($ch in $txt.ToCharArray()) {
            $cw = Get-CellWidth $ch
            if ($cursor -ge 0 -and $cursor -lt $width) {
                if ($null -eq $slot[$cursor]) { $slot[$cursor] = [string]$ch }
                if ($cw -eq 2 -and $cursor + 1 -lt $width -and $null -eq $slot[$cursor + 1]) { $slot[$cursor + 1] = '' }
            }
            $cursor += $cw
        }
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($s in $slot) {
        if ($null -eq $s) { [void]$sb.Append(' ') } else { [void]$sb.Append($s) }
    }
    return $sb.ToString()
}

# ===== 曲线画法 =====
# 全程 ASCII：`#` 是数据点，`|` 补竖直连接，于是得到一条连续的细折线。
# （先前用盲文点阵⣿，在这台机器的控制台里显示不出来——中文 Windows 的 936 代码页和不少
#  控制台字体都不带盲文，会被换成 ? 或方块。ASCII 没有这个风险。）
# 垂直档位由每个面板的行数决定（10 行 = 10 档），水平方向一列一个字符，所以线比"铺满整格
# 的面积图"细得多，也没有顶部高亮那一层。
# ChartGlyphs 可选：ascii（默认）/ block（用 ▁▂▃▄▅▆▇█ 画 1 行高的细方块线，1/8 行精度）
$script:blk = @('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')
$script:glyphMode = 'ascii'
if (([string]$cfg.ChartGlyphs).ToLower() -eq 'block') { $script:glyphMode = 'block' }

# 每列取一个值：把「桶」映射到「列」（$colsPer ≥ 1，短时间窗时一个桶占多列，横向拉开），
# 相邻两桶之间线性插值，于是曲线是斜的而不是台阶
function Set-AsciiCurve($cells, $vals, $count, $cols, $rows, $pmax, $colsPer) {
    $prev = -1
    for ($c = 0; $c -lt $cols; $c++) {
        $bf = $c / $colsPer
        $b0 = [int][Math]::Floor($bf)
        if ($b0 -gt $count - 1) { $b0 = $count - 1 }
        $b1 = $b0 + 1
        if ($b1 -gt $count - 1) { $b1 = $count - 1 }
        $v0 = $vals[$b0]; $v1 = $vals[$b1]
        if ($v0 -lt 0 -and $v1 -lt 0) { $prev = -1; continue }
        if ($v0 -lt 0) { $v = $v1 }
        elseif ($v1 -lt 0) { $v = $v0 }
        else { $v = $v0 + ($v1 - $v0) * ($bf - $b0) }
        if ($v -gt $pmax) { $v = $pmax }
        $r = $rows - 1 - [int][Math]::Round(($v / $pmax) * ($rows - 1))
        if ($r -lt 0) { $r = 0 }
        if ($r -gt $rows - 1) { $r = $rows - 1 }
        $cells[($r * $cols) + $c] = '#'
        # 相邻两列高度差得多的时候，把中间的空行用 | 补上，曲线才不会断成两截
        if ($prev -ge 0 -and $prev -ne $r) {
            $lo = $prev; $hi = $r
            if ($lo -gt $hi) { $lo = $r; $hi = $prev }
            for ($y = $lo + 1; $y -lt $hi; $y++) {
                if ($null -eq $cells[($y * $cols) + $c]) { $cells[($y * $cols) + $c] = '|' }
            }
        }
        $prev = $r
    }
}

# 备选：每个桶只画顶端那一个部分方块（1/8 行精度），不铺满整格 —— 一条更密的细线
function Set-BlockLine($cells, $vals, $count, $cols, $rows, $pmax, $colsPer) {
    for ($c = 0; $c -lt $cols; $c++) {
        $bf = $c / $colsPer
        $b0 = [int][Math]::Floor($bf)
        if ($b0 -gt $count - 1) { $b0 = $count - 1 }
        $b1 = $b0 + 1
        if ($b1 -gt $count - 1) { $b1 = $count - 1 }
        $v0 = $vals[$b0]; $v1 = $vals[$b1]
        if ($v0 -lt 0 -and $v1 -lt 0) { continue }
        if ($v0 -lt 0) { $v = $v1 }
        elseif ($v1 -lt 0) { $v = $v0 }
        else { $v = $v0 + ($v1 - $v0) * ($bf - $b0) }
        if ($v -gt $pmax) { $v = $pmax }
        $p = [int][Math]::Round(($v / $pmax) * $rows * 8.0)
        if ($p -lt 1) { $p = 1 }
        if ($p -gt $rows * 8) { $p = $rows * 8 }
        $cellRow = [int][Math]::Floor(($p - 1) / 8.0)
        if ($cellRow -lt 0) { $cellRow = 0 }
        if ($cellRow -gt $rows - 1) { $cellRow = $rows - 1 }
        $cells[(($rows - 1 - $cellRow) * $cols) + $c] = $script:blk[($p - 1) % 8]
    }
}

function Build-Frame([int]$winW, [int]$winH) {
    $width = $winW - 1
    $contentWidth = $width - 4
    $stateColor = switch ($script:uiState) {
        '追踪中' { [ConsoleColor]::Green }
        '等待重连' { [ConsoleColor]::DarkYellow }
        '空闲' { [ConsoleColor]::DarkGray }
        default { [ConsoleColor]::DarkYellow }
    }

    $frame = New-Line

    $hdr = New-Line
    Add-Seg $hdr '╔══ ' ([ConsoleColor]::DarkGray)
    Add-Seg $hdr 'v2rayN 断流监控' ([ConsoleColor]::White)
    Add-Seg $hdr ('  {0}   状态: ' -f (Get-Date).ToString('HH:mm:ss')) ([ConsoleColor]::DarkGray)
    Add-Seg $hdr $script:uiState $stateColor
    $fill = $width - 1 - (Get-SegWidth $hdr)
    if ($fill -gt 0) { Add-Seg $hdr ('═' * $fill) ([ConsoleColor]::DarkGray) }
    Add-Seg $hdr '╗' ([ConsoleColor]::DarkGray)
    $frame.Add($hdr) | Out-Null

    $stats = New-Line
    Add-Seg $stats '上传 ' ([ConsoleColor]::Gray)
    Add-Seg $stats (Format-Speed $script:lastUp) ([ConsoleColor]::Yellow)
    Add-Seg $stats '    下载 ' ([ConsoleColor]::Gray)
    Add-Seg $stats (Format-Speed $script:lastDown) ([ConsoleColor]::Cyan)
    Add-Seg $stats ('    |    阈值 <= {0} KB/s    低速 {1:N0}/{2}s    连续重启 {3}/{4}    累计 {5}' -f $threshold, $lowSeconds, $lowDuration, $restartCount, $maxRestarts, $script:totalRestarts) ([ConsoleColor]::Gray)
    $frame.Add((New-ContentLine $stats $contentWidth)) | Out-Null

    if ($showChart) {
        $avail = $winH - 7
        $chartRows = [int][Math]::Round($avail * 0.75)
        if ($chartRows -lt 5) { $chartRows = 5 }
        if ($chartRows -gt 26) { $chartRows = 26 }
        $eventRows = $avail - $chartRows
        if ($eventRows -lt 2) { $eventRows = 2 }
        $chartRows = $avail - $eventRows

        # 可用绘图列数（左边留出刻度栏）
        $gutter = 7
        $canvas = $contentWidth - $gutter
        if ($canvas -lt 20) { $canvas = 20 }
        $barWidth = $canvas

        # 一列代表多少秒 = 窗口长度 / 列数。如果采样比这还稀（ChartSeconds 设得很短时会发生），
        # 就改成"一个采样点占多列"，把曲线横向拉开 —— 这样 ChartSeconds 想设多少都行：
        # 既不会出现空列把线断开，也不会因为点太少而缩在左边一小块。
        $spanSec = [double]$script:chartSeconds
        $colsPer = 1.0
        $nBuckets = $canvas
        $bySlice = $spanSec / [double]$canvas
        if ($script:sampleSeconds -gt $bySlice) {
            $nBuckets = [int][Math]::Floor($spanSec / [double]$script:sampleSeconds) + 1
            if ($nBuckets -lt 8) { $nBuckets = 8 }
            if ($nBuckets -gt $canvas) { $nBuckets = $canvas }
            $colsPer = $canvas / [double]$nBuckets
        }
        $bucketDur = $spanSec / [double]$nBuckets

        # ===== 时间轴按「绝对时间」切桶 =====
        # 桶边界固定在 epoch0 的整数倍上：历史列画出来就再也不动。
        # 右端那个还没装满的桶也一起画（它每秒都在长），所以画面是"每秒刷新、只有最右一列在变"，
        # 不会像以前那样每帧重新分桶、整片数据一起跳。
        $nowE = ((Get-Date) - $script:epoch0).TotalSeconds
        $curBucket = [long][Math]::Floor($nowE / $bucketDur)
        $firstBucket = $curBucket - $nBuckets + 1

        $upSum = New-Object 'double[]' $nBuckets
        $upCnt = New-Object 'int[]' $nBuckets
        $dnSum = New-Object 'double[]' $nBuckets
        $dnCnt = New-Object 'int[]' $nBuckets
        foreach ($s in $script:samples) {
            $idx = [long][Math]::Floor($s.E / $bucketDur) - $firstBucket
            if ($idx -lt 0 -or $idx -ge $nBuckets) { continue }
            $upSum[$idx] += $s.Up; $upCnt[$idx]++
            $dnSum[$idx] += $s.Down; $dnCnt[$idx]++
        }
        # 桶内取平均而不是最大值：最大值会把每一列都顶到该窗口内最尖锐的那一下，
        # 看起来像一排等高的尖刺；平均更接近"这一段时间大概多快"
        $upVals = New-Object 'double[]' $nBuckets
        $downVals = New-Object 'double[]' $nBuckets
        for ($i = 0; $i -lt $nBuckets; $i++) {
            if ($upCnt[$i] -gt 0) { $upVals[$i] = $upSum[$i] / $upCnt[$i] } else { $upVals[$i] = -1 }
            if ($dnCnt[$i] -gt 0) { $downVals[$i] = $dnSum[$i] / $dnCnt[$i] } else { $downVals[$i] = -1 }
        }

        # 滑动平均（窗口由 ChartSmoothSeconds 换算成桶数）：网速每秒都在抖，
        # 直接画就是锯齿/台阶；平滑后才是"点与点之间用线连起来"的样子。
        # 用前缀和算，O(n) 而不是每个桶再套一层窗口循环（否则一帧要多花 20ms）
        $radius = 0
        if ($chartSmooth -gt 0) {
            $radius = [int][Math]::Floor($chartSmooth / $bucketDur / 2.0)
            if ($radius -lt 1) { $radius = 1 }
        }
        $upSm = New-Object 'double[]' $nBuckets
        $dnSm = New-Object 'double[]' $nBuckets
        if ($radius -eq 0) {
            for ($bi = 0; $bi -lt $nBuckets; $bi++) { $upSm[$bi] = $upVals[$bi]; $dnSm[$bi] = $downVals[$bi] }
        } else {
            $preUp = New-Object 'double[]' ($nBuckets + 1)
            $preUpN = New-Object 'double[]' ($nBuckets + 1)
            $preDn = New-Object 'double[]' ($nBuckets + 1)
            $preDnN = New-Object 'double[]' ($nBuckets + 1)
            for ($bi = 0; $bi -lt $nBuckets; $bi++) {
                $a = $upVals[$bi]; $c = $downVals[$bi]
                if ($a -ge 0) { $preUp[$bi + 1] = $preUp[$bi] + $a; $preUpN[$bi + 1] = $preUpN[$bi] + 1 }
                else { $preUp[$bi + 1] = $preUp[$bi]; $preUpN[$bi + 1] = $preUpN[$bi] }
                if ($c -ge 0) { $preDn[$bi + 1] = $preDn[$bi] + $c; $preDnN[$bi + 1] = $preDnN[$bi] + 1 }
                else { $preDn[$bi + 1] = $preDn[$bi]; $preDnN[$bi + 1] = $preDnN[$bi] }
            }
            for ($bi = 0; $bi -lt $nBuckets; $bi++) {
                $lo = $bi - $radius
                if ($lo -lt 0) { $lo = 0 }
                $hi = $bi + $radius + 1
                if ($hi -gt $nBuckets) { $hi = $nBuckets }
                if ($upVals[$bi] -lt 0) { $upSm[$bi] = -1 }
                else {
                    $n = $preUpN[$hi] - $preUpN[$lo]
                    if ($n -le 0) { $upSm[$bi] = -1 } else { $upSm[$bi] = ($preUp[$hi] - $preUp[$lo]) / $n }
                }
                if ($downVals[$bi] -lt 0) { $dnSm[$bi] = -1 }
                else {
                    $n = $preDnN[$hi] - $preDnN[$lo]
                    if ($n -le 0) { $dnSm[$bi] = -1 } else { $dnSm[$bi] = ($preDn[$hi] - $preDn[$lo]) / $n }
                }
            }
        }

        # ===== 上下两个面板：上传 / 下载，各自独立定标 =====
        # 共用一个刻度的话，下载通常只有上传的 1/4 高，会一直贴着地面看不出形状（nload 也是分两块画的）
        $upPanelRows = [int][Math]::Floor($chartRows / 2)
        $dnPanelRows = $chartRows - $upPanelRows

        $titleLine = New-Line
        # 窗口长度的写法：整小时 / 整分钟 / 秒
        $spanTxt = if ($spanSec -ge 3600 -and ($spanSec % 3600) -eq 0) { '{0} 小时' -f [int]($spanSec / 3600) }
                   elseif ($spanSec -ge 60 -and ($spanSec % 60) -eq 0) { '{0} 分钟' -f [int]($spanSec / 60) }
                   else { '{0} 秒' -f [int]$spanSec }
        Add-Seg $titleLine ('── 最近 {0}网速（' -f $spanTxt) ([ConsoleColor]::DarkGray)
        Add-Seg $titleLine '##' ([ConsoleColor]::Yellow)
        Add-Seg $titleLine ' 上传  ' ([ConsoleColor]::DarkGray)
        Add-Seg $titleLine '##' ([ConsoleColor]::Cyan)
        Add-Seg $titleLine (' 下载 · 每格 {0:0.#}s） ' -f ($spanSec / [double]$canvas)) ([ConsoleColor]::DarkGray)
        $fill = $contentWidth - (Get-SegWidth $titleLine)
        if ($fill -gt 0) { Add-Seg $titleLine ('─' * $fill) ([ConsoleColor]::DarkGray) }
        $frame.Add((New-ContentLine $titleLine $contentWidth)) | Out-Null

        $panels = @(
            @{ Name = '上传'; Color = [ConsoleColor]::Yellow; Vals = $upSm; Raw = $upVals; Mon = ($direction -ne 'down'); Rows = $upPanelRows },
            @{ Name = '下载'; Color = [ConsoleColor]::Cyan; Vals = $dnSm; Raw = $downVals; Mon = ($direction -eq 'down'); Rows = $dnPanelRows }
        )

        $runText = New-Object System.Text.StringBuilder
        $cThr = [ConsoleColor]::Red
        $cGrid = [ConsoleColor]::DarkGray
        foreach ($p in $panels) {
            $vals = $p.Vals
            $rows = [int]$p.Rows
            $parentColor = [ConsoleColor]$p.Color

            # 真实峰值（用未平滑的原始桶最大值，平滑后峰值会被削平）
            $pk = 0.0
            foreach ($rv in $p.Raw) { if ($rv -gt $pk) { $pk = $rv } }

            # 各自按 98 分位定标（防止瞬时尖峰把曲线压扁）
            $sorted = New-Object System.Collections.Generic.List[double]
            for ($bi = 0; $bi -lt $nBuckets; $bi++) { if ($vals[$bi] -ge 0) { $sorted.Add($vals[$bi]) } }
            $peak = 100.0
            if ($sorted.Count -gt 0) {
                $sorted.Sort()
                $pIdx = [int][Math]::Floor($sorted.Count * 0.98)
                if ($pIdx -ge $sorted.Count) { $pIdx = $sorted.Count - 1 }
                $peak = $sorted[$pIdx]
            }
            # 被监控那条要保证阈值线画得进来
            if ($p.Mon) { $peak = [Math]::Max($peak, $threshold * 1.2) }

            # ===== 刻度带粘性 =====
            # 原来每帧重算 pmax：刻度一变，整张图所有列的高度就跟着一起缩放，
            # 视觉上就是"图一直在动、历史数据也在动"。现在：需要放大立即生效（否则数据会被裁掉），
            # 缩小要等峰值跌到当前刻度的一半以下才降，于是刻度只会偶尔跳一次。
            $need = Get-NiceCeil $peak
            $cur = $script:pmaxCache[$p.Name]
            if ($null -eq $cur -or $cur -le 0) { $cur = $need }
            elseif ($peak -gt $cur) { $cur = $need }
            elseif ($peak -lt ($cur * 0.5)) { $cur = $need }
            $script:pmaxCache[$p.Name] = $cur
            $pmax = $cur

            # 断流阈值只画在被监控的那个面板上（updown 模式是合计值，两条都不对应，就不画）
            $thrR = -1
            if ($p.Mon -and $direction -ne 'updown' -and $threshold -gt 0 -and $threshold -le $pmax) {
                $thrR = $rows - 1 - [int][Math]::Round(($threshold / $pmax) * ($rows - 1))
                if ($thrR -lt 0) { $thrR = 0 }
                if ($thrR -gt $rows - 1) { $thrR = $rows - 1 }
            }

            # 曲线：ASCII 折线（默认）或细方块线
            $cells = New-Object 'object[]' ($rows * $canvas)
            if ($script:glyphMode -eq 'block') { Set-BlockLine $cells $vals $nBuckets $canvas $rows $pmax $colsPer }
            else { Set-AsciiCurve $cells $vals $nBuckets $canvas $rows $pmax $colsPer }

            # 面板名 + 峰值贴在第一行右侧（放不下就只写名字，再放不下就不写）
            $tip = ('{0} 峰值 {1}' -f $p.Name, (Format-SpeedShort $pk))
            $nameCells = $null
            $nameStart = 0
            $nameLen = 0
            foreach ($cand in @($tip, $p.Name)) {
                $w = 0
                foreach ($cch in $cand.ToCharArray()) { $w += (Get-CellWidth $cch) }
                if ($barWidth -ge $w + 6) {
                    $nameLen = $w
                    $nameStart = $barWidth - $w
                    $nameCells = New-Object string[] $w
                    $k = 0
                    foreach ($cch in $cand.ToCharArray()) {
                        $nameCells[$k] = [string]$cch
                        $cw = Get-CellWidth $cch
                        if ($cw -eq 2 -and $k + 1 -lt $w) { $nameCells[$k + 1] = '' }
                        $k += $cw
                    }
                    break
                }
            }

            for ($r = 0; $r -lt $rows; $r++) {
                $rowBase = $r * $canvas
                $isThr = ($r -eq $thrR)
                $isGrid = ($r -eq 0 -or $r -eq $rows - 1)
                $isName = ($r -eq 0 -and $nameLen -gt 0)
                $rowLine = New-Line
                $label = ''
                if ($r -eq 0) { $label = Format-SpeedShort $pmax }
                elseif ($r -eq $rows - 1) { $label = '0' }
                Add-Seg $rowLine ('{0,6}┤' -f $label) ([ConsoleColor]::DarkGray)
                [void]$runText.Clear()
                $runColor = $null
                for ($b = 0; $b -lt $barWidth; $b++) {
                    $ch = ' '
                    $col = $null
                    if ($isName -and $b -ge $nameStart) {
                        $ch = $nameCells[$b - $nameStart]
                        $col = $parentColor
                    } else {
                        $ac = $cells[$rowBase + $b]
                        if ($null -ne $ac) {
                            # 一条细线，统一一个颜色，不再给顶端单独描高亮
                            $ch = [string]$ac
                            $col = $parentColor
                        } elseif ($isThr) {
                            $ch = '.'
                            $col = $cThr
                        } elseif ($isGrid) {
                            $ch = '.'
                            $col = $cGrid
                        }
                    }
                    if ($null -ne $col) {
                        if ($null -eq $runColor) {
                            $runColor = $col
                        } elseif ($col -ne $runColor) {
                            Add-Seg $rowLine $runText.ToString() $runColor
                            [void]$runText.Clear()
                            $runColor = $col
                        }
                    }
                    [void]$runText.Append($ch)
                }
                if ($null -eq $runColor) { $runColor = [ConsoleColor]::Gray }
                Add-Seg $rowLine $runText.ToString() $runColor
                $frame.Add((New-ContentLine $rowLine $contentWidth)) | Out-Null
            }
        }

        $axisLine = New-Line
        Add-Seg $axisLine ((' ' * $gutter) + (Build-AxisLine $barWidth $spanSec)) ([ConsoleColor]::DarkGray)
        $frame.Add((New-ContentLine $axisLine $contentWidth)) | Out-Null
    } else {
        $eventRows = [Math]::Min(8, $winH - 9)
    }

    $evTitle = New-Line
    Add-Seg $evTitle '── 事件 ' ([ConsoleColor]::DarkGray)
    $fill = $contentWidth - (Get-SegWidth $evTitle)
    if ($fill -gt 0) { Add-Seg $evTitle ('─' * $fill) ([ConsoleColor]::DarkGray) }
    $frame.Add((New-ContentLine $evTitle $contentWidth)) | Out-Null

    $evLines = New-Line
    $start = [Math]::Max(0, $script:events.Count - $eventRows)
    for ($i = $start; $i -lt $script:events.Count; $i++) {
        $ev = $script:events[$i]
        $text = Fit-Line (('{0}  {1}' -f $ev.T, $ev.Msg)) $contentWidth
        $line = New-Line
        Add-Seg $line $text $ev.Color
        $evLines.Add((New-ContentLine $line $contentWidth)) | Out-Null
    }
    while ($evLines.Count -lt $eventRows) {
        $line = New-Line
        Add-Seg $line '' ([ConsoleColor]::Gray)
        $evLines.Add((New-ContentLine $line $contentWidth)) | Out-Null
    }
    foreach ($l in $evLines) { $frame.Add($l) | Out-Null }

    $bottom = New-Line
    Add-Seg $bottom ('╚' + ('═' * ($width - 2)) + '╝') ([ConsoleColor]::DarkGray)
    $frame.Add($bottom) | Out-Null

    return ,$frame
}

function Render-Frame {
    try {
        $winW = [Console]::WindowWidth
        $winH = [Console]::WindowHeight
    } catch {
        return
    }
    if ($winW -lt 50 -or $winH -lt 16) { return }
    $frame = Build-Frame $winW $winH
    $width = $winW - 1
    # 每 60 帧强制整屏重绘一次：万一某行被终端换行串位，能自动恢复，不会一直花屏
    $script:frameSeq++
    if ($script:frameSeq % 60 -eq 0) { $script:rowCache = @{} }
    if ($winW -ne $script:lastWinW -or $winH -ne $script:lastWinH) {
        try { [Console]::Clear() } catch {}
        $script:rowCache = @{}
        $script:lastWinW = $winW
        $script:lastWinH = $winH
    }
    if ($script:vtEnabled) {
        for ($i = 0; $i -lt $frame.Count; $i++) {
            $ansi = Convert-LineToAnsi $frame[$i] $width
            if ($script:rowCache[$i] -ne $ansi) {
                try {
                    [Console]::SetCursorPosition(0, $i)
                    [Console]::Write($ansi)
                    if ($i -lt $winH - 2) { [Console]::Write("`r`n") }
                } catch {}
                $script:rowCache[$i] = $ansi
            }
        }
        for ($i = $frame.Count; $i -lt $winH - 1; $i++) {
            if ($script:rowCache.ContainsKey($i)) {
                try {
                    [Console]::SetCursorPosition(0, $i)
                    [Console]::Write((' ' * $width))
                    if ($i -lt $winH - 2) { [Console]::Write("`r`n") }
                } catch {}
                $script:rowCache.Remove($i)
            }
        }
    } else {
        for ($i = 0; $i -lt $frame.Count; $i++) {
            $sig = (($frame[$i] | ForEach-Object { $_.Color.ToString() + ':' + $_.Text }) -join '|')
            if ($script:rowCache[$i] -ne $sig) {
                try {
                    [Console]::SetCursorPosition(0, $i)
                    Write-FrameLine $frame[$i] $width ($i -lt $winH - 2)
                } catch {}
                $script:rowCache[$i] = $sig
            }
        }
    }
}

Write-Log '===== 启动 =====' 'Green'
if ($configError) {
    Write-Log ('配置文件读取失败，使用默认值: ' + $configError) 'Yellow'
}
Write-Log ('阈值={0} KB/s 方向={1} 低速持续={2}s 活动门槛={3} KB/s 活动窗口={4}s 重启等待={5}s 恢复判定={6}s 连续重启报警={7}次 图表平滑={8}s' -f $threshold, $direction, $lowDuration, $activityFloor, $activityWindow, $graceSeconds, $recoverSeconds, $maxRestarts, $chartSmooth)
Write-Log ('配置文件: {0}' -f (Resolve-Path -LiteralPath $ConfigPath -ErrorAction SilentlyContinue))
if ($activityGuard -and $activityFloor -le $threshold) {
    Write-Log ('提示: 活动门槛({0}) 不高于断流阈值({1})，建议把活动门槛设高一些' -f $activityFloor, $threshold) 'Yellow'
}
if (-not $showChart) { Write-Log '已在配置中关闭图表显示（ShowChart=false）' }
if ($showChart) {
    Write-Log ('图表: 窗口 {0}s（{1} 列，约 {2:0.##}s 一列），采样 {3:0.##}s，平滑 {4}s，字形 {5}' -f $script:chartSeconds, $nominalBuckets, $bucketDur0, $sampleSeconds, $chartSmooth, $script:glyphMode)
    if ($sampleSeconds -gt ($bucketDur0 * 1.5)) {
        Write-Log ('提示: 采样间隔比一列还宽，脚本会把一个采样点横向拉开成多列（曲线偏台阶）。想让线更细可以调小 SampleSeconds 或调大 ChartSeconds') 'Yellow'
    }
}
if ($script:layoutOk) { Write-Log ('控制台窗口已固定为 {0}x{1} 并居中' -f $script:consoleCols, $script:consoleRows) } else { Write-Log '当前终端不支持固定窗口大小，将自适应显示' 'Yellow' }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

function New-PropCond($prop, $val) {
    return New-Object System.Windows.Automation.PropertyCondition($prop, $val)
}

function Find-V2rayWindowElement {
    $script:foundVisible = [IntPtr]::Zero
    $script:foundAny = [IntPtr]::Zero
    $cb = [WdWin32+EnumWindowsProc] {
        param($h, $l)
        $sb = New-Object System.Text.StringBuilder 512
        [void][WdWin32]::GetWindowText($h, $sb, 512)
        $t = $sb.ToString()
        if ($t -like 'v2rayN - *') {
            $procId = 0
            [void][WdWin32]::GetWindowThreadProcessId($h, [ref]$procId)
            $procName = ''
            try { $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch {}
            if ($procName -eq 'v2rayN') {
                if ([WdWin32]::IsWindowVisible($h)) { $script:foundVisible = $h }
                elseif ($script:foundAny -eq [IntPtr]::Zero) { $script:foundAny = $h }
            }
        }
        return $true
    }
    [void][WdWin32]::EnumWindows($cb, [IntPtr]::Zero)
    $h = $script:foundVisible
    if ($h -eq [IntPtr]::Zero) { $h = $script:foundAny }
    if ($h -eq [IntPtr]::Zero) { return $null }
    try { return $AE::FromHandle($h) } catch { return $null }
}

function Find-SpeedElement($win) {
    return $win.FindFirst($TS::Descendants, (New-PropCond $AE::AutomationIdProperty 'txtSpeedProxyDisplay'))
}

function Find-RestartElement($win) {
    $el = $win.FindFirst($TS::Descendants, (New-PropCond $AE::AutomationIdProperty 'menuReload'))
    if ($el) { return $el }
    $all = $win.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        if ($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::MenuItem -and $e.Current.Name -eq '重启服务') { return $e }
    }
    return $null
}

function Invoke-V2rayRestart($win) {
    $el = Find-RestartElement $win
    if (-not $el) { throw '未找到「重启服务」按钮(menuReload)' }
    $pattern = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
}

function Convert-SpeedToKBps([string]$num, [string]$unit) {
    $v = [double]::Parse($num, [System.Globalization.CultureInfo]::InvariantCulture)
    switch ($unit.ToUpper()) {
        'B' { return $v / 1024.0 }
        'KB' { return $v }
        'MB' { return $v * 1024.0 }
        'GB' { return $v * 1024.0 * 1024.0 }
    }
    return $v
}

function Parse-ProxySpeed([string]$text) {
    $m = [regex]::Match($text, 'proxy\s*:\s*([\d.]+)\s*([KMG]?B)/s[^|]*\|\s*([\d.]+)\s*([KMG]?B)/s')
    if (-not $m.Success) { return $null }
    $up = Convert-SpeedToKBps $m.Groups[1].Value $m.Groups[2].Value
    $down = Convert-SpeedToKBps $m.Groups[3].Value $m.Groups[4].Value
    return [pscustomobject]@{ Up = $up; Down = $down }
}

function Play-Alarm([int]$rounds) {
    for ($i = 0; $i -lt $rounds; $i++) {
        try {
            [console]::Beep(1568, 220); Start-Sleep -Milliseconds 90
            [console]::Beep(1046, 220); Start-Sleep -Milliseconds 90
            [console]::Beep(1568, 380); Start-Sleep -Milliseconds 260
        } catch {
            [System.Media.SystemSounds]::Hand.Play()
            Start-Sleep -Milliseconds 800
        }
    }
    [System.Media.SystemSounds]::Hand.Play()
}

$win = $null
$speedEl = $null
$lowSeconds = 0.0
$highSeconds = 0.0
$restartCount = 0
$armed = -not $activityGuard
$lastActiveAt = $null
$graceUntil = [DateTime]::MinValue
$lastWindowWarn = [DateTime]::MinValue
$lastTextWarn = [DateTime]::MinValue
$startAt = Get-Date

Render-Frame

try {
    while ($true) {
        if ($StopAfterSeconds -gt 0 -and ((Get-Date) - $startAt).TotalSeconds -ge $StopAfterSeconds) {
            Write-Log ('测试运行时间到（{0}s），退出' -f $StopAfterSeconds) 'Yellow'
            break
        }

        if ($null -eq $win) {
            $win = Find-V2rayWindowElement
            if ($null -eq $win) {
                if (((Get-Date) - $lastWindowWarn).TotalSeconds -ge 30) {
                    Write-Log '未找到 v2rayN 窗口，等待中...' 'Yellow'
                    $lastWindowWarn = Get-Date
                }
                $script:uiState = '等待 v2rayN'
                Render-Frame
                Start-Sleep -Milliseconds 2000
                continue
            }
            Write-Log '已连接 v2rayN 窗口' 'Green'
            $speedEl = $null
        }

        if ($null -eq $speedEl) {
            try { $speedEl = Find-SpeedElement $win } catch { $speedEl = $null }
            if ($null -eq $speedEl) {
                $script:uiState = '等待网速控件'
                if (((Get-Date) - $lastWindowWarn).TotalSeconds -ge 10) {
                    Write-Log '未找到网速显示控件：如果 v2rayN 主窗口处于最小化或托盘隐藏状态，请先恢复窗口（恢复后会自动继续）' 'Yellow'
                    $lastWindowWarn = Get-Date
                }
                Render-Frame
                Start-Sleep -Milliseconds 2000
                continue
            }
        }

        try {
            $text = $speedEl.Current.Name
        } catch {
            Write-Log '读取界面失败（窗口可能已关闭），重新查找...' 'Yellow'
            $win = $null
            $speedEl = $null
            Render-Frame
            Start-Sleep -Milliseconds 2000
            continue
        }

        $parsed = Parse-ProxySpeed $text
        if ($null -eq $parsed) {
            if (((Get-Date) - $lastTextWarn).TotalSeconds -ge 30) {
                Write-Log ('无法解析网速文本: ' + $text) 'Yellow'
                $lastTextWarn = Get-Date
            }
            Render-Frame
            Start-Sleep -Milliseconds $pollMs
            continue
        }

        switch ($direction) {
            'up' { $speed = $parsed.Up }
            'down' { $speed = $parsed.Down }
            'updown' { $speed = $parsed.Up + $parsed.Down }
        }

        $now = Get-Date
        $script:lastUp = $parsed.Up
        $script:lastDown = $parsed.Down

        # 图表采样与「读取/判定」解耦：读取仍然每秒一次（断流判定要灵敏），
        # 但只有每 SampleSeconds 秒才往图表里存一个点 —— 存得太密，画出来全是瞬时抖动，
        # 而且 v2rayN 自己刷新没那么快，1 秒取一次经常是同一个数值在重复放。
        $elapsed = ($now - $script:epoch0).TotalSeconds
        if ($script:lastSampleE -lt 0 -or ($elapsed - $script:lastSampleE) -ge ($sampleSeconds - 0.05)) {
            $script:samples.Add([pscustomobject]@{ E = $elapsed; Up = $parsed.Up; Down = $parsed.Down })
            $script:lastSampleE = $elapsed
        }
        if ($script:samples.Count -gt 0) {
            $cut = $elapsed - ($script:chartSeconds + 10)
            $script:samples.RemoveAll({ param($s) $s.E -lt $cut })
        }

        if ($activityGuard) {
            if ($speed -ge $activityFloor) {
                $lastActiveAt = $now
                if (-not $armed) {
                    $armed = $true
                    Write-Log ('检测到正常速度 {0:N1} KB/s >= {1} KB/s，开始追踪' -f $speed, $activityFloor) 'Green'
                }
            } elseif ($armed -and $restartCount -eq 0 -and $null -ne $lastActiveAt -and ($now - $lastActiveAt).TotalSeconds -gt $activityWindow) {
                $armed = $false
                $lowSeconds = 0.0
                Write-Log ('已有超过 {0}s 未出现正常速度，判定为空闲，暂停自动重启' -f $activityWindow)
            }
        }

        if ($now -lt $graceUntil) {
            $script:uiState = '等待重连'
            Render-Frame
            Start-Sleep -Milliseconds $pollMs
            continue
        }

        if ($speed -le $threshold) {
            $highSeconds = 0.0
            if ($armed) { $lowSeconds += $intervalSec } else { $lowSeconds = 0.0 }
            if ($lowSeconds -ge $lowDuration) {
                try {
                    Invoke-V2rayRestart $win
                    $script:totalRestarts++
                    $restartCount++
                    Write-Log ('速度 {0:N1} KB/s <= {1} KB/s 已持续 {2}s，已点击「重启服务」（累计第 {3} 次，连续第 {4} 次）' -f $speed, $threshold, [int]$lowSeconds, $script:totalRestarts, $restartCount) 'Red'
                    if ($restartCount -ge $maxRestarts) {
                        Write-Log ('连续 {0} 次重启仍未恢复，播放声音报警！' -f $restartCount) 'Magenta'
                        Play-Alarm $alarmRounds
                        Write-Log '报警完毕，暂停自动重启；再次出现正常速度 >= 活动门槛后恢复追踪' 'Magenta'
                        $restartCount = 0
                        if ($activityGuard) { $armed = $false }
                    }
                } catch {
                    Write-Log ('点击「重启服务」失败: ' + $_.Exception.Message) 'Yellow'
                }
                $lowSeconds = 0.0
                $highSeconds = 0.0
                $graceUntil = (Get-Date).AddSeconds($graceSeconds)
            }
        } else {
            $lowSeconds = 0.0
            $highSeconds += $intervalSec
            if ($restartCount -gt 0 -and $highSeconds -ge $recoverSeconds) {
                Write-Log ('速度已恢复 {0:N1} KB/s（> {1} KB/s），连续重启计数清零' -f $speed, $threshold) 'Green'
                $restartCount = 0
            }
        }

        $script:uiState = if ($armed) { '追踪中' } else { '空闲' }
        Render-Frame
        Start-Sleep -Milliseconds $pollMs
    }
} finally {
    try { [Console]::CursorVisible = $true } catch {}
    try {
        $winH = [Console]::WindowHeight
        [Console]::SetCursorPosition(0, $winH - 1)
    } catch {}
    Write-Host ''
    Write-Host ('已退出（累计重启 {0} 次）。完整日志: {1}' -f $script:totalRestarts, $script:LogFile) -ForegroundColor Green
}
