--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- panel.luau —— 磁盘详情面板
--
-- 上半部分：每个物理块设备文件系统一张卡片（挂载点、占用条、已用/总量、剩余、
--   设备与文件系统类型），阈值配色与栏上一致（primary / tertiary / error）。
-- 下半部分：btrfs 子卷 / 挂载点占用（statvfs 看不到的那一层，由 lib/subvol.luau
--   后台遍历统计，按需触发、结果缓存）。
--
-- 打开方式：栏组件左键，或
--   noctalia msg panel-toggle ylxc/disk:panel
-- ══════════════════════════════════════════════════════════════════════════

local disk = require("./lib/disk.luau")
local subvol = require("./lib/subvol.luau")

local function settings()
    return {
        warn = disk.number("warn_percent", 80),
        crit = disk.number("crit_percent", 90),
        refresh = disk.number("refresh_seconds", 30),
        -- 子卷区
        showSubvol = disk.flag("show_subvolumes", true),
        mode = disk.text("subvol_size_mode", "allocated"),
        auto = disk.flag("subvol_auto_scan", false),
        cache = disk.number("subvol_cache_minutes", 720),
        paths = disk.text("subvol_paths", ""),
    }
end

-- ── 工具 ───────────────────────────────────────────────────────────────────

local function agoText(seconds)
    if seconds < 60 then
        return disk.tr("subvol_ago_now", "just now")
    elseif seconds < 3600 then
        return string.format(disk.tr("subvol_ago_min", "%d min ago"), math.floor(seconds / 60))
    elseif seconds < 48 * 3600 then
        return string.format(disk.tr("subvol_ago_hour", "%d h ago"), math.floor(seconds / 3600))
    end
    return string.format(disk.tr("subvol_ago_day", "%d d ago"), math.floor(seconds / 86400))
end

-- ── 文件系统卡片 ───────────────────────────────────────────────────────────

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

-- ── 子卷区 ─────────────────────────────────────────────────────────────────

local render -- 前向声明

local function scan(paths, cfg)
    if subvol.running() or #paths == 0 then
        return
    end
    if subvol.start(paths, cfg.mode) then
        render()
    end
end

local function subvolCard(r, cfg)
    local entry = r.entry
    local fsStats = r.fs and r.fs.stats or nil
    local percent = nil
    if entry and fsStats and fsStats.totalBytes and fsStats.totalBytes > 0 then
        percent = math.min(100, math.floor(entry.bytes / fsStats.totalBytes * 100 + 0.5))
    end
    local role = "on_surface_variant"
    if percent then
        role = disk.roleOf(disk.level(percent, cfg.warn, cfg.crit))
    end

    local sizeText
    if entry then
        -- rc ~= 0 说明有读不到的目录，du 会跳过 → 结果只是下界
        sizeText = (entry.rc ~= 0 and "≥ " or "") .. disk.bytes(entry.bytes)
    elseif r.running then
        sizeText = disk.tr("subvol_scanning", "scanning…")
    else
        sizeText = disk.tr("subvol_not_scanned", "not scanned")
    end

    local lines = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({
                name = r.kind == "btrfs" and "stack-2" or "folder",
                size = 13,
                color = "on_surface_variant",
            }),
            ui.label({ text = r.path, fontWeight = "semibold", maxLines = 1 }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = sizeText, fontWeight = "bold", color = entry and role or "on_surface_variant" }),
        }),
    }

    if entry and percent then
        table.insert(lines, ui.progress({
            progress = percent / 100,
            height = 5,
            radius = 3,
            fill = role,
            track = "surface_variant",
        }))
    end

    -- 元信息行：子卷名 / 设备 · 统计时间
    local left
    if r.kind == "btrfs" then
        left = string.format("subvol=%s", r.subvol or "?")
        if r.id then
            left = left .. string.format(" · id %d", r.id)
        end
    else
        left = disk.tr("subvol_extra", "extra path")
    end
    local right
    if entry and entry.at then
        right = agoText(os.time() - entry.at)
        if entry.rc ~= 0 then
            right = right .. " · " .. disk.tr("subvol_lower", "lower bound")
        end
    elseif r.running then
        right = disk.tr("subvol_scanning", "scanning…")
    end
    table.insert(lines, ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = left, color = "on_surface_variant", fontSize = 10, maxLines = 1 }),
        ui.spacer({ flexGrow = 1 }),
        right and ui.label({ text = right, color = "on_surface_variant", fontSize = 10 })
            or ui.label({ text = "", fontSize = 10 }),
    }))

    local tooltip = disk.tr("subvol_card_tip", "Click to recount this one")
    if entry and entry.err and entry.err ~= "" then
        tooltip = tooltip .. "\n" .. entry.err
    end

    return ui.column({
        gap = 5,
        padding = 9,
        radius = 9,
        fill = "surface_variant/0.35",
        tooltip = tooltip,
        onClick = function()
            scan({ { path = r.path } }, cfg)
        end,
    }, lines)
