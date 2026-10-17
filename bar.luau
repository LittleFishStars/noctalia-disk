--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- bar.luau —— 状态栏上的磁盘占用
--
-- 默认显示挂载点的占用百分比，可切换成「已用 / 总量」「剩余空间」「剩余百分比」，
-- 或者一段迷你进度条 + 百分比。图标和文字按阈值变色（正常 → 主题主色，
-- 偏高 → tertiary，告急 → error）。
--
-- 交互（可在设置里的挂载组件手势中改绑）：
--   左键：打开详情面板（plugin.toml 的 [widget.actions] 默认绑定）
--   右键：立刻重读一次 statvfs 并重画
--   滚轮：在所有磁盘之间切换显示（不动设置，插件重载后回到设置里的挂载点）
--
-- 数据源是宿主的 statvfs 快照（noctalia.diskMounts / noctalia.diskStats），只读、不落盘、
-- 不起后台进程。
-- ══════════════════════════════════════════════════════════════════════════

local disk = require("./lib/disk.luau")
local subvol = require("./lib/subvol.luau")

-- 滚轮选中的行号；nil = 跟随设置里的挂载点
local scrollIndex = nil

-- ── 设置 ───────────────────────────────────────────────────────────────────
-- 每轮 tick 重读一次，改设置后不用重载插件；plugin.toml 里的 default 只兜首次。

local function settings()
    return {
        -- 组件级（[[widget.setting]]）
        mount = disk.text("mount", ""),
        display = disk.text("display", "percent"),
        glyph = disk.text("glyph", "server"),
        showGlyph = disk.flag("show_glyph", true),
        glyphColor = disk.text("glyph_color", "level"),
        -- 插件级（[[setting]]，与面板共用）
        warn = disk.number("warn_percent", 80),
        crit = disk.number("crit_percent", 90),
        showAll = disk.flag("tooltip_mounts", true),
        maxRows = disk.number("tooltip_max", 6),
        refresh = disk.number("refresh_seconds", 30),
        -- 子卷统计（供 IPC 的 scan 事件用；面板自己也会读这几个键）
        mode = disk.text("subvol_size_mode", "allocated"),
        extra = disk.text("subvol_paths", ""),
        cache = disk.number("subvol_cache_minutes", 720),
    }
end

local function glyphRole(cfg, level)
    if cfg.glyphColor == "level" then
        return disk.roleOf(level)
    end
    -- 默认模式下传 "on_surface" 表示「跟随组件自己配置的颜色」
    if cfg.glyphColor == "theme" then
        return "on_surface"
    end
    return cfg.glyphColor
end

-- ── 文案 ───────────────────────────────────────────────────────────────────

local function barText(cfg, row)
    local percent = disk.percent(row.stats) or 0
    if cfg.display == "used" then
        return string.format("%s/%s", disk.bytes(disk.usedBytes(row.stats)), disk.bytes(row.stats.totalBytes))
    end
    if cfg.display == "free" then
        return string.format("%s %s", disk.bytes(disk.available(row.stats)), disk.tr("bar_free", "free"))
    end
    if cfg.display == "free_percent" then
        return string.format("%d%% %s", 100 - percent, disk.tr("bar_free", "free"))
    end
    return string.format("%d%%", percent)
end

