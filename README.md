# ylxc/disk —— 磁盘占用（状态栏组件 + 详情面板）

在状态栏上显示磁盘占用：默认是挂载点的占用百分比，鼠标悬停能看到每块磁盘的明细，左键点开详情面板 —— 上半部分是**每个文件系统一张卡片**，下半部分是**各 btrfs 子卷 / 挂载点的占用**（`statvfs` 看不到的那一层）。

- 文件系统占用：直接用宿主自己的 `statvfs` 快照（`noctalia.diskMounts` / `noctalia.diskStats`），零磁盘 I/O。
- 子卷占用：从 `/proc/self/mountinfo` 枚举已挂载的 btrfs 子卷，按需（或打开面板时）跑一次 `du -x` 遍历，结果缓存到插件数据目录 —— 没有常驻进程，重载插件也不会打断统计。

```
bar.luau    ─┐
             ├─▶ lib/disk.luau    ──▶ noctalia.diskMounts() / noctalia.diskStats(path)
panel.luau  ─┘   lib/subvol.luau  ──▶ /proc/self/mountinfo + du（一次性后台任务）
```

## 效果

![栏内显示](docs/bar.png)

![详情面板](docs/panel.png)

## 安装与启用

插件目录：`~/.local/share/noctalia/plugins/ylxc-disk/`

1. **设置 → 插件** → 找到 **Disk Usage**（作者 ylxc）并启用。
2. 把它加进栏里：**设置 → 栏** → 添加组件 → 选 `ylxc` / `disk` / `usage`。
   也可以手写配置（`~/.local/state/noctalia/settings.toml`）：

   ```toml
   [bar.default]
   center = ["ram", "disk", "clock"]   # 位置随你，名字自取

   [widget.disk]
   type = "ylxc/disk:usage"
   ```

   改完执行 `noctalia msg config-reload` 生效。

离线自检（不启动 shell）：

```bash
noctalia plugins lint ~/.local/share/noctalia/plugins/ylxc-disk
```

## 配置

### 插件级（设置 → 插件 → Disk Usage 的齿轮；栏组件与面板共用）

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `warn_percent` | int（50–99） | `80` | 占用率超过它算「偏高」 |
| `crit_percent` | int（51–100） | `90` | 占用率超过它算「告急」 |
| `refresh_seconds` | int（2–600） | `30` | 刷新间隔；栏组件与面板共用一个节奏 |
| `tooltip_mounts` | bool | `true` | 悬停时是否列出所有磁盘 |
| `tooltip_max` | int（1–16） | `6` | 悬停时最多列几个（仅在上一条打开时显示） |
| `show_subvolumes` | bool | `true` | 面板下半部分是否列出各子卷占用 |
| `subvol_size_mode` | select | `allocated` | 子卷统计口径，见下表 |
| `subvol_auto_scan` | bool | `true` | 打开面板时，若有未统计或已过期的条目就自动开始遍历 |
| `subvol_cache_minutes` | int（10–10080） | `720` | 子卷结果缓存多久（默认 12 小时），过期会显示为需要重新统计 |
| `subvol_paths` | string | 空 | 除已挂载的子卷外，额外统计的目录，英文逗号分隔（例如 `/home/ylxc/.cache`），支持 `~` |

`subvol_size_mode` 的取值：

| 值 | 含义 | 背后的命令 |
| --- | --- | --- |
| `allocated` | 压缩后的实际占用（推荐，和文件管理器、`df` 的观感一致） | `du -sx --block-size=1` |
| `apparent` | 文件原始大小之和（btrfs 压缩率高的地方会明显大于实际占用） | `du -sx --apparent-size --block-size=1` |
| `btrfs` | 不含与快照共享的空间（exclusive） | `btrfs filesystem du -s --raw`（需 btrfs-progs；部分目录要 root） |

### 组件级（栏组件自己的设置）

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `mount` | string | 空 | 显示哪一块磁盘：留空 = 占用率最高的那个；也可以填挂载点（`/`）、块设备（`/dev/nvme0n1p2`）或任意目录（自动匹配它所在的文件系统） |
| `display` | select | `percent` | 栏上显示什么，见下表 |
| `glyph` | glyph | `server` | 图标（Tabler 图标名） |
| `show_glyph` | bool | `true` | 是否显示图标 |
| `glyph_color` | select | `level` | 图标颜色：`level` 跟随阈值变色、`theme` 用组件自己的配色、其余为固定颜色 |

`display` 的取值：

| 值 | 栏上长这样 | 说明 |
| --- | --- | --- |
| `percent` | `63%` | 默认 |
| `used` | `585G/933G` | 已用 / 总量 |
| `free` | `321G 可用` | 剩余可用空间 |
| `free_percent` | `34% 可用` | 剩余百分比 |
| `bar` | ▓▓▓▓░░ `63%` | 迷你进度条 + 百分比；竖向栏会自动排成上下 |

文字颜色同样跟随阈值：正常用主题主色（`on_surface`，也就是组件自己的配色），偏高转 `tertiary`，告急转 `error`，所以浅色/深色主题都好看。

## 交互

| 动作 | 默认行为 |
| --- | --- |
| 左键 | 打开详情面板 `ylxc/disk:panel` |
| 右键 | 立刻重读一次 `statvfs` 并重画（不用等刷新周期） |
| 中键 | 打开这个组件的设置（宿主默认绑定） |
| 滚轮 | 在所有磁盘之间循环切换显示（只影响当前显示，不改设置，插件重载后回到设置里的那块） |

这几个绑定都写在 `plugin.toml` 的 `[widget.actions]` 里，可以在**设置 → 栏 → 组件手势**中改绑或改成 `none`。