end

local function subvolSection(cfg, rows)
    local job = subvol.job()
    local scanning = job ~= nil
    local elapsed = scanning and (os.time() - job.started) or 0

    local head = {
        ui.glyph({ name = "stack-2", size = 14, color = "on_surface_variant" }),
        ui.label({ text = disk.tr("subvol_title", "Subvolumes"), fontWeight = "semibold" }),
        ui.label({ text = tostring(#rows), color = "on_surface_variant", fontSize = 11 }),
        ui.spacer({ flexGrow = 1 }),
    }
    if scanning then
        table.insert(head, ui.label({
            text = string.format(disk.tr("subvol_scanning_for", "scanning %ds…"), elapsed),
            color = "tertiary",
            fontSize = 11,
        }))
    else
        table.insert(head, ui.button({
            text = disk.tr("subvol_scan_all", "Scan"),
            glyph = "refresh",
            glyphSize = 13,
            variant = "ghost",
            controlSize = "sm",
            tooltip = disk.tr("subvol_scan_all_tip", "Count every subvolume again"),
            onClick = function()
                scan(subvol.pending(rows), cfg)
            end,
        }))
    end

    local lines = { ui.row({ gap = 8, align = "center" }, head) }

    if #rows == 0 then
        table.insert(lines, ui.label({
            text = disk.tr("subvol_empty", "No mounted subvolume found."),
            color = "on_surface_variant",
            fontSize = 11,
        }))
    else
        for _, r in ipairs(rows) do
            table.insert(lines, subvolCard(r, cfg))
        end
    end

    -- 合计（各子卷相加减去重复的额外路径；同一文件系统只算一次总量）
    local sum, seenFs, fsTotal = 0, {}, 0
    for _, r in ipairs(rows) do
        if r.entry then
            sum = sum + (r.entry.bytes or 0)
        end
        if r.fs and r.fs.mount and not seenFs[r.fs.mount.path] then
            seenFs[r.fs.mount.path] = true
            fsTotal = fsTotal + (r.fs.stats.totalBytes or 0)
        end
    end
    if sum > 0 then
        table.insert(lines, ui.row({ gap = 8, align = "center" }, {
            ui.label({
                text = fsTotal > 0
                        and string.format(disk.tr("subvol_total", "counted %s of %s"), disk.bytes(sum), disk.bytes(fsTotal))
                    or string.format(disk.tr("subvol_total_only", "counted %s"), disk.bytes(sum)),
                color = "on_surface_variant",
                fontSize = 10,
            }),
        }))
    end

    table.insert(lines, ui.label({
        text = disk.tr("subvol_note", "Counted by traversal (no root): unmounted subvolumes are invisible and snapshots share space."),
        color = "on_surface_variant",
        fontSize = 10,
        opacity = 0.7,
    }))

    return ui.column({ gap = 7 }, lines)
end

-- ── 渲染 ───────────────────────────────────────────────────────────────────

local function body(cfg)
    local diskRows = disk.rows()
    local nodes = {}

    if #diskRows == 0 then
        table.insert(nodes, ui.label({
            text = disk.tr("panel_empty", "No physical block-device filesystems found."),
            color = "on_surface_variant",
        }))
    else
        for _, entry in ipairs(diskRows) do
            table.insert(nodes, card(entry, cfg))
        end
    end

    if cfg.showSubvol then
        local state = subvol.collect()
        local srows = subvol.rows({ extra = cfg.paths, cacheMinutes = cfg.cache }, diskRows, state)
        if cfg.auto and not subvol.running() then
            local pending = subvol.pending(srows)
            if #pending > 0 and subvol.start(pending, cfg.mode) then
                -- 重新算一遍，让刚启动的项立刻显示「统计中」
                srows = subvol.rows({ extra = cfg.paths, cacheMinutes = cfg.cache }, diskRows, state)
            end
        end
        table.insert(nodes, subvolSection(cfg, srows))
    end

    return nodes
end

render = function()
    local cfg = settings()
    if cfg.crit <= cfg.warn then
        cfg.crit = cfg.warn + 1
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
        ui.scroll({ flexGrow = 1 }, body(cfg)),
    }))
end

-- ── 生命周期 ───────────────────────────────────────────────────────────────

function onOpen(_context)
    update()
end

function update()
    local cfg = settings()
    -- 统计进行中时刷快一点，进度看得见
    local seconds = cfg.refresh
    if cfg.showSubvol and subvol.running() then
        seconds = math.min(seconds, 2)
    end
    noctalia.setUpdateInterval(disk.clamp(seconds, 2, 600) * 1000)
    render()
end

render()
