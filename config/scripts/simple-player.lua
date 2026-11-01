-- Simple Player: the whole UI (seek bar, pause, settings panel, toasts) drawn on top of mpv.
-- Colors are ASS colors, which are written BGR: "00B3FF" = #FFB300 (yellow), "008FFF" = #FF8F00 (orange).

local YELLOW = "00B3FF"
local ORANGE = "008FFF"
local WHITE  = "FFFFFF"
local BLACK  = "000000"

local utils = require "mp.utils"

------------------------------------------------------------------ settings (saved between runs)
local S = { font = 45, pos = 95, border = 3, volume = 100, color = "white", shade = true, size = "best" }
local cfg_path = mp.command_native({ "expand-path", "~~/sp-settings.cfg" })

local function load_settings()
    local f = io.open(cfg_path, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^(%w+)=(.-)%s*$")
        if k == "font" and tonumber(v) then S.font = tonumber(v)
        elseif k == "pos" and tonumber(v) then S.pos = tonumber(v)
        elseif k == "border" and tonumber(v) then S.border = tonumber(v)
        elseif k == "volume" and tonumber(v) then S.volume = math.max(0, math.min(100, tonumber(v)))
        elseif k == "color" and (v == "white" or v == "black") then S.color = v
        elseif k == "shade" then S.shade = (v == "1")
        elseif k == "size" and (v == "best" or v == "fit" or v == "original") then S.size = v
        end
    end
    f:close()
end

local function save_settings()
    local f = io.open(cfg_path, "w")
    if not f then return end
    f:write("font=" .. S.font .. "\n", "pos=" .. S.pos .. "\n", "border=" .. S.border .. "\n", "volume=" .. S.volume .. "\n", "color=" .. S.color .. "\n",
            "shade=" .. (S.shade and "1" or "0") .. "\n", "size=" .. S.size .. "\n")
    f:close()
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function fmt(t)
    if not t or t < 0 then t = 0 end
    t = math.floor(t)
    local h = math.floor(t / 3600)
    local m = math.floor((t % 3600) / 60)
    local s = t % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

------------------------------------------------------------------ state
local W, H = 1280, 720
local panel_open, dragging, fullscreen, paused = false, false, false, false
local list_open, list_files, list_cur, list_scroll, list_dir = false, {}, 0, 0, ""
local list_sel = 0                                -- row selected with the arrow keys / mouse
local play_path, play_pos, play_dur = nil, 0, 0   -- the video playing now
local resume_path, resume_pos = nil, 0            -- last video of the previous session
local last_file = mp.command_native({ "expand-path", "~~/sp-last.cfg" })
local mouse = { x = -1, y = -1, hover = false }
local last_move, last_render = -10, 0
local toast_text, toast_until = nil, 0
local hit = {}                 -- clickable areas of the last render
local seek_area = nil          -- {x0, y0, x1, y1} of the seek bar (nil when hidden)
local panel_rect = nil
local bar_top = nil            -- y where the bar starts (nil when hidden)
local drag_ratio, last_drag_seek = 0, 0
local click_timer = nil
local last_vis = false

local overlay = mp.create_osd_overlay("ass-events")

local function has_file() return mp.get_property("path") ~= nil end
local function scale() return clamp(H / 720, 0.8, 2.2) end

------------------------------------------------------------------ applying settings to mpv
local function apply_sub()
    local fg = (S.color == "black") and "#000000" or "#FFFFFF"
    local bg = (S.color == "black") and "#FFFFFF" or "#000000"   -- frame is the opposite color
    mp.set_property("sub-font-size", string.format("%.0f", S.font))
    mp.set_property("sub-color", fg)
    mp.set_property("sub-border-color", bg)
    mp.set_property("sub-border-size", S.shade and tostring(S.border) or "0")
    mp.set_property("sub-shadow-offset", "0")
    mp.set_property("sub-pos", string.format("%.0f", S.pos))
end

local function apply_size()
    mp.set_property("keepaspect", (S.size == "fit") and "no" or "yes")
    mp.set_property("video-unscaled", (S.size == "original") and "yes" or "no")
end

------------------------------------------------------------------ ASS drawing helpers
local function rect(x0, y0, x1, y1, col, alpha)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}m %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f{\\p0}\n",
        col, alpha or "00", x0, y0, x1, y0, x1, y1, x0, y1)
end

local function circle(cx, cy, r, col, alpha)
    local k = r * 0.5523
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}" ..
        "m %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f " ..
        "b %.1f %.1f %.1f %.1f %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f{\\p0}\n",
        col, alpha or "00",
        cx, cy - r,
        cx + k, cy - r, cx + r, cy - k, cx + r, cy,
        cx + r, cy + k, cx + k, cy + r, cx, cy + r,
        cx - k, cy + r, cx - r, cy + k, cx - r, cy,
        cx - r, cy - k, cx - k, cy - r, cx, cy - r)
