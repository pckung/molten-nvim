-- molten.remote: run molten kernels on a remote Jupyter Server reached through SSH port forwarding.
--
--   require("molten.remote").setup({
--     hosts = {
--       mine = { port = 8888 },  -- you forward the port yourself; molten only connects to it
--       gpu = { host = "me@gpu-box", start_server = true, cwd = "~/project" },
--       lab = { host = "lab", remote_port = 8888 }, -- a server that is already running
--     },
--   })
--
--   :MoltenRemoteConnect gpu [kernel]   open the tunnel (and server), then :MoltenInit a new kernel
--   :MoltenRemoteAttach gpu             attach to a kernel already running on that server
--   :MoltenRemoteDisconnect [gpu]       close the tunnel (and stop the server if we started it)
--   :MoltenRemoteStatus                 list connections
--   :MoltenRemoteLog gpu                show ssh / jupyter output for a connection
--
-- See docs/Remote-Jupyter-Server.md for details.

local uv = vim.uv or vim.loop

local M = {}

local defaults = {
  -- ssh executable and options passed to every connection
  ssh = "ssh",
  ssh_args = {
    "-o", "ExitOnForwardFailure=yes",
    "-o", "ServerAliveInterval=30",
    -- neovim can't answer password prompts; use keys / ssh-agent / ControlMaster instead
    "-o", "BatchMode=yes",
  },
  -- command that starts the server on the remote machine (start_server = true). molten adds
  -- --no-browser, --ip and --port. The token is passed in the JUPYTER_TOKEN env var.
  jupyter_cmd = "jupyter server",
  -- shell code run on the remote before any jupyter command, e.g. "source ~/venv/bin/activate"
  prelude = nil,
  -- seconds to wait for the tunnel/server to come up
  startup_timeout = 60,
  -- run :MoltenInit once the connection is up
  auto_init = true,
  -- leave kernels running on the server when neovim exits / :MoltenDeinit, so that
  -- :MoltenRemoteConnect can reattach to them later (like VS Code). Kernels of a server started
  -- by molten (start_server = true) still go away when the server is stopped.
  keep_kernels = true,
  -- save cell outputs whenever you write a file that uses a remote kernel, and show them again
  -- the next time you connect from that file (like outputs stored in a notebook). Saved to
  -- stdpath("data")/molten-remote/, without the server token.
  save_outputs = true,
  -- name of the Jupyter session for a buffer. Connecting from a buffer whose session already
  -- exists on the server reattaches to that kernel. Return nil to always start a new kernel.
  session_name = function(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    return name ~= "" and vim.fn.fnamemodify(name, ":~:.") or nil
  end,
  -- named connection profiles; see host_defaults for the fields
  hosts = {},
}

local host_defaults = {
  -- Direct mode: the server is already reachable on this local port (you forward it yourself).
  -- No ssh is run. The token comes from `token`, $JUPYTER_TOKEN, or a prompt.
  port = nil,
  host = nil, -- ssh destination: "user@host", or a Host alias from ~/.ssh/config
  ssh_args = {}, -- extra ssh args for this host, e.g. { "-J", "bastion" } or { "-p", "2222" }
  start_server = false, -- start `jupyter_cmd` on the remote (and stop it on disconnect)
  remote_port = nil, -- port of the server on the remote. Existing server: discovered if nil
  remote_host = nil, -- forward target as seen from the ssh host, e.g. a compute node. Defaults
  -- to "localhost" (127.0.0.1 when molten starts the server)
  local_port = nil, -- local end of the tunnel; a free port is chosen if nil
  token = nil, -- string, or function returning one. Existing server: discovered if nil
  base_url = nil, -- server base url, e.g. "/user/me/" (discovered, or "/")
  kernel = nil, -- kernelspec to start; asked for when nil and there are several
  keep_kernels = nil, -- per-host override of the global option
  cwd = nil, -- remote directory to start the server in (start_server only)
  jupyter_cmd = nil, -- per-host override of the global options
  prelude = nil,
}

local config = vim.deepcopy(defaults)

---@type table<string, table> name -> connection state
local connections = {}

-- utils ---------------------------------------------------------------------------------------

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("[molten-remote] " .. msg, level or vim.log.levels.INFO)
  end)
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

