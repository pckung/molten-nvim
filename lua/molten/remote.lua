-- molten.remote: run molten kernels on a remote Jupyter Server reached through SSH port forwarding.
--
--   require("molten.remote").setup({
--     hosts = {
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
  host = nil, -- ssh destination: "user@host", or a Host alias from ~/.ssh/config (required)
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
local function http_get(port, path, token, cb)
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
    local req = "GET " .. path .. " HTTP/1.0\r\nHost: localhost:" .. port .. "\r\n"
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
    -- ad-hoc: `:MoltenRemoteConnect user@host`
    p = { host = name }
  end
  p = vim.tbl_extend("force", vim.deepcopy(host_defaults), p)
  if not p.host then
    error("host profile '" .. name .. "' has no `host`")
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
  local deadline = uv.now() + config.startup_timeout * 1000
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
        notify(string.format("%s: connected (localhost:%d -> %s:%d)", conn.name, conn.local_port,
          conn.profile.host, conn.remote_port))
        on_ready(conn)
      elseif status == 401 or status == 403 then
        fail(conn, "the server rejected the token")
      elseif uv.now() > deadline then
        fail(conn, "timed out waiting for the Jupyter Server")
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
    local_port = profile.local_port or free_port(),
    base_url = normalize_base_url(profile.base_url),
  }
  connections[name] = conn
  notify(name .. ": connecting to " .. profile.host .. " ...")

  if profile.start_server then
    conn.remote_port = profile.remote_port or (20000 + tonumber(random_token():sub(1, 6), 16) % 20000)
    profile.remote_port = conn.remote_port
    conn.token = random_token()
    return open_tunnel(conn)
  end

  local token = profile.token
  if type(token) == "function" then
    token = token()
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

local function molten_init(buf, url)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_call(buf, function()
    -- not `:MoltenInit url`: Ex commands would expand the % and # in the query string
    local ok, err = pcall(vim.fn.MoltenInitUrl, url)
    if not ok then
      notify("MoltenInit failed: " .. tostring(err), vim.log.levels.ERROR)
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
            molten_init(buf, server_url(conn, { kernel_id = k.id }))
          end
        end)
      end)
    end)
  end)
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
      host = conn.profile.host,
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

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("molten-remote", { clear = true }),
    callback = function()
      M.disconnect()
    end,
  })
end

return M