local function buildTooltip(cfg, row, rows, level)
    local out = {}

    if row then
        table.insert(out, { key = disk.tr("tt_usage", "Usage"), value = disk.summary(row.stats) })
        table.insert(out, { key = disk.tr("tt_mount", "Mount"), value = row.mount.path })
        if type(row.mount.source) == "string" and row.mount.source ~= "" then
            table.insert(out, { key = disk.tr("tt_device", "Device"), value = row.mount.source })
        end
        if type(row.mount.filesystem) == "string" and row.mount.filesystem ~= "" then
            table.insert(out, { key = disk.tr("tt_filesystem", "Filesystem"), value = row.mount.filesystem })
        end
        table.insert(out, { key = disk.tr("tt_free", "Free"), value = disk.bytes(disk.available(row.stats)) })
        table.insert(out, { key = disk.tr("tt_level", "Status"), value = disk.levelText(level) })
    elseif #rows == 0 then
        table.insert(out, { key = disk.tr("tt_level", "Status"), value = disk.tr("tt_none", "No physical filesystem found") })
    else
        local template = disk.tr("tt_not_found", "No filesystem mounted at %s")
        table.insert(out, { key = disk.tr("tt_mount", "Mount"), value = string.format(template, cfg.mount) })
    end

    if cfg.showAll and #rows > 1 then
        local shown = 0
        for _, other in ipairs(rows) do
            if other ~= row then
                if shown >= cfg.maxRows then
                    table.insert(out, { key = "+", value = string.format(disk.tr("tt_more", "+%d more"), #rows - 1 - shown) })
                    break
                end
                shown += 1
                table.insert(out, { key = other.mount.path, value = disk.summary(other.stats) })
            end
        end
    end

    table.insert(out, { key = disk.tr("tt_hint_key", "Hint"), value = disk.tr("tt_hint", "Left click: details · scroll: switch disk") })
    return out
end

-- ── 渲染 ───────────────────────────────────────────────────────────────────

local function render()
    local cfg = settings()
    if cfg.crit <= cfg.warn then
        cfg.crit = cfg.warn + 1
    end

    local rows = disk.rows()
    if #rows == 0 then
        barWidget.setGlyph(cfg.glyph)
        barWidget.setGlyphColor(glyphRole(cfg, "ok"))
        barWidget.setText("--")
        barWidget.setTooltip(buildTooltip(cfg, nil, rows, "ok"))
        return
    end

    local row = nil
    if scrollIndex ~= nil and rows[scrollIndex] ~= nil then
        row = rows[scrollIndex]
    else
        scrollIndex = nil
        row = disk.pick(cfg.mount, rows)
    end
    if row == nil then
        barWidget.setGlyph(cfg.glyph)
        barWidget.setGlyphColor("error")
        barWidget.setText("--")
        barWidget.setTooltip(buildTooltip(cfg, nil, rows, "crit"))
        return
    end

    local percent = disk.percent(row.stats) or 0
    local level = disk.level(percent, cfg.warn, cfg.crit)
    local role = disk.roleOf(level)

    if cfg.display == "bar" then
        -- 迷你进度条：ui.* 树会替换掉内置的图标/文字行
        local container = barWidget.isVertical() and ui.column or ui.row
        local children = {}
        if cfg.showGlyph then
            table.insert(children, ui.glyph({ name = cfg.glyph, size = 14, color = glyphRole(cfg, level) }))
        end
        table.insert(children, ui.progress({
            width = 46,
            height = 5,
            radius = 3,
            progress = percent / 100,
            fill = role,
            track = "surface_variant",
        }))
        table.insert(children, ui.label({ text = string.format("%d%%", percent) }))
        barWidget.render(container({ gap = 6, align = "center", justify = "center" }, children))
    else
        if cfg.showGlyph then
            barWidget.setGlyph(cfg.glyph)
            barWidget.setGlyphColor(glyphRole(cfg, level))
        else
            barWidget.setGlyph("")
        end
        barWidget.setText(barText(cfg, row))
        -- 默认模式回落到组件自己配置的文字颜色；告急/偏高时才接管
        if level == "ok" then
            barWidget.setColor("on_surface")
        else
            barWidget.setColor(role)
        end
    end

    barWidget.setTooltip(buildTooltip(cfg, row, rows, level))
end

-- ── 指针回调 ───────────────────────────────────────────────────────────────

--- 左键：清单里默认绑成了 panel-toggle；用户改成 none 时这里兜底
function onClick()
    noctalia.togglePanel("ylxc/disk:panel")
end

--- 右键：立刻重读一次
function onRightClick()
    render()
    noctalia.log("[disk] 已重新采样磁盘占用")
end

--- 滚轮：在磁盘之间切换
function onScroll(axis, steps, startsGesture)
    if axis ~= "vertical" or not startsGesture then
        return
    end
    local cfg = settings()
    local rows = disk.rows()
    if #rows < 2 then
        return
    end

    local index = scrollIndex
    if index == nil then
        local current = disk.pick(cfg.mount, rows)
        for i, row in ipairs(rows) do
            if row == current then
                index = i
            end
        end
        index = index or 1
    end

    scrollIndex = disk.clamp(index + (steps > 0 and 1 or -1), 1, #rows)
    render()
end

function onIpc(event, _payload)
    if event == "refresh" then
        render()
    elseif event == "next" or event == "prev" then
        local rows = disk.rows()
        if #rows > 0 then
            local index = scrollIndex or 1
            scrollIndex = disk.clamp(index + (event == "next" and 1 or -1), 1, #rows)
            render()
        end
    elseif event == "panel" then
        noctalia.togglePanel("ylxc/disk:panel")
    elseif event == "scan" then
        -- 不打开面板也能重跑子卷统计（统计过期或新加了 subvol_paths 时有用）
        local cfg = settings()
        local fsRows = disk.rows()
        local state = subvol.collect()
        local rows = subvol.rows({ extra = cfg.extra, cacheMinutes = cfg.cache }, fsRows, state)
        if not subvol.running() then
            subvol.start(subvol.pending(rows), cfg.mode)
        end
    end
end

-- ── 生命周期 ───────────────────────────────────────────────────────────────

function update()
    local seconds = disk.clamp(settings().refresh, 2, 600)
    noctalia.setUpdateInterval(seconds * 1000)
    render()
end

update()
