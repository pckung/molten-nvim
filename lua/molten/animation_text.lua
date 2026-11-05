-- Plays animations as coloured text in a pop-up window: each character cell is a "▀" whose
-- foreground colour is the upper pixel and background colour the lower one. Less detail than the
-- image player (molten.animation), but it's only text, so it works in any terminal and over ssh
-- and doesn't depend on the terminal's image memory. Used by :MoltenToggleAnimation text.

local M = {}

local ns = vim.api.nvim_create_namespace("molten_animation_text")
local HALF = "▀"

---@class molten.TextPlayer
---@field frames {runs: {[1]: integer, [2]: integer, [3]: integer, [4]: string}[]}[]
---@field width integer
---@field height integer rows of text
---@field i integer
---@field buf integer?
---@field win integer?
---@field timer uv.uv_timer_t
---@field jobs vim.SystemObj[]

---@type table<string, molten.TextPlayer>
local players = {}

-- one highlight group per (upper colour, lower colour) pair, colours reduced to 4096 (4 bits per
-- channel) so there are a few thousand groups at most
local groups = {}
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("molten_animation_text", { clear = true }),
  callback = function() groups = {} end, -- a colour scheme clears them
})

local function hex(c)
  local r, g, b = math.floor(c / 256), math.floor(c / 16) % 16, c % 16
  return string.format("#%02x%02x%02x", r * 17, g * 17, b * 17)
end

local function group(top, bottom)
  local key = top * 4096 + bottom
  local name = groups[key]
  if not name then
    name = string.format("MoltenAnim%03x%03x", top, bottom)
    vim.api.nvim_set_hl(0, name, { fg = hex(top), bg = hex(bottom) })
    groups[key] = name
  end
  return name
end

--- binary PPM (P6, 8 bit) → frame: highlight runs per row
---@return {runs: table}?, integer?, integer?
local function parse_ppm(data)
  local fields, pos = {}, 1
  while #fields < 4 do
    local s, e, tok = data:find("^%s*(%S+)", pos)
    if not s then
      return nil
    end
    fields[#fields + 1] = tok
    pos = e + 1
  end
  if fields[1] ~= "P6" or tonumber(fields[4]) ~= 255 then
    return nil
  end
  local w, h = tonumber(fields[2]), tonumber(fields[3])
  pos = pos + 1 -- the single whitespace before the pixels
  local byte = string.byte
  local function px(x, y) -- 12-bit colour of pixel (x, y), 0-based; white below the image
    if y >= h then
      return 4095
    end
    local i = pos + (y * w + x) * 3
    local r, g, b = byte(data, i, i + 2)
    return math.floor(r / 16) * 256 + math.floor(g / 16) * 16 + math.floor(b / 16)
  end
  local rows = math.ceil(h / 2)
  local runs = {}
  for row = 0, rows - 1 do
    local start, current = 0, nil
    for x = 0, w do
      local g = x < w and group(px(x, row * 2), px(x, row * 2 + 1)) or nil
      if g ~= current then
        if current then
          -- each "▀" is 3 bytes
          runs[#runs + 1] = { row, start * #HALF, x * #HALF, current }
        end
        start, current = x, g
      end
    end
  end
  return { runs = runs }, w, rows
end

local function convert_cmd(file, cols, pixel_rows)
  local args = {
    file, "-background", "white", "-alpha", "remove", "-resize", cols .. "x" .. pixel_rows, "-depth", "8", "ppm:-",
  }
  if vim.fn.executable("magick") == 1 then
    return vim.list_extend({ "magick" }, args)
  elseif vim.fn.executable("convert") == 1 then
    return vim.list_extend({ "convert" }, args)
  end
end

function M.playing(key)
  return players[key] ~= nil
end

function M.stop(key)
  local p = players[key]
  if not p then
    return
  end
  players[key] = nil
  for _, job in ipairs(p.jobs) do
    pcall(job.kill, job, 9)
  end
  p.timer:stop()
  p.timer:close()
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  if p.buf and vim.api.nvim_buf_is_valid(p.buf) then
    pcall(vim.api.nvim_buf_delete, p.buf, { force = true })
  end
end

function M.stop_all()
  for key in pairs(players) do
    M.stop(key)
  end
end

local function draw(p, frame)
  vim.api.nvim_buf_clear_namespace(p.buf, ns, 0, -1)
  local set = vim.api.nvim_buf_set_extmark
  for _, r in ipairs(frame.runs) do
    set(p.buf, ns, r[1], r[2], { end_col = r[3], hl_group = r[4] })
  end
end

local function open(key, p, interval_ms)
  p.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[p.buf].bufhidden = "wipe"
  local line = string.rep(HALF, p.width)
  local lines = {}
  for i = 1, p.height do
    lines[i] = line
  end
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, lines)
  vim.bo[p.buf].modifiable = false
  p.win = vim.api.nvim_open_win(p.buf, true, { -- the cursor moves into it
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - p.height) / 2) - 1),
    col = math.max(0, vim.o.columns - p.width - 4),
    width = p.width,
    height = p.height,
    style = "minimal",
    border = "rounded",
    title = " animation · q close · space pause ",
    title_pos = "center",
    focusable = true,
    noautocmd = true,
  })
  vim.wo[p.win].winhighlight = "Normal:Normal"
  vim.keymap.set("n", "q", function() M.stop(key) end, { buffer = p.buf, nowait = true, desc = "Close the animation" })
  vim.keymap.set("n", "<Esc>", function() M.stop(key) end, { buffer = p.buf, nowait = true, desc = "Close the animation" })
  vim.keymap.set("n", "<Space>", function()
    p.paused = not p.paused
    vim.api.nvim_echo({ { p.paused and "[Molten] paused" or "[Molten] playing" } }, false, {})
  end, { buffer = p.buf, nowait = true, desc = "Pause / resume" })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(p.win),
    once = true,
    callback = function() vim.schedule(function() M.stop(key) end) end,
  })
  draw(p, p.frames[1])
  p.timer:start(
    interval_ms,
    math.max(math.floor(interval_ms), 30),
    vim.schedule_wrap(function()
      if players[key] ~= p or p.paused or not (p.win and vim.api.nvim_win_is_valid(p.win)) then
        return
      end
      p.i = p.i % #p.frames + 1
      draw(p, p.frames[p.i])
    end)
  )
