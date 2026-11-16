# v2rayN 断流监控 (watchdog)

监控 v2rayN 状态栏的代理网速：网速持续低于阈值时自动点击 v2rayN 里的「重启服务」按钮；
连续多次重启仍不恢复则播放声音报警。监控界面（图表 + 事件）直接显示在启动它的控制台窗口里。

## 文件说明

| 文件 | 说明 |
|---|---|
| `start-watchdog.bat` | 启动入口，双击运行；有 PowerShell 7 就用 7，否则回退 5.1；脚本会自动申请管理员权限（UAC） |
| `watchdog.ps1` | 主程序（PowerShell 5.1 / 7 通用，无第三方依赖） |
| `config.json` | 配置，支持 `//` 和 `#` 注释（加载时会自动剥离） |
| `watchdog.log` | 运行日志（UTF-8，与脚本同目录，>2MB 时自动轮转为 `watchdog.log.old`） |

## 运行环境

- Windows 10 / 11，PowerShell 5.1（系统自带）或 PowerShell 7（`pwsh`）
- v2rayN v7.x（依赖其界面 AutomationId：`txtSpeedProxyDisplay`、`menuReload`）
- v2rayN 以管理员身份运行时，本工具也必须提权（脚本自动处理）

### 用 PowerShell 7 跑（可选）

`start-watchdog.bat` 会优先找 `pwsh.exe`，找不到才用 `powershell.exe`；直接命令行跑也可以：

```powershell
pwsh -NoProfile -File .\watchdog.ps1
```

- 提权重启已经改成**跟随当前宿主**（用 `pwsh` 启动就用 `pwsh` 提权，不会掉回 5.1）。
- PS7 安装目录自带 `UIAutomationClient/Types`，读 v2rayN 界面没问题。
- 实测两者的渲染耗时基本一致（都约 70 ms/帧），PS7 的好处主要是启动更快、控制台渲染更好、
  语法更现代；想用哪个都行，5.1 依然完整支持。


## 使用方法

1. 确认 v2rayN 正在运行，**启动监控时其主窗口处于显示状态**（最小化/托盘隐藏时读不到控件）。
   启动成功后可以随意最小化 v2rayN，监控不受影响（元素已缓存）。
2. 双击 `start-watchdog.bat`，UAC 点「是」。
3. 控制台固定为 120x40 并居中显示：顶部状态行、实时速度行、网速图（上传/下载两个面板）、事件区。
4. 关闭控制台窗口或 Ctrl+C 即停止监控。

## 配置项（config.json）

| 参数 | 默认 | 含义 |
|---|---|---|
| `ThresholdKBps` | 500 | 断流阈值：被监控方向速度 ≤ 该值 |
| `LowDurationSeconds` | 5 | 低速需持续多少秒才触发重启 |
| `Direction` | `up` | 监控方向：`up`=上传(第一个数字) / `down`=下载 / `updown`=合计 |
| `ActivityFloorKBps` | 800 | 活动门槛：窗口内曾达到该速度才算「正在传输」；0 关闭活动判断 |
| `ActivityWindowSeconds` | 60 | 活动窗口：超过这么久没到过活动门槛则判空闲，暂停自动重启 |
| `RestartGraceSeconds` | 20 | 点击重启后等待多少秒再继续判定 |
| `RecoverSeconds` | 10 | 速度高于阈值持续多少秒视为恢复，连续重启计数清零 |
| `MaxConsecutiveRestarts` | 3 | 连续重启多少次仍未恢复就声音报警（报警后暂停自动重启） |
| `PollIntervalMs` | 1000 | 读取网速间隔（毫秒） |
| `AlarmBeepRounds` | 3 | 报警蜂鸣轮数 |
| `ShowChart` | true | 是否显示图表 |
| `ChartSeconds` | 300 | 图表时间窗口（秒）。**随便设**：10 / 45 / 60 / 120 / 600 / 1800 都行，时间轴刻度会自动跟着变 |
| `SampleSeconds` | 1 | 图表采样间隔（秒），只影响画图不影响判定；0 = 1 秒。最小等于 `PollIntervalMs`，设大一点图更稳 |
| `ChartSmoothSeconds` | 8 | 图表平滑窗口（秒）：画图前做滑动平均，0 = 不平滑（最有棱角）。只影响画面，不影响断流判定 |
| `ChartGlyphs` | `ascii` | 曲线字形：`ascii` = `#`+`|` 画的细折线（默认，任何终端都正常）；`block` = `▁▂▃▄▅▆▇█` 细方块线（1/8 行精度） |

调参建议：`ThresholdKBps` 设得接近正常上传速度会让空闲时段频繁触发；`ActivityFloorKBps`
应高于 `ThresholdKBps`（"本来快过、现在掉下来"才重启）。`ChartSmoothSeconds` 只影响图表观感：
设小（0~5）棱角分明、瞬时下切最真实，默认 8，设大（20+）画面就"肉"了、短暂掉速会被抹平。
脚本启动时会在事件区打印实际生效参数。

