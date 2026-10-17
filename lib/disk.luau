--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- lib/disk.luau —— 磁盘数据的读取、格式化与阈值分级
--
-- bar.luau（状态栏组件）与 panel.luau（详情面板）共用这一份逻辑：
--   * 设置读取：noctalia.getConfig 只收一个参数、没有默认值，统一在这里兜底
--   * 挂载点查找：支持挂载点路径、块设备名、以及「挂载点下面的目录」
--   * 单位格式化：1024 进制（B/K/M/G/T/P），df -h 的观感
--   * 阈值分级：ok / warn / crit → 主题角色 primary / tertiary / error
--
-- 数据来自宿主的 statvfs 快照：noctalia.diskMounts() 列出物理块设备文件系统
-- （按 source 去重、按挂载路径排序），noctalia.diskStats(path) 给出该挂载点的一次
-- statvfs 采样。
-- ══════════════════════════════════════════════════════════════════════════

local M = {}

-- ── 设置读取 ───────────────────────────────────────────────────────────────

local function raw(key)
    local ok, value = pcall(noctalia.getConfig, key)
    if not ok then
        return nil
    end
    return value
end

--- 字符串设置；空串按「未设置」处理，回落到 default
function M.text(key, default)
    local value = raw(key)
    if type(value) ~= "string" or value == "" then
        return default
    end
    return value
end

--- 布尔设置；兼容字符串/数字形式
function M.flag(key, default)
    local value = raw(key)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        if value == "true" or value == "1" then
            return true
        end
        if value == "false" or value == "0" then
            return false
        end
    end
    return default
end

--- 数字设置；兼容字符串形式的数字
function M.number(key, default)
    local value = raw(key)
    if type(value) == "number" then
        return value
    end
    local parsed = tonumber(value)
    if parsed ~= nil then
        return parsed
    end
    return default
end

function M.clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

-- ── 翻译 ───────────────────────────────────────────────────────────────────
-- 翻译键写成扁平的下划线形式（translations/<lang>.json 的顶层键）；
-- 清单里 settings.* 的 label_key / description_key 才是嵌套路径。

function M.tr(key, fallback)
    local ok, value = pcall(noctalia.tr, key)
    if ok and type(value) == "string" and value ~= "" and value ~= key then
        return value
    end
    return fallback or key
end

-- ── 单位格式化 ─────────────────────────────────────────────────────────────

local UNITS = { "B", "K", "M", "G", "T", "P", "E" }

--- 字节数 → 人类可读（1024 进制）。小于 10 时保留一位小数（9.8G / 12G）。
function M.bytes(value)
    if type(value) ~= "number" or value < 0 then
        return "--"
    end
    local scaled = value
    local index = 1
    while scaled >= 1024 and index < #UNITS do
        scaled = scaled / 1024
        index += 1
    end
    if index == 1 then
        return string.format("%d%s", scaled, UNITS[index])
    end
    if scaled < 10 then
        return string.format("%.1f%s", scaled, UNITS[index])
    end
    return string.format("%d%s", scaled, UNITS[index])
end

--- 占用率取整（statvfs 给的是浮点）
function M.percent(stats)
    if type(stats) ~= "table" or type(stats.usagePercent) ~= "number" then
        return nil
    end
    return math.floor(stats.usagePercent + 0.5)
end

--- 已用字节数（statvfs 只给总量与剩余，已用自己算）
function M.usedBytes(stats)
    if type(stats) ~= "table" or type(stats.totalBytes) ~= "number" or type(stats.freeBytes) ~= "number" then
        return nil
    end
    return stats.totalBytes - stats.freeBytes
end

-- ── 阈值分级 ───────────────────────────────────────────────────────────────

-- 主题只有 primary / secondary / tertiary / error 四个可用角色，
-- 所以「正常 / 偏高 / 告急」映射为 primary / tertiary / error。
local LEVEL_ROLE = {
    ok = "primary",
    warn = "tertiary",
    crit = "error",
}

function M.level(percent, warn, crit)
    if type(percent) ~= "number" then
        return "ok"
    end
    if percent >= crit then
        return "crit"
    end
    if percent >= warn then
        return "warn"
    end
    return "ok"
end

function M.roleOf(level)
    return LEVEL_ROLE[level] or "primary"
end

function M.levelText(level)
    return M.tr("level_" .. tostring(level), tostring(level))
end

-- ── 挂载点 ─────────────────────────────────────────────────────────────────

local function normalize(path)
    if type(path) ~= "string" then
        return nil
    end
    local trimmed = path:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end
    if #trimmed > 1 then
        trimmed = trimmed:gsub("/+$", "")
    end
    return trimmed
end

M.normalize = normalize

--- 物理块设备文件系统列表（宿主已去重、排序）
function M.mounts()
    local ok, list = pcall(noctalia.diskMounts)
    if not ok or type(list) ~= "table" then
        return {}
    end
    return list
end

--- 单个挂载点的 statvfs 快照
function M.stats(path)
    local ok, stats = pcall(noctalia.diskStats, path)
    if not ok or type(stats) ~= "table" then
        return nil
    end
    return stats
end

--- 全部挂载点 + 各自的占用数据；取不到数据的挂载点跳过
function M.rows()
    local out = {}
    for _, mount in ipairs(M.mounts()) do
        local stats = M.stats(mount.path)
        if stats then
            table.insert(out, { mount = mount, stats = stats })
        end
    end
    return out
end

--- 按选择器挑一行：
---   ""/"auto"  → 占用率最高的那个
---   "/home"    → 挂载点路径
---   "/dev/nvme0n1p2" → 块设备名
---   "/home/ylxc/Videos" → 所在目录，取路径最长的祖先挂载点
function M.pick(selector, rows)
    rows = rows or M.rows()
    local want = normalize(selector)
    if want == nil or want == "auto" then
        local best, bestPercent = nil, -1
        for _, row in ipairs(rows) do
            local percent = M.percent(row.stats) or 0
            if percent > bestPercent then
                best, bestPercent = row, percent
            end
        end
        return best, rows
    end

    for _, row in ipairs(rows) do
        if normalize(row.mount.path) == want or row.mount.source == selector then
            return row, rows
        end
    end

    local best, bestLength = nil, -1
    for _, row in ipairs(rows) do
        local path = normalize(row.mount.path)
        if path ~= nil then
            local hit = (path == "/" and want:sub(1, 1) == "/")
                or want == path
                or want:sub(1, #path + 1) == path .. "/"
            if hit and #path > bestLength then
                best, bestLength = row, #path
            end
        end
    end
    return best, rows
end

--- 一句话摘要：62% · 248G / 512G
function M.summary(stats, percent)
    local used = M.usedBytes(stats)
    if used == nil or type(stats.totalBytes) ~= "number" then
        return "--"
    end
    return string.format("%d%% · %s / %s", percent or M.percent(stats) or 0, M.bytes(used), M.bytes(stats.totalBytes))
end

--- 剩余（可用）字节数：优先用 availableBytes，没有就退回 freeBytes
function M.available(stats)
    if type(stats) ~= "table" then
        return nil
    end
    if type(stats.availableBytes) == "number" then
        return stats.availableBytes
    end
    return stats.freeBytes
end

return M
