--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- lib/subvol.luau —— 子卷（挂载点）的占用统计
--
-- 为什么要单独统计：statvfs 对同一个文件系统上的每个子卷返回的是**整个文件系统**
-- 的数字（total / free 都一样），所以「/home 自己占了多少」拿不到，只能遍历统计。
--
-- 不需要 root 就能做到：
--   * 从 /proc/self/mountinfo 枚举**已挂载**的 btrfs 子卷（挂载点、subvol=、
--     subvolid、设备）——这就是「各子卷」的准确定义
--   * 后台遍历统计占用：du -x 走 st_blocks（压缩后的实际占用）或 st_size（文件合计）
--   * 结果按路径原子落盘缓存，面板轮询；进程用 setsid 脱离插件进程组，
--     重载插件不会打断正在跑的统计
--
-- 没有 root 拿不到的部分（UI 上会标注）：
--   * 未挂载的子卷（btrfs subvolume list 需要 root）
--   * qgroup 的 exclusive（需要 root + quota）→ 快照共享的空间会被重复计入
--   * 读不了的目录（/root 等）会被 du 跳过 → 结果是下界
-- ══════════════════════════════════════════════════════════════════════════

local M = {}

local json = noctalia.json

local STALL_SECONDS = 3 * 3600 -- 任务标记超过这么久还没收完，视为中断

local function log(msg)
    noctalia.log("[disk/subvol] " .. msg)
end

-- shell 单引号转义
local function shQuote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- mountinfo 里的转义：空格 / 制表 / 换行 / 反斜杠
local function unescape(s)
    s = string.gsub(s, "\\040", " ")
    s = string.gsub(s, "\\011", "\t")
    s = string.gsub(s, "\\012", "\n")
    s = string.gsub(s, "\\134", "\\")
    return s
end

-- 仅用于生成稳定的文件名（不做位运算，避免依赖 bit32）
function M.slug(path)
    local h = 5381
    for i = 1, #path do
        h = (h * 33 + string.byte(path, i)) % 2147483647
    end
    return string.format("%08x", h)
end

-- ── 枚举 ───────────────────────────────────────────────────────────────────

-- 已挂载的 btrfs 子卷；不需要 root
function M.mounts()
    local content = noctalia.readFile("/proc/self/mountinfo")
    if type(content) ~= "string" then
        return {}
    end
    local out = {}
    for line in string.gmatch(content, "[^\n]+") do
        local f = {}
        for field in string.gmatch(line, "[^ ]+") do
            table.insert(f, field)
        end
        -- 分隔符 '-' 之后的两个字段依次是 fstype 与 source
        local sep = nil
        for i = 7, #f do
            if f[i] == "-" then
                sep = i
                break
            end
        end
        if sep and f[sep + 1] == "btrfs" then
            local root = unescape(f[4] or "")
            local superopts = f[sep + 3] or ""
            local subvol = string.match(superopts, "subvol=([^,]*)")
            table.insert(out, {
                path = unescape(f[5] or ""),
                subvol = subvol and unescape(subvol) or root,
                id = tonumber(string.match(superopts, "subvolid=(%d+)") or ""),
                source = unescape(f[sep + 2] or ""),
                kind = "btrfs",
            })
        end
    end
    return out
end

-- 设置里手填的额外路径：英文逗号 / 分号 / 换行分隔；~ 展开
function M.extraPaths(text)
    local out = {}
    local seen = {}
    if type(text) ~= "string" then
        return out
    end
    for raw in string.gmatch(text, "[^,;\n]+") do
        local p = string.gsub(raw, "^%s*(.-)%s*$", "%1")
        local skip = (p == "")
        if not skip and string.sub(p, 1, 1) == "~" then
            -- 沙箱里没有 os.getenv，展开 ~ 得用宿主的 noctalia.expandPath；
            -- 展开不了就跳过这一条（总比拿字面量 "~/x" 去 du 强）
            local ok, expanded = pcall(noctalia.expandPath, p)
            if ok and type(expanded) == "string" and expanded ~= ""
                and string.sub(expanded, 1, 1) ~= "~" then
                p = expanded
            else
                skip = true
            end
        end
        if not skip then
            p = string.gsub(p, "/+$", "")
            if p == "" then
                p = "/"
            end
            if not seen[p] then
                seen[p] = true
                table.insert(out, { path = p, kind = "path" })
            end
        end
    end
    return out
end

