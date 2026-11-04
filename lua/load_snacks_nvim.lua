-- loads the snacks.nvim plugin and exposes methods to the python remote plugin
local ok, snacks = pcall(require, "snacks")

if not ok then
  vim.api.nvim_echo({ { "[Molten] `snacks.nvim` not found" } }, true, { err = true })
  return
end

local snacks_api = {}
local images = {}

snacks_api.from_file = function(path, opts)
  -- key by molten's identifier: the inline copy ("virt-<path>") and the output window's copy
  -- (<path>) are separate images. Keying by path made them overwrite each other.
  local id = opts.id or path
  local old = images[id]
  if old and old.placement then
    -- re-drawing an output: remove the image already on screen, or it stays there as a copy
    old.placement:close()
  end
  opts.path = path
  opts.opts = {
    inline = true,
    pos = { opts.y, opts.x },
    -- Control max size by snacks config
    -- FIX check if config has been set by user, use default instead
    max_width = snacks.config.image.doc and snacks.config.image.doc.max_width or 80,
    max_height = snacks.config.image.doc and  snacks.config.image.doc.max_height or 40,
  }
  opts.placement = nil

  images[id] = opts
  return id
end

snacks_api.render = function(identifier)
  local img = images[identifier]

  if img.placement == nil then
    img.placement = Snacks.image.placement.new(img.buffer, img.path, img.opts)
  end
end

snacks_api.clear = function(identifier)
  local img = images[identifier]
  if img and img.placement then
    img.placement:close()
    img.placement = nil
  end
end

--- the snacks placement currently showing an image (used to play animations, see molten.animation)
snacks_api.get_placement = function(identifier)
  local img = images[identifier]
  return img and img.placement or nil
end

snacks_api.clear_all = function()
  for id in pairs(images) do
    snacks_api.clear(id)
  end
end

--- try to estimate actual size based on raw image and snack opts. Actual rendered size is somewhat random but we cannot get it due to it not being available until after render()
snacks_api.image_size = function(identifier)
  local img = images[identifier]
  local size =
    snacks.image.util.fit(img.path, { width = img.opts.max_width, height = img.opts.max_height })
  return size
end

return { snacks_api = snacks_api }
