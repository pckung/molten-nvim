-- Plays animations (a list of frame image files) in place of molten's image output, with the
-- snacks.nvim image provider. Used by :MoltenToggleAnimation.
--
-- Swapping frames doesn't redraw anything: snacks.nvim shows an image through placeholder cells in
-- the buffer whose colour says which image to show (kitty graphics protocol, unicode placeholders).
-- Pointing the existing placement at another image just changes that, so the layout never moves.
-- Each frame is converted and sent to the terminal once, then reused on every loop.

local M = {}

---@class molten.Player
---@field ids string[] molten image identifiers showing this animation (inline, output window)
---@field imgs snacks.image.Image[]
---@field i integer current frame
---@field timer uv.uv_timer_t
---@field missing integer ticks without any visible copy

---@type table<string, molten.Player> keyed by the first frame's file
local players = {}

--- the open snacks placements currently showing this animation (inline and/or output window)
local function placements(ids)
  local ok, api = pcall(require, "load_snacks_nvim")
  if not ok or not api or not api.snacks_api then
    return {}
  end
  local list = {}
  for _, id in ipairs(ids) do
    local p = api.snacks_api.get_placement(id)
    if p and not p.closed then
      table.insert(list, p)
    end
  end
  return list
end

--- point the placement at another (already sent) image
local function show(pl, img)
  if pl.img == img then
    return
  end
  -- detach from the old frame without asking the terminal to delete it: it's needed next loop
  pl.img.placements[pl.id] = nil
  pl.img = img
  img:place(pl)
  pl._state = nil -- make update() re-send the placement
  pl:update()
end

--- make sure the terminal has this frame. snacks.nvim keeps ~200 MB of images in the terminal and
--- marks the oldest as not sent when there are more (long or large animations); send it again.
---@return boolean ready to show
local function ensure_sent(img)
  if img:failed() or not img:ready() then
    return false
  end
  if not img.sent then
    pcall(img.send, img)
  end
  return img.sent == true
end

--- remove a frame from the terminal (image data and placements). Terminals keep a limited amount
--- of image data (Ghostty: 320 MB per screen) and, when it's full, drop older images, including
--- the frames of the animation that is playing: that showed as an empty output with an occasional
--- flash. snacks.nvim sends it again if it's ever shown again.
local function forget(img)
  if img.sent then
    pcall(Snacks.image.terminal.request, { a = "d", d = "I", i = img.id })
    img.sent = false
  end
  img.placements = {}
end

---@param key string the first frame's file
function M.stop(key)
  local player = players[key]
  if not player then
    return
  end
  players[key] = nil
  player.timer:stop()
  player.timer:close()
  local first = player.imgs[1]
  if first and ensure_sent(first) then
    for _, pl in ipairs(placements(player.ids)) do
      show(pl, first) -- back to the first frame
    end
  end
  -- the other frames aren't shown anymore: free the terminal's memory for them
  for i = 2, #player.imgs do
    if player.imgs[i] ~= first then
      forget(player.imgs[i])
    end
  end
end

function M.stop_all()
  for key in pairs(players) do
    M.stop(key)
  end
  require("molten.animation_text").stop_all()
end