图表窗口设得特别长（几小时以上）时记得把 `SampleSeconds` 调大一点（比如 10~30 秒）：
采样点全部留在内存里、每帧都要遍历一遍，1 秒采样 + 24 小时窗口会有 8 万多个点，帧耗时会翻倍。

## 工作原理

1. **读取网速**：UI Automation 从 v2rayN 主窗口的 `txtSpeedProxyDisplay`（状态栏 proxy 文本，
   形如 `proxy : 1.2 MB/s↑ | 30 KB/s↓`）解析出两个数字，按 `Direction` 取被监控值。
2. **点击重启**：UI Automation `InvokePattern` 触发 `menuReload`（「重启服务」菜单项）。
   若找不到 id 则回退为按名称「重启服务」查找 MenuItem。
3. **状态机**（每秒一次）：
   - 速度 ≥ `ActivityFloorKBps` → 武装（追踪中）；
   - 武装期间低速累计 ≥ `LowDurationSeconds` → 点击重启，连续重启 +1，进入 `RestartGraceSeconds` 等待期；
   - 连续重启 ≥ `MaxConsecutiveRestarts` → 蜂鸣 + 系统提示音，暂停自动重启，直到再次出现正常速度；
   - 武装且连续重启为 0 时，超过 `ActivityWindowSeconds` 未达活动门槛 → 判空闲，不重启；
   - 恢复（速度 > 阈值持续 `RecoverSeconds`）→ 连续重启计数清零。
4. **界面渲染**：每秒重绘（只有变化的行才真正写屏）。图表的实现要点：
   - **采样与读取解耦**：读取/判定仍是 `PollIntervalMs`（1 秒一次，保证断流判断灵敏），
     记录点按 `SampleSeconds`（默认 1 秒）一次。采样越密最右一列越"活"，越稀越稳。
   - **时间桶按绝对时间对齐**：桶边界固定在脚本启动时刻的整数倍上，右端那个还没装满的桶也一起画。
     早先的写法每帧都用 `now - 窗口` 重新划分时间桶，桶边界一直在漂，已经过去的数据会被重新
     归组，于是"柱子移过去之后高度还在变"。现在历史列一旦画出来就不再变，只有最右一列随新采样
     生长、以及每滚过一个桶时整体左移一格。
   - **一列代表多少时间**由 `ChartSeconds / 列数` 决定（默认 5 分钟 / 108 列 ≈ 2.8 秒）。
     窗口设得很短、采样点比列数还少时，一个采样点会自动占多列（横向拉开），所以任何窗口长度
     都能画满宽度、不会出现空列把线断开。想让"每秒滚动一格"，把 `ChartSeconds` 设成 100 左右即可。
   - **桶内取平均**（不是最大值）：最大值会把每一列都顶到该窗口内最尖的那一下，看起来像一排刺。
   - **刻度带粘性**：每列高度都依赖纵轴上限，上限一变整张图就一起缩放，看起来仍然是"在动"。
     所以纵轴只在需要放大时立即上调，缩小要等峰值跌到当前刻度一半以下才降。
   - 再按 `ChartSmoothSeconds`（默认 8 秒）做滑动平均，然后才画。
   - **曲线是一条细折线，不是铺满的面积图**：每列一个 `#` 数据点，行与行之间用 `|` 补竖直连接，
     所以没有"大砖块"感、也没有顶端那层高亮。非 ASCII 字符一律不用——盲文点阵（`⠿`）在中文
     Windows 的 936 代码页 / 老 conhost 下会变成 `?` 或方块，实测过，所以放弃。<br>
     想要更密的线可以设 `ChartGlyphs: "block"`（`▁▂▃▄▅▆▇█`，1/8 行精度），但方块字符的宽度
     在少数中文字体下也有风险，默认不启用。
   图表分**上下两个面板**（上=上传，下=下载），各自按自己的 98 分位独立定标、各用各的刻度
   （刻度取 1/1.2/1.5/2/2.5/3/4/5/6/8/10 档）——共用一个刻度的话，下载通常只有上传的 1/4 高，
   会一直贴着地面看不出形状。面板名字写在每个面板第一行的右端。
   红色点线为断流阈值，只画在**被监控**的那个面板上（`Direction` 决定）；`updown` 模式下
   阈值是合计值、两个面板都不对应，因此不画阈值线。灰色点线为每个面板的 0 线 / 顶端网格线。
   每个面板第一行右端写着「上传 峰值 1.0M」——峰值取当前窗口内的**原始最大值**（不受平滑影响），
   窗口太窄放不下时自动退化成只写名字或不写。

## 窗口与查找逻辑

- 查找 v2rayN 窗口的条件：标题以 `v2rayN - ` 开头 **且** 进程名为 `v2rayN`。
  （曾发生资源管理器窗口标题 `v2rayN-watchdog 和 1 个其他选项卡...` 被误匹配的问题。）
