-- :MoltenOpenVideo: play an animation from a cell's output as a real video, in a video player
-- outside Neovim (full frame rate and quality, nothing to load into the terminal).
--
-- The video always goes to the same file (g:molten_video_file, default
-- stdpath("cache")/molten/molten-animation.mp4), so it is remembered: :MoltenOpenVideo on a cell
-- without an animation (or after a restart) opens it again, and opening another cell's animation
-- replaces it and reloads the player. A small .json next to it says which animation it holds, so
-- the same one isn't encoded twice.
--
-- Players (g:molten_video_player): "auto" (mpv if installed, else QuickTime on macOS, else the
-- system's default app), "mpv", "quicktime", "quicklook" (macOS Quick Look), "open" (the default
-- app; can't be closed from Neovim), or a list such as { "vlc", "--loop" } (the file is added at
-- the end; closed by stopping the process).

local M = {}

---@type {backend: string, job: vim.SystemObj?, id: string?}?
local current

function M.file()
  local f = vim.g.molten_video_file
  if type(f) == "string" and f ~= "" then
    return vim.fn.fnamemodify(vim.fn.expand(f), ":p")
  end
  return vim.fn.stdpath("cache") .. "/molten/molten-animation.mp4"
end

local function meta_file()
  return M.file() .. ".json"
end

---@return {id: string?, source: string?, time: integer?}
function M.meta()
  local fd = io.open(meta_file(), "r")
  if not fd then
    return {}
  end
  local ok, data = pcall(vim.json.decode, fd:read("*a"))
  fd:close()
  return ok and type(data) == "table" and data or {}
end

local function write_meta(data)
  local fd = io.open(meta_file(), "w")
  if fd then
    fd:write(vim.json.encode(data))
    fd:close()
  end
end

local function backend()
  local p = vim.g.molten_video_player
  if type(p) == "table" then
    return "command"
  end
  if p and p ~= "" and p ~= "auto" then
    return p
  end
  if vim.fn.executable("mpv") == 1 then
    return "mpv"
  elseif vim.fn.has("mac") == 1 then
    return "quicktime"
  end
  return "open"
end

local function osascript(lines, cb)
  local cmd = { "osascript" }
  for _, l in ipairs(lines) do
    vim.list_extend(cmd, { "-e", l })
  end
  if cb then
    return vim.system(cmd, { text = true }, cb)
  end
  return vim.system(cmd, { text = true }):wait(3000)
end

local function applescript_string(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- macOS: give the focus back to the terminal, so you can keep typing (g:molten_video_focus)
local function refocus_terminal()
  if vim.g.molten_video_focus ~= "terminal" or vim.fn.has("mac") == 0 then
    return
  end
  local apps = { ghostty = "Ghostty", ["iTerm.app"] = "iTerm", Apple_Terminal = "Terminal", WezTerm = "WezTerm" }
  local app = apps[vim.env.TERM_PROGRAM or ""] or (vim.env.KITTY_PID and "kitty")
  if app then
    vim.defer_fn(function() vim.system({ "open", "-a", app }) end, 700)
  end
end

--- is the player (that this Neovim opened) still showing the video?
function M.is_open()
  if not current then
    return false
  end
  if current.backend == "quicktime" then
    local res = osascript({
      'if application "QuickTime Player" is not running then return 0',
      'tell application "QuickTime Player" to return count of (every document whose name starts with '
        .. applescript_string(vim.fn.fnamemodify(M.file(), ":t:r")) .. ")",
    })
    local open = res.code == 0 and (tonumber(vim.trim(res.stdout or "")) or 0) > 0
    if not open then
      current = nil
    end
    return open
  end
  if current.job then
    return true -- cleared by the job's exit callback
  end
  return false
end

function M.close()
  local was = current
  current = nil
  if not was then
    return false
  end
  if was.backend == "quicktime" then
    osascript({
      'if application "QuickTime Player" is running then',
      '  tell application "QuickTime Player"',
      "    close (every document whose name starts with " .. applescript_string(vim.fn.fnamemodify(M.file(), ":t:r")) .. ") saving no",
      "    if (count of documents) is 0 then quit",
      "  end tell",
      "end if",
    }, function() end)
  elseif was.job then
    pcall(was.job.kill, was.job, 15)
  end
  return true
end

local function spawn(cmd, id)
  local entry = { backend = backend(), id = id }
  local ok, job = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      if current == entry then
        current = nil
      end
      if res.code ~= 0 and res.signal == 0 then
        local err = vim.trim(res.stderr or "")
        if err ~= "" then
          vim.notify("[Molten] the video player stopped: " .. err, vim.log.levels.WARN)
        end
      end
    end)
  end)
  if not ok then
    vim.notify("[Molten] couldn't start " .. cmd[1] .. ": " .. tostring(job), vim.log.levels.ERROR)
    return false
  end
  entry.job = job
  current = entry
  return true