--- What the players are doing, for troubleshooting: `:lua require("molten.animation").status()`
function M.status()
  local env = Snacks and Snacks.image and Snacks.image.terminal.env() or {}
  local lines = {
    string.format("terminal: %s | placeholders: %s | nvim %s", tostring(env.name), tostring(env.placeholders),
      tostring(vim.version())),
  }
  if not next(players) then
    table.insert(lines, "no animation is playing")
  end
  for key, p in pairs(players) do
    local frames, readable = {}, 0
    for _, img in ipairs(p.imgs) do
      -- S = in the terminal, r = loaded but not sent, . = loading, F = failed
      frames[#frames + 1] = img:failed() and "F" or img:ready() and (img.sent and "S" or "r") or "."
      readable = readable + (vim.fn.filereadable(img.src) == 1 and 1 or 0)
    end
    local vis = {}
    for _, id in ipairs(p.ids) do
      local api = require("load_snacks_nvim").snacks_api
      local pl = api.get_placement(id)
      vis[#vis + 1] = (id:match("^virt%-") and "inline" or "window") .. "="
        .. (pl and (pl.closed and "closed" or ("open, showing image " .. pl.img.id)) or "none")
    end
    table.insert(lines, string.format("%s: frame %d/%d [%s], %d/%d frame files on disk, %s, %s",
      vim.fn.fnamemodify(key, ":t"), p.i, #p.imgs, table.concat(frames), readable, #p.imgs,
      p.loading and "loading" or (p.timer:is_active() and "playing" or "stopped"), table.concat(vis, ", ")))
  end
  local text = table.concat(lines, "\n")
  vim.notify(text)
  return text
end

--- ImageMagick command: { "magick", sub } (v7) or { sub } (v6), or nil
local function magick(sub)
  if vim.fn.executable("magick") == 1 then
    return { "magick", sub }
  elseif vim.fn.executable(sub) == 1 then
    return { sub }
  end
end

--- Lower the frames' resolution, in place, keeping their size on screen (snacks sizes images by
--- pixels / dpi): to `dpi`, and further when all frames together would take more than `budget_mb`
--- of the terminal's image memory (it stores them decoded, 4 bytes per pixel). Only shrinks;
--- skips when ImageMagick or the frame's dpi is unknown.
local function shrink(files, dpi, budget_mb, done)
  local identify, mogrify = magick("identify"), magick("mogrify")
  if not identify or not mogrify then
    return done()
  end
  local out = {}
  vim.fn.jobstart(vim.list_extend(identify, { "-format", "%x %U %w %h", files[1] }), {
    stdout_buffered = true,
    on_stdout = function(_, data) out = data end,
    on_exit = function(_, code)
      local x, units, w, h = (out[1] or ""):match("^([%d.]+)%s+(%S+)%s+(%d+)%s+(%d+)")
      local current = tonumber(x)
      if code ~= 0 or not current or current <= 0 or units == "Undefined" then
        return done() -- no resolution stored in the image: leave it
      end
      if units == "PixelsPerCentimeter" then
        current = current * 2.54
      end
      local target = (dpi and dpi > 0) and math.min(dpi, current) or current
      local bytes = tonumber(w) * tonumber(h) * 4 * #files * (target / current) ^ 2
      local budget = (budget_mb or 150) * 1024 * 1024
      if bytes > budget then
        target = target * math.sqrt(budget / bytes)
      end
      target = math.max(math.floor(target), 12)
      if target >= current - 0.5 then
        return done() -- already small enough
      end
      local cmd = vim.list_extend(mogrify, { "-units", "PixelsPerInch", "-resample", tostring(target) })
      vim.fn.jobstart(vim.list_extend(cmd, files), {
        on_exit = function(_, rc)
          if rc ~= 0 then
            vim.notify("[Molten] couldn't lower the animation's resolution; playing it as is", vim.log.levels.WARN)
          end
          done()
        end,
      })
    end,
  })
end

local function play(key, player, interval_ms)
  player.timer:start(
    0,
    math.max(math.floor(interval_ms), 30), -- ~33 fps at most
    vim.schedule_wrap(function()
      if players[key] ~= player then
        return
      end
      local visible = placements(player.ids)
      if #visible == 0 then
        -- output hidden or being redrawn: wait for it, but give up if it's gone for good (~10 s)
        player.missing = player.missing + 1
        if player.missing * interval_ms > 10000 then
          M.stop(key)
        end
        return
      end
      player.missing = 0
      local imgs = player.imgs
      local next_i = player.i % #imgs + 1
      local img = imgs[next_i]
      if img:failed() then
        player.i = next_i -- skip a frame that couldn't be loaded
        return
      end
      if not ensure_sent(img) then
        return -- evicted and being sent again
      end
      player.i = next_i
      for _, pl in ipairs(visible) do
        show(pl, img)
      end
    end)
  )
end

--- Load (convert + send to the terminal) every frame, then start playing. The output keeps showing
--- the first frame until then.
local function load_then_play(key, player, interval_ms)
  local started = (vim.uv or vim.loop).now()
  player.timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      if players[key] ~= player then
        return
      end
      local loaded, failed = 0, 0
      for i, img in ipairs(player.imgs) do
        if img:failed() then
          failed = failed + 1
        elseif player.sent_once[i] or ensure_sent(img) then
          player.sent_once[i] = true -- may get evicted later; playback sends it again then
          loaded = loaded + 1
        end
      end
      if loaded + failed < #player.imgs then
        if (vim.uv or vim.loop).now() - started > 120000 then
          M.stop(key)
          vim.notify("[Molten] the animation's frames took too long to load", vim.log.levels.ERROR)
        end
        return
      end
      player.timer:stop()
      if loaded == 0 then
        M.stop(key)
        vim.notify("[Molten] couldn't load the animation's frames (" .. tostring(player.imgs[1].file) .. ")",
          vim.log.levels.ERROR)
        return
      end
      player.loading = false
      vim.notify(string.format("[Molten] playing %d frames%s", loaded,
        failed > 0 and (" (" .. failed .. " couldn't be loaded)") or ""))
      play(key, player, interval_ms)
    end)
  )