end

--- Convert every frame to text (in the background), then open the pop-up and play
---@return boolean started
function M.start(key, files, interval_ms)
  local cols = math.max(20, math.min(vim.g.molten_animation_text_width or 100, vim.o.columns - 6))
  local rows = math.max(6, math.min(vim.g.molten_animation_text_height or 40, vim.o.lines - 6))
  if not convert_cmd(files[1], cols, rows * 2) then
    vim.notify("[Molten] text animations need ImageMagick (brew install imagemagick)", vim.log.levels.WARN)
    return false
  end
  ---@type molten.TextPlayer
  local p = { frames = {}, width = 0, height = 0, i = 1, jobs = {}, timer = assert((vim.uv or vim.loop).new_timer()) }
  players[key] = p
  local pending, next_file, failed = #files, 1, 0

  local function finish()
    if players[key] ~= p then
      return
    end
    local frames = {}
    for i = 1, #files do
      if p.frames[i] then
        frames[#frames + 1] = p.frames[i]
      end
    end
    p.frames = frames
    if #frames == 0 then
      M.stop(key)
      vim.notify("[Molten] couldn't convert the animation's frames", vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("[Molten] playing %d frames as text%s", #frames,
      failed > 0 and (" (" .. failed .. " couldn't be converted)") or ""))
    open(key, p, interval_ms)
  end

  -- a few conversions at a time
  local function launch()
    if players[key] ~= p or next_file > #files then
      return
    end
    local i = next_file
    next_file = next_file + 1
    local job = vim.system(convert_cmd(files[i], cols, rows * 2), { text = false }, function(res)
      vim.schedule(function()
        if players[key] ~= p then
          return
        end
        local frame, w, h
        if res.code == 0 and res.stdout then
          frame, w, h = parse_ppm(res.stdout)
        end
        if frame then
          p.frames[i] = frame
          p.width, p.height = math.max(p.width, w), math.max(p.height, h)
        else
          failed = failed + 1
        end
        pending = pending - 1
        if pending == 0 then
          finish()
        else
          launch()
        end
      end)
    end)
    table.insert(p.jobs, job)
  end
  for _ = 1, math.min(6, #files) do
    launch()
  end
  return true
end

return M
