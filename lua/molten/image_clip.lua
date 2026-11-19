-- Copy an image from a cell's output to the system clipboard, or save it to a file.
-- Used by :MoltenCopyImage and :MoltenSaveImage (rplugin), which pass the image files of the
-- output under the cursor (several: you pick one).

local M = {}

local function pick(paths, prompt, cb)
  if #paths == 1 then
    return cb(paths[1])
  end
  local items = {}
  for i, p in ipairs(paths) do
    items[i] = { i = i, path = p }
  end
  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(it) return string.format("Image %d of %d  (%s)", it.i, #paths, vim.fn.fnamemodify(it.path, ":e")) end,
  }, function(it)
    if it then cb(it.path) end
  end)
end

local function applescript_string(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- convert `src` to PNG in a temporary file (macOS sips, or ImageMagick); nil if neither works
local function to_png(src)
  local out = vim.fn.tempname() .. ".png"
  if vim.fn.executable("sips") == 1 then
    local res = vim.system({ "sips", "-s", "format", "png", src, "--out", out }):wait()
    if res.code == 0 then return out end
  end
  for _, cmd in ipairs({ { "magick", src, out }, { "convert", src, out } }) do
    if vim.fn.executable(cmd[1]) == 1 and vim.system(cmd):wait().code == 0 then
      return out
    end
  end
end

local function copy_one(path)
  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  local cmd
  if vim.fn.has("mac") == 1 then
    local class = ({ png = "«class PNGf»", jpg = "JPEG picture", jpeg = "JPEG picture" })[ext]
    if not class then
      path = to_png(path)
      if not path then
        return vim.notify("[Molten] can't copy a ." .. ext .. " image (no sips or ImageMagick to convert it)",
          vim.log.levels.ERROR)
      end
      class = "«class PNGf»"
    end
    cmd = { "osascript", "-e", "set the clipboard to (read (POSIX file " .. applescript_string(path) .. ") as " .. class .. ")" }
  elseif vim.fn.executable("wl-copy") == 1 then
    cmd = { "sh", "-c", 'wl-copy --type image/png < "$1"', "sh", ext == "png" and path or (to_png(path) or path) }
  elseif vim.fn.executable("xclip") == 1 then
    cmd = { "xclip", "-selection", "clipboard", "-t", "image/png", "-i", ext == "png" and path or (to_png(path) or path) }
  else
    return vim.notify("[Molten] no way to put an image on the clipboard here (install wl-copy or xclip)",
      vim.log.levels.ERROR)
  end
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(res)
    if res.code == 0 then
      vim.notify("[Molten] image copied: paste it with Cmd+V (Ctrl+V) in another app")
    else
      vim.notify("[Molten] couldn't copy the image: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
    end
  end))
end

function M.copy(paths)
  pick(paths, "Copy which image?", copy_one)
end

local function save_one(path, target)
  target = vim.fn.fnamemodify(vim.fn.expand(target), ":p")
  local src_ext = vim.fn.fnamemodify(path, ":e"):lower()
  local ext = vim.fn.fnamemodify(target, ":e"):lower()
  if ext == "" then
    ext = src_ext
    target = target .. "." .. ext
  end
  if vim.fn.filereadable(target) == 1
    and vim.fn.confirm(vim.fn.fnamemodify(target, ":~") .. " exists. Replace it?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
  local same = ext == src_ext or (ext == "jpeg" and src_ext == "jpg") or (ext == "jpg" and src_ext == "jpeg")
  local ok
  if same then
    ok = vim.uv.fs_copyfile(path, target)
  else
    -- another format: macOS sips (png/jpeg/tiff/gif/bmp/pdf...), else ImageMagick
    local fmt = ({ jpg = "jpeg", tif = "tiff" })[ext] or ext
    if vim.fn.executable("sips") == 1 then
      ok = vim.system({ "sips", "-s", "format", fmt, path, "--out", target }):wait().code == 0
    end
    for _, c in ipairs({ "magick", "convert" }) do
      if not ok and vim.fn.executable(c) == 1 then
        ok = vim.system({ c, path, target }):wait().code == 0
      end
    end
  end
  if ok then
    vim.notify("[Molten] image saved to " .. vim.fn.fnamemodify(target, ":~"))
  else
    vim.notify("[Molten] couldn't save the image as ." .. ext .. " (the output is ." .. src_ext .. ")", vim.log.levels.ERROR)
  end
end

--- `target`: a path (its extension picks the format: .png, .jpg, .pdf, ...), or nil to ask
function M.save(paths, target, default)
  pick(paths, "Save which image?", function(path)
    if target and target ~= "" then
      return save_one(path, target)
    end
    vim.ui.input({ prompt = "Save the image as: ", default = default, completion = "file" }, function(t)
      if t and t ~= "" then save_one(path, t) end
    end)
  end)
end

return M