end

local function triangle(x0, y0, x1, y1, x2, y2, col)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\p1}m %.1f %.1f l %.1f %.1f %.1f %.1f{\\p0}\n",
        col, x0, y0, x1, y1, x2, y2)
end

local function text(x, y, an, size, col, s, bold, font, outline)
    return string.format("{\\an%d\\pos(%.1f,%.1f)\\fs%.0f\\bord%d\\3c&H000000&\\shad0\\1c&H%s&\\fn%s\\b%d}%s\n",
        an, x, y, size, outline or 0, col, font or "Segoe UI", bold and 1 or 0, s)
end

local function inside(x, y, r)
    return x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4]
end

local function hovered(x0, y0, x1, y1)
    return mouse.hover and inside(mouse.x, mouse.y, { x0, y0, x1, y1 })
end

-- a clickable button; returns the ASS string and registers the hit area
local function button(x0, y0, x1, y1, label, active, fn)
    local hov = hovered(x0, y0, x1, y1)
    local out = rect(x0 - 1, y0 - 1, x1 + 1, y1 + 1, hov and YELLOW or "20536B")
    out = out .. rect(x0, y0, x1, y1, active and YELLOW or "2A2A2A")
    local col = active and "001A12" or (hov and YELLOW or "E6F0F5")
    out = out .. text((x0 + x1) / 2, (y0 + y1) / 2, 5, (y1 - y0) * 0.5, col, label, active)
    hit[#hit + 1] = { x0, y0, x1, y1, fn }
    return out
end

------------------------------------------------------------------ toast
local render   -- forward declaration

local function toast(msg, secs)
    secs = secs or 1.2
    toast_text = msg
    toast_until = mp.get_time() + secs
    render()
    mp.add_timeout(secs + 0.05, function() render() end)
end

------------------------------------------------------------------ actions
local function pick_file(kind, cb)
    local filter
    if kind == "sub" then
        filter = "Subtitles|*.srt;*.vtt;*.ass;*.ssa;*.sub|All files|*.*"
    else
        filter = "Video|*.mp4;*.mkv;*.webm;*.avi;*.mov;*.m4v;*.wmv;*.flv;*.ts;*.mpg;*.mpeg|All files|*.*"
    end
    local ps = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; " ..
        "$d=New-Object System.Windows.Forms.OpenFileDialog; $d.Filter='" .. filter .. "'; " ..
        "$f=New-Object System.Windows.Forms.Form; $f.TopMost=$true; " ..
        "if($d.ShowDialog($f) -eq 'OK'){ [Console]::Out.Write($d.FileName) }"
    mp.command_native_async({
        name = "subprocess",
        args = { "powershell", "-NoProfile", "-STA", "-Command", ps },
        capture_stdout = true,
        playback_only = false,
    }, function(ok, res)
        if ok and res and res.status == 0 and res.stdout then
            local p = res.stdout:gsub("^\239\187\191", ""):gsub("[\r\n]+$", "")
            if #p > 0 then cb(p) end
        end
    end)
end

local function open_video()
    pick_file("video", function(p) mp.commandv("loadfile", p, "replace") end)
end

local function load_sub()
    if not has_file() then toast("Open a video first"); return end
    pick_file("sub", function(p)
        mp.commandv("sub-add", p, "select")
        mp.set_property("sub-visibility", "yes")
        toast("Subtitles loaded", 1.5)
    end)
end

local function change_font(d)
    S.font = clamp(S.font + d, 15, 150)
    apply_sub(); save_settings()
    toast("Subtitle size " .. S.font)
end

local function change_pos(d)
    S.pos = clamp(S.pos + d, 0, 100)
    apply_sub(); save_settings()
    toast("Subtitle position " .. S.pos)
end

local function change_border(d)
    S.border = clamp(S.border + d, 0, 15)
    S.shade = S.border > 0
    apply_sub(); save_settings()
    toast("Subtitle shade size " .. S.border)
end

local function set_color(c)
    S.color = c
    apply_sub(); save_settings()
    toast("Subtitle color: " .. c)
end

local function set_shade(on)
    S.shade = on
    apply_sub(); save_settings()
    toast("Subtitle shade " .. (on and "on" or "off"))
end

local function change_delay(d)
    if d == 0 then
        mp.set_property("sub-delay", "0")
    else
        mp.commandv("add", "sub-delay", tostring(d))
    end
    local v = mp.get_property_number("sub-delay") or 0
    toast(string.format("Subtitle delay %+.1fs", v))
end

local SIZE_NAMES = { best = "Best fit", fit = "Fit to screen", original = "Original size" }
local function set_size(mode)
    S.size = mode
    apply_size(); save_settings()
    toast(SIZE_NAMES[mode])
end

local function set_speed(v)
    mp.set_property("speed", tostring(v))
    toast("Speed " .. v .. "x")
end

local function set_subs_visible(v)
    mp.set_property("sub-visibility", v and "yes" or "no")
    toast(v and "Subtitles on" or "Subtitles off")
end

------------------------------------------------------------------ file list (other videos in the same folder)
local VIDEO_EXT = { mp4 = true, mkv = true, webm = true, avi = true, mov = true, m4v = true,
                    wmv = true, flv = true, ts = true, mpg = true, mpeg = true }

local function list_rows()
    return clamp(math.floor((H - 170 * scale()) / (34 * scale())), 3, 12)
end

-- "Episode 2" sorts before "Episode 10"
local function natural_key(name)
    return (name:lower():gsub("%d+", function(n)
        if #n < 12 then n = string.rep("0", 12 - #n) .. n end
        return n
    end))
end

-- shorten text to n characters (safe for UTF-8)
local function cut(str, n)
    local count, i = 0, 1
    while i <= #str do
        local c = str:byte(i)
        local len = (c >= 240 and 4) or (c >= 224 and 3) or (c >= 192 and 2) or 1
        count = count + 1
        if count > n then return str:sub(1, i - 1) .. "..." end
        i = i + len
    end
    return str
end

local function abs_path(path)
    if path:match("^%a:[\\/]") or path:match("^[\\/][\\/]") or path:match("^/") then return path end
    return utils.join_path(mp.get_property("working-directory") or "", path)
end

local function build_list()
    list_files, list_cur, list_dir = {}, 0, ""
    local path = mp.get_property("path")
    if not path then return end
    path = abs_path(path)
    local dir, file = utils.split_path(path)
    list_dir = dir
    local items = {}
    for _, n in ipairs(utils.readdir(dir, "files") or {}) do
        local ext = n:match("%.([^.]+)$")
        if ext and VIDEO_EXT[ext:lower()] then items[#items + 1] = { name = n, key = natural_key(n) } end
    end
    table.sort(items, function(a, b) return a.key < b.key end)
    for i, it in ipairs(items) do
        list_files[i] = it.name
        if it.name == file then list_cur = i end
    end
end

local function toggle_list()
    if not has_file() then toast("Open a video first"); return end
    if list_open then
        list_open = false
    else
        build_list()
        if #list_files == 0 then toast("No video files found in this folder", 1.8); return end
        panel_open = false
        list_open = true
        list_sel = list_cur > 0 and list_cur or 1
        list_scroll = clamp(list_cur - math.floor(list_rows() / 2), 0, math.max(0, #list_files - list_rows()))
    end
    render()
end

local function scroll_list(d)
    list_scroll = clamp(list_scroll + d, 0, math.max(0, #list_files - list_rows()))
    render()
end

local function move_sel(d)
    list_sel = clamp(list_sel + d, 1, #list_files)
    local rows = list_rows()
    if list_sel <= list_scroll then
        list_scroll = list_sel - 1
    elseif list_sel > list_scroll + rows then
        list_scroll = list_sel - rows
    end
    render()
end

local function play_list_item(i)
    local name = list_files[i]
    if not name then return end
    list_open = false
    mp.commandv("loadfile", utils.join_path(list_dir, name), "replace")
    render()
end

------------------------------------------------------------------ remember the last video (offered on the start screen)
local function load_last()
    local f = io.open(last_file, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^(%w+)=(.-)%s*$")
        if k == "path" and v ~= "" then resume_path = v
        elseif k == "pos" and tonumber(v) then resume_pos = tonumber(v) end
    end
    f:close()
    if resume_path and not utils.file_info(resume_path) then resume_path = nil end
end

local function save_last()
    if not play_path or play_path:match("^%a[%w+.-]*://") then return end
    local finished = play_dur > 0 and play_pos >= play_dur - 10
    if play_pos <= 5 and not finished then return end   -- keep the older memory
    local f = io.open(last_file, "w")
    if not f then return end
    if not finished then   -- a finished video is forgotten
        f:write("path=" .. abs_path(play_path) .. "\n", string.format("pos=%.1f\n", play_pos))
    end
    f:close()
end

local function resume_last()
    if not resume_path then return end
    local p, pos = resume_path, resume_pos
    resume_path = nil
    mp.commandv("loadfile", p, "replace", "-1", string.format("start=%.1f", pos))
end

local function change_volume(d)
    mp.commandv("add", "volume", tostring(d))
    S.volume = math.floor((mp.get_property_number("volume") or 0) + 0.5)
    save_settings()
    toast("Volume " .. S.volume, 0.8)
end

------------------------------------------------------------------ visibility of the bar
local function bar_visible()
    if not has_file() then return false end
    if panel_open or list_open or dragging then return true end
    local s = scale()
    if mouse.hover and mouse.y > H - 100 * s then return true end
    if not fullscreen and (mp.get_time() - last_move < 3 or paused) then return true end
    return false
end

------------------------------------------------------------------ drawing
local function draw_idle(out, s)
    out[#out + 1] = circle(W / 2, H / 2 - 70 * s, 46 * s, ORANGE)
    out[#out + 1] = triangle(W / 2 - 14 * s, H / 2 - 70 * s - 22 * s, W / 2 - 14 * s, H / 2 - 70 * s + 22 * s,
        W / 2 + 24 * s, H / 2 - 70 * s, "001A12")
    out[#out + 1] = text(W / 2, H / 2 + 8 * s, 5, 46 * s, YELLOW, "Simple Player", true)
    out[#out + 1] = text(W / 2, H / 2 + 56 * s, 5, 20 * s, "A8B8C0", "Click anywhere, drop a video here, or press O")
    if resume_path then
        local name = resume_path:match("([^\\/]+)$") or resume_path
        name = name:gsub("%.[^.]+$", "")
        name = name:gsub("[{}]", "-")
        name = cut(name, 70)
        out[#out + 1] = text(W / 2, H / 2 + 112 * s, 5, 20 * s, "E6F0F5",
            "Do you want to continue \"" .. name .. "\"?  (" .. fmt(resume_pos) .. ")")
        out[#out + 1] = button(W / 2 - 90 * s, H / 2 + 140 * s, W / 2 + 90 * s, H / 2 + 182 * s,
            "Resume  (R)", true, resume_last)
    end
end

local function draw_bar(out, s)
    local barH = 72 * s
    local y0 = H - barH
    bar_top = y0
    out[#out + 1] = rect(0, y0, W, H, "000000", "78")
    out[#out + 1] = rect(0, y0 + barH * 0.5, W, H, "000000", "A0")

    local yc = H - 32 * s
    local pad, btn = 16 * s, 44 * s

    -- pause / play button
    local px0, px1 = pad, pad + btn
    local pcx = (px0 + px1) / 2
    if hovered(px0, yc - btn / 2, px1, yc + btn / 2) then
        out[#out + 1] = circle(pcx, yc, btn / 2, YELLOW, "C8")
    end
    if paused then
        out[#out + 1] = triangle(pcx - 8 * s, yc - 12 * s, pcx - 8 * s, yc + 12 * s, pcx + 13 * s, yc, YELLOW)
    else
        out[#out + 1] = rect(pcx - 10 * s, yc - 12 * s, pcx - 3 * s, yc + 12 * s, YELLOW)
        out[#out + 1] = rect(pcx + 3 * s, yc - 12 * s, pcx + 10 * s, yc + 12 * s, YELLOW)
    end
    hit[#hit + 1] = { px0, yc - btn / 2, px1, yc + btn / 2, function() mp.commandv("cycle", "pause") end }

    -- times
    local dur = mp.get_property_number("duration") or 0
    local pos = mp.get_property_number("time-pos") or 0
    out[#out + 1] = text(px1 + 38 * s, yc, 5, 18 * s, "F0F0F0", fmt(pos))

    -- seek bar
    local sx0 = px1 + 76 * s
    local sx1 = W - pad - 2 * btn - 82 * s
    seek_area = { sx0 - 6 * s, yc - 16 * s, sx1 + 6 * s, yc + 16 * s }
    local over_seek = hovered(seek_area[1], seek_area[2], seek_area[3], seek_area[4])
    local th = (over_seek or dragging) and 9 * s or 5 * s
    local ratio = (dur > 0) and clamp(pos / dur, 0, 1) or 0
    if dragging then ratio = drag_ratio end
    out[#out + 1] = rect(sx0, yc - th / 2, sx1, yc + th / 2, WHITE, "CC")
    out[#out + 1] = rect(sx0, yc - th / 2, sx0 + (sx1 - sx0) * ratio, yc + th / 2, ORANGE)
    if over_seek or dragging then
        out[#out + 1] = circle(sx0 + (sx1 - sx0) * ratio, yc, 8 * s, YELLOW)
        -- time tooltip above the mouse
        local mr = clamp((mouse.x - sx0) / (sx1 - sx0), 0, 1)
        local label = fmt(mr * dur)
        local tw, thh = 64 * s, 26 * s
        local tx = clamp(sx0 + (sx1 - sx0) * mr, sx0 + tw / 2 - 20 * s, sx1 - tw / 2 + 20 * s)
        out[#out + 1] = rect(tx - tw / 2 - 1, yc - 52 * s - 1, tx + tw / 2 + 1, yc - 52 * s + thh + 1, YELLOW)
        out[#out + 1] = rect(tx - tw / 2, yc - 52 * s, tx + tw / 2, yc - 52 * s + thh, "101010")
        out[#out + 1] = text(tx, yc - 52 * s + thh / 2, 5, 15 * s, YELLOW, label)
    end
    out[#out + 1] = text(sx1 + 38 * s, yc, 5, 18 * s, "F0F0F0", fmt(dur))

    -- settings (gear) button
    local gx1 = W - pad
    local gx0 = gx1 - btn
    if panel_open or hovered(gx0, yc - btn / 2, gx1, yc + btn / 2) then
        out[#out + 1] = circle((gx0 + gx1) / 2, yc, btn / 2, YELLOW, panel_open and "A0" or "C8")
    end
    out[#out + 1] = text((gx0 + gx1) / 2, yc, 5, 30 * s, panel_open and "001A12" or YELLOW, "\226\154\153", false, "Segoe UI Symbol")
    hit[#hit + 1] = { gx0, yc - btn / 2, gx1, yc + btn / 2, function() panel_open = not panel_open; list_open = false end }

    -- file list button (three lines), next to the settings button
    local mx1 = gx0 - 6 * s
    local mx0 = mx1 - btn
    local mcx = (mx0 + mx1) / 2
    if list_open or hovered(mx0, yc - btn / 2, mx1, yc + btn / 2) then
        out[#out + 1] = circle(mcx, yc, btn / 2, YELLOW, list_open and "A0" or "C8")
    end
    local lc = list_open and "001A12" or YELLOW
    for k = -1, 1 do
        out[#out + 1] = rect(mcx - 10 * s, yc + k * 7 * s - 1.5 * s, mcx + 10 * s, yc + k * 7 * s + 1.5 * s, lc)
    end
    hit[#hit + 1] = { mx0, yc - btn / 2, mx1, yc + btn / 2, function() toggle_list() end }
end

local function draw_panel(out, s)
    local pw, rowH = 450 * s, 38 * s
    local keysH = 4 * 19 * s + 16 * s
    local ph = 12 * s + 9 * rowH + keysH
    local px1, py1 = W - 16 * s, H - 80 * s
    local px0, py0 = px1 - pw, py1 - ph
    panel_rect = { px0, py0, px1, py1 }
    out[#out + 1] = rect(px0 - 1, py0 - 1, px1 + 1, py1 + 1, "20536B")
    out[#out + 1] = rect(px0, py0, px1, py1, "0A1216", "10")

    local function row(i, label, items)
        local yc = py0 + 6 * s + (i - 0.5) * rowH
        out[#out + 1] = text(px0 + 14 * s, yc, 4, 13 * s, "8AB8C9", string.upper(label))
        local bx0, bx1, gap = px0 + 108 * s, px1 - 14 * s, 6 * s
        local total = 0
        for _, it in ipairs(items) do total = total + (it.w or 1) end
        local avail = (bx1 - bx0) - gap * (#items - 1)
        local x = bx0
        for _, it in ipairs(items) do
            local w = avail * (it.w or 1) / total
            if it.val then
                out[#out + 1] = text(x + w / 2, yc, 5, 17 * s, YELLOW, it.val, true)
            else
                out[#out + 1] = button(x, yc - 14 * s, x + w, yc + 14 * s, it.label, it.on, it.fn)
            end
            x = x + w + gap
        end
    end

    local subs_on = mp.get_property_bool("sub-visibility")
    local delay = mp.get_property_number("sub-delay") or 0
    local speed = mp.get_property_number("speed") or 1

    row(1, "File", {
        { label = "Open video...", fn = open_video },
        { label = "Load subtitles...", fn = load_sub } })
    row(2, "Subtitles", {
        { label = "Show", on = subs_on, fn = function() set_subs_visible(true) end },
        { label = "Hide", on = not subs_on, fn = function() set_subs_visible(false) end } })
    row(3, "Font size", {
        { label = "-", w = 0.5, fn = function() change_font(-3) end },
        { val = tostring(S.font) },
        { label = "+", w = 0.5, fn = function() change_font(3) end } })
    row(4, "Position", {
        { label = "Higher", fn = function() change_pos(-2) end },
        { label = "Lower", fn = function() change_pos(2) end } })
    row(5, "Color", {
        { label = "White", on = S.color == "white", fn = function() set_color("white") end },
        { label = "Black", on = S.color == "black", fn = function() set_color("black") end } })
    row(6, "Shade", {
        { label = "On", on = S.shade, fn = function() set_shade(true) end },
        { label = "Off", on = not S.shade, fn = function() set_shade(false) end },
        { label = "-", w = 0.5, fn = function() change_border(-1) end },
        { val = tostring(S.border) },
        { label = "+", w = 0.5, fn = function() change_border(1) end } })
    row(7, "Delay", {
        { label = "-", w = 0.5, fn = function() change_delay(-0.5) end },
        { val = string.format("%+.1fs", delay) },
        { label = "+", w = 0.5, fn = function() change_delay(0.5) end },
        { label = "Reset", fn = function() change_delay(0) end } })
    row(8, "Screen", {
        { label = "Best", on = S.size == "best", fn = function() set_size("best") end },
        { label = "Fit", on = S.size == "fit", fn = function() set_size("fit") end },
        { label = "Original", on = S.size == "original", fn = function() set_size("original") end } })
    row(9, "Speed", {
        { label = "0.5x", on = speed == 0.5, fn = function() set_speed(0.5) end },
        { label = "1x", on = speed == 1, fn = function() set_speed(1) end },
        { label = "1.5x", on = speed == 1.5, fn = function() set_speed(1.5) end },
        { label = "2x", on = speed == 2, fn = function() set_speed(2) end } })

    local ky = py0 + 6 * s + 9 * rowH + 14 * s
    out[#out + 1] = rect(px0 + 14 * s, ky - 8 * s, px1 - 14 * s, ky - 7 * s, "20536B")
    local lines = {
        "Space play/pause   \226\134\144 \226\134\146 \194\1775s   \226\134\145 \226\134\147 volume   Enter fullscreen",
        "F / B next / previous frame   M mute   A screen size",
        ". / ,  subtitle delay   Shift+\226\134\145\226\134\147 size   Alt+\226\134\145\226\134\147 position",
        "C color   H shade   S subtitles   O open video",
    }
    for i, l in ipairs(lines) do
        out[#out + 1] = text(px0 + 14 * s, ky + (i - 0.5) * 19 * s, 4, 12 * s, "9AA8B0", l)
    end
end

local function draw_list(out, s)
    local rows = list_rows()
    local rowH, headH = 34 * s, 40 * s
    local pw = clamp(560 * s, 300, W - 32 * s)
    local shown = math.min(rows, #list_files)
    local ph = headH + shown * rowH + 10 * s
    local px1, py1 = W - 16 * s, H - 80 * s
    local px0, py0 = px1 - pw, py1 - ph
    panel_rect = { px0, py0, px1, py1 }
    out[#out + 1] = rect(px0 - 1, py0 - 1, px1 + 1, py1 + 1, "20536B")
    out[#out + 1] = rect(px0, py0, px1, py1, "0A1216", "10")
    out[#out + 1] = text(px0 + 14 * s, py0 + headH / 2, 4, 14 * s, "8AB8C9",
        string.format("FILES IN THIS FOLDER  (%d)", #list_files))
    if #list_files > shown then
        out[#out + 1] = text(px1 - 14 * s, py0 + headH / 2, 6, 13 * s, "9AA8B0",
            string.format("%d-%d  (scroll)", list_scroll + 1, list_scroll + shown))
    end
    -- moving the mouse over a row selects it (the arrow keys keep working in between)
    if mp.get_time() - last_move < 0.15 then
        for r = 1, shown do
            local ry = py0 + headH + (r - 1) * rowH
            if hovered(px0, ry, px1, ry + rowH) then list_sel = list_scroll + r end
        end
    end
    local maxch = math.max(10, math.floor((pw - 40 * s) / (8.4 * s)))
    for r = 1, shown do
        local i = list_scroll + r
        local name = list_files[i]
        if not name then break end
        local y0 = py0 + headH + (r - 1) * rowH
        local y1 = y0 + rowH
        local cur = (i == list_cur)
        local sel = (i == list_sel)
        if cur then
            out[#out + 1] = rect(px0 + 6 * s, y0 + 1 * s, px1 - 6 * s, y1 - 1 * s, YELLOW)
        elseif sel then
            out[#out + 1] = rect(px0 + 6 * s, y0 + 1 * s, px1 - 6 * s, y1 - 1 * s, "2A2A2A")
        end
        if sel then
            out[#out + 1] = rect(px0 + 6 * s, y0 + 1 * s, px0 + 10 * s, y1 - 1 * s, cur and "001A12" or ORANGE)
        end
        local label = name:gsub("%.[^.]+$", "")
        label = label:gsub("[{}]", "-")
        label = cut(label, maxch)
        local col = cur and "001A12" or (sel and YELLOW or "E6F0F5")
        out[#out + 1] = text(px0 + 18 * s, (y0 + y1) / 2, 4, 16 * s, col, label, cur)
        hit[#hit + 1] = { px0, y0, px1, y1, function() play_list_item(i) end }
    end
end

-- hide the cursor only while the video is playing (not paused, no settings panel, not dragging)
local cursor_mode = nil
local function update_cursor()
    local want = (paused or panel_open or list_open or dragging or not has_file()) and "no" or "2000"
    if want ~= cursor_mode then
        cursor_mode = want
        mp.set_property("cursor-autohide", want)
    end
end

render = function()
    update_cursor()
    last_render = mp.get_time()
    local w, h = mp.get_osd_size()
    if w and w > 0 and h and h > 0 then W, H = w, h end
    local s = scale()
    local out = {}
    hit, seek_area, panel_rect, bar_top = {}, nil, nil, nil

    if not has_file() then
        panel_open = false
        list_open = false
        draw_idle(out, s)
    else
        if bar_visible() then
            draw_bar(out, s)
            if panel_open then draw_panel(out, s) end
            if list_open then draw_list(out, s) end
        end
    end

    if toast_text and mp.get_time() < toast_until then
        out[#out + 1] = text(W - 24 * s, 22 * s, 9, 24 * s, YELLOW, toast_text, true, nil, 2)
    end

    last_vis = bar_visible()
    local data = table.concat(out)
    if data == "" then
        overlay:remove()
    else
        overlay.res_x, overlay.res_y = W, H
        overlay.data = data
        overlay:update()
    end
end

------------------------------------------------------------------ mouse
local function refresh_mouse()
    local m = mp.get_property_native("mouse-pos")
    if m then mouse.x, mouse.y, mouse.hover = m.x or -1, m.y or -1, m.hover and true or false end
end

local function seek_to_mouse(exact)
    local dur = mp.get_property_number("duration")
    if not dur or not seek_area then return end
    local s = scale()
    local pad, btn = 16 * s, 44 * s
    local sx0 = pad + btn + 76 * s
    local sx1 = W - pad - 2 * btn - 82 * s
    drag_ratio = clamp((mouse.x - sx0) / (sx1 - sx0), 0, 1)
    mp.commandv("seek", string.format("%.3f", drag_ratio * dur), exact and "absolute+exact" or "absolute+keyframes")
end

local function on_mouse(ev, dbl)
    refresh_mouse()
    if ev == "up" then
        if dragging then
            seek_to_mouse(false)
            dragging = false
            render()
        end
        return
    end
    if ev ~= "down" and ev ~= "press" then return end

    if not has_file() then
        for i = #hit, 1, -1 do
            local a = hit[i]
            if inside(mouse.x, mouse.y, a) then a[5](); render(); return end
        end
        open_video(); return
    end

    -- seek bar: start dragging
    if seek_area and inside(mouse.x, mouse.y, seek_area) then
        dragging = true
        seek_to_mouse(false)
        render()
        return
    end
    -- buttons (last drawn is on top)
    for i = #hit, 1, -1 do
        local a = hit[i]
        if inside(mouse.x, mouse.y, a) then
            a[5]()
            render()
            return
        end
    end
    -- clicks on the panel or the bar background do nothing
    if panel_rect and inside(mouse.x, mouse.y, panel_rect) then return end
    if bar_top and mouse.y >= bar_top then return end
    -- clicking elsewhere closes the panel
    if panel_open or list_open then panel_open = false; list_open = false; render(); return end

    -- video area: click = play/pause, double click = fullscreen
    if dbl then
        if click_timer then click_timer:kill() end
        mp.commandv("cycle", "fullscreen")
    else
        if click_timer then click_timer:kill() end
        click_timer = mp.add_timeout(0.25, function() mp.commandv("cycle", "pause") end)
    end
end

mp.add_forced_key_binding("MBTN_LEFT", "sp-click", function(t) on_mouse(t.event, false) end, { complex = true })
mp.add_forced_key_binding("MBTN_LEFT_DBL", "sp-dblclick", function(t) on_mouse(t.event, true) end, { complex = true })

mp.observe_property("mouse-pos", "native", function(_, m)
    if not m then return end
    local was_vis = last_vis
    mouse.x, mouse.y, mouse.hover = m.x or -1, m.y or -1, m.hover and true or false
    last_move = mp.get_time()
    if dragging then
        if mp.get_time() - last_drag_seek > 0.05 then
            last_drag_seek = mp.get_time()
            seek_to_mouse(false)
        end
        render()
    elseif bar_visible() or was_vis or (resume_path and not has_file()) then
        if mp.get_time() - last_render > 0.03 then render() end
    end
end)

------------------------------------------------------------------ other events
mp.observe_property("pause", "bool", function(_, v)
    local first = (paused == nil)
    local changed = (v ~= paused)
    paused = v and true or false
    if changed and mp.get_property("path") then toast(paused and "Paused" or "Play", 0.6) else render() end
end)
paused = nil

mp.observe_property("fullscreen", "bool", function(_, v) fullscreen = v and true or false; render() end)
mp.observe_property("osd-width", "number", function() render() end)
mp.observe_property("path", "string", function(_, p)
    if p ~= play_path then
        save_last()   -- remember the video we are leaving
        play_path, play_pos, play_dur = p, 0, 0
    end
    render()
end)
mp.observe_property("duration", "number", function(_, v)
    if v then play_dur = v end
    render()
end)
mp.observe_property("sub-delay", "number", function() if panel_open then render() end end)
mp.observe_property("speed", "number", function() if panel_open then render() end end)
mp.observe_property("sub-visibility", "bool", function() if panel_open then render() end end)

mp.observe_property("time-pos", "number", function(_, v)
    if v then play_pos = v end
    if (last_vis or panel_open) and mp.get_time() - last_render > 0.2 then render() end
end)

mp.register_event("file-loaded", function()
    mp.set_property("sub-delay", "0")
    mp.set_property("speed", "1")
    render()
end)

mp.register_event("seek", function()
    if dragging then return end
    mp.add_timeout(0.08, function()
        local p, d = mp.get_property_number("time-pos"), mp.get_property_number("duration")
        if p and d then toast(fmt(p) .. " / " .. fmt(d), 0.8) end
    end)
end)

mp.add_periodic_timer(0.3, function()
    if bar_visible() ~= last_vis or (toast_text and mp.get_time() >= toast_until and toast_text ~= "") then
        if toast_text and mp.get_time() >= toast_until then toast_text = nil end
        render()
    end
end)

-- save the last video: when closing, when a video ends, and every 5 seconds while playing
mp.register_event("shutdown", save_last)
mp.register_event("end-file", save_last)
mp.add_periodic_timer(5, function() if not paused then save_last() end end)

------------------------------------------------------------------ keyboard messages (see input.conf)
mp.register_script_message("sp-volume", function(d)
    if list_open then move_sel(tonumber(d) > 0 and -1 or 1) else change_volume(tonumber(d)) end
end)
mp.register_script_message("sp-wheel", function(d)
    if list_open then scroll_list(tonumber(d) > 0 and -1 or 1) else change_volume(tonumber(d)) end
end)
mp.register_script_message("sp-enter", function()
    if list_open then play_list_item(list_sel) else mp.commandv("cycle", "fullscreen") end
end)
mp.register_script_message("sp-resume", function() if not has_file() then resume_last() end end)
mp.register_script_message("sp-list", function() toggle_list() end)
mp.register_script_message("sp-sub-delay", function(d) change_delay(tonumber(d)) end)
mp.register_script_message("sp-sub-font", function(d) change_font(tonumber(d)) end)
mp.register_script_message("sp-sub-pos", function(d) change_pos(tonumber(d)) end)
mp.register_script_message("sp-sub-border", function(d) change_border(tonumber(d)) end)
mp.register_script_message("sp-sub-color", function() set_color(S.color == "white" and "black" or "white") end)
mp.register_script_message("sp-sub-shade", function() set_shade(not S.shade) end)
mp.register_script_message("sp-size-cycle", function()
    local order = { best = "fit", fit = "original", original = "best" }
    set_size(order[S.size])
end)
mp.register_script_message("sp-mute", function()
    mp.commandv("cycle", "mute")
    toast(mp.get_property_bool("mute") and "Muted" or "Unmuted", 0.8)
end)
mp.register_script_message("sp-load-sub", load_sub)
mp.register_script_message("sp-open-video", open_video)
mp.register_script_message("sp-escape", function()
    if panel_open or list_open then panel_open = false; list_open = false; render()
    elseif fullscreen then mp.set_property("fullscreen", "no") end
end)

------------------------------------------------------------------ start
load_settings()
load_last()
mp.set_property("volume", tostring(S.volume))
apply_sub()
apply_size()
render()