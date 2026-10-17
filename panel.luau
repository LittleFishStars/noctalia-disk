--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- panel.luau —— 磁盘详情面板
--
-- 每个物理块设备文件系统一张卡片：挂载点、占用进度条、已用/总量、剩余空间、
-- 设备与文件系统类型。阈值配色与栏上一致（primary / tertiary / error）。
--
-- 打开方式：栏组件左键，或
--   noctalia msg panel-toggle ylxc/disk:panel
-- ══════════════════════════════════════════════════════════════════════════

local disk = require("./lib/disk.luau")

local function settings()
    return {
        warn = disk.number("warn_percent", 80),
        crit = disk.number("crit_percent", 90),
        refresh = disk.number("refresh_seconds", 30),
    }
end

-- ── 卡片 ───────────────────────────────────────────────────────────────────

local function card(entry, cfg)
    local mount = entry.mount
    local stats = entry.stats
    local percent = disk.percent(stats) or 0
    local level = disk.level(percent, cfg.warn, cfg.crit)
    local role = disk.roleOf(level)

    local lines = {
        -- 标题行：图标 + 挂载点 + 右侧占用率
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = percent >= cfg.crit and "alert-triangle" or "server", size = 14, color = role }),
            ui.label({ text = mount.path, fontWeight = "semibold", maxLines = 1 }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = string.format("%d%%", percent), color = role, fontWeight = "bold" }),
            ui.label({ text = disk.levelText(level), color = role, fontSize = 11 }),
        }),
        -- 占用条
        ui.progress({
            progress = percent / 100,
            height = 6,
            radius = 3,
            fill = role,
            track = "surface_variant",
        }),
        -- 已用 / 总量 + 剩余
        ui.row({ gap = 8, align = "center" }, {
            ui.label({
                text = string.format(
                    disk.tr("panel_used_of", "used %s of %s"),
                    disk.bytes(disk.usedBytes(stats)),
                    disk.bytes(stats.totalBytes)
                ),
                color = "on_surface_variant",
                fontSize = 11,
            }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({
                text = string.format("%s %s", disk.bytes(disk.available(stats)), disk.tr("bar_free", "free")),
                color = "on_surface_variant",
                fontSize = 11,
            }),
        }),
    }

    local device = type(mount.source) == "string" and mount.source or ""
    local filesystem = type(mount.filesystem) == "string" and mount.filesystem or ""
    local detail = device
    if filesystem ~= "" then
        detail = detail ~= "" and (device .. " · " .. filesystem) or filesystem
    end
    if detail ~= "" then
        table.insert(lines, ui.label({
            text = detail,
            color = "on_surface_variant",
            fontSize = 10,
            maxLines = 1,
        }))
    end

    return ui.column({ gap = 6, padding = 10, radius = 10, fill = "surface_variant/0.45" }, lines)
end

-- ── 渲染 ───────────────────────────────────────────────────────────────────

local function render()
    local cfg = settings()
    if cfg.crit <= cfg.warn then
        cfg.crit = cfg.warn + 1
    end

    local rows = disk.rows()
    local cards = {}
    if #rows == 0 then
        table.insert(cards, ui.label({
            text = disk.tr("panel_empty", "No physical block-device filesystems found."),
            color = "on_surface_variant",
        }))
    else
        for _, entry in ipairs(rows) do
            table.insert(cards, card(entry, cfg))
        end
    end

    panel.render(ui.column({ padding = 14, gap = 10 }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = disk.tr("title", "Disk Usage"), fontWeight = "bold", fontSize = 15 }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({
                text = string.format(disk.tr("panel_updated", "Updated %s"), os.date("%H:%M:%S")),
                color = "on_surface_variant",
                fontSize = 11,
            }),
            ui.button({
                glyph = "refresh",
                glyphSize = 14,
                variant = "ghost",
                controlSize = "sm",
                tooltip = disk.tr("panel_refresh", "Refresh"),
                onClick = function()
                    render()
                end,
            }),
        }),
        ui.scroll({ flexGrow = 1 }, cards),
    }))
end

-- ── 生命周期 ───────────────────────────────────────────────────────────────

function onOpen(_context)
    update()
end

function update()
    local seconds = disk.clamp(settings().refresh, 2, 600)
    noctalia.setUpdateInterval(seconds * 1000)
    render()
end

render()
