-- ribbon.lua - Ribbon's conky layouts, drawn with Cairo to match the Ribbon
-- mockups: card, gaming, clock, graphs, strip, calendar.
--
-- Cheap by design: sensors are read straight from /proc and /sys (no shell
-- per tick); only NVIDIA (nvidia-smi), GameMode, wlr-randr and playerctl
-- need a command, and those run every few seconds at most, and only in the
-- layouts that show them.
require 'cairo'

local home = os.getenv('HOME') or ''
local run = os.getenv('XDG_RUNTIME_DIR') or '/tmp'

-- ---- palette --------------------------------------------------------------
local P = { bar = '#1D1C1B', field = '#2A2826', pill = '#36302C', border = '#3B3835',
	fg = '#EEE9E3', muted = '#A49D95', accent = '#FF7A59', on_accent = '#1A0F0B' }
do
	local ok, user = pcall(dofile, home .. '/.config/ribbon/palette.lua')
	if ok and type(user) == 'table' then for k, v in pairs(user) do P[k] = v end end
end

local function rgb(hex)
	return tonumber(hex:sub(2, 3), 16) / 255, tonumber(hex:sub(4, 5), 16) / 255, tonumber(hex:sub(6, 7), 16) / 255
end
local function src(cr, hex, a) local r, g, b = rgb(hex); cairo_set_source_rgba(cr, r, g, b, a or 1) end

-- ---- small helpers -------------------------------------------------------
local function readf(path)
	local f = io.open(path); if not f then return nil end
	local s = f:read('*a'); f:close(); return s
end
local function readn(path) local s = readf(path); return s and tonumber(s:match('%-?[%d.]+')) end
local function sh(cmd)
	local f = io.popen(cmd .. ' 2>/dev/null'); if not f then return '' end
	local s = f:read('*a') or ''; f:close(); return s
end
local now = 0
local cache = {}
-- run fn at most every `every` seconds, keep its value in between
local function every(key, secs, fn)
	local c = cache[key]
	if not c or now - c.t >= secs then c = { t = now, v = fn() }; cache[key] = c end
	return c.v
end

local function rrect(cr, x, y, w, h, r)
	r = math.min(r, w / 2, h / 2)
	cairo_new_sub_path(cr)
	cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
	cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
	cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
	cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
	cairo_close_path(cr)
end
local function box(cr, x, y, w, h, r, hex, a)
	rrect(cr, x, y, w, h, r); src(cr, hex, a); cairo_fill(cr)
end
-- the translucent card with its 1 px inset ring
local function card(cr, x, y, w, h, r)
	box(cr, x, y, w, h, r, P.bar, 0.86)
	rrect(cr, x + 0.5, y + 0.5, w - 1, h - 1, r - 0.5); src(cr, P.border); cairo_set_line_width(cr, 1); cairo_stroke(cr)
end

