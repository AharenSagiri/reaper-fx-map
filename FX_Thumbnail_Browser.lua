---@diagnostic disable: undefined-global
-- FX Thumbnail Browser / FX Map for REAPER
--
-- Features:
--   * Keyword search across name, identifier, type, group, and vendor
--   * Sidebar filters: Favorites, plugin type (VST3/VST2/CLAP/JS/AU), group, vendor
--   * Collapsible sidebar sections with persistent state
--   * Thumbnail grid with lazy image loading
--   * Per-card "Shot" button to capture a plugin GUI into the thumbnail cache
--   * Right-click context menu: add FX, toggle favorite, assign manual group
--   * Double-click to add FX to selected track
--   * Persistent data: favorites, manual groups, auto-group rules
--   * Single-instance enforcement with toolbar toggle sync
--
-- Data directory:  REAPER resource path / FXMap
-- Thumbnail cache:  REAPER resource path / FXMap / Thumbs
-- Screenshot dependency: js_ReaScriptAPI extension

------------------------------------------------------------
-- Constants
------------------------------------------------------------

local SECTION = "FXMap"

-- Path separator (Windows: "\", macOS: "/")
local SEP = package.config:sub(1, 1)
local RESOURCE = reaper.GetResourcePath()
local BASE_DIR = RESOURCE .. SEP .. "FXMap"
local THUMB_DIR = BASE_DIR .. SEP .. "Thumbs"

-- Persistence files
local FAVORITES_FILE = BASE_DIR .. SEP .. "favorites.txt"
local MANUAL_GROUP_FILE = BASE_DIR .. SEP .. "manual_groups.txt"
local GROUP_RULE_FILE = BASE_DIR .. SEP .. "group_rules.txt"

------------------------------------------------------------
-- UI layout constants
------------------------------------------------------------

local UI_MARGIN = 18
local TOP_H = 72

-- Sidebar
local LEFT_W = 224
local SIDEBAR_PAD = 12
local SIDEBAR_ITEM_H = 26
local SIDEBAR_HEADER_H = 26
local SIDEBAR_SECTION_GAP = 12
local SCROLLBAR_W = 7

-- Plugin cards / thumbnails
local CARD_W = 440
local CARD_H = 284
local THUMB_H = 252
local PAD = 18

-- Modern flat black/gray theme
local RADIUS_SM = 5
local RADIUS_MD = 7
local RADIUS_LG = 8

local C = {
  bg = { 0.045, 0.047, 0.052 },
  top = { 0.064, 0.066, 0.072 },
  sidebar = { 0.055, 0.057, 0.063 },
  surface = { 0.092, 0.095, 0.104 },
  surface_hover = { 0.135, 0.138, 0.150 },
  surface_active = { 0.190, 0.196, 0.212 },
  thumb = { 0.070, 0.073, 0.080 },
  stroke = { 0.185, 0.190, 0.205 },
  stroke_soft = { 0.115, 0.120, 0.132 },
  text = { 0.900, 0.910, 0.925 },
  text_muted = { 0.620, 0.640, 0.670 },
  text_dim = { 0.390, 0.405, 0.430 },
  accent = { 0.640, 0.665, 0.710 },
  accent_dim = { 0.310, 0.325, 0.350 },
  gold = { 1.000, 0.780, 0.250 },
  warning = { 0.900, 0.740, 0.340 },
}

-- Mouse wheel scroll amounts (px per notch)
local WHEEL_STEP_SIDEBAR = 50
local WHEEL_STEP_GRID = 80

-- gfx image slots are limited (0–1023); allocate on demand
local MAX_IMG_SLOTS = 1023
local img_slot_next = 0

-- FX thumbnail capture
local CAPTURE_WAIT_SECONDS = 1.0
local CAPTURE_TIMEOUT_SECONDS = 5.0
local TEMP_CAPTURE_TRACK_NAME = "FX Map Thumbnail Capture"

------------------------------------------------------------
-- Runtime state
------------------------------------------------------------

local scroll = 0
local search_text = ""
local search_focus = false

local active_type = "All"
local active_group = "All"
local active_vendor = "All"

local last_add_track_guid = reaper.GetExtState(SECTION, "last_add_track_guid") or ""
local last_add_insert_index = tonumber(reaper.GetExtState(SECTION, "last_add_insert_index")) or nil

local vendor_filters = { "All" }
local sidebar_scroll = 0

-- Click / double-click tracking
local mouse_down_prev = false
local right_down_prev = false
local last_click_time = 0
local last_click_key = ""

-- Scrollbar drag state
local scrollbar_drag_target = nil
local scrollbar_drag_start_y = 0
local scrollbar_drag_start_scroll = 0

-- Persistent data caches
local fxs = {}          -- All enumerated FX entries
local filtered = {}     -- Post-filter result set
local favorites = {}    -- key → boolean
local manual_groups = {} -- key → group name
local group_rules = {}  -- { group, keywords[] }

-- Thumbnail capture state
local capture_job = nil
local status_message = ""
local status_until = 0

------------------------------------------------------------
-- Sidebar filter lists
------------------------------------------------------------

local type_filters = {
  "All",
  "Favorites",
  "VST3",
  "VST2",
  "CLAP",
  "JS",
  "AU",
  "Instrument"
}

local group_filters = {
  "All",
  "Instrument",
  "EQ",
  "Dynamics",
  "Reverb",
  "Delay",
  "Saturation",
  "Modulation",
  "Pitch",
  "Meter",
  "Utility",
  "Other"
}

-- Persisted to ExtState so collapse survives script restarts
local collapsed_sections = {
  Favorites = false,
  Type = false,
  Group = false,
  Vendor = false
}

------------------------------------------------------------
-- Single-instance enforcement + toolbar toggle sync
------------------------------------------------------------

local _, _, sectionID, cmdID = reaper.get_action_context()

local function set_toolbar_state(state)
  if sectionID and cmdID and cmdID ~= 0 then
    reaper.SetToggleCommandState(sectionID, cmdID, state)
    reaper.RefreshToolbar2(sectionID, cmdID)
  end
end

-- If another instance is already running, signal it to close and exit
if reaper.GetExtState(SECTION, "running") == "1" then
  reaper.SetExtState(SECTION, "close", "1", false)
  return
end

reaper.SetExtState(SECTION, "running", "1", false)
reaper.SetExtState(SECTION, "close", "0", false)
set_toolbar_state(1)

-- Cleanup on exit: persist dock state, clear running flag
reaper.atexit(function()
  local dock_state = gfx.dock(-1)
  reaper.SetExtState(SECTION, "dock_state", tostring(dock_state), true)
  reaper.SetExtState(SECTION, "running", "0", false)
  reaper.SetExtState(SECTION, "close", "0", false)
  set_toolbar_state(0)
end)

------------------------------------------------------------
-- Utility helpers
------------------------------------------------------------

local function clamp(v, min_v, max_v)
  if v < min_v then return min_v end
  if v > max_v then return max_v end
  return v
end

local function lower(s)
  return string.lower(s or "")
end

local function contains(haystack, needle)
  return lower(haystack):find(lower(needle), 1, true) ~= nil
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

--- Read non-empty lines from a file into a table.
local function read_lines(path)
  local t = {}
  local f = io.open(path, "r")
  if not f then return t end

  for raw_line in f:lines() do
    local line = raw_line:gsub("\r", "")  -- strip CR for cross-platform compat
    if line ~= "" then
      table.insert(t, line)
    end
  end

  f:close()
  return t
end

--- Write a table of strings to a file, one per line.
local function write_lines(path, lines)
  local f = io.open(path, "w")
  if not f then return end

  for _, line in ipairs(lines) do
    f:write(line .. "\n")
  end

  f:close()
end

local function set_status(message, seconds)
  status_message = message or ""
  status_until = reaper.time_precise() + (seconds or 2.5)
end

local function status_is_active()
  return status_message ~= "" and reaper.time_precise() < status_until
end

--- Sanitize an FX identifier into a safe filename for thumbnail storage.
local function sanitize_filename(s)
  s = s:gsub("[\\/:*?\"<>|]", "_")   -- replace filesystem-illegal chars
  s = s:gsub("%s+", "_")             -- collapse whitespace
  s = s:gsub("[^%w%._%-_]", "_")     -- replace remaining non-safe chars
  if #s > 120 then
    s = s:sub(1, 120)                -- truncate to avoid path-too-long
  end
  return s
end

--- Strip REAPER's plugin-type prefix from a plugin name.
--  e.g. "VST3: Pro-Q 3 (FabFilter)" → "Pro-Q 3 (FabFilter)"
local function strip_fx_prefix(s)
  s = s:gsub("^VST3i:%s*", "")
  s = s:gsub("^VST3:%s*", "")
  s = s:gsub("^VSTi:%s*", "")
  s = s:gsub("^VST:%s*", "")
  s = s:gsub("^CLAPi:%s*", "")
  s = s:gsub("^CLAP:%s*", "")
  s = s:gsub("^AUi:%s*", "")
  s = s:gsub("^AU:%s*", "")
  s = s:gsub("^JS:%s*", "")
  return s
end

------------------------------------------------------------
-- Sidebar collapse persistence
------------------------------------------------------------

local function load_collapsed_sections()
  for name, _ in pairs(collapsed_sections) do
    collapsed_sections[name] =
      reaper.GetExtState(SECTION, "collapsed_" .. name) == "1"
  end
end

-- Persist a single section's collapse state (avoids writing all four every frame)
local function save_collapsed_section(name)
  reaper.SetExtState(
    SECTION,
    "collapsed_" .. name,
    collapsed_sections[name] and "1" or "0",
    true
  )
end

------------------------------------------------------------
-- FX name / type / vendor parsing
------------------------------------------------------------

--- Derive the cleaned display name (no prefix) from the raw REAPER name.
local function clean_plugin_display_name(name)
  return strip_fx_prefix(name or "")
end

--- Determine plugin format and whether it is an instrument.
--  Returns: fx_type ("VST3"|"VST2"|"CLAP"|"JS"|"AU"|"Other"), is_instrument (bool)
local function parse_fx_type(name)
  local n = lower(name)
  if n:match("^vst3i:") then return "VST3", true
  elseif n:match("^vst3:") then return "VST3", false
  elseif n:match("^vsti:") then return "VST2", true
  elseif n:match("^vst:") then return "VST2", false
  elseif n:match("^clapi:") then return "CLAP", true
  elseif n:match("^clap:") then return "CLAP", false
  elseif n:match("^js:") then return "JS", false
  elseif n:match("^aui:") then return "AU", true
  elseif n:match("^au:") then return "AU", false
  end
  return "Other", false
end

--- Attempt to extract the vendor name from the trailing parenthesised segment.
--  e.g. "Pro-Q 3 (FabFilter)" → "FabFilter"
--  Returns "JS" for JS plugins, "Unknown" when no vendor is detected.
local function parse_vendor_from_fx_name(name)
  local s = strip_fx_prefix(name or "")

  -- Match the last parenthesised group on the line
  local vendor = s:match("%(([^%)]+)%)%s*$")
  if vendor and vendor ~= "" then
    vendor = vendor:gsub("^%s+", ""):gsub("%s+$", "")

    -- Filter out text that is almost certainly not a vendor name
    local v_lower = lower(vendor)
    if v_lower:find("out") then return "Unknown" end
    if v_lower:find("in") then return "Unknown" end
    if v_lower:find("mono") then return "Unknown" end
    if v_lower:find("stereo") then return "Unknown" end
    if v_lower:find("range") then return "Unknown" end
    if v_lower:match("^%d") then return "Unknown" end
    return vendor
  end

  -- JS plugins have no vendor — group them under "JS"
  if lower(name):match("^js:") then
    return "JS"
  end

  return "Unknown"
end

------------------------------------------------------------
-- Vendor filter list
------------------------------------------------------------

local function rebuild_vendor_filters()
  local map = {}
  vendor_filters = { "All" }
  local has_unknown = false

  for _, fx in ipairs(fxs) do
    local vendor = fx.vendor or "Unknown"
    if vendor == "Unknown" or vendor == "" then
      has_unknown = true
    else
      map[vendor] = true
    end
  end

  -- Sorted alphabetically; "Unknown" always pinned to the end
  local vendors = {}
  for vendor, _ in pairs(map) do
    table.insert(vendors, vendor)
  end
  table.sort(vendors, function(a, b) return lower(a) < lower(b) end)

  for _, vendor in ipairs(vendors) do
    table.insert(vendor_filters, vendor)
  end

  if has_unknown then
    table.insert(vendor_filters, "Unknown")
  end
end

------------------------------------------------------------
-- Group rules (auto-classification)
------------------------------------------------------------

--- Write the default group-rule file when it does not yet exist.
local function create_default_group_rules()
  if file_exists(GROUP_RULE_FILE) then return end

  local lines = {
    "# Format: GroupName|keyword1,keyword2,keyword3",
    "Instrument|synth,sampler,piano,keys,bass,drum,kick,snare,violin,guitar,orchestra,kontakt,serum,omnisphere",
    "EQ|eq,equalizer,filter,pro-q,channel strip",
    "Dynamics|compressor,comp,limiter,limit,maximizer,gate,expander,de-ess,deess,clipper",
    "Reverb|reverb,room,hall,plate,space,verb",
    "Delay|delay,echo,tape delay",
    "Saturation|saturation,saturator,distortion,distort,overdrive,drive,tape,tube,amp",
    "Modulation|chorus,flanger,phaser,tremolo,vibrato,ensemble,modulator",
    "Pitch|pitch,tune,autotune,melodyne,vocalign,harmonizer",
    "Meter|meter,analyzer,scope,loudness,spectrum,vu",
    "Utility|gain,trim,pan,phase,utility,router,send,mix",
  }
  write_lines(GROUP_RULE_FILE, lines)
end

--- Parse group_rules.txt into the `group_rules` table.
--  Format:  GroupName|keyword1,keyword2,...
--  Lines starting with '#' are comments.
local function load_group_rules()
  create_default_group_rules()
  group_rules = {}

  for _, line in ipairs(read_lines(GROUP_RULE_FILE)) do
    if not line:match("^#") then
      local group, keywords = line:match("^([^|]+)|(.+)$")
      if group and keywords then
        local rule = { group = group, keywords = {} }
        for raw_kw in keywords:gmatch("[^,]+") do
          local kw = raw_kw:gsub("^%s+", ""):gsub("%s+$", "")
          if kw ~= "" then
            table.insert(rule.keywords, lower(kw))
          end
        end
        table.insert(group_rules, rule)
      end
    end
  end
end

--- Classify an FX based on group-rule keyword matching.
--  Instruments are always classified first; the rest match against rule keywords.
local function auto_group_for_fx(fx)
  if fx.is_instrument then
    return "Instrument"
  end

  -- Search both the display name and the internal identifier
  local n = lower(fx.name .. " " .. fx.ident)
  for _, rule in ipairs(group_rules) do
    for _, kw in ipairs(rule.keywords) do
      if n:find(kw, 1, true) then
        return rule.group
      end
    end
  end

  return "Other"
end

--- Recompute the final group for every FX.
--  Manual groups take priority; auto-group is the fallback.
local function rebuild_groups()
  for _, fx in ipairs(fxs) do
    fx.auto_group = auto_group_for_fx(fx)
    fx.group = manual_groups[fx.key] or fx.auto_group
  end
end

------------------------------------------------------------
-- Favorites persistence
------------------------------------------------------------

local function load_favorites()
  favorites = {}
  for _, key in ipairs(read_lines(FAVORITES_FILE)) do
    favorites[key] = true
  end
end

local function save_favorites()
  local lines = {}
  for key, state in pairs(favorites) do
    if state then table.insert(lines, key) end
  end
  table.sort(lines)
  write_lines(FAVORITES_FILE, lines)
end

local function toggle_favorite(fx)
  favorites[fx.key] = not favorites[fx.key]
  save_favorites()
end

------------------------------------------------------------
-- Manual group persistence
------------------------------------------------------------

local function load_manual_groups()
  manual_groups = {}
  for _, line in ipairs(read_lines(MANUAL_GROUP_FILE)) do
    local key, group = line:match("^(.+)|([^|]+)$")
    if key and group then
      manual_groups[key] = group
    end
  end
end

local function save_manual_groups()
  local lines = {}
  for key, group in pairs(manual_groups) do
    if group and group ~= "" then
      table.insert(lines, key .. "|" .. group)
    end
  end
  table.sort(lines)
  write_lines(MANUAL_GROUP_FILE, lines)
end

--- Assign (or clear) a manual group override for an FX.
--  Passing "Auto" or "" removes the manual override so auto-group takes effect.
local function set_manual_group(fx, group)
  if group == "Auto" or group == "" then
    manual_groups[fx.key] = nil
  else
    manual_groups[fx.key] = group
  end
  save_manual_groups()
end

------------------------------------------------------------
-- FX enumeration
------------------------------------------------------------

--- Enumerate all installed FX via the REAPER API and build the `fxs` table.
local function enum_fx()
  fxs = {}
  filtered = {}
  img_slot_next = 0

  local i = 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end

    local key = ident ~= "" and ident or name
    local fx_type, is_instrument = parse_fx_type(name)
    local vendor = parse_vendor_from_fx_name(name)
    local display_name = clean_plugin_display_name(name)
    local filename = sanitize_filename(key) .. ".png"

    table.insert(fxs, {
      name = name,
      vendor = vendor,
      display_name = display_name,
      ident = ident or "",
      key = key,
      fx_type = fx_type,
      is_instrument = is_instrument,
      thumb_file = THUMB_DIR .. SEP .. filename,
      thumb_name = filename,
      img = nil,           -- lazy-loaded gfx slot (nil = not tried, -1 = failed)
      auto_group = "Other",
      group = "Other",
    })

    i = i + 1
  end

  table.sort(fxs, function(a, b) return lower(a.name) < lower(b.name) end)

  rebuild_groups()
  rebuild_vendor_filters()
end

------------------------------------------------------------
-- Filtering
------------------------------------------------------------

--- Rebuild `filtered` from `fxs` based on search text + sidebar selections.
local function apply_filter()
  filtered = {}
  local q = lower(search_text)

  for _, fx in ipairs(fxs) do
    local ok = true

    -- Keyword search across all relevant fields
    if q ~= "" then
      local searchable = lower(
        fx.name .. " " .. fx.ident .. " " .. fx.fx_type
        .. " " .. fx.group .. " " .. fx.vendor
      )
      if not searchable:find(q, 1, true) then
        ok = false
      end
    end

    -- Type filter (All / Favorites / plugin format / Instrument)
    if ok and active_type ~= "All" then
      if active_type == "Favorites" then
        ok = favorites[fx.key] == true
      elseif active_type == "Instrument" then
        ok = fx.is_instrument == true
      else
        ok = fx.fx_type == active_type
      end
    end

    -- Group filter
    if ok and active_group ~= "All" then
      ok = fx.group == active_group
    end

    -- Vendor filter
    if ok and active_vendor ~= "All" then
      ok = fx.vendor == active_vendor
    end

    if ok then
      table.insert(filtered, fx)
    end
  end

  scroll = math.max(0, scroll)
end

local function reset_filter()
  search_text = ""
  active_type = "All"
  active_group = "All"
  active_vendor = "All"
  scroll = 0
  sidebar_scroll = 0
  apply_filter()
end

local function sidebar_filter_is_clear()
  return active_type == "All" and active_group == "All" and active_vendor == "All"
end

local function set_sidebar_filter(kind, value)
  active_type = "All"
  active_group = "All"
  active_vendor = "All"

  if value ~= "All" then
    if kind == "type" then
      active_type = value
    elseif kind == "group" then
      active_group = value
    elseif kind == "vendor" then
      active_vendor = value
    end
  end

  scroll = 0
  apply_filter()
end

local function active_filter_label()
  if active_type ~= "All" then return active_type end
  if active_group ~= "All" then return active_group end
  if active_vendor ~= "All" then return active_vendor end
  return "All"
end

------------------------------------------------------------
-- Add FX to track
------------------------------------------------------------

--- Return the first selected track, or create one at the end of the project.
local function get_track_guid(track)
  if track and reaper.GetTrackGUID then
    return reaper.GetTrackGUID(track)
  end
  return ""
end

local function find_track_by_guid(guid)
  if guid == "" then return nil end

  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if get_track_guid(track) == guid then
      return track
    end
  end

  return nil
end

local function get_target_track()
  local tr = reaper.GetSelectedTrack(0, 0)
  if tr then return tr end

  tr = find_track_by_guid(last_add_track_guid)
  if tr then return tr end

  local count = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(count, true)
  return reaper.GetTrack(0, count)
end

local function get_insert_index_for_track(track)
  local count = reaper.TrackFX_GetCount(track)
  local guid = get_track_guid(track)

  if guid ~= "" and guid == last_add_track_guid and last_add_insert_index then
    return clamp(math.floor(last_add_insert_index), 0, count)
  end

  return count
end

local function save_last_add_position(track, fx_index)
  local guid = get_track_guid(track)
  if guid == "" or not fx_index or fx_index < 0 then return end

  last_add_track_guid = guid
  last_add_insert_index = math.min(fx_index + 1, reaper.TrackFX_GetCount(track))

  reaper.SetExtState(SECTION, "last_add_track_guid", last_add_track_guid, true)
  reaper.SetExtState(SECTION, "last_add_insert_index", tostring(last_add_insert_index), true)
end

local function add_fx_to_track(fx)
  local tr = get_target_track()
  if not tr then return end

  local insert_index = get_insert_index_for_track(tr)

  reaper.Undo_BeginBlock()
  local fx_index = reaper.TrackFX_AddByName(tr, fx.name, false, -1000 - insert_index)
  reaper.Undo_EndBlock("Add FX from FX Map", -1)
  if fx_index and fx_index >= 0 then
    save_last_add_position(tr, fx_index)
    reaper.defer(function()
      reaper.TrackFX_Show(tr, fx_index, 3)
    end)
  end
end

------------------------------------------------------------
-- Thumbnail image loading (lazy, slot-based)
------------------------------------------------------------

--- Load thumbnail for a single FX, or return the cached result.
--  Returns the gfx image slot number, or -1 if no thumbnail is available.
--  Uses -1 as a "tried and failed" sentinel to avoid repeated disk I/O.
local function load_thumb(fx)
  if fx.img ~= nil then
    return fx.img
  end

  if not file_exists(fx.thumb_file) then
    fx.img = -1
    return -1
  end

  if img_slot_next > MAX_IMG_SLOTS then
    fx.img = -1
    return -1
  end

  local slot = img_slot_next
  img_slot_next = img_slot_next + 1

  local loaded = gfx.loadimg(slot, fx.thumb_file)
  fx.img = (loaded == -1) and -1 or slot
  return fx.img
end

--- Reset all cached image slots (e.g. after thumbnails were regenerated).
local function reload_thumbnails()
  img_slot_next = 0
  for _, fx in ipairs(fxs) do
    fx.img = nil
  end
end

------------------------------------------------------------
-- Thumbnail capture
------------------------------------------------------------

local function capture_api_available()
  return reaper.JS_Window_GetRect
    and reaper.JS_Window_SetForeground
    and reaper.JS_Window_SetFocus
    and reaper.JS_GDI_GetWindowDC
    and reaper.JS_GDI_Blit
    and reaper.JS_GDI_ReleaseDC
    and reaper.JS_LICE_CreateBitmap
    and reaper.JS_LICE_GetDC
    and reaper.JS_LICE_WritePNG
    and reaper.JS_LICE_DestroyBitmap
end

local function track_is_valid(track)
  return track and (not reaper.ValidatePtr2 or reaper.ValidatePtr2(0, track, "MediaTrack*"))
end

local function save_track_selection()
  local selected = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    table.insert(selected, reaper.GetSelectedTrack(0, i))
  end
  return selected
end

local function restore_track_selection(selected)
  for i = 0, reaper.CountTracks(0) - 1 do
    reaper.SetTrackSelected(reaper.GetTrack(0, i), false)
  end

  for _, track in ipairs(selected or {}) do
    if track_is_valid(track) then
      reaper.SetTrackSelected(track, true)
    end
  end
end

local function cleanup_capture_job(job)
  if not job then return end

  if track_is_valid(job.track) then
    if job.fx_index then
      reaper.TrackFX_Show(job.track, job.fx_index, 2)
    end
    reaper.DeleteTrack(job.track)
  end

  restore_track_selection(job.selected_tracks)
  reaper.UpdateArrange()
end

local function capture_window_to_png(hwnd, filename)
  local ok, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
  if not ok then
    return false, "无法读取插件窗口尺寸。"
  end

  local src_x = 0
  local src_y = 0
  local w = right - left
  local h = bottom - top

  if w <= 0 or h <= 0 then
    return false, "插件窗口尺寸无效。"
  end

  -- Windows 10/11 会把不可见边框计入窗口矩形；裁掉后缩略图更干净。
  if lower(reaper.GetOS()):find("win") then
    src_x = 8
    w = math.max(1, w - 16)
    h = math.max(1, h - 8)
  end

  reaper.JS_Window_SetForeground(hwnd)
  reaper.JS_Window_SetFocus(hwnd)

  local src_dc = reaper.JS_GDI_GetWindowDC(hwnd)
  if not src_dc then
    return false, "无法读取插件窗口画面。"
  end

  local dest_bmp = reaper.JS_LICE_CreateBitmap(true, w, h)
  if not dest_bmp then
    reaper.JS_GDI_ReleaseDC(hwnd, src_dc)
    return false, "无法创建截图缓存。"
  end

  local dest_dc = reaper.JS_LICE_GetDC(dest_bmp)
  if not dest_dc then
    reaper.JS_GDI_ReleaseDC(hwnd, src_dc)
    reaper.JS_LICE_DestroyBitmap(dest_bmp)
    return false, "无法创建截图绘制目标。"
  end

  reaper.JS_GDI_Blit(dest_dc, 0, 0, src_dc, src_x, src_y, w, h)
  reaper.JS_LICE_WritePNG(filename, dest_bmp, false)

  reaper.JS_GDI_ReleaseDC(hwnd, src_dc)
  reaper.JS_LICE_DestroyBitmap(dest_bmp)

  if file_exists(filename) then
    return true
  end

  return false, "截图文件没有写入。"
end

local function finish_capture_job(ok, message)
  local job = capture_job
  capture_job = nil

  cleanup_capture_job(job)

  if ok then
    reload_thumbnails()
    set_status("截图已保存：" .. job.fx.thumb_name, 3)
  else
    set_status(message or "截图失败。", 4)
  end
end

local function start_thumbnail_capture(fx)
  if capture_job then
    set_status("正在截图，请稍等。", 2)
    return
  end

  if not capture_api_available() then
    local message = "截图功能需要安装 js_ReaScriptAPI 扩展。"
    reaper.MB(message .. "\n可通过 ReaPack 安装：ReaTeam Extensions / js_ReaScriptAPI。", "FX Map", 0)
    set_status(message, 4)
    return
  end

  reaper.RecursiveCreateDirectory(THUMB_DIR, 0)

  local selected_tracks = save_track_selection()
  local track_index = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(track_index, false)

  local track = reaper.GetTrack(0, track_index)
  if not track then
    restore_track_selection(selected_tracks)
    set_status("无法创建临时轨道。", 4)
    return
  end

  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", TEMP_CAPTURE_TRACK_NAME, true)

  local fx_index = reaper.TrackFX_AddByName(track, fx.name, false, -1)
  if not fx_index or fx_index < 0 then
    reaper.DeleteTrack(track)
    restore_track_selection(selected_tracks)
    set_status("无法加载插件：" .. fx.display_name, 4)
    return
  end

  reaper.TrackFX_Show(track, fx_index, 3)

  local now = reaper.time_precise()
  capture_job = {
    fx = fx,
    track = track,
    fx_index = fx_index,
    selected_tracks = selected_tracks,
    next_try_at = now + CAPTURE_WAIT_SECONDS,
    deadline = now + CAPTURE_TIMEOUT_SECONDS,
  }

  set_status("正在打开插件窗口：" .. fx.display_name, CAPTURE_WAIT_SECONDS + 1.5)
end

local function update_capture_job()
  if not capture_job then return end

  local now = reaper.time_precise()
  if now < capture_job.next_try_at then return end

  if now > capture_job.deadline then
    finish_capture_job(false, "截图超时：没有找到插件浮窗。")
    return
  end

  local hwnd = reaper.TrackFX_GetFloatingWindow(capture_job.track, capture_job.fx_index)
  if not hwnd then
    capture_job.next_try_at = now + 0.1
    return
  end

  local ok, captured, message = pcall(capture_window_to_png, hwnd, capture_job.fx.thumb_file)
  if not ok then
    finish_capture_job(false, "截图失败：" .. tostring(captured))
    return
  end

  finish_capture_job(captured, message)
end

reaper.atexit(function()
  if capture_job then
    cleanup_capture_job(capture_job)
    capture_job = nil
  end
end)

------------------------------------------------------------
-- Drawing primitives
------------------------------------------------------------

--- Edge-triggered left-click: true only on the frame the button goes down.
local function mouse_clicked()
  local down = (gfx.mouse_cap & 1) == 1
  return down and not mouse_down_prev
end

--- Edge-triggered right-click.
local function right_clicked()
  local down = (gfx.mouse_cap & 2) == 2
  return down and not right_down_prev
end

local function point_in_rect(x, y, w, h)
  return gfx.mouse_x >= x and gfx.mouse_x <= x + w
     and gfx.mouse_y >= y and gfx.mouse_y <= y + h
end

local function draw_color_rect(x, y, w, h, color, alpha, filled)
  gfx.set(color[1], color[2], color[3], alpha or 1)
  gfx.rect(x, y, w, h, filled)
end

local function draw_round_rect(x, y, w, h, radius, color, alpha, filled)
  radius = math.max(0, math.min(radius or 0, math.floor(math.min(w, h) / 2)))
  gfx.set(color[1], color[2], color[3], alpha or 1)

  if radius <= 0 then
    gfx.rect(x, y, w, h, filled)
    return
  end

  if filled then
    gfx.rect(x + radius, y, w - radius * 2, h, true)
    gfx.rect(x, y + radius, w, h - radius * 2, true)
    gfx.circle(x + radius, y + radius, radius, true, true)
    gfx.circle(x + w - radius, y + radius, radius, true, true)
    gfx.circle(x + radius, y + h - radius, radius, true, true)
    gfx.circle(x + w - radius, y + h - radius, radius, true, true)
  elseif gfx.roundrect then
    gfx.roundrect(x, y, w, h, radius, true)
  else
    gfx.rect(x, y, w, h, false)
  end
end

local function draw_text(text, x, y, cr, cg, cb, ca)
  gfx.set(cr or 0.9, cg or 0.9, cb or 0.9, ca or 1)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(text)
end

local function draw_text_color(text, x, y, color, alpha)
  draw_text(text, x, y, color[1], color[2], color[3], alpha or 1)
end

local function draw_text_centered(text, x, y, w, h, color, alpha)
  local tw, th = gfx.measurestr(text)
  draw_text_color(
    text,
    x + math.floor((w - tw) * 0.5),
    y + math.floor((h - th) * 0.5),
    color,
    alpha
  )
end

--- Draw a standard button. Returns true on click.
local function draw_button(label, x, y, w, h, active)
  local hover = point_in_rect(x, y, w, h)

  if active then
    draw_round_rect(x, y, w, h, RADIUS_SM, C.surface_active, 1, true)
    draw_round_rect(x, y, w, h, RADIUS_SM, C.accent_dim, 1, false)
  elseif hover then
    draw_round_rect(x, y, w, h, RADIUS_SM, C.surface_hover, 1, true)
    draw_round_rect(x, y, w, h, RADIUS_SM, C.stroke, 1, false)
  else
    draw_round_rect(x, y, w, h, RADIUS_SM, C.surface, 1, true)
    draw_round_rect(x, y, w, h, RADIUS_SM, C.stroke_soft, 1, false)
  end

  draw_text_centered(label, x, y, w, h, active and C.text or C.text_muted, 1)

  return hover and mouse_clicked()
end

--- Generic vertical scrollbar supporting click-to-track and drag.
--  @param id       string discriminator ("sidebar" | "grid") to avoid cross-talk
--  @param current  current scroll offset
--  @param max_val  maximum scroll offset (0 = scrollbar hidden)
--  @return         updated scroll offset
local function draw_vertical_scrollbar(id, x, y, w, h, current, max_val)
  if max_val <= 0 then
    return current
  end

  local mouse_down = (gfx.mouse_cap & 1) == 1
  local mouse_pressed = mouse_down and not mouse_down_prev

  -- Track background
  draw_round_rect(x, y, w, h, math.floor(w * 0.5), C.stroke_soft, 0.75, true)

  local content_h = h + max_val
  local thumb_h = math.max(28, h * (h / content_h))
  local movable_h = h - thumb_h

  local thumb_y = y
  if max_val > 0 and movable_h > 0 then
    thumb_y = y + movable_h * (current / max_val)
  end

  local thumb_hover =
    gfx.mouse_x >= x and gfx.mouse_x <= x + w
    and gfx.mouse_y >= thumb_y and gfx.mouse_y <= thumb_y + thumb_h

  local track_hover =
    gfx.mouse_x >= x and gfx.mouse_x <= x + w
    and gfx.mouse_y >= y and gfx.mouse_y <= y + h

  -- Click on thumb → begin drag
  if mouse_pressed and thumb_hover then
    scrollbar_drag_target = id
    scrollbar_drag_start_y = gfx.mouse_y
    scrollbar_drag_start_scroll = current
  end

  -- Click on track (not thumb) → jump to approximate position
  if mouse_pressed and track_hover and not thumb_hover then
    local ratio = clamp((gfx.mouse_y - y - thumb_h * 0.5) / movable_h, 0, 1)
    current = ratio * max_val
    scrollbar_drag_target = id
    scrollbar_drag_start_y = gfx.mouse_y
    scrollbar_drag_start_scroll = current
  end

  -- Drag in progress
  if scrollbar_drag_target == id then
    if mouse_down then
      local delta_y = gfx.mouse_y - scrollbar_drag_start_y
      current = clamp(
        scrollbar_drag_start_scroll + (delta_y / movable_h) * max_val,
        0, max_val
      )
      thumb_y = y + movable_h * (current / max_val)
    else
      scrollbar_drag_target = nil
    end
  end

  -- Thumb colour: dragging > hover > idle
  if scrollbar_drag_target == id then
    draw_round_rect(x, thumb_y, w, thumb_h, math.floor(w * 0.5), C.accent, 1, true)
  elseif thumb_hover then
    draw_round_rect(x, thumb_y, w, thumb_h, math.floor(w * 0.5), C.text_muted, 1, true)
  else
    draw_round_rect(x, thumb_y, w, thumb_h, math.floor(w * 0.5), C.text_dim, 1, true)
  end

  return current
end

------------------------------------------------------------
-- Search box
------------------------------------------------------------

local function draw_search_box()
  local x = UI_MARGIN
  local y = 18
  local w = 350
  local h = 30

  local hover = point_in_rect(x, y, w, h)

  -- Clicking outside the search box releases focus
  if mouse_clicked() then
    search_focus = hover
  end

  if search_focus then
    draw_round_rect(x, y, w, h, RADIUS_MD, C.surface_active, 1, true)
    draw_round_rect(x, y, w, h, RADIUS_MD, C.accent_dim, 1, false)
  elseif hover then
    draw_round_rect(x, y, w, h, RADIUS_MD, C.surface_hover, 1, true)
    draw_round_rect(x, y, w, h, RADIUS_MD, C.stroke, 1, false)
  else
    draw_round_rect(x, y, w, h, RADIUS_MD, C.surface, 1, true)
    draw_round_rect(x, y, w, h, RADIUS_MD, C.stroke_soft, 1, false)
  end

  local display = search_text
  if display == "" and not search_focus then
    draw_text_color("Search FX...", x + 12, y + 8, C.text_dim, 1)
  else
    local cursor = search_focus and "_" or ""
    draw_text_color(display .. cursor, x + 12, y + 8, C.text, 1)
  end

  local clear_x = x + w + 12
  if draw_button("Clear", clear_x, y, 62, h, false) then
    search_text = ""
    scroll = 0
    apply_filter()
  end
end

------------------------------------------------------------
-- Sidebar
------------------------------------------------------------

--- Compute the total content height of the sidebar (all sections, expanded).
local function get_sidebar_content_height()
  local h = SIDEBAR_PAD

  -- Favorites section
  h = h + SIDEBAR_HEADER_H
  if not collapsed_sections.Favorites then
    h = h + SIDEBAR_ITEM_H + 4
  end
  h = h + SIDEBAR_SECTION_GAP

  -- Type section (Favorites item is in its own section above)
  h = h + SIDEBAR_HEADER_H
  if not collapsed_sections.Type then
    for _, t in ipairs(type_filters) do
      if t ~= "Favorites" then
        h = h + SIDEBAR_ITEM_H + 4
      end
    end
  end
  h = h + SIDEBAR_SECTION_GAP

  -- Group section
  h = h + SIDEBAR_HEADER_H
  if not collapsed_sections.Group then
    for _, _ in ipairs(group_filters) do
      h = h + SIDEBAR_ITEM_H + 4
    end
  end
  h = h + SIDEBAR_SECTION_GAP

  -- Vendor section
  h = h + SIDEBAR_HEADER_H
  if not collapsed_sections.Vendor then
    for _, _ in ipairs(vendor_filters) do
      h = h + SIDEBAR_ITEM_H + 4
    end
  end

  h = h + SIDEBAR_PAD
  return h
end

local function get_sidebar_max_scroll()
  local content_h = get_sidebar_content_height()
  local visible_h = gfx.h - TOP_H
  return math.max(0, content_h - visible_h)
end

--- A clickable sidebar filter item. Returns true when clicked.
local function sidebar_item(label, x, y, w, active)
  local hover =
    point_in_rect(x, y, w, SIDEBAR_ITEM_H)
    and gfx.mouse_y > TOP_H
    and scrollbar_drag_target == nil

  if active then
    draw_round_rect(x, y, w, SIDEBAR_ITEM_H, RADIUS_MD, C.surface_active, 1, true)
    draw_round_rect(x + 1, y + 5, 3, SIDEBAR_ITEM_H - 10, 2, C.accent, 1, true)
  elseif hover then
    draw_round_rect(x, y, w, SIDEBAR_ITEM_H, RADIUS_MD, C.surface_hover, 1, true)
  else
    draw_round_rect(x, y, w, SIDEBAR_ITEM_H, RADIUS_MD, C.sidebar, 1, true)
  end

  local text = label
  if #text > 24 then
    text = text:sub(1, 21) .. "..."
  end

  draw_text_color(text, x + 12, y + 6, active and C.text or C.text_muted, 1)
  return hover and mouse_clicked()
end

--- A collapsible sidebar section header. Toggles collapse on click.
local function sidebar_header(label, x, y, w)
  local collapsed = collapsed_sections[label]
  local hover = point_in_rect(x, y, w, SIDEBAR_HEADER_H)
                  and gfx.mouse_y > TOP_H

  if hover then
    draw_round_rect(x, y, w, SIDEBAR_HEADER_H, RADIUS_MD, C.surface, 1, true)
  else
    draw_round_rect(x, y, w, SIDEBAR_HEADER_H, RADIUS_MD, C.sidebar, 1, true)
  end

  local arrow = collapsed and ">" or "v"
  draw_color_rect(x + 3, y + 7, 3, SIDEBAR_HEADER_H - 14, C.stroke, 1, true)
  draw_text_color(label, x + 14, y + 6, C.text_muted, 1)
  draw_text_color(arrow, x + w - 16, y + 6, C.text_dim, 1)

  if hover and mouse_clicked() then
    collapsed_sections[label] = not collapsed_sections[label]
    save_collapsed_section(label)
    sidebar_scroll = clamp(sidebar_scroll, 0, get_sidebar_max_scroll())
    return true
  end

  return false
end

--- Draw the entire sidebar: sections, filter items, and scrollbar.
local function draw_sidebar()
  local x = 0
  local y = TOP_H
  local w = LEFT_W
  local h = gfx.h - TOP_H

  -- Sidebar background + right-edge separator
  draw_color_rect(x, y, w, h, C.sidebar, 1, true)
  draw_color_rect(w - 1, y, 1, h, C.stroke_soft, 1, true)

  local ix = SIDEBAR_PAD
  local iy = TOP_H + SIDEBAR_PAD - sidebar_scroll
  local iw = LEFT_W - SIDEBAR_PAD * 2 - SCROLLBAR_W - 4
  local item_x = ix + 14
  local item_w = iw - 14

  -- ── Favorites ──
  sidebar_header("Favorites", ix, iy, iw)
  iy = iy + SIDEBAR_HEADER_H
  if not collapsed_sections.Favorites then
    if sidebar_item("Favorites", item_x, iy, item_w, active_type == "Favorites") then
      set_sidebar_filter("type", "Favorites")
    end
    iy = iy + SIDEBAR_ITEM_H + 4
  end
  iy = iy + SIDEBAR_SECTION_GAP

  -- ── Type ──
  sidebar_header("Type", ix, iy, iw)
  iy = iy + SIDEBAR_HEADER_H
  if not collapsed_sections.Type then
    for _, t in ipairs(type_filters) do
      if t ~= "Favorites" then
        local active = (t == "All" and sidebar_filter_is_clear())
          or (t ~= "All" and active_type == t)
        if sidebar_item(t, item_x, iy, item_w, active) then
          set_sidebar_filter("type", t)
        end
        iy = iy + SIDEBAR_ITEM_H + 4
      end
    end
  end
  iy = iy + SIDEBAR_SECTION_GAP

  -- ── Group ──
  sidebar_header("Group", ix, iy, iw)
  iy = iy + SIDEBAR_HEADER_H
  if not collapsed_sections.Group then
    for _, g in ipairs(group_filters) do
      local active = g ~= "All" and active_group == g
      if sidebar_item(g, item_x, iy, item_w, active) then
        set_sidebar_filter("group", g)
      end
      iy = iy + SIDEBAR_ITEM_H + 4
    end
  end
  iy = iy + SIDEBAR_SECTION_GAP

  -- ── Vendor ──
  sidebar_header("Vendor", ix, iy, iw)
  iy = iy + SIDEBAR_HEADER_H
  if not collapsed_sections.Vendor then
    for _, vendor in ipairs(vendor_filters) do
      local active = vendor ~= "All" and active_vendor == vendor
      if sidebar_item(vendor, item_x, iy, item_w, active) then
        set_sidebar_filter("vendor", vendor)
      end
      iy = iy + SIDEBAR_ITEM_H + 4
    end
  end

  -- Sidebar scrollbar (right edge of sidebar)
  sidebar_scroll = draw_vertical_scrollbar(
    "sidebar",
    LEFT_W - SCROLLBAR_W - 3,
    TOP_H + 4,
    SCROLLBAR_W,
    gfx.h - TOP_H - 8,
    sidebar_scroll,
    get_sidebar_max_scroll()
  )
end

------------------------------------------------------------
-- Top bar
------------------------------------------------------------

local function draw_top_bar()
  draw_color_rect(0, 0, gfx.w, TOP_H, C.top, 1, true)
  draw_color_rect(0, TOP_H - 1, gfx.w, 1, C.stroke_soft, 1, true)

  draw_search_box()

  local x = UI_MARGIN + 432
  local y = 18

  if draw_button("Reset", x, y, 64, 30, false) then
    reset_filter()
  end

  x = x + 72
  if draw_button("Reload", x, y, 74, 30, false) then
    reload_thumbnails()
  end

  x = x + 82
  if draw_button("Rescan FX", x, y, 96, 30, false) then
    enum_fx()
    apply_filter()
  end

  -- Filtered / total count
  x = x + 112
  draw_text_color(
    "FX: " .. tostring(#filtered) .. " / " .. tostring(#fxs),
    x, y + 8, C.text_muted, 1
  )

  -- Active filter summary line, temporarily replaced by capture/status messages.
  local info
  local info_r, info_g, info_b = C.text_muted[1], C.text_muted[2], C.text_muted[3]

  if capture_job then
    info = "Capturing thumbnail: " .. capture_job.fx.display_name
    info_r, info_g, info_b = C.warning[1], C.warning[2], C.warning[3]
  elseif status_is_active() then
    info = status_message
    info_r, info_g, info_b = C.accent[1], C.accent[2], C.accent[3]
  else
    info = "Filter: " .. active_filter_label()
  end

  if #info > 90 then
    info = info:sub(1, 87) .. "..."
  end
  draw_text(info, UI_MARGIN, 48, info_r, info_g, info_b, 1)
end

------------------------------------------------------------
-- Plugin card grid
------------------------------------------------------------

local function get_grid_max_scroll()
  local grid_x = LEFT_W + UI_MARGIN
  local available_w = math.max(1, gfx.w - grid_x - UI_MARGIN)
  local cols = math.max(1, math.floor(available_w / (CARD_W + PAD)))
  local rows = math.ceil(#filtered / cols)
  local content_h = rows * (CARD_H + PAD)
  local visible_h = gfx.h - TOP_H - PAD
  return math.max(0, content_h - visible_h)
end

--- Placeholder drawn inside a card when no thumbnail image exists.
local function draw_thumb_placeholder(fx, x, y, w, h)
  draw_round_rect(x, y, w, h, RADIUS_MD, C.thumb, 1, true)

  draw_text_color("No thumbnail", x + 14, y + 26, C.text_muted, 1)
  draw_text_color(fx.fx_type, x + 14, y + 55, C.text_dim, 1)
  draw_text_color(fx.group, x + 14, y + 76, C.text_dim, 1)
end

--- Draw a single FX card (thumbnail + metadata + favorite star + context menu).
--  Handles left-click (double-click to add), right-click (context menu),
--  and favorite star toggle.
local function draw_card(fx, index, x, y)
  -- Cull: skip cards entirely above or below the visible area
  if y > gfx.h or y + CARD_H < TOP_H then
    return
  end

  local hover =
    point_in_rect(x, y, CARD_W, CARD_H)
    and gfx.mouse_y > TOP_H
    and gfx.mouse_x > LEFT_W
    and scrollbar_drag_target == nil

  local fav = favorites[fx.key] == true

  -- Card background
  if hover then
    draw_round_rect(x, y, CARD_W, CARD_H, RADIUS_LG, C.surface_hover, 1, true)
  else
    draw_round_rect(x, y, CARD_W, CARD_H, RADIUS_LG, C.surface, 1, true)
  end

  -- Thumbnail area
  local tx = x
  local ty = y
  local tw = CARD_W
  local th = THUMB_H

  local img = load_thumb(fx)
  if img ~= -1 then
    local iw, ih = gfx.getimgdim(img)
    if iw > 0 and ih > 0 then
      gfx.set(1, 1, 1, 1)
      gfx.blit(img, 1, 0, 0, 0, iw, ih, tx, ty, tw, th)
    else
      draw_thumb_placeholder(fx, tx, ty, tw, th)
    end
  else
    draw_thumb_placeholder(fx, tx, ty, tw, th)
  end

  -- Favorite star appears only while hovering, as an overlay on the image.
  if hover then
    local star_x = tx + 10
    local star_y = ty + 9
    local star_hover = point_in_rect(star_x, star_y, 24, 24)

    draw_round_rect(star_x - 4, star_y - 3, 26, 24, RADIUS_SM, C.bg, 0.72, true)
    if fav then
      draw_text_color("★", star_x, star_y, C.gold, 1)
    else
      draw_text_color("☆", star_x, star_y, star_hover and C.text or C.text_muted, 1)
    end

    if star_hover and mouse_clicked() then
      toggle_favorite(fx)
      apply_filter()
      return
    end
  end

  -- Plugin name, directly under the image.
  local name = fx.name
  if #name > 76 then
    name = name:sub(1, 73) .. "..."
  end
  draw_text_color(name, x + 12, y + THUMB_H + 9, C.text, 1)

  -- Capture button: keep the image clean unless hovered or actively capturing.
  local shot_x = x + CARD_W - 58
  local shot_y = y + 9
  local shot_active = capture_job and capture_job.fx == fx
  if hover or shot_active then
    local shot_clicked = draw_button("Shot", shot_x, shot_y, 48, 22, shot_active)
    if shot_clicked and gfx.mouse_y > TOP_H then
      start_thumbnail_capture(fx)
      return
    end
  end

  -- ── Right-click context menu ──
  if hover and right_clicked() then
    local menu = "Add FX|Capture Thumbnail|Toggle Favorite|Group: Auto"
    for _, g in ipairs(group_filters) do
      if g ~= "All" then
        menu = menu .. "|Group: " .. g
      end
    end

    gfx.x = gfx.mouse_x
    gfx.y = gfx.mouse_y
    local choice = gfx.showmenu(menu)

    if choice == 1 then
      add_fx_to_track(fx)
    elseif choice == 2 then
      start_thumbnail_capture(fx)
    elseif choice == 3 then
      toggle_favorite(fx)
      apply_filter()
    elseif choice == 4 then
      set_manual_group(fx, "Auto")
      rebuild_groups()
      apply_filter()
    elseif choice >= 5 then
      -- Map menu index back to the group name (skipping "All" at position 1)
      local group_index = choice - 4
      local groups_without_all = {}
      for _, g in ipairs(group_filters) do
        if g ~= "All" then
          table.insert(groups_without_all, g)
        end
      end
      local group = groups_without_all[group_index]
      if group then
        set_manual_group(fx, group)
        rebuild_groups()
        apply_filter()
      end
    end
    return
  end

  -- ── Left-click / double-click ──
  if hover and mouse_clicked() then
    local now = reaper.time_precise()
    if last_click_key == fx.key and now - last_click_time < 0.35 then
      add_fx_to_track(fx)   -- double-click → add FX
    end
    last_click_key = fx.key
    last_click_time = now
  end
end

--- Draw all visible cards in a grid layout, plus the scrollbar.
local function draw_grid()
  local grid_x = LEFT_W + UI_MARGIN
  local available_w = math.max(1, gfx.w - grid_x - UI_MARGIN)
  local cols = math.max(1, math.floor(available_w / (CARD_W + PAD)))

  local start_y = TOP_H + PAD

  for i, fx in ipairs(filtered) do
    local idx = i - 1
    local col = idx % cols
    local row = math.floor(idx / cols)

    local x = grid_x + col * (CARD_W + PAD)
    local y = start_y + row * (CARD_H + PAD) - scroll

    if y + CARD_H > TOP_H then
      draw_card(fx, i, x, y)
    end
  end

  if #filtered == 0 then
    local grid_x = LEFT_W + UI_MARGIN
    draw_round_rect(grid_x, TOP_H + 18, 260, 54, RADIUS_LG, C.surface, 1, true)
    draw_round_rect(grid_x, TOP_H + 18, 260, 54, RADIUS_LG, C.stroke_soft, 1, false)
    draw_text_color("No FX found.", grid_x + 18, TOP_H + 36, C.text_muted, 1)
  end
end

local function draw_grid_scrollbar()
  local x = gfx.w - SCROLLBAR_W - 4
  local y = TOP_H + 4
  local h = gfx.h - TOP_H - 8

  scroll = draw_vertical_scrollbar(
    "grid", x, y, SCROLLBAR_W, h, scroll, get_grid_max_scroll()
  )
end

------------------------------------------------------------
-- Mouse wheel
------------------------------------------------------------

local function handle_mouse_wheel()
  if gfx.mouse_wheel == 0 then return end

  local wheel = gfx.mouse_wheel
  gfx.mouse_wheel = 0

  -- Top bar does not scroll
  if gfx.mouse_y < TOP_H then return end

  -- Left side → scroll sidebar; right side → scroll grid
  if gfx.mouse_x >= 0 and gfx.mouse_x <= LEFT_W then
    sidebar_scroll = clamp(
      sidebar_scroll - (wheel / 120) * WHEEL_STEP_SIDEBAR,
      0, get_sidebar_max_scroll()
    )
  elseif gfx.mouse_x > LEFT_W then
    scroll = clamp(
      scroll - (wheel / 120) * WHEEL_STEP_GRID,
      0, get_grid_max_scroll()
    )
  end
end

------------------------------------------------------------
-- Keyboard input
------------------------------------------------------------

local function handle_keyboard(char)
  if char < 0 then return false end

  if search_focus then
    if char == 8 then                           -- Backspace
      search_text = search_text:sub(1, -2)
      scroll = 0
      apply_filter()
    elseif char == 27 then                      -- Escape
      search_focus = false
    elseif char == 13 then                      -- Enter
      search_focus = false
    elseif char >= 32 and char <= 126 then      -- Printable ASCII
      search_text = search_text .. string.char(char)
      scroll = 0
      apply_filter()
    end
  else
    if char == 6 then                           -- Ctrl+F → focus search
      search_focus = true
    elseif char == 27 then                      -- Escape
      search_focus = false
    end
  end

  return true
end

------------------------------------------------------------
-- Main frame + loop
------------------------------------------------------------

local function draw_ui()
  handle_mouse_wheel()
  update_capture_job()

  -- Background
  draw_color_rect(0, 0, gfx.w, gfx.h, C.bg, 1, true)

  -- Draw order: grid → sidebar → top bar (overlays cover content)
  draw_grid()
  draw_grid_scrollbar()
  draw_sidebar()
  draw_top_bar()

  -- Store button state for edge detection next frame
  mouse_down_prev = (gfx.mouse_cap & 1) == 1
  right_down_prev = (gfx.mouse_cap & 2) == 2
end

local function loop()
  -- Exit when another instance signals close
  if reaper.GetExtState(SECTION, "close") == "1" then
    return
  end

  local char = gfx.getchar()
  if char < 0 then return end

  handle_keyboard(char)
  draw_ui()
  gfx.update()
  reaper.defer(loop)
end

------------------------------------------------------------
-- Initialisation
------------------------------------------------------------

-- Ensure data directories exist
reaper.RecursiveCreateDirectory(BASE_DIR, 0)
reaper.RecursiveCreateDirectory(THUMB_DIR, 0)

-- Load persisted state
load_collapsed_sections()
load_group_rules()
load_favorites()
load_manual_groups()

-- Enumerate and filter
enum_fx()
apply_filter()

-- Restore dock state and open window
local saved_dock_state = tonumber(reaper.GetExtState(SECTION, "dock_state")) or 1
gfx.init("FX Map", 1100, 520, saved_dock_state)
gfx.dock(saved_dock_state)
gfx.setfont(1, "Segoe UI", 14)

loop()
