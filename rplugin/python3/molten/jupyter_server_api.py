"""Minimal client for running kernels through a (possibly remote) Jupyter Server.

Molten uses this when `:MoltenInit` is given an ``http(s)://`` URL instead of a kernel name. The
URL may carry these query parameters:

- ``token``: the Jupyter Server auth token
- ``kernel_name`` (alias ``kernel``): kernelspec to start (defaults to the server's default)
- ``kernel_id``: attach to an already running kernel instead of starting a new one. Molten will
  not shut that kernel down on exit.
- ``path``: working directory for a new kernel, relative to the server's root dir
- ``session``: name a Jupyter *session* after this path (usually the buffer's file). If a session
  with that path already exists on the server, molten reattaches to its kernel instead of starting
  a new one -- this is how you get back to "your" kernel after restarting neovim, like VS Code.
  The session's kernel also shows up in JupyterLab under that name.
- ``keep_kernel=1``: leave the kernel running when molten exits/deinits, so it can be reattached.

The URL path is kept as the base URL, so servers hosted under a prefix (e.g. JupyterHub's
``/user/<name>/``) work too. This is what ``require("molten.remote")`` uses after it sets up an SSH
tunnel to a remote server.
"""

import datetime
import json
import time
import uuid
from queue import Empty as EmptyQueueException
from queue import Queue
from threading import Lock, Thread
from types import SimpleNamespace
from typing import Any, Dict, Optional, Set
from urllib.parse import parse_qs, quote, urlparse

from molten.runtime_state import RuntimeState

REQUEST_TIMEOUT = 30


def _now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