-- fonts: Inter (13 px = UI), Space Grotesk for headings and big numbers
local FACES = { [400] = 'Inter', [500] = 'Inter Medium', [600] = 'Inter SemiBold' }
local function font(cr, size, weight, family)
	cairo_select_font_face(cr, family or FACES[weight or 400], CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
	cairo_set_font_size(cr, size)
end
local ext = cairo_text_extents_t:create()
tolua.takeownership(ext)
local function adv(cr, s) cairo_text_extents(cr, s, ext); return ext.x_advance end
-- advance with tabular figures: every digit as wide as "0"
local function tadv(cr, s)
	local d, w = adv(cr, '0'), 0
	for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do w = w + (ch:match('%d') and d or adv(cr, ch)) end
	return w
end
-- draw text; align 'l' | 'r' | 'c'; baseline y; tabular; letter-spacing
local function text(cr, s, x, y, hex, align, tab, ls)
	local w = tab and tadv(cr, s) or adv(cr, s)
	if ls then w = w + ls * #s end
	if align == 'r' then x = x - w elseif align == 'c' then x = x - w / 2 end
	src(cr, hex)
	if not tab and not ls then cairo_move_to(cr, x, y); cairo_show_text(cr, s); return w end
	local d = adv(cr, '0')
	for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
		local cw = adv(cr, ch)
		if tab and ch:match('%d') then
			cairo_move_to(cr, x + (d - cw) / 2, y); cairo_show_text(cr, ch); x = x + d
		else
			cairo_move_to(cr, x, y); cairo_show_text(cr, ch); x = x + cw
		end
		x = x + (ls or 0)
	end
	return w
end
-- CSS line boxes: baseline for a line of `size` px starting at `top`
local function base(top, size) return top + size * 0.96875 end          -- Inter
local function sgbase(top, size, lh) -- Space Grotesk, line-height lh (px)
	return top + (lh - size * 1.276) / 2 + size * 0.984
end
local function bar(cr, x, y, w, h, pct)
	box(cr, x, y, w, h, h / 2, P.field)
	if pct > 0 then box(cr, x, y, math.max(h, w * math.min(pct, 100) / 100), h, h / 2, P.accent) end
end

-- ---- sensors ---------------------------------------------------------------
local prev_cpu
local function cpu_pct()
	local s = readf('/proc/stat'); if not s then return 0 end
	local u, n, sy, id, io, irq, sirq, st = s:match('cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)')
	local busy = u + n + sy + irq + sirq + st
	local total = busy + id + io
	local pct = 0
	if prev_cpu and total > prev_cpu[2] then pct = 100 * (busy - prev_cpu[1]) / (total - prev_cpu[2]) end
	prev_cpu = { busy, total }
	return pct
end

local function hwmon(names)
	for i = 0, 15 do
		local d = '/sys/class/hwmon/hwmon' .. i
		local n = readf(d .. '/name')
		if n then n = n:gsub('%s', '')
			for _, want in ipairs(names) do if n == want then return d end end
		end
	end
end
local cpu_mon = hwmon({ 'k10temp', 'zenpower', 'coretemp', 'cpu_thermal' })
local function cpu_temp() return cpu_mon and (readn(cpu_mon .. '/temp1_input') or 0) / 1000 end

local function mem()
	local s = readf('/proc/meminfo') or ''
	local t = tonumber(s:match('MemTotal:%s+(%d+)')) or 0
	local a = tonumber(s:match('MemAvailable:%s+(%d+)')) or 0
	return (t - a) * 1024, t * 1024
end

local amd
for i = 0, 7 do
	local d = '/sys/class/drm/card' .. i .. '/device'
	if readf(d .. '/gpu_busy_percent') then amd = d; break end
end
local nvidia = not amd and os.execute('command -v nvidia-smi >/dev/null 2>&1')
-- {busy, temp, vram_used, vram_total, ghz, watts, fan}
local function gpu()
	if amd then
		local h = sh('ls -d ' .. amd .. '/hwmon/hwmon* | head -n1'):gsub('%s', '')
		local sclk = (readf(amd .. '/pp_dpm_sclk') or ''):match('(%d+)Mhz %*')
		return { readn(amd .. '/gpu_busy_percent') or 0, (readn(h .. '/temp1_input') or 0) / 1000,
			readn(amd .. '/mem_info_vram_used') or 0, readn(amd .. '/mem_info_vram_total') or 0,
			sclk and sclk / 1000, (readn(h .. '/power1_average') or readn(h .. '/power1_input') or 0) / 1e6,
			readn(h .. '/fan1_input') }
	elseif nvidia then
		return every('nv', 4, function()
			local o = sh('nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,clocks.sm,power.draw,fan.speed --format=csv,noheader,nounits | head -n1')
			local v = {}
			for x in o:gmatch('[^,]+') do v[#v + 1] = tonumber(x) end
			if #v < 4 then return nil end
			return { v[1], v[2], (v[3] or 0) * 1048576, (v[4] or 0) * 1048576, v[5] and v[5] / 1000, v[6], v[7] }
		end)
	end
end

local function gb(b) return string.format('%.1f', b / 1e9):gsub('%.0$', '') end
local function pair(used, total)
	if total >= 1e12 then
		return string.format('%s / %s TB', (string.format('%.1f', used / 1e12):gsub('%.0$', '')), (string.format('%.1f', total / 1e12):gsub('%.0$', '')))
	end
	return string.format('%s / %s GB', gb(used), (string.format('%.0f', total / 1e9)))
end

-- the first gaming drive (ribbon drives add), else the system disk
local function disk()
	return every('disk', 30, function()
		local label, path = 'System', '/'
		local m = sh('ls -d /mnt/games/* | head -n1'):gsub('%s+$', '')
		if m ~= '' then path = m; label = (m:match('[^/]+$') or m):gsub('^%l', string.upper) end
		local o = sh("df -B1 --output=used,size '" .. path .. "' | tail -n1")
		local u, s = o:match('(%d+)%s+(%d+)')
		return { label, tonumber(u) or 0, tonumber(s) or 1 }
	end)
end

local function scheduler()
	return every('sched', 10, function()
		local st = readf('/sys/kernel/sched_ext/state') or ''
		local ops = (readf('/sys/kernel/sched_ext/root/ops') or ''):gsub('%s', '')
		if st:match('enabled') and ops ~= '' then return ops:match('^scx_') and ops or ('scx_' .. ops) end
		return 'eevdf'
	end)
end

local function display()
	return every('disp', 60, function()
		local hdr = (readf(home .. '/.config/ribbon/hdr.conf') or ''):match('HDR=(%w+)') or 'off'
		local o = sh('wlr-randr')
		local w, h, hz = o:match('(%d+)x(%d+) px, ([%d.]+) Hz %([^)]*current')
		return { hdr, w and (w .. '×' .. h) or nil, hz and math.floor(tonumber(hz) + 0.5) or nil }
	end)
end

local function battery()
	for _, b in ipairs({ 'BAT0', 'BAT1', 'BAT' }) do
		local c = readn('/sys/class/power_supply/' .. b .. '/capacity'); if c then return c end
	end
end

local function uptime()
	local s = readn('/proc/uptime') or 0
	local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
	if h > 0 then return string.format('up %d h %d min', h, m) end
	return string.format('up %d min', m)
end

local function updates() return readn(run .. '/ribbon-updates') end

-- network rate on the default route's interface, bytes/s {down, up}
local prev_net
local function net()
	local route = readf('/proc/net/route') or ''
	local iface = route:match('\n(%S+)%s+00000000')
	if not iface then return nil end
	local d = '/sys/class/net/' .. iface .. '/statistics/'
	local rx, tx = readn(d .. 'rx_bytes') or 0, readn(d .. 'tx_bytes') or 0
	local r = { 0, 0 }
	if prev_net and now > prev_net[3] then r = { (rx - prev_net[1]) / (now - prev_net[3]), (tx - prev_net[2]) / (now - prev_net[3]) } end
	prev_net = { rx, tx, now }
	return r
end
local function rate(b)
	if b >= 1048576 then return string.format('%.1f MB/s', b / 1048576) end
	return string.format('%.0f KB/s', b / 1024)
end
local function short_rate(b)
	if b >= 1048576 then return string.format('%.1fM', b / 1048576) end
	return string.format('%.0fK', b / 1024)
end

local function gamemode()
	return every('gm', 10, function()
		local o = sh('gamemoded -s')
		return o:match('is active') ~= nil
	end)
end

local function player()
	return every('mpris', 2, function()
		local o = sh("playerctl metadata --format '{{title}}\t{{artist}}\t{{playerName}}\t{{position}}\t{{mpris:length}}'")
		local t, a, p, pos, len = o:match('([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t\n]*)')
		if not t or t == '' then return nil end
		return { t, a, (p:gsub('^%l', string.upper)), tonumber(pos) or 0, tonumber(len) or 0 }
	end)
end

-- histories for the graphs: the last two minutes
local hist = { cpu = {}, gpu = {}, net = {} }
local function push(t, v) t[#t + 1] = v; if #t > 60 then table.remove(t, 1) end end

-- ---- layouts ----------------------------------------------------------------
local L = {}

-- Card (256 wide): load, memory, drives
function L.card(cr)
	local W, x, y = 256, 16, 16
	local stats = {}
	local cp, ct = cpu_pct(), cpu_temp()
	stats[#stats + 1] = { 'CPU', string.format('%d%%', cp) .. (ct and string.format(' · %d°C', ct) or ''), cp }
	local g = gpu()
	if g then
		stats[#stats + 1] = { 'GPU', string.format('%d%% · %d°C', g[1], g[2]), g[1] }
	end
	local mu, mt = mem()
	stats[#stats + 1] = { 'Memory', pair(mu, mt), 100 * mu / mt }
	if g and g[4] > 0 then stats[#stats + 1] = { 'VRAM', pair(g[3], g[4]), 100 * g[3] / g[4] } end
	local dk = disk()
	stats[#stats + 1] = { dk[1], pair(dk[2], dk[3]), 100 * dk[2] / dk[3] }
	local H = 16 + 19.14 + 13 + #stats * (14.52 + 6 + 4) + (#stats - 1) * 13 + 13 + 13.31 + 16
	card(cr, 0, 0, W, H, 14)
	font(cr, 15, nil, 'Space Grotesk SemiBold')
	text(cr, 'system', x, sgbase(y, 15, 19.14), P.fg)
	font(cr, 11, 600)
	local sched = scheduler()
	local cw = adv(cr, sched) + 16
	box(cr, W - 16 - cw, y + 0.915, cw, 17.31, 8.65, P.pill)
	text(cr, sched, W - 16 - cw + 8, base(y + 0.915 + 2, 11), P.accent)
	y = y + 19.14 + 13
	for i, s in ipairs(stats) do
		font(cr, 12)
		text(cr, s[1], x, base(y, 12) + 0.8, P.muted)
		text(cr, s[2], W - 16, base(y, 12) + 0.8, P.fg, 'r', true)
		bar(cr, x, y + 14.52 + 6, W - 32, 4, s[3])
		y = y + 14.52 + 6 + 4 + 13
	end
	local d = display()
	font(cr, 11)
	local foot = 'HDR ' .. d[1]
	if d[2] then foot = foot .. ' · ' .. d[2] end
	if d[3] then foot = foot .. ' · ' .. d[3] .. ' Hz' end
	text(cr, foot, x, base(y, 11) + 0.7, P.muted)
end

-- Gaming (270 wide): GPU first, GameMode and scheduler state
function L.gaming(cr)
	local W, x, y = 270, 18, 18
	local H = 18 + 59.31 + 14 + 116.5 + 14 + 55.56 + 18
	card(cr, 0, 0, W, H, 14)
	local g = gpu() or { 0, 0, 0, 0 }
	font(cr, 11, 600)
	text(cr, 'GPU', x, base(y, 11) + 0.7, P.muted, 'l', false, 0.88)
	font(cr, 44, nil, 'Space Grotesk SemiBold')
	text(cr, string.format('%d°', g[2]), x, sgbase(y + 15.31, 44, 44), P.fg, 'l', true)
	font(cr, 12)
	text(cr, string.format('%d%% load', g[1]), W - 18, base(y + 59.31 - 31.04, 12) + 0.8, P.fg, 'r', true)
	local sub = {}
	if g[5] then sub[#sub + 1] = string.format('%.2f GHz', g[5]) end
	if g[6] then sub[#sub + 1] = string.format('%d W', g[6]) end
	text(cr, table.concat(sub, ' · '), W - 18, base(y + 59.31 - 14.52, 12) + 0.8, P.muted, 'r', true)
	y = y + 59.31 + 14
	local mu, mt = mem()
	local cp, ct = cpu_pct(), cpu_temp()
	local tiles = {
		{ 'VRAM', g[4] > 0 and string.format('%s / %s GB', gb(g[3]), string.format('%.0f', g[4] / 1e9)) or '-' },
		{ 'CPU', string.format('%d%%', cp) .. (ct and string.format(' · %d°', ct) or '') },
		{ 'RAM', string.format('%s / %s GB', string.format('%.0f', mu / 1e9), string.format('%.0f', mt / 1e9)) },
		{ 'Fan', g[7] and string.format('%d rpm', g[7]) or '-' },
	}
	local tw = (W - 36 - 10) / 2
	for i, t in ipairs(tiles) do
		local tx = x + ((i - 1) % 2) * (tw + 10)
		local ty = y + math.floor((i - 1) / 2) * (53.25 + 10)
		box(cr, tx, ty, tw, 53.25, 10, P.field)
		font(cr, 11); text(cr, t[1], tx + 10, base(ty + 10, 11) + 0.7, P.muted)
		font(cr, 14, 600); text(cr, t[2], tx + 10, base(ty + 10 + 13.31 + 3, 14) + 0.9, P.fg, 'l', true)
	end
	y = y + 116.5 + 14
	local d = display()
	local rows = {
		{ 'GameMode', gamemode() and 'on' or 'off', gamemode() },
		{ 'Scheduler', scheduler() .. (gamemode() and ' --performance' or ''), false },
		{ 'Display', (d[1] == 'on' and 'HDR' or 'SDR') .. (d[3] and (' · ' .. d[3] .. ' Hz') or ''), false },
	}
	for _, r in ipairs(rows) do
		font(cr, 12); text(cr, r[1], x, base(y, 12) + 0.8, P.muted)
		if r[3] then font(cr, 12, 600); text(cr, r[2], W - 18, base(y, 12) + 0.8, P.accent, 'r')
		else font(cr, 12); text(cr, r[2], W - 18, base(y, 12) + 0.8, P.fg, 'r') end
		y = y + 14.52 + 6
	end
end

-- Clock: big time on the wallpaper, no card
function L.clock(cr)
	local y = 0
	font(cr, 96, nil, 'Space Grotesk SemiBold')
	text(cr, os.date('%H:%M'), 0, sgbase(y, 96, 86.4), P.fg, 'l', true, -3.84)
	y = y + 86.4 + 6
	font(cr, 18, 500)
	text(cr, os.date('%A ') .. tonumber(os.date('%d')) .. os.date(' %B'), 0, base(y, 18) + 1.3, P.accent)
	y = y + 21.8 + 6
	local bits = { uptime() }
	local b = battery(); if b then bits[#bits + 1] = string.format('battery %d%%', b) end
	local u = updates(); if u and u > 0 then bits[#bits + 1] = u .. (u == 1 and ' update' or ' updates') end
	font(cr, 13)
	text(cr, table.concat(bits, ' · '), 0, base(y, 13) + 0.9, P.muted)
end

local function graph(cr, x, y, w, h, t, max)
	box(cr, x, y, w, h, 6, P.field)
	if #t < 2 then return end
	local n = 60
	local function px(i) return x + (n - #t + i - 1) * w / (n - 1) end
	local function py(v) return y + h - math.min(v / max, 1) * (h * 0.94) end
	cairo_save(cr); rrect(cr, x, y, w, h, 6); cairo_clip(cr)
	cairo_move_to(cr, px(1), y + h)
	for i, v in ipairs(t) do cairo_line_to(cr, px(i), py(v)) end
	cairo_line_to(cr, px(#t), y + h); cairo_close_path(cr)
	src(cr, P.accent, 0.18); cairo_fill(cr)
	for i, v in ipairs(t) do if i == 1 then cairo_move_to(cr, px(i), py(v)) else cairo_line_to(cr, px(i), py(v)) end end
	src(cr, P.accent); cairo_set_line_width(cr, 2); cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND); cairo_stroke(cr)
	cairo_restore(cr)
end

-- Graphs (290 wide): the last two minutes of CPU, GPU and network
function L.graphs(cr)
	local W, x, y = 290, 16, 16
	card(cr, 0, 0, W, 289.56, 14)
	local cp = cpu_pct(); push(hist.cpu, cp)
	local g = gpu(); push(hist.gpu, g and g[1] or 0)
	local n = net() or { 0, 0 }; push(hist.net, n[1])
	local nmax = 1048576
	for _, v in ipairs(hist.net) do if v > nmax then nmax = v end end
	local rows = {
		{ 'CPU', string.format('%d%%', cp), hist.cpu, 100 },
		{ 'GPU', string.format('%d%%', g and g[1] or 0), hist.gpu, 100 },
		{ 'Network ↓', rate(n[1]), hist.net, nmax },
	}
	for _, r in ipairs(rows) do
		font(cr, 12)
		text(cr, r[1], x, base(y, 12) + 0.8, P.muted)
		text(cr, r[2], W - 16, base(y, 12) + 0.8, P.fg, 'r', true)
		graph(cr, x, y + 14.52 + 6, 258, 56, r[3], r[4])
		y = y + 76.52 + 14
	end
end

-- Strip: one quiet line along the bottom edge
function L.strip(cr)
	local W = conky_window and conky_window.width or 1408
	card(cr, 0, 0, W, 34, 10)
	local cp, g, mu = cpu_pct(), gpu(), (mem())
	local n = net() or { 0, 0 }
	font(cr, 12)
	local yb = base((34 - 14.52) / 2, 12) + 0.8
	local items = {
		{ { 'CPU ', P.muted }, { string.format('%d%%', cp), P.fg } },
		{ { 'GPU ', P.muted }, { g and string.format('%d%% %d°', g[1], g[2]) or '-', P.fg } },
		{ { 'RAM ', P.muted }, { string.format('%.1fG', mu / 1073741824), P.fg } },
		{ { '↓', P.accent }, { ' ' .. short_rate(n[1]) .. ' ', P.fg }, { '↑', P.accent }, { ' ' .. short_rate(n[2]), P.fg } },
	}
	local widths, total = {}, 0
	for i, it in ipairs(items) do
		local w = 0; for _, p in ipairs(it) do w = w + tadv(cr, p[1]) end
		widths[i] = w; total = total + w
	end
	local gap = (W - 28 - total) / (#items - 1)
	local x = 14
	for i, it in ipairs(items) do
		for _, p in ipairs(it) do x = x + text(cr, p[1], x, yb, p[2], 'l', true) end
		x = x + gap
	end
end

-- Calendar and music (270 wide)
function L.calendar(cr)
	local W, x, y = 270, 16, 16
	local t = os.date('*t')
	local first = os.date('*t', os.time({ year = t.year, month = t.month, day = 1 }))
	local lead = (first.wday + 5) % 7                     -- Monday first
	local days = os.date('*t', os.time({ year = t.year, month = t.month + 1, day = 0 })).day
	local weeks = math.ceil((lead + days) / 7)
	local gridh = (weeks + 1) * 24 + weeks * 2
	local H = 16 + 19.14 + 14 + gridh + 14 + 1 + 12 + 36 + 8 + 3 + 16
	card(cr, 0, 0, W, H, 14)
	font(cr, 15, nil, 'Space Grotesk SemiBold')
	local bl = sgbase(y, 15, 19.14)
	text(cr, os.date('%B %Y'), x, bl, P.fg)
	font(cr, 12)
	text(cr, 'week ' .. tonumber(os.date('%V')), W - 16, bl, P.muted, 'r', true)
	y = y + 19.14 + 14
	local cw = (W - 32 - 12) / 7
	for i, d in ipairs({ 'M', 'T', 'W', 'T', 'F', 'S', 'S' }) do
		font(cr, 11, 600)
		text(cr, d, x + (i - 1) * (cw + 2) + cw / 2, base(y + (24 - 13.31) / 2, 11) + 0.7, P.muted, 'c')
	end
	for d = 1, days do
		local k = lead + d - 1
		local cx = x + (k % 7) * (cw + 2)
		local cy = y + (math.floor(k / 7) + 1) * 26
		local today = d == t.day
		if today then box(cr, cx, cy, cw, 24, 6, P.accent) end
		font(cr, 11, today and 700 or 400, today and 'Inter Bold' or nil)
		text(cr, tostring(d), cx + cw / 2, base(cy + (24 - 13.31) / 2, 11) + 0.7, today and P.on_accent or P.fg, 'c', true)
	end
	y = y + gridh + 14
	src(cr, P.border); cairo_rectangle(cr, x, y, W - 32, 1); cairo_fill(cr)
	y = y + 1 + 12
	local p = player()
	box(cr, x, y, 36, 36, 8, P.pill)
	-- music note (the mockup's line icon, 16 px)
	cairo_save(cr); cairo_translate(cr, x + 10, y + 10); cairo_scale(cr, 16 / 24, 16 / 24)
	cairo_move_to(cr, 9, 18); cairo_line_to(cr, 9, 5); cairo_line_to(cr, 21, 3); cairo_line_to(cr, 21, 16)
	cairo_new_sub_path(cr); cairo_arc(cr, 6, 18, 3, 0, 2 * math.pi)
	cairo_new_sub_path(cr); cairo_arc(cr, 18, 16, 3, 0, 2 * math.pi)
	cairo_restore(cr)
	src(cr, P.accent); cairo_set_line_width(cr, 1.8 * 16 / 24); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
	cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND); cairo_stroke(cr)
	local col = 32.25
	local ty = y + (36 - col) / 2
	font(cr, 13, 600)
	text(cr, p and p[1] or 'Nothing playing', x + 46, base(ty, 13) + 0.9, P.fg)
	font(cr, 12)
	text(cr, p and (p[2] ~= '' and (p[2] .. ' · ' .. p[3]) or p[3]) or 'Start some music', x + 46, base(ty + 15.73 + 2, 12) + 0.8, P.muted)
	y = y + 36 + 8
	bar(cr, x, y, W - 32, 3, p and p[5] > 0 and 100 * p[4] / p[5] or 0)
end

-- ---- entry point --------------------------------------------------------------
function conky_ribbon(layout)
	if conky_window == nil then return end
	local cs = conky_surface and conky_surface() or nil
	if cs == nil then return end
	now = os.time()
	local cr = cairo_create(cs)
	local ok, err = pcall(L[layout] or L.card, cr)
	if not ok then print('ribbon conky: ' .. tostring(err)) end
	cairo_destroy(cr)
end