-- 合并：已挂载子卷 + 手填路径（按路径去重）
function M.list(cfg)
    local out = {}
    local seen = {}
    for _, m in ipairs(M.mounts()) do
        if not seen[m.path] then
            seen[m.path] = true
            table.insert(out, m)
        end
    end
    for _, e in ipairs(M.extraPaths(cfg and cfg.extra)) do
        if not seen[e.path] then
            seen[e.path] = true
            table.insert(out, e)
        end
    end
    table.sort(out, function(a, b)
        return a.path < b.path
    end)
    return out
end

-- ── 缓存与任务标记 ─────────────────────────────────────────────────────────

function M.dir()
    local base = noctalia.pluginDataDir()
    if type(base) ~= "string" then
        return nil
    end
    local dir = base .. "/subvol"
    noctalia.mkdirAll(dir)
    return dir
end

local function statePath(dir)
    return dir .. "/state.json"
end

function M.loadState()
    local dir = M.dir()
    local state = { version = 1, paths = {}, entries = {} }
    if not dir then
        return state
    end
    local raw = noctalia.readFile(statePath(dir))
    if type(raw) == "string" then
        local decoded = json.decode(raw)
        if type(decoded) == "table" then
            state.paths = type(decoded.paths) == "table" and decoded.paths or {}
            state.entries = type(decoded.entries) == "table" and decoded.entries or {}
        end
    end
    return state
end

function M.saveState(state)
    local dir = M.dir()
    if not dir then
        return false
    end
    local encoded = json.encode({ version = 1, paths = state.paths or {}, entries = state.entries or {} }, true)
    if type(encoded) ~= "string" then
        return false
    end
    local ok = noctalia.writeFile(statePath(dir), encoded)
    return ok and true or false
end

function M.job()
    local dir = M.dir()
    if not dir then
        return nil
    end
    local raw = noctalia.readFile(dir .. "/job.json")
    if type(raw) ~= "string" then
        return nil
    end
    local decoded = json.decode(raw)
    if type(decoded) == "table" and type(decoded.started) == "number" then
        return decoded
    end
    return nil
end

function M.running()
    return M.job() ~= nil
end

-- ── 统计任务 ───────────────────────────────────────────────────────────────

local AWK = {
    allocated = "NF {v=$1} END {print v+0}",
    apparent = "NF {v=$1} END {print v+0}",
    btrfs = "NF>=3 && $1 ~ /^[0-9]+$/ {v=$2} END {print v+0}",
}

-- 启动后台统计；mode: allocated | apparent | btrfs
function M.start(entries, mode)
    local dir = M.dir()
    if not dir or #entries == 0 then
        return false
    end
    if mode ~= "apparent" and mode ~= "btrfs" then
        mode = "allocated"
    end
    if mode == "btrfs" and not noctalia.commandExists("btrfs") then
        mode = "allocated"
    end

    local lines = {
        "#!/bin/sh",
        "# 由 ylxc/disk 生成：逐个子卷统计占用，结果原子落盘（请勿手工修改）",
        "D=" .. shQuote(dir),
    }
    local slugs = {}
    for _, e in ipairs(entries) do
        local path = e.path
        local s = M.slug(path)
        slugs[s] = path
        local cmd
        if mode == "btrfs" then
            cmd = "btrfs filesystem du -s --raw -- " .. shQuote(path)
        elseif mode == "apparent" then
            cmd = "du -sx --apparent-size --block-size=1 -- " .. shQuote(path)
        else
            cmd = "du -sx --block-size=1 -- " .. shQuote(path)
        end
        table.insert(lines, "")
        table.insert(lines, "# " .. path)
        table.insert(lines, "s=$(date +%s)")
        table.insert(lines, "o=$(" .. cmd .. " 2>\"$D/" .. s .. ".err\"); rc=$?")
        table.insert(lines, "e=$(date +%s)")
        table.insert(lines, "b=$(printf '%s\\n' \"$o\" | awk '" .. AWK[mode] .. "')")
        table.insert(lines, "printf 'bytes=%s\\nrc=%s\\nsecs=%s\\nmode=" .. mode
            .. "\\n' \"$b\" \"$rc\" \"$((e - s))\" > \"$D/" .. s .. ".done.tmp\"")
        table.insert(lines, "mv \"$D/" .. s .. ".done.tmp\" \"$D/" .. s .. ".done\"")
    end
    table.insert(lines, "rm -f \"$D/job.json\"")

    local script = table.concat(lines, "\n") .. "\n"
    if not noctalia.writeFile(dir .. "/scan.sh", script) then
        log("无法写入统计脚本")
        return false
    end

    local state = M.loadState()
    for s, p in pairs(slugs) do
        state.paths[s] = p
    end
    M.saveState(state)

    noctalia.writeFile(dir .. "/job.json", json.encode({
        started = os.time(),
        mode = mode,
        slugs = slugs,
    }) or "")

    local prefix = noctalia.commandExists("setsid") and "setsid " or ""
    noctalia.runAsync(prefix .. "sh " .. shQuote(dir .. "/scan.sh") .. " </dev/null >/dev/null 2>&1 &")
    return true
