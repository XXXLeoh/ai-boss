$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase, System.Drawing, System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BossNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    private delegate bool WindowCallback(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int count);
    public static IntPtr[] BrowserWindows() {
        var windows = new System.Collections.Generic.List<IntPtr>();
        EnumWindows(delegate(IntPtr window, IntPtr state) {
            var name = new System.Text.StringBuilder(128);
            if (IsWindowVisible(window) && GetClassName(window, name, name.Capacity) > 0
                && name.ToString() == "Chrome_WidgetWin_1") windows.Add(window);
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint x, uint y, int data, UIntPtr extra);
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    public static void ConfigureDpi() {
        try { if (SetThreadDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero) return; }
        catch (EntryPointNotFoundException) {}
        SetProcessDPIAware();
    }
    public static bool At(int x, int y) {
        Point p;
        return GetCursorPos(out p) && p.X == x && p.Y == y;
    }
    public static void Click() {
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }
    public static void Scroll(int amount) { mouse_event(0x800, 0, 0, amount, UIntPtr.Zero); }
}
'@
[BossNative]::ConfigureDpi()

$homeDir = $env:BOSS_SCRIPT_HOME
$jobsUrl = 'https://www.zhipin.com/web/geek/jobs?scale=301,302'
$clock = [Diagnostics.Stopwatch]::StartNew()
$lastClick = -1000
$lastJob = -2000
$phase = '打开普通 Chrome'
$job = $null
$chatAttempted = $false
$windowHandle = [IntPtr]::Zero
$lastState = $null
$walker = [Windows.Automation.TreeWalker]::RawViewWalker
$all = [Windows.Automation.Condition]::TrueCondition
$descendants = [Windows.Automation.TreeScope]::Descendants
$count = 0

function Get-Value($element) {
    $pattern = $null
    if ($element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        return $pattern.Current.Value
    }
    return ''
}

function Get-JobUrl($value) {
    if ($value -match '^https://www\.zhipin\.com(/job_detail/[^?#]+)') { return $Matches[1] }
    return ''
}

function Test-Within($child, $ancestor) {
    for ($node = $child; $node; $node = $walker.GetParent($node)) {
        if ([Windows.Automation.Automation]::Compare($node, $ancestor)) { return $true }
    }
    return $false
}

function Get-Point($item, [switch]$Verify) {
    if (!$item -or !$item.Current.IsEnabled -or $item.Current.IsOffscreen) { return $null }
    $rect = $item.Current.BoundingRectangle
    if ($rect.IsEmpty -or $rect.Width -le 1 -or $rect.Height -le 1) { return $null }
    $p = [Windows.Point]::new([int]($rect.X + $rect.Width / 2), [int]($rect.Y + $rect.Height / 2))
    if ($Verify -and !(Test-Within ([Windows.Automation.AutomationElement]::FromPoint($p)) $item)) {
        return $null
    }
    return $p
}

function Read-Page {
    $foreground = [BossNative]::GetForegroundWindow()
    if ($windowHandle -ne [IntPtr]::Zero -and $foreground -ne $windowHandle) {
        throw 'Chrome 岗位窗口失去前台焦点'
    }
    if ($foreground -eq [IntPtr]::Zero) {
        $script:lastState = @{ foreground = '无前台窗口' }
        return $null
    }
    $root = [Windows.Automation.AutomationElement]::FromHandle($foreground)
    $processName = (Get-Process -Id $root.Current.ProcessId).ProcessName
    if ($processName -ne 'chrome') {
        $script:lastState = @{ foreground = $processName }
        return $null
    }
    $items = $root.FindAll($descendants, $all)
    $bar = @($items | Where-Object { $_.Current.AutomationId -eq 'view_1012' -or
        $_.Current.Name -in @('地址和搜索栏', 'Address and search bar') })
    $address = if ($bar.Count -eq 1) { Get-Value $bar[0] } else { '' }
    if ($address -notmatch '^(https://)?(www\.)?zhipin\.com/web/geek/jobs(\?|$)') {
        $script:lastState = @{ foreground = 'chrome'; addressBarMatches = $bar.Count; addressReadable = [bool]$address }
        if ($windowHandle -ne [IntPtr]::Zero) { throw '地址已离开岗位列表，或无法确认当前网址' }
        return $null
    }
    if ($windowHandle -eq [IntPtr]::Zero) { $script:windowHandle = $foreground }
    $script:lastState = @{ address = $address }

    $jobs = [Collections.Generic.List[object]]::new()
    $directions = [Collections.Generic.List[object]]::new()
    $recommendations = @($items | Where-Object {
        $_.Current.Name -eq '推荐' -and !$_.Current.IsOffscreen -and
        $_.Current.ControlType -in @([Windows.Automation.ControlType]::Text,
            [Windows.Automation.ControlType]::Hyperlink, [Windows.Automation.ControlType]::TabItem)
    })
    if ($recommendations.Count -gt 0) {
        $recommend = $recommendations[0]
        $row = $recommend.Current.BoundingRectangle
        $seenNames = [Collections.Generic.HashSet[string]]::new()
        foreach ($item in $items) {
            $c = $item.Current
            $b = $c.BoundingRectangle
            $label = ([string]$c.Name).Trim()
            if ($c.IsOffscreen -or $b.IsEmpty -or !$label -or
                $label -match '^(推荐|[+＋|｜]|搜索|搜索职位、公司|地图)$' -or
                $b.Left -le $row.Right -or [Math]::Abs(($b.Top + $b.Height / 2) - ($row.Top + $row.Height / 2)) -gt 10 -or
                $b.Width -gt 320 -or $b.Height -gt 60 -or
                $c.ControlType -notin @([Windows.Automation.ControlType]::Text,
                    [Windows.Automation.ControlType]::Hyperlink, [Windows.Automation.ControlType]::TabItem,
                    [Windows.Automation.ControlType]::ListItem)) { continue }
            if ($seenNames.Add($label)) {
                $directions.Add(@{ Name = $label; Element = $item; X = $b.Left })
            }
        }
    }
    $detailLinks = [Collections.Generic.List[object]]::new()
    $texts = [Collections.Generic.List[object]]::new()
    $controls = @{ '立即沟通' = @(); '继续沟通' = @(); '留在此页' = @() }
    $dialogs = [Collections.Generic.List[object]]::new()
    $atEnd = $false
    foreach ($element in $items) {
        $current = $element.Current
        $type = $current.ControlType
        $name = ([string]$current.Name).Trim()
        if ($type -eq [Windows.Automation.ControlType]::Hyperlink) {
            $value = Get-Value $element
            $id = Get-JobUrl $value
            if ($id -and $name) {
                $parent = $walker.GetParent($element)
                if ($parent -and $parent.Current.ControlType -eq [Windows.Automation.ControlType]::ListItem) {
                    $jobs.Add(@{ Id = $id; Title = $name; Element = $parent })
                } else {
                    $detailLinks.Add(@{ Id = $id; Name = $name; Element = $element })
                }
            }
        }
        if ($current.IsOffscreen) { continue }
        if ($name -match '^(安全验证|请完成验证|请输入验证码|访问过于频繁|操作过于频繁|访问受限|操作受限|滑动滑块)') {
            throw "发现验证码或限制提示：$name"
        }
        if ($name -in @('没有更多了', '没有更多职位了', '没有更多职位', '暂无更多职位', '暂无职位')) { $atEnd = $true }
        if ($type -eq [Windows.Automation.ControlType]::Text -and $name) {
            $texts.Add(@{ Name = $name; Element = $element })
        }
        if (($type -eq [Windows.Automation.ControlType]::Button -or
            $type -eq [Windows.Automation.ControlType]::Hyperlink) -and $controls.ContainsKey($name)) {
            $controls[$name] += $element
        }
        $isDialog = $null
        if ($current.ClassName -match 'Dialog' -or
            ($element.TryGetCurrentPattern([Windows.Automation.WindowPattern]::Pattern, [ref]$isDialog) -and
             $isDialog.Current.IsModal)) { $dialogs.Add($element) }
    }
    $script:lastState = @{
        address = $address; jobs = $jobs.Count; dialogs = $dialogs.Count; atEnd = $atEnd
        chat = $controls['立即沟通'].Count; already = $controls['继续沟通'].Count; stay = $controls['留在此页'].Count
    }
    return @{
        Handle = $foreground; Jobs = $jobs; DetailLinks = $detailLinks; Texts = $texts
        Directions = @($directions | Sort-Object X)
        Recommend = if ($recommendations.Count -gt 0) { $recommendations[0] } else { $null }
        Controls = $controls; Dialogs = $dialogs; End = $atEnd
    }
}

function Confirm-Dialog($state, [switch]$Allowed) {
    $stay = $state.Controls['留在此页']
    if ($stay.Count -gt 1 -or (!$Allowed -and ($stay.Count -gt 0 -or $state.Dialogs.Count -gt 0))) {
        throw '检测到流程外弹窗'
    }
    if ($Allowed) {
        foreach ($dialog in $state.Dialogs) {
            if ($stay.Count -ne 1 -or !(Test-Within $stay[0] $dialog)) { throw '检测到未知弹窗' }
        }
    }
}

function Test-DirectionSelected($element) {
    for ($node = $element; $node; $node = $walker.GetParent($node)) {
        $bounds = $node.Current.BoundingRectangle
        if ($bounds.IsEmpty -or $bounds.Height -gt 60) { return $false }
        $pattern = $null
        if ($node.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern) -and
            $pattern.Current.IsSelected) { return $true }
        if ($node.Current.ClassName -match '(^|[\s_-])(active|selected|current)($|[\s_-])') { return $true }
    }
    return $false
}

