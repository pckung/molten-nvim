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

---@param key string the first frame's file
function M.stop(key)
  local player = players[key]
  if not player then
    return
  end
  players[key] = nil
  player.timer:stop()
  player.timer:close()
  if ensure_sent(player.imgs[1]) then
    for _, pl in ipairs(placements(player.ids)) do
      show(pl, player.imgs[1]) -- back to the first frame
    end
  end
end

function M.stop_all()
  for key in pairs(players) do
    M.stop(key)
  end
end

--- Start (or stop) playing. Returns true when it's now playing.
---@param ids string[] molten's identifiers for the image (inline "virt-<file>", window "<file>")
---@param files string[] frame image files, in order
---@param interval_ms number time per frame
function M.toggle(ids, files, interval_ms)
  local key = files[1]
  if players[key] then
    M.stop(key)
    return false
  end
  if not (Snacks and Snacks.image) then
    vim.notify("[Molten] playing animations needs snacks.nvim", vim.log.levels.WARN)
    return false
  end

  local imgs = {}
  for i, file in ipairs(files) do
    imgs[i] = Snacks.image.image.new(file) -- converts and sends to the terminal in the background
  end

  local player = { ids = ids, imgs = imgs, i = 1, missing = 0, timer = assert((vim.uv or vim.loop).new_timer()) }
  players[key] = player
  player.timer:start(
    0,
    math.max(math.floor(interval_ms), 30), -- ~33 fps at most
    vim.schedule_wrap(function()
      if players[key] ~= player then
        return
      end
      local visible = placements(ids)
      if #visible == 0 then
        -- output hidden or being redrawn: wait for it, but give up if it's gone for good (~10 s)
        player.missing = player.missing + 1
        if player.missing * interval_ms > 10000 then
          M.stop(key)
        end
        return
      end
      player.missing = 0
      local next_i = player.i % #imgs + 1
      local img = imgs[next_i]
      if img:failed() then
        player.i = next_i -- skip a frame that couldn't be loaded
        return
      end
      if not ensure_sent(img) then
        return -- still loading: hold the current frame (only during the first loop)
      end
      player.i = next_i
      for _, pl in ipairs(visible) do
        show(pl, img)
      end
    end)
  )
  return true
end

return M