不打开面板也能重跑子卷统计：`noctalia msg plugin ylxc/disk:usage focused scan`（只统计未统计或已过期的项），可以把它绑到快捷键或脚本上。
详情面板：

- 上半部分每个物理块设备文件系统一张卡片，含占用百分比、阈值状态、进度条、`已用 / 共` 与 `设备 · 文件系统`；右上角的刷新按钮立即取数。
- 下半部分是各子卷 / 挂载点：**点某一行**只重新统计这一个，标题右侧的「统计」按钮重新统计所有未统计或已过期的项。统计进行中标题旁显示 `统计中 N 秒…`，面板打开期间每秒一个 tick、按刷新间隔重画（统计进行中每秒重画），进度看得见。

## 工作原理与细节

- **数据源**：`noctalia.diskMounts()` 列出物理块设备文件系统（按设备去重、按挂载路径排序），`noctalia.diskStats(path)` 返回该挂载点的一次采样 —— `usagePercent` / `totalBytes` / `freeBytes` / `availableBytes`。两者都接受绝对路径或 `~/` 路径，返回 `nil` 表示路径不可用。
- **占用率**：用 `usagePercent`（与 `df` 的 `Use%` 一致，即 `(total - free) / total`）。`freeBytes` 与 `availableBytes` 不同，后者已扣掉 root 预留 —— 「剩余可用」显示的是 `availableBytes`。
- **开销**：栏组件每次刷新只调用一次 `diskMounts` 与一次 `diskStats`；子卷统计只有在需要时才跑，跑完就把结果缓存起来。
- **面板重画**：面板只在打开期间干活 —— `onOpen` 里开 `panel.setWantsSecondTicks(true)` 与 `noctalia.setUpdateInterval(1000)`，`update()` 再按到期时间节流（统计中 1 秒一画，否则按刷新间隔），`onClose` 关掉 tick，关着的时候不渲染。
- **配色**：阈值分级 `ok` / `warn` / `crit` → 主题角色 `primary` / `tertiary` / `error`。
- **IPC**：`noctalia msg plugin ylxc/disk:usage focused refresh`、`next` / `prev`（切换磁盘）、`panel`（开合面板）、`scan`（不等面板就能重跑子卷统计；可以把它绑到快捷键或脚本上）。

### 子卷是怎么数出来的

- **为什么不能用 `statvfs`**：同一个 btrfs 文件系统上的所有子卷共享同一组 `total` / `free`，`diskStats("/home")` 和 `diskStats("/")` 给出的总量、剩余完全一样 —— 「`/home` 自己占了多少」只能靠遍历。
- **枚举**：读 `/proc/self/mountinfo`，取 `fstype == btrfs` 的行，解析出挂载点、`subvol=`、`subvolid=`、设备。这就是「已挂载的子卷」的精确定义，且不需要 root。
- **统计**：把要数的路径生成一个 `/bin/sh` 脚本（`<数据目录>/subvol/scan.sh`），用 `setsid` 脱离插件进程在后台执行；每项跑完就把 `bytes` / `rc` / `secs` / `mode` 原子写入 `<hash>.done`，全部结束后删掉任务标记 `job.json`。面板每个刷新周期收一次结果、合并进 `state.json` 并清掉已消费的文件。
- **数据目录**：`~/.local/state/noctalia/plugins/data/ylxc/disk/subvol/`（`state.json` 是缓存、`job.json` 标记统计进行中、`scan.sh` 是当前这份统计脚本、`<hash>.err` 是该项的 `du` 报错）。删掉整个目录即可清空缓存。
- **口径**：`allocated` 读的是 `st_blocks` —— 稀疏文件、透明压缩、CoW 都按真实占用算，和文件管理器右键属性里的数字一致；`apparent` 才是 `st_size` 之和。

## 文件结构

```
ylxc-disk/
├── plugin.toml          清单：设置 schema、栏组件、详情面板
├── bar.luau             栏组件（命令式渲染；bar 模式用 ui.* 声明式树）
├── panel.luau           详情面板（文件系统卡片 + 子卷区）
├── lib/disk.luau        共用的取值、格式化、阈值分级
├── lib/subvol.luau      子卷：枚举 mountinfo、后台统计、结果缓存
├── translations/
│   ├── en.json
│   └── zh-Hans.json
└── docs/                截图
```

## 限制

- 文件系统部分只列**物理块设备**上的文件系统（宿主 `diskMounts` 的口径），`tmpfs`、`overlay`、网络挂载等不会出现。
- 子卷部分不需要 root，因此边界是清楚的：
  - 只统计**已挂载**的子卷，未挂载的看不到（`btrfs subvolume list` 需要 root）。
  - `allocated` 口径下，与快照共享的空间会被**重复计入**；`btrfs` 口径用 exclusive 规避，但部分目录要 root，拿不到就显示 0。
  - 读不动的目录（`/root`、`/var/lib/private` 等）会被 `du` 跳过，此时结果只是下界 —— 条目上会标 `≥` 和「下界」，悬停能看到具体是哪些目录没读到。
  - 首次统计要遍历整个子卷，几百 GB 的分区可能要几十秒到几分钟；期间只是后台 IO，面板照常可用，也可以随时关掉面板（统计会继续跑完并落盘）。
- 面板尺寸 `420×560`；实际摆放位置（贴栏还是屏幕居中）由宿主的插件偏好 `panel_placement` 决定。
- 改了 `plugin.toml` 里某个设置的 **`default`** 之后，需要 `noctalia msg plugins disable ylxc/disk` 再 `enable`（宿主在加载插件时播种默认值，`config-reload` 不会重新播种）；只改 `.luau` 代码不用重载 —— 宿主会热重载。

## 许可

MIT