end

--- open the remembered video in the player (closing what this Neovim had open)
---@param id string? the animation it holds
---@param again boolean? opened from a cell without an animation: say which one it is
function M.open(id, again)
  local file = M.file()
  if vim.fn.filereadable(file) == 0 then
    vim.notify("[Molten] no video yet: put the cursor on a cell with an animation", vim.log.levels.WARN)
    return false
  end
  M.close()
  local b = backend()
  local how
  if b == "mpv" then
    -- loops, on top of other windows, 85% of the screen; q (or this key again) closes it
    spawn({ "mpv", "--loop-file=inf", "--ontop", "--autofit=85%x85%", "--force-window=yes",
      "--title=molten animation", "--keep-open=yes", file }, id)
    how = "mpv: q or the same key closes it, <Space> pauses"
  elseif b == "quicklook" then
    spawn({ "qlmanage", "-p", file }, id)
    how = "Quick Look: <Space>/<Esc> or the same key closes it"
  elseif b == "quicktime" then
    -- QuickTime: open, loop and play; it doesn't keep a process we could stop, so it's closed
    -- by name
    local res = osascript({
      'tell application "QuickTime Player"',
      "  activate",
      "  set d to open POSIX file " .. applescript_string(file),
      "  set looping of d to true",
      "  play d",
      "end tell",
    })
    if res.code ~= 0 then
      vim.notify("[Molten] QuickTime couldn't open the video: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
      return false
    end
    current = { backend = "quicktime", id = id }
    how = "QuickTime: ⌘W or the same key closes it, <Space> pauses"
  elseif b == "command" then
    local cmd = vim.deepcopy(vim.g.molten_video_player)
    table.insert(cmd, file)
    spawn(cmd, id)
    how = cmd[1] .. ": the same key closes it"
  else
    vim.ui.open(file)
    how = "opened in the default app (close it there)"
  end
  refocus_terminal()
  local what = "the animation"
  if again then
    local source = M.meta().source
    what = "the last animation" .. (source and (" (from " .. source .. ")") or "")
  end
  vim.notify("[Molten] playing " .. what .. " in " .. how)
  return true
end

--- Encode the frames (written into `tmpdir`, removed afterwards) into the remembered video file,
--- then open it.
---@param files string[]
---@param interval_ms number
---@param tmpdir string
---@param id string which animation it is
---@param source string? the file it came from (shown by :MoltenOpenVideo on a cell without one)
function M.encode_and_open(files, interval_ms, tmpdir, id, source)
  local file = M.file()
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local part = vim.fn.fnamemodify(file, ":r") .. ".part.mp4"
  M.close() -- the player may hold the old file
  require("molten.animation").save(files, interval_ms, part, tmpdir, function(ok)
    if not ok then
      return
    end
    vim.fn.delete(file)
    if vim.fn.rename(part, file) ~= 0 then
      vim.notify("[Molten] couldn't write " .. file, vim.log.levels.ERROR)
      return
    end
    write_meta({ id = id, source = source, time = os.time() })
    M.open(id)
  end)
end

--- current state, for :MoltenOpenVideo (Python side)
function M.state()
  local meta = M.meta()
  return {
    open = M.is_open(),
    open_id = current and current.id or vim.NIL,
    file = M.file(),
    exists = vim.fn.filereadable(M.file()) == 1,
    stored_id = meta.id or vim.NIL,
    source = meta.source or vim.NIL,
  }
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("molten_video", { clear = true }),
  callback = function()
    if current and current.backend ~= "quicktime" then
      M.close() -- don't leave a player running without Neovim; QuickTime is left open
    end
  end,
})

return M
