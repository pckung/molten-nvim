-- Plays animations (a list of frame image files) in place of molten's image output, with the
-- snacks.nvim image provider. Used by :MoltenToggleAnimation.
--
-- Swapping frames doesn't redraw anything: snacks.nvim shows an image through placeholder cells in
-- the buffer whose colour says which image to show (kitty graphics protocol, unicode placeholders).
-- Pointing the existing placement at another image just changes that, so the layout never moves.
-- Each frame is converted and sent to the terminal once, then reused on every loop.

local M = {}

---@class molten.Player
---@field imgs snacks.image.Image[]
---@field i integer current frame
---@field timer uv.uv_timer_t
---@field missing integer ticks without a visible placement

---@type table<string, molten.Player>
local players = {}

local function placement(id)
  local ok, api = pcall(require, "load_snacks_nvim")
  if not ok or not api or not api.snacks_api then
    return nil
  end
  local p = api.snacks_api.get_placement(id)
  if p and not p.closed then
    return p
  end
end

--- point the placement at another (already loaded) image
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

---@param id string molten's image identifier (the first frame's path)
function M.stop(id)
  local player = players[id]
  if not player then
    return
  end
  players[id] = nil
  player.timer:stop()
  player.timer:close()
  local pl = placement(id)
  if pl then
    show(pl, player.imgs[1]) -- back to the first frame
  end
end

function M.stop_all()
  for id in pairs(players) do
    M.stop(id)
  end
end

--- Start (or stop) playing. Returns true when it's now playing.
---@param id string molten's image identifier (the first frame's path)
---@param files string[] frame image files, in order
---@param interval_ms number time per frame
function M.toggle(id, files, interval_ms)
  if players[id] then
    M.stop(id)
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

  local player = { imgs = imgs, i = 1, missing = 0, timer = assert((vim.uv or vim.loop).new_timer()) }
  players[id] = player
  player.timer:start(
    0,
    math.max(math.floor(interval_ms), 30), -- ~33 fps at most
    vim.schedule_wrap(function()
      if players[id] ~= player then
        return
      end
      local pl = placement(id)
      if not pl then
        -- output hidden or redrawn: wait for it, but give up if it's gone for good (~10 s)
        player.missing = player.missing + 1
        if player.missing * interval_ms > 10000 then
          M.stop(id)
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
      if not (img:ready() and img.sent) then
        return -- still loading: hold the current frame (only during the first loop)
      end
      player.i = next_i
      show(pl, img)
    end)
  )
  return true
end

return M