function Restore-JobWindow {
    $deadline = $clock.ElapsedMilliseconds + 10000
    if ([BossNative]::IsIconic($windowHandle)) { [void][BossNative]::ShowWindowAsync($windowHandle, 9) }
    while ($clock.ElapsedMilliseconds -lt $deadline) {
        if ([BossNative]::GetForegroundWindow() -ne $windowHandle) {
            [void][BossNative]::SetForegroundWindow($windowHandle)
        }
        Start-Sleep -Milliseconds 150
        if ([BossNative]::GetForegroundWindow() -eq $windowHandle) {
            Start-Sleep -Milliseconds 150
            if ([BossNative]::GetForegroundWindow() -eq $windowHandle) { return }
        }
    }
    throw '选择后 10 秒内未能恢复 Chrome 前台焦点'
}

function Get-DirectionPoint($element) {
    if (!$element -or !$element.Current.IsEnabled -or $element.Current.IsOffscreen) { return $null }
    $bounds = $element.Current.BoundingRectangle
    if ($bounds.IsEmpty) { return $null }
    # Text bounds can extend beyond an ellipsis. Restrict input to the visible container.
    $clip = $bounds
    $container = $element
    for ($parent = $walker.GetParent($element); $parent; $parent = $walker.GetParent($parent)) {
        $b = $parent.Current.BoundingRectangle
        if ($b.IsEmpty -or $b.Height -gt 65 -or $b.Width -gt 350) { break }
        $clip.Intersect($b)
        $container = $parent
    }
    if ($clip.IsEmpty -or $clip.Width -lt 4 -or $clip.Height -lt 4) { return $null }
    foreach ($fraction in @(0.2, 0.35, 0.5, 0.65)) {
        $p = [Windows.Point]::new([int]($clip.Left + $clip.Width * $fraction),
            [int]($clip.Top + $clip.Height / 2))
        if (Test-Within ([Windows.Automation.AutomationElement]::FromPoint($p)) $container) { return $p }
    }
    return $null
}