local function url_encode(s)
  return (tostring(s):gsub("[^%w%-%._~/:@,]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function free_port()
  local tcp = uv.new_tcp()
  tcp:bind("127.0.0.1", 0)
  local port = tcp:getsockname().port
  tcp:close()
  return port
end

local function random_token()
  local ok, bytes = pcall(uv.random, 24)
  if not ok or type(bytes) ~= "string" then
    math.randomseed(os.time() + uv.hrtime())
    local t = {}
    for i = 1, 24 do
      t[i] = string.char(math.random(0, 255))
    end
    bytes = table.concat(t)
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local function normalize_base_url(base)
  base = base or "/"
  if base:sub(1, 1) ~= "/" then
    base = "/" .. base
  end
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  return base
end

local function append_log(conn, data)
  for _, line in ipairs(data or {}) do
    line = line:gsub("\r", "")
    if line ~= "" then
      table.insert(conn.log, line)
    end
  end
  while #conn.log > 500 do
    table.remove(conn.log, 1)
  end
end

local function last_log_lines(conn, n)
  local out = {}
  for i = math.max(1, #conn.log - n + 1), #conn.log do
    table.insert(out, conn.log[i])
  end
  return table.concat(out, "\n")
end

--- Minimal async HTTP/1.0 GET against the local end of the tunnel.
---@param cb fun(status: integer|nil, body: string|nil, err: string|nil)
local function http_request(method, port, path, token, cb)
  local tcp = uv.new_tcp()
  local chunks = {}
  local done = false
  local function finish(status, body, err)
    if done then
      return
    end
    done = true
    if not tcp:is_closing() then
      tcp:close()
    end
    vim.schedule(function()
      cb(status, body, err)
    end)
  end
  tcp:connect("127.0.0.1", port, function(err)
    if err then
      return finish(nil, nil, err)
    end
    local req = method .. " " .. path .. " HTTP/1.0\r\nHost: localhost:" .. port .. "\r\n"
    if token and token ~= "" then
      req = req .. "Authorization: token " .. token .. "\r\n"
    end
    tcp:write(req .. "\r\n")
    tcp:read_start(function(rerr, data)
      if rerr then
        return finish(nil, nil, rerr)
      end
      if data then
        table.insert(chunks, data)
        return
      end
      local resp = table.concat(chunks)
      local status = tonumber(resp:match("^HTTP/%d%.%d (%d+)"))
      local body = resp:match("\r\n\r\n(.*)$")
      if not status then
        return finish(nil, nil, "no HTTP response (is the server up?)")
      end
      finish(status, body)
    end)
  end)
  vim.defer_fn(function()
    finish(nil, nil, "timeout")
  end, 10000)
end

local function http_get(port, path, token, cb)
  http_request("GET", port, path, token, cb)
end

local function http_get_json(conn, path, cb)
  http_get(conn.local_port, conn.base_url .. path, conn.token, function(status, body, err)
    if status ~= 200 then
      return cb(nil, err or ("HTTP " .. tostring(status)))
    end
    local ok, decoded = pcall(vim.json.decode, body or "")
    if not ok then
      return cb(nil, "invalid JSON from server")
    end
    cb(decoded)
  end)
end

-- remote commands -----------------------------------------------------------------------------

local function remote_shell(script)
  -- the login shell on the remote may not be POSIX (fish, ...), so always go through sh
  return "sh -c " .. shell_quote(script)
end

local function ssh_cmd(profile, extra)
  local cmd = { config.ssh }
  vim.list_extend(cmd, config.ssh_args)
  vim.list_extend(cmd, profile.ssh_args or {})
  vim.list_extend(cmd, extra)
  return cmd
end

local function prelude_of(profile)
  local p = profile.prelude or config.prelude
  return p and (p .. "\n") or ""
end

--- Script that starts jupyter on the remote and stops it when the ssh session goes away.
--- The token is read from stdin so it never shows up in the remote's process list.
local function server_script(profile)
  local jupyter = profile.jupyter_cmd or config.jupyter_cmd
  local lines = {
    "read -r JUPYTER_TOKEN || exit 1",
    "export JUPYTER_TOKEN",
    prelude_of(profile),
  }
  if profile.cwd then
    table.insert(lines, "cd " .. profile.cwd .. " || exit 1")
  end
  vim.list_extend(lines, {
    "exec 3<&0",
    string.format(
      "%s --no-browser --ip=127.0.0.1 --port=%d --ServerApp.port_retries=0 </dev/null 3<&- &",
      jupyter,
      profile.remote_port
    ),
    "pid=$!",
    -- when neovim/ssh goes away, stdin hits EOF: stop the server
    "( cat <&3 >/dev/null; kill $pid ) >/dev/null 2>&1 &",
    "exec 3<&-",
    "wait $pid",
  })
  return table.concat(lines, "\n")
end

--- Ask the remote which servers are running (`jupyter server list --json`).
local function discover_server(profile, cb)
  local script = prelude_of(profile)
    .. "jupyter server list --json 2>/dev/null || jupyter notebook list --json 2>/dev/null"
  local out = {}
  local cmd = ssh_cmd(profile, { profile.host, remote_shell(script) })
  local ok = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      out = data
    end,
    on_exit = function()
      local servers = {}
      for _, line in ipairs(out) do
        local ok_json, s = pcall(vim.json.decode, line)
        if ok_json and type(s) == "table" and s.port then
          table.insert(servers, s)
        end
      end
      cb(servers)
    end,
  })
  if ok <= 0 then
    cb({}, "could not run " .. config.ssh)
  end
end

-- connection lifecycle ------------------------------------------------------------------------

local function resolve_profile(name)
  local p = config.hosts[name]
  if p == nil then
    -- ad-hoc: `:MoltenRemoteConnect 8888` / `localhost:8888` (already forwarded port), or
    -- `:MoltenRemoteConnect user@host` (ssh)
    local port = tonumber(name) or tonumber(name:match("^localhost:(%d+)$"))
      or tonumber(name:match("^127%.0%.0%.1:(%d+)$")) or tonumber(name:match("^:(%d+)$"))
    p = port and { port = port } or { host = name }
  end
  p = vim.tbl_extend("force", vim.deepcopy(host_defaults), p)
  if not p.host and not p.port then
    error("host profile '" .. name .. "' needs `port` (already forwarded) or `host` (ssh)")
  end
  return p
end

local function on_ready(conn)
  for _, cb in ipairs(conn.waiters) do
    cb(conn)
  end
  conn.waiters = {}
end

local function fail(conn, msg)
  if conn.status == "failed" or conn.status == "closed" then
    return
  end
  conn.status = "failed"
  if conn.job and conn.job > 0 then
    pcall(vim.fn.jobstop, conn.job)
  end
  local tail = last_log_lines(conn, 8)
  notify(
    string.format("%s: %s%s", conn.name, msg, tail ~= "" and ("\n" .. tail) or ""),
    vim.log.levels.ERROR
  )
  conn.waiters = {}
end

local function poll_until_ready(conn)
  local timeout = conn.direct and math.min(config.startup_timeout, 5) or config.startup_timeout
  local deadline = uv.now() + timeout * 1000
  local function poll()
    if conn.status ~= "connecting" then
      return
    end
    http_get(conn.local_port, conn.base_url .. "api/status", conn.token, function(status)
      if conn.status ~= "connecting" then
        return
      end
      if status == 200 then
        conn.status = "connected"
        if conn.direct then
          notify(string.format("%s: connected (localhost:%d)", conn.name, conn.local_port))
        else
          notify(string.format("%s: connected (localhost:%d -> %s:%d)", conn.name,
            conn.local_port, conn.profile.host, conn.remote_port))
        end
        on_ready(conn)
      elseif status == 401 or status == 403 then
        if conn.direct and not conn.asked_token then
          -- no/incorrect token: ask once (input is hidden)
          conn.asked_token = true
          local token = vim.fn.inputsecret("Jupyter token for localhost:" .. conn.local_port .. ": ")
          if token ~= "" then
            conn.token = token
            return poll()
          end
        end
        fail(conn, "the server rejected the token")
      elseif uv.now() > deadline then
        fail(conn, conn.direct
          and ("no Jupyter Server answering on localhost:" .. conn.local_port
            .. ". Is the port forward up?")
          or "timed out waiting for the Jupyter Server")
      else
        vim.defer_fn(poll, 500)
      end
    end)
  end
  poll()
end

local function open_tunnel(conn)
  local profile = conn.profile
  local target = profile.remote_host or (profile.start_server and "127.0.0.1" or "localhost")
  local forward = string.format("%d:%s:%d", conn.local_port, target, conn.remote_port)
  local extra = { "-L", forward, profile.host }
  if profile.start_server then
    table.insert(extra, remote_shell(server_script(profile)))
  else
    table.insert(extra, 1, "-N")
  end

  conn.job = vim.fn.jobstart(ssh_cmd(profile, extra), {
    on_stdout = function(_, data)
      append_log(conn, data)
    end,
    on_stderr = function(_, data)
      append_log(conn, data)
    end,
    on_exit = function(_, code)
      if conn.status == "connecting" then
        fail(conn, "ssh exited with code " .. code)
      elseif conn.status == "connected" then
        conn.status = "closed"
        notify(conn.name .. ": connection closed (ssh exited with code " .. code .. ")",
          vim.log.levels.WARN)
      else
        conn.status = "closed"
      end
    end,
  })
  if conn.job <= 0 then
    return fail(conn, "could not start " .. config.ssh)
  end
  if profile.start_server then
    vim.fn.chansend(conn.job, conn.token .. "\n")
  end
  poll_until_ready(conn)
end

--- Get (or create) the connection for `name`, calling `cb(conn)` once it is up.
local function ensure_connection(name, cb)
  local conn = connections[name]
  if conn and conn.status == "connected" then
    return cb(conn)
  end
  if conn and conn.status == "connecting" then
    table.insert(conn.waiters, cb)
    return
  end

  local ok, profile = pcall(resolve_profile, name)
  if not ok then
    return notify(profile, vim.log.levels.ERROR)
  end

  conn = {
    name = name,
    profile = profile,
    status = "connecting",
    log = {},
    waiters = { cb },
    direct = profile.host == nil,
    local_port = profile.port or profile.local_port or free_port(),
    base_url = normalize_base_url(profile.base_url),
  }
  connections[name] = conn

  local token = profile.token
  if type(token) == "function" then
    token = token()
  end

  if conn.direct then
    -- the port is already forwarded (or the server is local): just talk to it
    conn.remote_port = conn.local_port
    conn.token = token or vim.env.JUPYTER_TOKEN
    return poll_until_ready(conn)
  end

  notify(name .. ": connecting to " .. profile.host .. " ...")

  if profile.start_server then
    conn.remote_port = profile.remote_port or (20000 + tonumber(random_token():sub(1, 6), 16) % 20000)
    profile.remote_port = conn.remote_port
    conn.token = random_token()
    return open_tunnel(conn)
  end

  if profile.remote_port and token ~= nil then
    conn.remote_port = profile.remote_port
    conn.token = token
    return open_tunnel(conn)
  end

  -- find the running server (and its token) on the remote
  discover_server(profile, function(servers, err)
    if conn.status ~= "connecting" then
      return
    end
    local server
    for _, s in ipairs(servers) do
      if profile.remote_port == nil or tonumber(s.port) == profile.remote_port then
        server = s
        break
      end
    end
    if not server then
      return fail(conn, err or ("no running Jupyter Server found on " .. profile.host
        .. (profile.remote_port and (" port " .. profile.remote_port) or "")
        .. ". Start one, or set `start_server = true`."))
    end
    conn.remote_port = tonumber(server.port)
    conn.token = token or server.token or ""
    if not profile.base_url and server.base_url then
      conn.base_url = normalize_base_url(server.base_url)
    end
    open_tunnel(conn)
  end)
end

local function server_url(conn, params)
  local url = string.format("http://localhost:%d%s", conn.local_port, conn.base_url:gsub("/$", ""))
  local query = {}
  if conn.token and conn.token ~= "" then
    table.insert(query, "token=" .. url_encode(conn.token))
  end
  for k, v in pairs(params or {}) do
    table.insert(query, k .. "=" .. url_encode(v))
  end
  if #query > 0 then
    url = url .. "?" .. table.concat(query, "&")
  end
  return url
end

-- saved outputs ---------------------------------------------------------------------------

local function outputs_file(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  -- one flat file per source file; only plain characters, since molten's commands don't
  -- unescape their arguments
  local flat = name:gsub("[^%w%.%-_]", "_")
  return vim.fn.stdpath("data") .. "/molten-remote/" .. flat .. ".json"
end

local function buf_checksum(buf)
  return vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, true), "\n"))
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local ok_json, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  return ok_json and type(data) == "table" and data or nil
end