- 启动时把控制台设为 120x40 字符并居中（`Set-ConsoleLayout`）；终端不支持时自动退化为自适应。
- 渲染使用「每行定位写入 + 变更行才重绘」+ ANSI 颜色，避免整屏重写造成画面抖动。

## 维护须知（重要）

1. **文件编码**：`watchdog.ps1` 必须保存为 **UTF-8 with BOM**，否则 PowerShell 5.1 会把中文按
   ANSI 解析导致乱码/语法错误。`config.json` 用 UTF-8（无 BOM 也可）。
2. **不要引入宽度不确定的字符**（如 `↑ ↓ ■ ≥ ≤ ·`）：中文字体下会被渲染成双宽，导致行宽计算
   错误、换行错位。控制台里只用 ASCII、中日韩全角（按 2 列计）和已验证窄宽的字形
   （`╔ ═ ║ ╗ ╚ ╝ ┤ │ ─ █ ▁▂▃▄▅▆▇`）。
   图表曲线只用 ASCII（`#` `|`），这是踩过坑换来的：先前试过盲文点阵（`U+2800` 起），编码和
   字体两头都不保险——936 代码页送不出去、有些中文字体还当双宽渲染，实测在这台机器上直接
   显示成方块/问号。别再往图表里塞非 ASCII 的曲线字符。
   - 特别注意 `·`（U+00B7）：不少中文字体把它做成**全角**字形，控制台按 2 列推进，而
     `Get-CellWidth` 只按 1 列算 → 整行实际宽度翻倍 → 自动换行把**下一行**糊掉。
     症状：X 轴标签只剩最右边的 `-1m / 现在`，左边变成"点+竖线"的花屏；而且因为
     "变更行才重绘"的缓存，糊掉的静态行不会自己恢复。现在网格线改用 ASCII `.`。
   - 兜底：`New-ContentLine` 会把超宽的行直接截断，`Render-Frame` 每 60 帧强制整屏重绘一次，
     万一某行被串位也会自动恢复。
3. **PowerShell 5.1 语法坑**：
   - 函数返回 `List` 必须写 `return ,$list`，否则空集合会被展开成 `$null`；
   - 数组字面量中避免 `@(0, [int][Math]::Floor($x/2), $x - 1)` 这种混合写法（解析器 bug，
     运行时报 `op_Subtraction`），拆成中间变量再组装。
4. **性能**：逐字符调用 `Get-CellWidth` 一次约 18 µs，一帧要算几千个字符，是主要开销。
   现在宽度走 `$script:cwCache`（码位→宽度）缓存，`New-ContentLine` 也不再为每个色块新建
   StringBuilder，整帧渲染从 ~180 ms 降到 ~70 ms（5.1 与 7 差不多）。改渲染代码时别又把
   热循环写回成"每字符一次函数调用"。
5. **UIA 前提**：读取方与被读取方的完整性级别必须一致（所以必须提权）；v2rayN 处于
   最小化状态时 `FindFirst` 找不到子控件（启动时机要窗口可见），但元素缓存后读值不受影响。
6. **v2rayN 升级排查**：若读不到网速或点不到按钮，先用 UIA 检查控件是否改名：

   ```powershell
   # 以管理员身份运行，打印 v2rayN 窗口内名称含 proxy 的元素
   Add-Type -AssemblyName UIAutomationClient
   Add-Type -AssemblyName UIAutomationTypes
   $root = [System.Windows.Automation.AutomationElement]::RootElement
   $win = $root.FindAll([System.Windows.Automation.TreeScope]::Children,
           [System.Windows.Automation.Condition]::TrueCondition) |
       Where-Object { $_.Current.Name -like 'v2rayN - *' } | Select-Object -First 1
   $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
       [System.Windows.Automation.Condition]::TrueCondition)
   $all | Where-Object { $_.Current.Name -match 'proxy|KB/s' } |
       ForEach-Object { $_.Current.ControlType.ProgrammaticName + ' | ' + $_.Current.Name + ' | ' + $_.Current.AutomationId }
   ```

   对应修改集中在 `Parse-ProxySpeed` 的正则和 `Find-SpeedElement` 的 AutomationId。
7. **调试参数**（直接调用脚本时）：
   - `-StopAfterSeconds N`：运行 N 秒后自动退出（测试用）；
   - `-NoElevate`：不提权运行（会因 UIA 权限不足报错，仅用于调试提权提示）；
   - `-ConfigPath xxx.json`：指定其他配置文件。
8. **日志排查**：`watchdog.log` 记录了启动参数、武装/空闲切换、每次重启（速度、持续秒数、
   累计/连续次数）、报警、恢复等关键事件；界面事件区只显示最近若干条。

## 已知限制

- 依赖 v2rayN 的界面文本与控制 id，v2rayN 大版本升级后可能需要调整查找逻辑（见上）。
- 网速数据来自 v2rayN 状态栏（1 秒刷新一次），无法取得更高分辨率。
- 启动时若 v2rayN 窗口处于最小化/托盘状态，需要先恢复窗口（事件区会提示）。
