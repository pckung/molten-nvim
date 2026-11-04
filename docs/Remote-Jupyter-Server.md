# Remote Jupyter Server over SSH

`molten.remote` runs your kernels on a remote machine's Jupyter Server and reaches it through SSH
port forwarding. Like VS Code's "existing Jupyter server" workflow, **kernels keep running when you
close neovim, and you can reconnect to them later**.

## Requirements

- Locally: the python packages `requests` and `websocket-client` (in molten's python env), and an
  `ssh` client (not needed if you forward the port yourself).
- Remote: `jupyter_server` (or `notebook`/`jupyterlab`, which bring it) plus the kernels you want.
- When molten runs ssh: non-interactive SSH login. Neovim can't type a password for you, so use keys or `ssh-agent`.
  For hosts that need a password or 2FA, set up `ControlMaster` in `~/.ssh/config` and log in once
  from a terminal. molten's ssh then reuses that connection.

## Already forwarding the port yourself?

If your workflow already sets up the port forward (`ssh -L 8888:localhost:8888 ...`, VS Code, a
script, ...), molten doesn't need ssh at all. Point it at the local port:

```vim
:MoltenRemoteConnect 8888
```

or give it a name in your config:

```lua
require("molten.remote").setup({
  hosts = {
    lab = { port = 8888 },  -- token: `token = "..."`, else $JUPYTER_TOKEN, else you're asked
  },
})
```

Reconnecting to running kernels and `:MoltenRemoteAttach` work the same way. If nothing answers on
the port within 5 seconds, you get an error asking whether the forward is up. `token` can also be a
function, e.g. `token = function() return vim.fn.readfile(vim.fn.expand("~/.jupyter_token"))[1] end`.

## Setup (molten runs ssh)

```lua
require("molten.remote").setup({
  hosts = {
    -- molten starts `jupyter server` on the remote, and stops it when you disconnect / quit
    gpu = {
      host = "me@gpu-box",          -- or a Host alias from ~/.ssh/config
      start_server = true,
      cwd = "~/project",            -- where the server (and so the kernels) start
      prelude = "source ~/project/.venv/bin/activate", -- or `conda activate ...` etc.
      kernel = "python3",           -- omit to be asked (when there's more than one)
    },
    -- a server that is already running there (in tmux, a systemd unit, JupyterLab, ...)
    lab = {
      host = "lab",
      remote_port = 8888,           -- omit to use whichever server `jupyter server list` reports
      -- token = "...",             -- omit to read it from `jupyter server list`
    },
    -- server on a compute node, reached through a login node
    hpc = { host = "login.cluster", ssh_args = { "-J", "bastion" }, remote_host = "node042", remote_port = 8888, token = "..." },
  },
})
```

All options with their defaults are at the top of
[`lua/molten/remote.lua`](../lua/molten/remote.lua).

| Global option   | Default            | Description |
|-----------------|--------------------|-------------|
| `ssh`           | `"ssh"`            | ssh executable |
| `ssh_args`      | ExitOnForwardFailure, ServerAliveInterval=30, BatchMode | options for every connection |
| `jupyter_cmd`   | `"jupyter server"` | command that starts the server (`start_server = true`) |
| `prelude`       | `nil`              | shell code run on the remote before any `jupyter` command |
| `keep_kernels`  | `true`             | leave kernels running when neovim exits / `:MoltenDeinit` |
| `session_name`  | buffer path relative to cwd | names the buffer's Jupyter session. Return `nil` to never reattach automatically |
| `startup_timeout` | `60`             | seconds to wait for the tunnel / server |
| `auto_init`     | `true`             | run `MoltenInit` once connected |

## Commands

| Command | Description |
|---------|-------------|
| `:MoltenRemoteConnect {host} [kernel]` | `{host}` can also be a port (`8888`, `localhost:8888`) that is already forwarded. Open the tunnel (and start the server, if configured). Then initialize molten in the current buffer with **this file's kernel if one is still running on the server**, or a new one. `{host}` is a profile name or any ssh destination (`user@host`). With `!`, only open the tunnel. |
| `:MoltenRemoteAttach {host} [kernel_id]` | Pick any running kernel on the server (this file's comes first, and the list shows which file or notebook each one belongs to) and attach the current buffer to it. Molten never shuts down a kernel it attached to. |
| `:MoltenRemoteDisconnect [host]` | Close the tunnel (all of them without an argument). A server molten started is stopped, together with its kernels. |
| `:MoltenRemoteStatus` | List connections. |
| `:MoltenRemoteLog {host}` | Show ssh and jupyter output for a connection, for when something doesn't work. |
| `:MoltenRemoteSaveOutputs` | Save this file's outputs now (also happens on every write). |

All the regular molten commands (`:MoltenEvaluateLine`, `:MoltenInterrupt`, `:MoltenRestart`, ...)
then work as usual, including `input()`.

## How reconnecting works

When you run `:MoltenRemoteConnect` from `analysis/train.py`, molten creates a Jupyter **session**
named `analysis/train.py` on the server and starts the kernel in it. The session also shows up in
JupyterLab's "Running" tab. With `keep_kernels = true`, quitting neovim leaves both running.

Next time, in the same file, `:MoltenRemoteConnect lab` finds that session and reattaches to its
kernel, so your variables are still there. A kernel that is still busy with a long job counts as
ready. You can queue more code, but output from the cell that was already running isn't shown,
because Jupyter only sends it to the client that ran the cell.

Kernels you no longer need can be shut down from JupyterLab, or with `keep_kernels = false` and
`:MoltenDeinit`. To reattach, the tunnel must reach the *same* server, so this needs a server that
outlives your neovim session (not `start_server = true`).

## Saving outputs

With `save_outputs = true` (the default), every time you write a file that uses a remote kernel,
its cell outputs are saved to `stdpath("data")/molten-remote/` (without the server token). The next
`:MoltenRemoteConnect` from that file shows them again, before you run anything, like opening a
notebook. Combined with reattaching, you pick up exactly where you left off.

The outputs are tied to the file's exact contents: if the file changed after the last write (edited
in another program, `git pull`, ...), they aren't restored and you get a message saying so.
`:MoltenRemoteSaveOutputs` saves without writing the file.

To keep the outputs in a shareable form, export them into a notebook. For a `.qmd`:

```bash
quarto convert report.qmd        # creates report.ipynb with the same cells (once)
```

then `:MoltenExportOutput!` in Neovim writes the current outputs into `report.ipynb` (without the
`!`, into a new `copy-of-report.ipynb`). `quarto render report.ipynb` turns it into HTML/PDF using
those outputs, without running the code again. This needs `nbformat` in molten's Python environment.

## Without the Lua helper

The pieces also work on their own:

```bash
ssh -N -L 8888:localhost:8888 me@gpu-box
```

```vim
" new kernel
:call MoltenInitUrl("http://localhost:8888/?token=TOKEN&kernel_name=python3")
" reattach to this file's kernel (or start it), keep it alive on exit
:call MoltenInitUrl("http://localhost:8888/?token=TOKEN&session=train.py&keep_kernel=1")
" attach to a specific running kernel
:call MoltenInitUrl("http://localhost:8888/?token=TOKEN&kernel_id=KERNEL_ID")
```

`:MoltenInit <url>` works too, but Ex commands expand `%` and `#`, so URL-encoded characters must
be escaped as `\%`.