--- Save the outputs of `buf` (current buffer if nil). Called after every write.
function M.save_outputs(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local path = outputs_file(buf)
  if not path or not vim.b[buf].molten_remote then
    return
  end
  -- never replace saved outputs with none: a file connected without its outputs (e.g. when
  -- restoring them failed) would otherwise wipe them on the next :w
  local tmp = path .. ".new"
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.fn.MoltenSaveOutputs, tmp)
  end)
  local new = read_json(tmp)
  if not new then
    return
  end
  local old = read_json(path)
  if #(new.cells or {}) == 0 and old and #(old.cells or {}) > 0 then
    vim.fn.delete(tmp)
    return
  end
  vim.fn.rename(tmp, path)
end

--- If `buf` has saved outputs that still match its contents, load them with a kernel from `url`.
--- Returns true if it did (molten is then initialized for the buffer).
local function restore_outputs(buf, url)
  local path = outputs_file(buf)
  local data = path and vim.fn.filereadable(path) == 1 and read_json(path)
  if not data then
    return false
  end
  if #(data.cells or {}) == 0 then
    return false -- nothing saved for this file
  end
  local note
  if data.molten_remote_checksum ~= buf_checksum(buf) then
    -- the file was edited since: put each saved output back on its cell's code
    local has_text = data.cells[1] and data.cells[1].text
    if not has_text then
      notify("this file changed since its outputs were saved (by an older version, without the cells' "
        .. "code), so they weren't restored", vim.log.levels.INFO)
      return false
    end
    local saved = require("molten.saved_outputs")
    local unchanged, edited, lost
    data, unchanged, edited, lost = saved.relocate(data, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    if #data.cells == 0 then
      notify("none of the saved outputs' cells are in this file anymore", vim.log.levels.INFO)
      return false
    end
    note = (edited > 0 and string.format(", %d of them on cells you edited since", edited) or "")
      .. (lost > 0 and string.format("; %d couldn't be matched to a cell", lost) or "")
  end
  data.kernel = url
  local tmp = vim.fn.tempname() .. ".json" -- no spaces: :MoltenLoad splits its arguments
  vim.fn.writefile({ vim.json.encode(data) }, tmp)
  local ok, err = pcall(vim.cmd, "MoltenLoad " .. tmp)
  vim.fn.delete(tmp)
  if not ok then
    notify("couldn't restore the outputs: " .. tostring(err), vim.log.levels.WARN)
  end
  local restored = ok and #vim.fn.MoltenRunningKernels(true) > 0
  if restored then
    notify(string.format("restored the outputs of %d cell(s)%s", #(data.cells or {}), note or ""))
  end
  return restored
end

local function molten_init(buf, url)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  require("molten.saved_outputs").hide(buf) -- the real outputs replace the read-only ones
  vim.api.nvim_buf_call(buf, function()
    if config.save_outputs and restore_outputs(buf, url) then
      vim.b[buf].molten_remote = true
      return
    end
    -- not `:MoltenInit url`: Ex commands would expand the % and # in the query string
    local ok, err = pcall(vim.fn.MoltenInitUrl, url)
    if not ok then
      notify("MoltenInit failed: " .. tostring(err), vim.log.levels.ERROR)
    elseif #vim.fn.MoltenRunningKernels(true) > 0 then
      vim.b[buf].molten_remote = true
    end
  end)
end

local function pick_kernelspec(conn, cb)
  http_get_json(conn, "api/kernelspecs", function(specs, err)
    if not specs then
      notify(conn.name .. ": could not list kernels (" .. err .. "), using the default",
        vim.log.levels.WARN)
      return cb(nil)
    end
    local names = vim.tbl_keys(specs.kernelspecs or {})
    table.sort(names, function(a, b)
      return a == specs.default or (b ~= specs.default and a < b)
    end)
    if #names <= 1 then
      return cb(names[1])
    end
    vim.ui.select(names, {
      prompt = "Remote kernel (" .. conn.name .. ")",
      format_item = function(n)
        local s = specs.kernelspecs[n].spec or {}
        return s.display_name and (n .. "  (" .. s.display_name .. ")") or n
      end,
    }, function(choice)
      if choice then
        cb(choice)
      end
    end)
  end)
end

-- remembered kernels ----------------------------------------------------------------------
-- When you attach a file to a running kernel (:MoltenRemoteAttach), that choice is saved, and
-- :MoltenRemoteConnect from the same file reconnects to that kernel (as long as it's still
-- running) instead of the file's own session. Stored in stdpath("data")/molten-remote/kernels.json.

local function remembered_file()
  return vim.fn.stdpath("data") .. "/molten-remote/kernels.json"
end

local function remembered_all()
  local data = read_json(remembered_file())
  return type(data) == "table" and data or {}
end

local function remember(buf, host, kernel_id)
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    return
  end
  local data = remembered_all()
  data[file] = kernel_id and { host = host, kernel_id = kernel_id } or nil
  vim.fn.mkdir(vim.fn.fnamemodify(remembered_file(), ":h"), "p")
  vim.fn.writefile({ vim.json.encode(data) }, remembered_file())
end

local function remembered(buf, host)
  local entry = remembered_all()[vim.api.nvim_buf_get_name(buf)]
  return entry and entry.host == host and entry.kernel_id or nil
end

-- public API ----------------------------------------------------------------------------------

--- Connect to `name` (profile name or ssh destination) and start a new kernel in the current
--- buffer. opts.kernel overrides the profile's kernel; opts.init = false only opens the tunnel.
function M.connect(name, opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  ensure_connection(name, function(conn)
    local init = opts.init
    if init == nil then
      init = config.auto_init
    end
    if not init then
      return
    end
    -- the kernel you attached this file to last time, if it's still running
    local kept = not opts.kernel and remembered(buf, conn.name)
    if kept then
      return http_get_json(conn, "api/kernels/" .. kept, function(info)
        if info and info.id then
          molten_init(buf, server_url(conn, { kernel_id = kept }))
          if opts.on_init then
            opts.on_init()
          end
          return
        end
        remember(buf, conn.name, nil)
        notify("the kernel this file was attached to is gone; connecting to the file's own kernel")
        M.connect(name, opts)
      end)
    end
    local keep = conn.profile.keep_kernels
    if keep == nil then
      keep = config.keep_kernels
    end
    local session = config.session_name and config.session_name(buf) or nil
    local function start(kernel)
      molten_init(buf, server_url(conn, {
        kernel_name = kernel,
        session = session,
        keep_kernel = keep and "1" or nil,
      }))
      if opts.on_init then
        opts.on_init()
      end
    end
    local kernel = opts.kernel or conn.profile.kernel
    if kernel then
      return start(kernel)
    end
    if not session then
      return pick_kernelspec(conn, start)
    end
    -- reattach without asking if this file already has a kernel on the server
    http_get_json(conn, "api/sessions", function(sessions)
      for _, s in ipairs(sessions or {}) do
        if s.path == session then
          return start(nil)
        end
      end
      pick_kernelspec(conn, start)
    end)
  end)
end

--- Attach the current buffer to a kernel that is already running on the server (e.g. one that
--- is open in JupyterLab). molten won't shut it down when you leave.
function M.attach(name, kernel_id)
  local buf = vim.api.nvim_get_current_buf()
  ensure_connection(name, function(conn)
    if kernel_id then
      remember(buf, conn.name, kernel_id)
      return molten_init(buf, server_url(conn, { kernel_id = kernel_id }))
    end
    http_get_json(conn, "api/sessions", function(sessions)
      http_get_json(conn, "api/kernels", function(kernels, err)
        if not kernels then
          return notify(conn.name .. ": could not list kernels: " .. err, vim.log.levels.ERROR)
        end
        if #kernels == 0 then
          return notify(conn.name .. ": no running kernels", vim.log.levels.WARN)
        end
        local paths = {}
        for _, s in ipairs(sessions or {}) do
          if s.kernel then
            paths[s.kernel.id] = s.path or s.name
          end
        end
        -- this file's kernel first, then most recently active
        local mine = config.session_name and config.session_name(buf) or nil
        table.sort(kernels, function(a, b)
          local am, bm = paths[a.id] == mine, paths[b.id] == mine
          if am ~= bm then
            return am
          end
          return (a.last_activity or "") > (b.last_activity or "")
        end)
        vim.ui.select(kernels, {
          prompt = "Attach to kernel (" .. conn.name .. ")",
          format_item = function(k)
            return string.format("%s  %s  [%s]%s", k.id:sub(1, 8), k.name, k.execution_state,
              paths[k.id] and ("  " .. paths[k.id]) or "")
          end,
        }, function(k)
          if k then
            remember(buf, conn.name, k.id)
            molten_init(buf, server_url(conn, { kernel_id = k.id }))
          end
        end)
      end)
    end)
  end)
end

--- Shut a kernel down on the server (its variables are gone). Files connected to it are
--- disconnected first. Without `kernel_id`, pick from the running kernels.
function M.shutdown(name, kernel_id)
  ensure_connection(name, function(conn)
    http_get_json(conn, "api/sessions", function(sessions)
      http_get_json(conn, "api/kernels", function(kernels, err)
        if not kernels then
          return notify(conn.name .. ": could not list kernels: " .. err, vim.log.levels.ERROR)
        end
        local paths, session_of = {}, {}
        for _, s in ipairs(sessions or {}) do
          if s.kernel then
            paths[s.kernel.id] = s.path or s.name
            session_of[s.kernel.id] = s.id
          end
        end
        local function kill(k)
          local label = string.format("%s %s%s", k.name, k.id:sub(1, 8), paths[k.id] and ("  (" .. paths[k.id] .. ")") or "")
          if vim.fn.confirm("Shut down kernel " .. label .. " on the server?\nIts variables are lost.", "&Yes\n&No", 2) ~= 1 then
            return
          end
          -- disconnect open files that use it
          local short = k.id:sub(1, 8)
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) then
              vim.api.nvim_buf_call(buf, function()
                local ok, ids = pcall(vim.fn.MoltenRunningKernels, true)
                for _, id in ipairs(ok and ids or {}) do
                  if id:find(short, 1, true) then
                    pcall(vim.cmd, "MoltenDeinit")
                    vim.b[buf].molten_remote = nil
                    break
                  end
                end
              end)
            end
          end
          -- forget it for files that were attached to it
          local data = remembered_all()
          local changed = false
          for file, entry in pairs(data) do
            if entry.kernel_id == k.id then
              data[file], changed = nil, true
            end
          end
          if changed then
            vim.fn.writefile({ vim.json.encode(data) }, remembered_file())
          end
          local path = session_of[k.id] and ("api/sessions/" .. session_of[k.id]) or ("api/kernels/" .. k.id)
          http_request("DELETE", conn.local_port, conn.base_url .. path, conn.token, function(status, _, derr)
            if status and status >= 200 and status < 300 then
              notify("shut down kernel " .. label)
            else
              notify("couldn't shut down " .. label .. ": " .. tostring(derr or ("HTTP " .. tostring(status))),
                vim.log.levels.ERROR)
            end
          end)
        end
        if kernel_id then
          for _, k in ipairs(kernels) do
            if k.id == kernel_id or k.id:sub(1, #kernel_id) == kernel_id then
              return kill(k)
            end
          end
          return notify(conn.name .. ": no running kernel " .. kernel_id, vim.log.levels.WARN)
        end
        if #kernels == 0 then
          return notify(conn.name .. ": no running kernels", vim.log.levels.WARN)
        end
        local mine = config.session_name and config.session_name(vim.api.nvim_get_current_buf()) or nil
        table.sort(kernels, function(a, b)
          local am, bm = paths[a.id] == mine, paths[b.id] == mine
          if am ~= bm then
            return am
          end
          return (a.last_activity or "") > (b.last_activity or "")
        end)
        vim.ui.select(kernels, {
          prompt = "Shut down kernel (" .. conn.name .. ")",
          format_item = function(k)
            return string.format("%s  %s  [%s]%s", k.id:sub(1, 8), k.name, k.execution_state,
              paths[k.id] and ("  " .. paths[k.id]) or "")
          end,
        }, function(k)
          if k then
            kill(k)
          end
        end)
      end)
    end)
  end)
end

--- Show (or hide again) this file's saved outputs without connecting to a kernel: read-only, from
--- the last :w while it was connected. Edited cells get the output of their closest match.
function M.toggle_saved(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local saved = require("molten.saved_outputs")
  if vim.b[buf].molten_saved_shown then
    return saved.hide(buf)
  end
  if #vim.fn.MoltenRunningKernels(true) > 0 then
    return notify("this file is connected to a kernel: its outputs are the real ones")
  end
  local path = outputs_file(buf)
  local data = path and vim.fn.filereadable(path) == 1 and read_json(path)
  if not data or #(data.cells or {}) == 0 then
    return notify("no saved outputs for this file (they're saved on :w while connected)")
  end
  if not (data.cells[1] and data.cells[1].text) and data.molten_remote_checksum ~= buf_checksum(buf) then
    return notify("this file changed since its outputs were saved by an older version; run the cells "
      .. "and :w once to save them in the new format")
  end
  local shown, _, edited, lost = saved.show(buf, data)
  notify(string.format("showing %d saved output(s), read-only%s%s; <leader>jc connects", shown,
    edited > 0 and string.format(" (%d on edited cells)", edited) or "",
    lost > 0 and string.format(", %d couldn't be matched", lost) or ""))
end

--- Close the tunnel for `name` (all connections if nil). A server started by molten is stopped.
function M.disconnect(name)
  for n, conn in pairs(connections) do
    if name == nil or n == name then
      conn.status = "closed"
      if conn.job and conn.job > 0 then
        pcall(vim.fn.jobstop, conn.job)
      end
      connections[n] = nil
    end
  end
end

--- Connection info, e.g. for a statusline.
function M.status()
  local out = {}
  for n, conn in pairs(connections) do
    out[n] = {
      status = conn.status,
      host = conn.profile.host or "localhost (direct)",
      local_port = conn.local_port,
      remote_port = conn.remote_port,
      started_server = conn.profile.start_server,
      url = conn.status == "connected" and server_url(conn) or nil,
    }
  end
  return out
end

--- The Jupyter Server URL (with token) of a live connection, for :MoltenInit or a browser.
function M.url(name)
  local conn = connections[name]
  return conn and conn.status == "connected" and server_url(conn) or nil
end

function M.show_log(name)
  local conn = connections[name]
  if not conn then
    return notify("no connection named " .. tostring(name), vim.log.levels.WARN)
  end
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "molten-remote://" .. name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, conn.log)
end

local function complete_hosts(arglead)
  local names = vim.tbl_keys(config.hosts)
  for n in pairs(connections) do
    if not config.hosts[n] then
      table.insert(names, n)
    end
  end
  table.sort(names)
  return vim.tbl_filter(function(n)
    return n:find(arglead, 1, true) == 1
  end, names)
end

local function complete_connections(arglead)
  return vim.tbl_filter(function(n)
    return n:find(arglead, 1, true) == 1
  end, vim.tbl_keys(connections))
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  -- lists shouldn't be merged index-by-index
  if opts and opts.ssh_args then
    config.ssh_args = opts.ssh_args
  end

  local cmd = vim.api.nvim_create_user_command
  cmd("MoltenRemoteConnect", function(a)
    M.connect(a.fargs[1], { kernel = a.fargs[2], init = not a.bang })
  end, {
    nargs = "+",
    bang = true,
    complete = complete_hosts,
    desc = "Tunnel to a remote Jupyter Server and start a kernel (! = tunnel only)",
  })
  cmd("MoltenRemoteAttach", function(a)
    M.attach(a.fargs[1], a.fargs[2])
  end, {
    nargs = "+",
    complete = complete_hosts,
    desc = "Attach to a kernel running on a remote Jupyter Server",
  })
  cmd("MoltenRemoteShowSaved", function()
    M.toggle_saved()
  end, { desc = "Show / hide this file's saved outputs without a kernel (read-only)" })
  cmd("MoltenRemoteShutdown", function(a)
    M.shutdown(a.fargs[1], a.fargs[2])
  end, {
    nargs = "+",
    complete = complete_hosts,
    desc = "Shut down a kernel on a remote Jupyter Server (pick one, or give its id)",
  })
  cmd("MoltenRemoteDisconnect", function(a)
    M.disconnect(a.fargs[1])
  end, { nargs = "?", complete = complete_connections, desc = "Close remote Jupyter tunnel(s)" })
  cmd("MoltenRemoteStatus", function()
    local st = M.status()
    if vim.tbl_isempty(st) then
      return print("molten-remote: no connections")
    end
    for n, s in pairs(st) do
      print(string.format("%s: %s  %s  localhost:%s -> %s%s", n, s.status, s.host,
        tostring(s.local_port), tostring(s.remote_port), s.started_server and "  (server started by molten)" or ""))
    end
  end, { desc = "Show remote Jupyter connections" })
  cmd("MoltenRemoteLog", function(a)
    M.show_log(a.fargs[1])
  end, { nargs = 1, complete = complete_connections, desc = "Show ssh/jupyter output" })

  local group = vim.api.nvim_create_augroup("molten-remote", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.disconnect()
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if config.save_outputs and vim.b[ev.buf].molten_remote then
        M.save_outputs(ev.buf)
      end
    end,
  })
  cmd("MoltenRemoteForget", function()
    remember(vim.api.nvim_get_current_buf(), nil, nil)
    notify("forgot the kernel this file was attached to; :MoltenRemoteConnect uses its own kernel again")
  end, { desc = "Stop reconnecting this file to the kernel it was attached to" })
  cmd("MoltenRemoteSaveOutputs", function()
    M.save_outputs()
  end, { desc = "Save this file's outputs now (also happens on every write)" })
end

return M