class JupyterAPIClient:
    def __init__(
        self,
        url: str,
        kernel_info: Dict[str, Any],
        headers: Dict[str, str],
        token: Optional[str] = None,
    ):
        self._base_url = url.rstrip("/")
        self._kernel_info = kernel_info
        self._headers = headers
        self._token = token
        self._session_id = uuid.uuid4().hex
        self._kernel_api_base = f"{self._base_url}/api/kernels/{self._kernel_info['id']}"

        self._iopub_queue: Queue[Dict[str, Any]] = Queue()
        self._stdin_queue: Queue[Dict[str, Any]] = Queue()
        # msg_ids of the requests sent by this client. IOPub is broadcast to every client of the
        # kernel (the server itself, a browser tab, ...), so only messages answering one of our
        # own requests are handed to molten.
        self._own_msg_ids: Set[str] = set()
        self._lock = Lock()
        self._socket: Any = None
        self._closed = False
        self.connection_error: Optional[str] = None

        import requests

        self.requests = requests

    # --- connection -------------------------------------------------------------------------

    def start_channels(self) -> None:
        import websocket

        parsed_url = urlparse(self._base_url)
        ws_scheme = "wss" if parsed_url.scheme == "https" else "ws"
        ws_url = (
            f"{ws_scheme}://{parsed_url.netloc}{parsed_url.path}"
            f"/api/kernels/{self._kernel_info['id']}/channels?session_id={self._session_id}"
        )
        if self._token:
            ws_url += f"&token={quote(self._token)}"

        self._socket = websocket.create_connection(
            ws_url, header=self._headers, timeout=REQUEST_TIMEOUT
        )
        # The receive thread blocks on recv(); don't time out while the kernel is quiet.
        self._socket.settimeout(None)

        self._recv_thread = Thread(target=self._recv_message, daemon=True)
        self._recv_thread.start()

    def _recv_message(self) -> None:
        while not self._closed:
            try:
                raw = self._socket.recv()
            except Exception as e:  # connection closed, tunnel died, ...
                if not self._closed:
                    self.connection_error = f"Lost connection to Jupyter Server: {e}"
                return
            if not raw:
                if not self._closed:
                    self.connection_error = "Jupyter Server closed the connection"
                return
            try:
                msg = json.loads(raw)
            except (TypeError, ValueError):
                continue  # binary frames (buffers) are not used by molten

            channel = msg.get("channel")
            parent_id = (msg.get("parent_header") or {}).get("msg_id")
            with self._lock:
                ours = parent_id in self._own_msg_ids

            if channel == "stdin":
                if ours:
                    self._stdin_queue.put(msg)
            elif channel == "iopub":
                if ours:
                    self._iopub_queue.put(msg)
            # shell/control replies are not needed by molten

    def wait_for_ready(self, timeout: float = 0.0) -> None:
        """Raise RuntimeError if the kernel isn't idle yet (polled by molten's tick)."""
        start = time.time()
        while True:
            try:
                response = self.requests.get(
                    self._kernel_api_base, headers=self._headers, timeout=REQUEST_TIMEOUT
                )
                state = response.json().get("execution_state")
            except Exception:
                state = None

            # a reattached kernel may be busy with a long job; don't block on it
            if state == "idle" or (state == "busy" and self._kernel_info.get("_reattached")):
                break
            if time.time() - start >= timeout:
                raise RuntimeError(f"Kernel not ready (state: {state})")
            time.sleep(0.1)
        # (Nothing to discard here: only replies to our own requests are queued, and a cell run
        # right after connecting must keep its output. Discarding them left it "On Hold".)

    # --- messaging --------------------------------------------------------------------------

    def _make_msg(self, msg_type: str, content: Dict[str, Any], channel: str,
                  parent_header: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        header = {
            "msg_id": uuid.uuid4().hex,
            "msg_type": msg_type,
            "session": self._session_id,
            "username": "molten",
            "date": _now(),
            "version": "5.3",
        }
        return {
            "header": header,
            "parent_header": parent_header or {},
            "metadata": {},
            "content": content,
            "channel": channel,
            "buffers": [],
        }

    def _send(self, msg: Dict[str, Any]) -> None:
        if self.connection_error:
            raise RuntimeError(self.connection_error)
        self._socket.send(json.dumps(msg))

    def execute(self, code: str) -> str:
        msg = self._make_msg(
            "execute_request",
            {
                "code": code,
                "silent": False,
                "store_history": True,
                "user_expressions": {},
                "allow_stdin": True,
                "stop_on_error": True,
            },
            channel="shell",
        )
        msg_id = msg["header"]["msg_id"]
        with self._lock:
            self._own_msg_ids.add(msg_id)
        self._send(msg)
        return msg_id

    def input(self, value: str) -> None:
        """Reply to the most recent input_request (stdin)."""
        parent = getattr(self, "_last_input_request", None)
        if parent is None:
            return
        self._send(self._make_msg("input_reply", {"value": value}, "stdin", parent))
        self._last_input_request = None

    def get_iopub_msg(self, **kwargs) -> Dict[str, Any]:
        return self._iopub_queue.get_nowait()

    def get_stdin_msg(self, **kwargs) -> Optional[Dict[str, Any]]:
        try:
            msg = self._stdin_queue.get_nowait()
        except EmptyQueueException:
            return None
        if msg.get("msg_type") == "input_request":
            self._last_input_request = msg["header"]
        return msg

    def shutdown(self) -> None:
        self._closed = True
        try:
            if self._socket is not None:
                self._socket.close()
        except Exception:
            pass
        if self._kernel_info.get("_attached") or self._kernel_info.get("_keep"):
            return  # we didn't start it / asked to keep it, so leave it running
        session_id = self._kernel_info.get("_session_id")
        url = (f"{self._base_url}/api/sessions/{session_id}" if session_id
               else self._kernel_api_base)
        try:
            self.requests.delete(url, headers=self._headers, timeout=5)
        except Exception:
            pass  # e.g. the SSH tunnel is already gone

    def cleanup_connection_file(self) -> None:
        pass


def resolve_kernel_id(url: str) -> Optional[str]:
    """The id of the server kernel a molten URL points at, without starting anything: the
    `kernel_id` given, or the kernel of the `session` (file) if the server has one. None when the
    URL would start a new kernel."""
    parsed = urlparse(url)
    query = parse_qs(parsed.query)
    if query.get("kernel_id"):
        return query["kernel_id"][0]
    if not query.get("session"):
        return None
    base = f"{parsed.scheme}://{parsed.netloc}{parsed.path}".rstrip("/")
    headers = {"Authorization": f"token {query['token'][0]}"} if query.get("token") else {}
    try:
        import requests

        response = requests.get(f"{base}/api/sessions", headers=headers, timeout=REQUEST_TIMEOUT)
        for session in response.json() if response.ok else []:
            if session.get("path") == query["session"][0] and session.get("kernel"):
                return session["kernel"]["id"]
    except Exception:
        pass
    return None


class JupyterAPIManager:
    def __init__(self, url: str):
        parsed_url = urlparse(url)
        self._base_url = f"{parsed_url.scheme}://{parsed_url.netloc}{parsed_url.path}".rstrip("/")

        query = parse_qs(parsed_url.query)

        def first(*names: str) -> Optional[str]:
            for name in names:
                if query.get(name):
                    return query[name][0]
            return None

        self._token = first("token")
        self._kernel_name = first("kernel_name", "kernel")
        self._kernel_id = first("kernel_id")
        self._path = first("path")
        self._session = first("session")
        self._keep_kernel = first("keep_kernel") in ("1", "true", "yes")
        # set after start_kernel: True if we reattached to a kernel that was already running
        self.reattached = False

        if self._token:
            self._headers = {"Authorization": f"token {self._token}"}
        else:
            # Server must run without auth (e.g. --IdentityProvider.token='').
            self._headers = {}

        import requests

        self.requests = requests
        self.state = RuntimeState.STARTING

    def _check(self, response, what: str) -> Dict[str, Any]:
        if response.status_code in (401, 403):
            raise RuntimeError(
                f"{what}: Jupyter Server rejected the request ({response.status_code}). "
                "Is the token correct?"
            )
        try:
            data = response.json()
        except ValueError:
            data = None
        if not response.ok or not isinstance(data, dict):
            raise RuntimeError(
                f"{what}: unexpected response from {response.url} ({response.status_code}). "
                "The URL may be incorrect."
            )
        return data

    def start_kernel(self) -> None:
        url = f"{self._base_url}/api/kernels"
        if self._kernel_id:
            response = self.requests.get(
                f"{url}/{self._kernel_id}", headers=self._headers, timeout=REQUEST_TIMEOUT
            )
            self._kernel_info = self._check(response, f"Attaching to kernel {self._kernel_id}")
            self._kernel_info["_attached"] = True
            self.reattached = True
            self._kernel_info["_reattached"] = True
        elif self._session:
            self._kernel_info = self._start_session(url)
        else:
            body: Dict[str, Any] = {}
            if self._kernel_name:
                body["name"] = self._kernel_name
            if self._path:
                body["path"] = self._path
            response = self.requests.post(
                url, headers=self._headers, json=body, timeout=REQUEST_TIMEOUT
            )
            self._kernel_info = self._check(response, "Starting kernel")
        assert "id" in self._kernel_info, "Could not connect to Jupyter Server API."
        self._kernel_info["_keep"] = self._keep_kernel
        self._kernel_api_base = f"{url}/{self._kernel_info['id']}"

    def _start_session(self, kernels_url: str) -> Dict[str, Any]:
        sessions_url = f"{self._base_url}/api/sessions"
        response = self.requests.get(sessions_url, headers=self._headers, timeout=REQUEST_TIMEOUT)
        sessions = response.json() if response.ok else []
        for session in sessions if isinstance(sessions, list) else []:
            if session.get("path") == self._session and session.get("kernel"):
                # reattach to the kernel this file was using before
                response = self.requests.get(f"{kernels_url}/{session['kernel']['id']}",
                                             headers=self._headers, timeout=REQUEST_TIMEOUT)
                info = self._check(response, "Reattaching to kernel")
                info["_session_id"] = session["id"]
                info["_reattached"] = True
                self.reattached = True
                return info

        body: Dict[str, Any] = {
            "path": self._session,
            "name": self._session.rsplit("/", 1)[-1],
            "type": "notebook",
            "kernel": {"name": self._kernel_name} if self._kernel_name else {},
        }
        response = self.requests.post(sessions_url, headers=self._headers, json=body,
                                      timeout=REQUEST_TIMEOUT)
        session = self._check(response, "Starting kernel session")
        info = session["kernel"]
        info["_session_id"] = session["id"]
        return info

    @property
    def kernel_id(self) -> str:
        return self._kernel_info["id"]

    @property
    def kernel_spec(self) -> SimpleNamespace:
        """Like jupyter_client's KernelSpec (language, argv, resource_dir), read from the server.
        Used by :MoltenExportOutput / :MoltenImportOutput and :MoltenInfo."""
        if getattr(self, "_kernel_spec", None) is None:
            name = self._kernel_info.get("name", "")
            spec: Dict[str, Any] = {}
            try:
                response = self.requests.get(f"{self._base_url}/api/kernelspecs/{name}",
                                             headers=self._headers, timeout=REQUEST_TIMEOUT)
                spec = response.json().get("spec", {}) if response.ok else {}
            except Exception:
                pass
            self._kernel_spec = SimpleNamespace(
                name=name,
                language=spec.get("language", "python"),
                argv=spec.get("argv", []),
                resource_dir=f"(on the server) {self._base_url}",
                display_name=spec.get("display_name", name),
            )
        return self._kernel_spec

    def client(self) -> JupyterAPIClient:
        return JupyterAPIClient(
            url=self._base_url,
            kernel_info=self._kernel_info,
            headers=self._headers,
            token=self._token,
        )

    def interrupt_kernel(self) -> None:
        self.requests.post(
            f"{self._kernel_api_base}/interrupt", headers=self._headers, timeout=REQUEST_TIMEOUT
        )

    def restart_kernel(self) -> None:
        self.state = RuntimeState.STARTING
        self.requests.post(
            f"{self._kernel_api_base}/restart", headers=self._headers, timeout=REQUEST_TIMEOUT
        )