function Wait-State([scriptblock]$check, [switch]$AllowDialog) {
    $deadline = $clock.ElapsedMilliseconds + 10000
    while ($clock.ElapsedMilliseconds -lt $deadline) {
        $state = Read-Page
        if ($clock.ElapsedMilliseconds -ge $deadline) { break }
        if ($state) {
            Confirm-Dialog $state -Allowed:$AllowDialog
            $result = & $check $state
            if ($result -and $clock.ElapsedMilliseconds -lt $deadline) { return $result }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "${phase}：10 秒内未满足页面条件"
}

function Get-Detail($state) {
    $immediate = $state.Controls['立即沟通']
    $already = $state.Controls['继续沟通']
    if ($immediate.Count + $already.Count -ne 1) { return $null }
    $control = if ($immediate.Count -eq 1) { $immediate[0] } else { $already[0] }
    $button = Get-Point $control -Verify:($immediate.Count -eq 1)
    if (!$button -or $button.X -le $job.Left) { return $null }
    $title = @($state.Texts | Where-Object {
        $bounds = $_.Element.Current.BoundingRectangle
        $_.Name -ceq $job.Title -and !$bounds.IsEmpty -and $bounds.X -gt $job.Left -and $bounds.Y -le $button.Y
    })
    if ($title.Count -ne 1) { return $null }
    $rightLinks = @($state.DetailLinks | Where-Object {
        $bounds = $_.Element.Current.BoundingRectangle
        $_.Name -eq '查看更多信息' -and !$bounds.IsEmpty -and
        $bounds.X -ge ($title[0].Element.Current.BoundingRectangle.X - 20)
    })
    if ($rightLinks.Count -ne 1 -or $rightLinks[0].Id -ne $job.Id) { return $null }
    return @{ Element = $control; Already = ($already.Count -eq 1) }
}

function Get-ClickPoint($item, [switch]$Selecting, [switch]$Direction) {
    if ($Direction) { return Get-DirectionPoint $item }
    if (!$Selecting) { return Get-Point $item -Verify }
    if (!$item -or !$item.Current.IsEnabled) { return $null }
    $bounds = $item.Current.BoundingRectangle
    if ($bounds.IsEmpty -or $bounds.Width -lt 4 -or $bounds.Height -lt 4) { return $null }
    $jobLinks = @($item.FindAll($descendants, $all) | Where-Object {
        $_.Current.ControlType -eq [Windows.Automation.ControlType]::Hyperlink -and
        (Get-JobUrl (Get-Value $_))
    })
    $jobIds = @($jobLinks | ForEach-Object { Get-JobUrl (Get-Value $_) } | Select-Object -Unique)
    foreach ($yFraction in @(0.5, 0.3, 0.15, 0.7)) {
    foreach ($xFraction in @(0.95, 0.7, 0.5, 0.25)) {
    $p = [Windows.Point]::new([int]($bounds.Left + $bounds.Width * $xFraction),
        [int]($bounds.Top + $bounds.Height * $yFraction))
    $hit = [Windows.Automation.AutomationElement]::FromPoint($p)
    if (!(Test-Within $hit $item)) { continue }
    $valid = $true
    for ($node = $hit; $node -and ![Windows.Automation.Automation]::Compare($node, $item); $node = $walker.GetParent($node)) {
        if ($node.Current.ControlType -eq [Windows.Automation.ControlType]::Button) {
            $valid = $false
            break
        }
        if ($node.Current.ControlType -eq [Windows.Automation.ControlType]::Hyperlink) {
            $linkId = Get-JobUrl (Get-Value $node)
            if (!$linkId -or $jobIds.Count -ne 1 -or $jobIds[0] -ne $linkId) {
                $valid = $false
                break
            }
        }
    }
    if ($valid) { return $p }
    }
    }
    return $null
}

function Invoke-FlowClick([scriptblock]$target, [switch]$Selecting, [switch]$AllowDialog, [switch]$Chatting,
    [switch]$Direction) {
    $earliest = $lastClick + 1000
    if ($Selecting) { $earliest = [Math]::Max($earliest, $lastJob + 2000) }
    while ($clock.ElapsedMilliseconds -lt $earliest) {
        $state = Read-Page
        Confirm-Dialog $state -Allowed:$AllowDialog
        Start-Sleep -Milliseconds 80
    }
    $state = Read-Page
    Confirm-Dialog $state -Allowed:$AllowDialog
    $point = Get-ClickPoint (& $target $state) -Selecting:$Selecting -Direction:$Direction
    if (!$point -or ![BossNative]::SetCursorPos([int]$point.X, [int]$point.Y)) { throw '目标不可点击' }
    $state = Read-Page
    Confirm-Dialog $state -Allowed:$AllowDialog
    $confirm = Get-ClickPoint (& $target $state) -Selecting:$Selecting -Direction:$Direction
    if (!$confirm -or $confirm.X -ne $point.X -or $confirm.Y -ne $point.Y -or
        [BossNative]::GetForegroundWindow() -ne $windowHandle -or
        ![BossNative]::At([int]$point.X, [int]$point.Y)) { throw '点击前目标或鼠标位置发生变化' }
    if ($Chatting) { $script:chatAttempted = $true }
    [BossNative]::Click()
    $script:lastClick = $clock.ElapsedMilliseconds
}

function Find-Next($state, $previousId) {
    if (!$previousId) {
        foreach ($card in $state.Jobs) {
            if (!$processed.Contains($card.Id)) { return $card }
        }
        return $null
    }
    for ($index = 0; $index -lt $state.Jobs.Count; $index++) {
        if ($state.Jobs[$index].Id -eq $previousId) {
            for ($nextIndex = $index + 1; $nextIndex -lt $state.Jobs.Count; $nextIndex++) {
                if (!$processed.Contains($state.Jobs[$nextIndex].Id)) { return $state.Jobs[$nextIndex] }
            }
            return $null
        }
    }
    throw '列表已改变，无法确认下一条岗位'
}

function Switch-Direction([string]$name, [switch]$Recommend) {
    $script:phase = if ($Recommend) { '切换到推荐以刷新列表' } else { "切换求职方向：$name" }
    $before = Read-Page
    Confirm-Dialog $before
    $idsBefore = ($before.Jobs | ForEach-Object Id) -join '|'
    $target = {
        param($s)
        if ($Recommend) { return $s.Recommend }
        $matches = @($s.Directions | Where-Object { $_.Name -ceq $name })
        if ($matches.Count -eq 1) { return $matches[0].Element }
    }
    $null = Wait-State { param($s) Get-DirectionPoint (& $target $s) }
    Invoke-FlowClick -Direction -Target $target
    $null = Wait-State {
        param($s)
        $element = & $target $s
        $idsNow = ($s.Jobs | ForEach-Object Id) -join '|'
        if ($element -and ($s.Jobs.Count -gt 0 -or $s.End) -and
            ((Test-DirectionSelected $element) -or $idsNow -ne $idsBefore)) { return $true }
    }
}

function Get-ScrollAnchor($card) {
    $bounds = $card.Element.Current.BoundingRectangle
    if ($bounds.IsEmpty) { return $null }
    $windowBounds = [Windows.Automation.AutomationElement]::FromHandle($windowHandle).Current.BoundingRectangle
    $bounds.Intersect($windowBounds)
    if ($bounds.IsEmpty -or $bounds.Height -lt 8) { return $null }
    foreach ($fraction in @(0.5, 0.2, 0.8)) {
        $point = [Windows.Point]::new([int]($bounds.Right - 10),
            [int]($bounds.Top + $bounds.Height * $fraction))
        if (Test-Within ([Windows.Automation.AutomationElement]::FromPoint($point)) $card.Element) { return $point }
    }
    return $null
}

function Save-Failure($reason) {
    $dir = Join-Path $homeDir 'logs'
    [void][IO.Directory]::CreateDirectory($dir)
    $base = Join-Path $dir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-native-$PID")
    $report = @{
        time = (Get-Date -Format o); step = $phase; reason = $reason; chatAttempted = $chatAttempted
        completed = $count; observation = $lastState
        job = if ($job) { @{ id = $job.Id; title = $job.Title } } else { $null }
    }
    try {
        if ($windowHandle -eq [IntPtr]::Zero -or [BossNative]::GetForegroundWindow() -ne $windowHandle) {
            throw '岗位窗口不在前台'
        }
        $bounds = [Windows.Automation.AutomationElement]::FromHandle($windowHandle).Current.BoundingRectangle
        $windowRect = [Drawing.Rectangle]::new([int]$bounds.X, [int]$bounds.Y, [int]$bounds.Width, [int]$bounds.Height)
        $area = [Drawing.Rectangle]::Intersect($windowRect, [Windows.Forms.SystemInformation]::VirtualScreen)
        if ($area.IsEmpty) { throw '岗位窗口不在可视区域内' }
        $bitmap = [Drawing.Bitmap]::new($area.Width, $area.Height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($area.Location, [Drawing.Point]::Empty, $area.Size)
            $bitmap.Save("$base.png", [Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    } catch {
        $report.screenshotError = $_.Exception.Message
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$base.json" -Encoding UTF8
    [Console]::Error.WriteLine("脚本已退出：$reason`n日志：$base.json")
}

try {
    $paths = @(
        $env:BOSS_CHROME_PATH
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $chrome = $paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (!$chrome) { throw '找不到 Chrome，请配置 BOSS_CHROME_PATH' }
    $profile = Join-Path $homeDir '.chrome-boss'
    $before = [BossNative]::BrowserWindows()
    Start-Process -FilePath $chrome -ArgumentList ('--user-data-dir="{0}" --no-first-run --new-window "{1}"' -f $profile, $jobsUrl)
    $deadline = $clock.ElapsedMilliseconds + 10000
    do {
        $newWindows = @([BossNative]::BrowserWindows() | Where-Object { $_ -notin $before })
        if ($newWindows.Count -eq 1) {
            $candidate = $newWindows[0]
            $candidateRoot = [Windows.Automation.AutomationElement]::FromHandle($candidate)
            if ((Get-Process -Id $candidateRoot.Current.ProcessId).ProcessName -eq 'chrome') {
                if ([BossNative]::GetForegroundWindow() -ne $candidate) {
                    [void][BossNative]::SetForegroundWindow($candidate)
                }
                if ([BossNative]::GetForegroundWindow() -eq $candidate) {
                    $initial = Read-Page
                    if ($initial) {
                        Confirm-Dialog $initial
                        break
                    }
                } else { $lastState = @{ foreground = 'Chrome 新窗口未取得前台焦点' } }
            }
        } else { $lastState = @{ newWindows = $newWindows.Count } }
        Start-Sleep -Milliseconds 120
    } while ($clock.ElapsedMilliseconds -lt $deadline)
    if (!$initial -or $clock.ElapsedMilliseconds -ge $deadline) {
        throw '10 秒内未确认普通 Chrome 岗位页，请检查新打开的窗口是否已登录并处于前台'
    }
    $windowHandle = $initial.Handle
    $phase = '读取求职方向'
    $options = @(Wait-State { param($s) if ($s.Directions.Count -gt 0) { $s.Directions } })
    Write-Host '从当前页面读取到以下求职方向：'
    for ($i = 0; $i -lt $options.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i + 1), $options[$i].Name)
    }
    if ($env:BOSS_CHECK_ONLY -ne '1') {
        $phase = '等待用户选择求职方向'
        if ($options.Count -eq 1) {
            $number = 1
            Write-Host '只有一个求职方向，自动选择。'
        } else {
        do {
            $answer = Read-Host '请输入编号（输入 q 退出）'
            if ($answer -eq 'q') { exit 0 }
            $number = 0
            $valid = [int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $options.Count
            if (!$valid) { Write-Host '请输入列表内的有效编号。' }
        } until ($valid)
        }
        $selectedName = $options[$number - 1].Name
        # Reading terminal input changes focus. Restore only the already verified Chrome window.
        Restore-JobWindow
        $phase = '点击所选求职方向'
        $beforeState = Read-Page
        Confirm-Dialog $beforeState
        $beforeIds = ($beforeState.Jobs | ForEach-Object Id) -join '|'
        $null = Wait-State {
            param($s)
            $matches = @($s.Directions | Where-Object { $_.Name -ceq $selectedName })
            if ($matches.Count -eq 1) { Get-DirectionPoint $matches[0].Element }
        }
        Invoke-FlowClick -Direction -Target {
            param($s)
            $matches = @($s.Directions | Where-Object { $_.Name -ceq $selectedName })
            if ($matches.Count -eq 1) { $matches[0].Element }
        }
        $phase = '等待所选方向岗位列表'
        $null = Wait-State {
            param($s)
            $matches = @($s.Directions | Where-Object { $_.Name -ceq $selectedName })
            if ($matches.Count -ne 1 -or $s.Jobs.Count -eq 0) { return $null }
            $selected = Test-DirectionSelected $matches[0].Element
            $ids = ($s.Jobs | ForEach-Object Id) -join '|'
            if ($selected -or $ids -ne $beforeIds) { return $true }
        }
        Write-Host "已选择：$selectedName"
    }
    $previousId = ''
    $processed = [Collections.Generic.HashSet[string]]::new()
    $recovered = $false
    while ($true) {
        $phase = '确认下一条岗位'
        $job = $null
        $chatAttempted = $false
        $scroll = @{ Last = -1000 }
        try {
        $next = Wait-State {
            param($state)
            $card = Find-Next $state $previousId
            if ($card) {
                $duplicates = @($state.Jobs | Where-Object { $_.Id -eq $card.Id }).Count
                if ($processed.Contains($card.Id) -or !$card.Title -or $duplicates -ne 1) {
                    $lastState.candidate = @{ id = $card.Id; title = $card.Title; occurrences = $duplicates
                        positions = @($state.Jobs | Where-Object { $_.Id -eq $card.Id } | ForEach-Object {
                            $b = $_.Element.Current.BoundingRectangle
                            @{ x = $b.X; y = $b.Y; w = $b.Width; h = $b.Height
                               parent = $walker.GetParent($_.Element).Current.ControlType.ProgrammaticName }
                        })
                    }
                    throw '无法唯一确认岗位'
                }
                $point = Get-ClickPoint $card.Element -Selecting
                $lastState.candidate = @{ id = $card.Id; visible = [bool](Get-Point $card.Element)
                    hit = [bool]$point }
                if ($point) {
                    return @{ Id = $card.Id; Title = $card.Title; Left = $point.X }
                }
            } elseif ($state.End) { return @{ End = $true } }
            if ($env:BOSS_CHECK_ONLY -ne '1' -and $clock.ElapsedMilliseconds -ge $scroll.Last + 500) {
                $anchors = @(
                foreach ($visibleCard in $state.Jobs) {
                    $anchor = Get-ScrollAnchor $visibleCard
                    if ($anchor) { $anchor }
                })
                if ($anchors.Count -gt 0) {
                    $ordered = @($anchors | Sort-Object Y)
                    $anchor = $ordered[[int][Math]::Floor(($ordered.Count - 1) / 2)]
                    $amount = -360
                    if ($card) {
                        $bounds = $card.Element.Current.BoundingRectangle
                        if (!$bounds.IsEmpty) {
                            $center = $bounds.Top + $bounds.Height / 2
                            # A large wheel step can pass the next card. Scroll back toward that card.
                            $amount = if ($center -lt $anchor.Y) { 120 } else { -120 }
                            $lastState.scrollTarget = @{
                                id = $card.Id; top = $bounds.Top; bottom = $bounds.Bottom
                                anchorY = $anchor.Y; wheel = $amount
                            }
                        }
                    }
                    if ([BossNative]::GetForegroundWindow() -eq $windowHandle -and
                        [BossNative]::SetCursorPos([int]$anchor.X, [int]$anchor.Y)) {
                        [BossNative]::Scroll($amount)
                        $scroll.Last = $clock.ElapsedMilliseconds
                    }
                }
            }
        }
        } catch {
            if ($env:BOSS_CHECK_ONLY -eq '1' -or
                $_.Exception.Message -notmatch '确认下一条岗位：10 秒内未满足页面条件|列表已改变，无法确认下一条岗位' -or $recovered) { throw }
            Save-Failure $_.Exception.Message
            Write-Host '滚动后仍无法确认下一条，切换方向后重新选择岗位。'
            $state = Read-Page
            Confirm-Dialog $state
            $alternatives = @($state.Directions | Where-Object { $_.Name -cne $selectedName })
            if ($alternatives.Count -gt 0) {
                $selectedName = $alternatives[0].Name
                Switch-Direction $selectedName
            } else {
                Switch-Direction -Recommend
                Switch-Direction $selectedName
            }
            $previousId = ''
            $recovered = $true
            continue
        }
        if ($next.End) { break }
        $job = $next
        if ($env:BOSS_CHECK_ONLY -eq '1') {
            Write-Host "只读检查通过：已识别第一条岗位和可点击区域。当前页识别到 $($lastState.jobs) 条岗位。"
            if (Get-Detail (Read-Page)) { Write-Host '已核对页面预选岗位与右侧详情一致。' }
            exit 0
        }
        $phase = '点击岗位'
        Invoke-FlowClick -Selecting -Target {
            param($state)
            $card = Find-Next $state $previousId
            if ($card -and $card.Id -eq $job.Id -and $card.Title -ceq $job.Title) { $card.Element }
        }
        $phase = '等待匹配的右侧详情和沟通按钮'
        $detail = Wait-State { param($state) Get-Detail $state }
        if ($detail.Already) {
            Write-Host "已跳过「继续沟通」 $($job.Title)"
        } else {
            $phase = '点击立即沟通'
            Invoke-FlowClick -Chatting -Target {
                param($state)
                $current = Get-Detail $state
                if ($current -and !$current.Already) { $current.Element }
            }
            $phase = '等待留在此页'
            $null = Wait-State -AllowDialog -Check { param($state) Get-Point $state.Controls['留在此页'][0] -Verify }
            $phase = '点击留在此页'
            Invoke-FlowClick -AllowDialog -Target { param($state) $state.Controls['留在此页'][0] }
            $phase = '确认弹窗关闭'
            $null = Wait-State -AllowDialog -Check {
                param($state)
                $state.Controls['留在此页'].Count -eq 0 -and $state.Dialogs.Count -eq 0 -and
                @($state.Jobs | Where-Object { $_.Id -eq $job.Id }).Count -eq 1
            }
            $count++
            Write-Host "已完成沟通点击流程 $($job.Title)"
        }
        $lastJob = $clock.ElapsedMilliseconds
        $recovered = $false
        $previousId = $job.Id
        [void]$processed.Add($previousId)
    }
    Write-Host "列表处理结束，完成 $count 次沟通点击流程。"
} catch {
    Save-Failure $_.Exception.Message
    exit 1
}
