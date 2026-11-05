-- Saved outputs (written by molten.remote on every :w) after the file was edited, and without a
-- kernel:
--   * relocate(): put each saved cell back on its code in the current file. Unchanged cells are
--     found by their exact code (wherever they moved); edited cells go to the most similar cell
--     of the file (`# %%` cells in .py, ```{python} chunks in .qmd). Cells that can't be matched
--     are left out.
--   * show() / hide() / toggle(): draw the saved outputs below their cells as read-only virtual
--     text, without connecting to a kernel. Connecting (molten.remote) hides them again and
--     loads the real ones.

local M = {}

local ns = vim.api.nvim_create_namespace("molten-saved-outputs")
local placements = {} ---@type table<integer, table[]> snacks image placements per buffer

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- code cells of the current file as { first, last } (1-based, code lines only)
local function current_cells(lines)
  local cells = {}
  local quarto = false
  for _, l in ipairs(lines) do
    if l:match("^%s*```+%s*{") then
      quarto = true
      break
    end
  end
  if quarto then
    local start
    for i, l in ipairs(lines) do
      if not start and l:match("^%s*```+%s*{") then
        start = i + 1
      elseif start and l:match("^%s*```+%s*$") then
        cells[#cells + 1] = { start, i - 1 }
        start = nil
      end
    end
  else
    local start = 1
    local function close(stop)
      while stop >= start and trim(lines[stop] or "") == "" do
        stop = stop - 1
      end
      local first = start
      while first <= stop and trim(lines[first]) == "" do
        first = first + 1
      end
      if first <= stop then
        cells[#cells + 1] = { first, stop }
      end
    end
    for i, l in ipairs(lines) do
      if l:match("^%s*#%s*%%%%") then
        close(i - 1)
        start = i + 1
      end
    end
    close(#lines)
  end
  return cells
end

--- 0..1: how alike two blocks of code are, by the words (names, numbers, strings) they share, so
--- a changed line still counts for most of its words
local function similarity(a, b)
  local function words(block)
    local count, n = {}, 0
    for _, l in ipairs(block) do
      for w in l:gmatch("[%w_]+") do
        count[w] = (count[w] or 0) + 1
        n = n + 1
      end
    end
    return count, n
  end
  local ca, na = words(a)
  local cb, nb = words(b)
  if na + nb == 0 then
    return 0
  end
  local common = 0
  for w, k in pairs(ca) do
    common = common + math.min(k, cb[w] or 0)
  end
  return 2 * common / (na + nb)
end

--- Move the saved cells onto their code in `lines`. Returns a copy of `data` with the cells that
--- were found, and how many were found unchanged / edited / not at all.
---@return table data, integer unchanged, integer edited, integer lost
function M.relocate(data, lines)
  local taken = {} -- line ranges already given to a cell
  local function free(first, last)
    for _, r in ipairs(taken) do
      if first <= r[2] and last >= r[1] then
        return false
      end
    end
    return true
  end
  local out = vim.deepcopy(data)
  out.cells = {}
  local placed = {} ---@type table<integer, {first: integer, last: integer}>
  local cells = data.cells or {}

  -- 1. exact code, nearest to where the cell was
  for idx, cell in ipairs(cells) do
    local text = cell.text
    if type(text) == "table" and #text > 0 then
      local was = (cell.span and cell.span.begin and cell.span.begin.lineno or 0) + 1
      local best, best_dist
      for i = 1, #lines - #text + 1 do
        local same = true
        for j = 1, #text do
          if lines[i + j - 1] ~= text[j] then
            same = false
            break
          end
        end
        if same and free(i, i + #text - 1) then
          local dist = math.abs(i - was)
          if not best or dist < best_dist then
            best, best_dist = i, dist
          end
        end
      end
      if best then
        placed[idx] = { first = best, last = best + #text - 1, exact = true }
        taken[#taken + 1] = { best, best + #text - 1 }
      end
    end
  end

  -- 2. edited cells: the most similar free cell of the file
  local candidates = {}
  for idx, cell in ipairs(cells) do
    if not placed[idx] and type(cell.text) == "table" and #cell.text > 0 then
      for _, c in ipairs(current_cells(lines)) do
        if free(c[1], c[2]) then
          local score = similarity(cell.text, vim.list_slice(lines, c[1], c[2]))
          if score >= 0.4 then
            candidates[#candidates + 1] = { idx = idx, first = c[1], last = c[2], score = score }
          end
        end
      end
    end
  end
  table.sort(candidates, function(a, b) return a.score > b.score end)
  for _, c in ipairs(candidates) do
    if not placed[c.idx] and free(c.first, c.last) then
      placed[c.idx] = { first = c.first, last = c.last, exact = false }
      taken[#taken + 1] = { c.first, c.last }
    end
  end

  local unchanged, edited, lost = 0, 0, 0
  for idx, cell in ipairs(cells) do
    local p = placed[idx]
    if p then
      local c = vim.deepcopy(cell)
      c.span = {
        begin = { lineno = p.first - 1, colno = 0 },
        ["end"] = { lineno = p.last - 1, colno = #(lines[p.last] or "") },
      }
      c.text = vim.list_slice(lines, p.first, p.last)
      out.cells[#out.cells + 1] = c
      if p.exact then
        unchanged = unchanged + 1
      else
        edited = edited + 1
      end
    elseif cell.execution_count ~= nil or (cell.chunks and #cell.chunks > 0) then
      lost = lost + 1
    end
  end
  out.relocated = true
  return out, unchanged, edited, lost
end

-- showing saved outputs without a kernel -----------------------------------------------------

local function strip_ansi(s)
  return (s:gsub("\27%[[%d;]*m", ""))
end

local function chunk_lines(chunk)
  if chunk.error then
    local e = chunk.error
    local out = { { (e.ename or "Error") .. ": " .. (e.evalue or ""), "DiagnosticError" } }
    for _, tb in ipairs(e.traceback or {}) do
      for _, l in ipairs(vim.split(strip_ansi(tb), "\n", { plain = true })) do
        out[#out + 1] = { l, "DiagnosticError" }
      end
    end
    return out
  end
  local data = chunk.data or {}
  local text = data["text/plain"]
  if type(text) == "table" then
    text = table.concat(text, "")
  end
  if (data["image/png"] or data["image/jpeg"]) then
    return { { "[image: shown after connecting (<leader>jc)]", "Comment" } }, true
  end
  if type(text) == "string" then
    local out = {}
    for _, l in ipairs(vim.split(text:gsub("\n$", ""), "\n", { plain = true })) do
      out[#out + 1] = { strip_ansi(l), "MoltenVirtualText" }
    end
    return out
  end
  if data["text/html"] then
    return { { "[HTML output: shown after connecting]", "Comment" } }
  end
  return {}
end

local function show_image(buf, row, chunk)
  if vim.g.molten_image_provider ~= "snacks.nvim" or not (Snacks and Snacks.image) then
    return false
  end
  local data = chunk.data or {}
  local b64, ext = data["image/png"], "png"
  if not b64 then
    b64, ext = data["image/jpeg"], "jpg"
  end
  if type(b64) == "table" then
    b64 = table.concat(b64, "")
  end
  if type(b64) ~= "string" then
    return false
  end
  local file = vim.fn.tempname() .. "." .. ext
  local ok = pcall(function()
    local fd = assert(io.open(file, "wb"))
    fd:write(vim.base64.decode((b64:gsub("%s", ""))))
    fd:close()
  end)
  if not ok then
    return false
  end
  local pok, placement = pcall(Snacks.image.placement.new, buf, file, {
    inline = true,
    pos = { row + 1, 0 },
    max_width = 80,
    max_height = 20,
  })
  if pok and placement then
    placements[buf] = placements[buf] or {}
    table.insert(placements[buf], placement)
    return true
  end
  return false
end

function M.hide(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  for _, p in ipairs(placements[buf] or {}) do
    pcall(p.close, p)
  end
  placements[buf] = nil
  vim.b[buf].molten_saved_shown = nil
end

--- Draw the cells' saved outputs (`data`, from the save file) below their cells.
---@return integer cells shown, integer unchanged, integer edited, integer lost
function M.show(buf, data)
  M.hide(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local moved, unchanged, edited, lost = M.relocate(data, lines)
  local max = tonumber(vim.g.molten_virt_text_max_lines) or 12
  for _, cell in ipairs(moved.cells) do
    local row = cell.span["end"].lineno
    if (lines[row + 2] or ""):match("^%s*```+%s*$") then
      row = row + 1 -- below the chunk's closing fence in .qmd
    end
    local virt = {}
    local header = string.format("[saved] Out[%s]%s", cell.execution_count and tostring(cell.execution_count) or "?",
      cell.success == false and ": ✗ error" or ":")
    virt[#virt + 1] = { { header, "Comment" } }
    local body, images = {}, {}
    for _, chunk in ipairs(cell.chunks or {}) do
      local cl, is_image = chunk_lines(chunk)
      if is_image then
        images[#images + 1] = chunk
      end
      vim.list_extend(body, cl)
    end
    for i, l in ipairs(body) do
      if i > max then
        virt[#virt + 1] = { { string.format("… %d more lines (connect to see all)", #body - max), "Comment" } }
        break
      end
      virt[#virt + 1] = { l }
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = virt })
    for _, chunk in ipairs(images) do
      show_image(buf, row, chunk)
    end
  end
  vim.b[buf].molten_saved_shown = true
  return #moved.cells, unchanged, edited, lost
end

return M