end

--- Start (or stop) playing. Returns true when it's now loading/playing.
---@param ids string[] molten's identifiers for the image (inline "virt-<file>", window "<file>")
---@param files string[] frame image files, in order
---@param interval_ms number time per frame
---@param mode? "image"|"text" image: in place, in the output (snacks.nvim); text: coloured
---  text characters in a pop-up window (works in any terminal). Default: vim.g.molten_animation_mode
function M.toggle(ids, files, interval_ms, mode)
  local key = files[1]
  local text = require("molten.animation_text")
  if players[key] or text.playing(key) then
    M.stop(key)
    text.stop(key)
    return false
  end
  mode = mode or vim.g.molten_animation_mode or "image"
  if mode == "text" then
    return text.start(key, files, interval_ms)
  end
  if not (Snacks and Snacks.image) then
    vim.notify("[Molten] playing animations needs snacks.nvim", vim.log.levels.WARN)
    return false
  end

  local player = {
    ids = ids,
    imgs = {},
    i = 1,
    missing = 0,
    loading = true,
    sent_once = {},
    timer = assert((vim.uv or vim.loop).new_timer()),
  }
  players[key] = player
  -- lower resolution = smaller frames = faster to load and send, same size on screen
  local dpi = tonumber(vim.g.molten_animation_dpi or 72)
  shrink(files, dpi, tonumber(vim.g.molten_animation_max_mb or 150), function()
    vim.schedule(function()
      if players[key] ~= player then
        return -- stopped meanwhile
      end
      for i, file in ipairs(files) do
        player.imgs[i] = Snacks.image.image.new(file) -- converts and sends in the background
      end
      load_then_play(key, player, interval_ms)
    end)
  end)
  return true
end

--- :MoltenSaveAnimation without a path: ask for one
function M.ask_save_path(default)
  vim.ui.input({
    prompt = "Save the animation as (.gif .mp4 .html, or folder/): ",
    default = vim.fn.fnamemodify(default, ":~"),
    completion = "file",
  }, function(path)
    if path and path ~= "" then
      vim.cmd("MoltenSaveAnimation " .. vim.fn.fnameescape(path))
    end
  end)
end

--- Assemble the frames (original resolution, written by :MoltenSaveAnimation into `tmpdir`)
--- into a gif (ImageMagick) or a video (ffmpeg), in the background
---@param files string[]
---@param interval_ms number
---@param target string
---@param tmpdir string removed afterwards
function M.save(files, interval_ms, target, tmpdir)
  local ext = vim.fn.fnamemodify(target, ":e"):lower()
  local fps = interval_ms > 0 and 1000 / interval_ms or 10
  local cmd, missing
  if ext == "gif" then
    local im = vim.fn.executable("magick") == 1 and { "magick" } or vim.fn.executable("convert") == 1 and { "convert" }
    if im then
      -- -delay is in 1/100 s; loop forever; only store what changes between frames (smaller file)
      cmd = vim.list_extend(vim.list_extend(im, { "-delay", tostring(math.max(1, math.floor(interval_ms / 10 + 0.5))), "-loop", "0" }), files)
      vim.list_extend(cmd, { "-layers", "Optimize", target })
    else
      missing = "ImageMagick (brew install imagemagick)"
    end
  else
    if vim.fn.executable("ffmpeg") == 1 then
      local frame_ext = vim.fn.fnamemodify(files[1], ":e")
      cmd = {
        "ffmpeg", "-y", "-loglevel", "error", "-framerate", string.format("%.4f", fps),
        "-i", tmpdir .. "/frame_%05d." .. frame_ext,
        -- even width/height, needed by most video players
        "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2:color=white",
      }
      if ext == "webm" then
        vim.list_extend(cmd, { "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "30" })
      else
        vim.list_extend(cmd, { "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18" })
      end
      table.insert(cmd, target)
    else
      missing = "ffmpeg (brew install ffmpeg); or save as .gif"
    end
  end
  if not cmd then
    vim.fn.delete(tmpdir, "rf")
    vim.notify("[Molten] saving as ." .. ext .. " needs " .. missing, vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format("[Molten] saving %d frames to %s ...", #files, vim.fn.fnamemodify(target, ":~")))
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      vim.fn.delete(tmpdir, "rf")
      if res.code == 0 then
        vim.notify("[Molten] saved the animation to " .. vim.fn.fnamemodify(target, ":~"))
      else
        vim.notify("[Molten] couldn't save the animation:\n" .. (res.stderr or ""), vim.log.levels.ERROR)
      end
    end)
  end)
end

return M