end

-- 收结果文件：解析 → 合并进缓存 → 清理任务标记；返回最新缓存
function M.collect()
    local dir = M.dir()
    if not dir then
        return nil
    end
    local state = M.loadState()
    local changed = false

    local names = noctalia.listDir(dir)
    if type(names) == "table" then
        for _, name in ipairs(names) do
            local s = string.match(name, "^([0-9a-f]+)%.done$")
            if s then
                local raw = noctalia.readFile(dir .. "/" .. name)
                local rec = {}
                if type(raw) == "string" then
                    for k, v in string.gmatch(raw, "([%a_]+)=(.-)\n") do
                        rec[k] = v
                    end
                end
                local path = (state.paths or {})[s]
                if path and rec.bytes then
                    local err = noctalia.readFile(dir .. "/" .. s .. ".err")
                    local errText = nil
                    if type(err) == "string" and err ~= "" then
                        errText = string.sub(string.gsub(err, "%s+$", ""), 1, 200)
                    end
                    state.entries[path] = {
                        bytes = tonumber(rec.bytes) or 0,
                        rc = tonumber(rec.rc) or 0,
                        secs = tonumber(rec.secs) or 0,
                        mode = rec.mode or "allocated",
                        at = os.time(),
                        err = errText,
                    }
                    changed = true
                end
                noctalia.removeFile(dir .. "/" .. name)
                noctalia.removeFile(dir .. "/" .. s .. ".err")
            end
        end
    end

    local job = M.job()
    if job then
        local allDone = true
        for _, path in pairs(job.slugs or {}) do
            local e = state.entries[path]
            if not (e and e.at and e.at >= job.started) then
                allDone = false
                break
            end
        end
        if allDone then
            noctalia.removeFile(dir .. "/job.json")
        elseif (os.time() - job.started) > STALL_SECONDS then
            noctalia.removeFile(dir .. "/job.json")
            log("统计任务超时未收完，已清除标记")
        end
    end

    if changed then
        M.saveState(state)
    end
    return state
end

-- ── 供 UI 使用的行 ─────────────────────────────────────────────────────────

-- cfg: { extra, cacheMinutes }
-- fsRows: disk.rows() 的结果，用来算「该子卷占它所在文件系统的百分比」
function M.rows(cfg, fsRows, state)
    state = state or M.loadState()
    local job = M.job()
    local now = os.time()
    local cacheSeconds = (cfg and cfg.cacheMinutes or 720) * 60
    local out = {}
    for _, info in ipairs(M.list(cfg)) do
        local entry = (state.entries or {})[info.path]
        local running = false
        if job and (job.slugs or {})[M.slug(info.path)] then
            running = not (entry and entry.at and entry.at >= job.started)
        end
        local stale = true
        if entry and entry.at then
            stale = (now - entry.at) > cacheSeconds
        end
        local fs = nil
        if type(fsRows) == "table" then
            fs = (function()
                -- 1) 挂载点完全一致；2) 挂载点是它的祖先（最长者优先）；
                -- 3) 兜底：取总量最大的那个文件系统 —— 同一个 btrfs 上各子卷共享
                --    同一组 total/free，宿主按设备去重后只留了一个挂载点条目，
                --    所以 /home 这类子卷得靠兜底才拿得到分母。
                local exact, best, bestLen, biggest = nil, nil, 0, nil
                for _, r in ipairs(fsRows) do
                    local p = r.mount and r.mount.path
                    if p and p == info.path then
                        exact = r
                        break
                    end
                    if p and #p > 1 and #p > bestLen
                        and info.path:sub(1, #p) == p
                        and info.path:sub(#p + 1, #p + 1) == "/" then
                        best, bestLen = r, #p
                    end
                    if r.stats and r.stats.totalBytes
                        and (not biggest or (r.stats.totalBytes or 0) > (biggest.stats.totalBytes or 0)) then
                        biggest = r
                    end
                end
                return exact or best or biggest
            end)()
        end
        table.insert(out, {
            path = info.path,
            subvol = info.subvol,
            id = info.id,
            source = info.source,
            kind = info.kind,
            entry = entry,
            running = running,
            stale = stale,
            fs = fs,
        })
    end
    return out
end

-- 需要统计的路径（没结果或已过期）
function M.pending(rows)
    local out = {}
    for _, r in ipairs(rows) do
        if (not r.entry) or r.stale then
            table.insert(out, { path = r.path })
        end
    end
    return out
end

return M
