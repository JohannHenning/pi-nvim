local M = {}

--- Directory holding the .info manifests / marker files. Must match the
--- pi extension's SOCKETS_DIR: /tmp on unix, %TEMP% on Windows.
local function sockets_dir()
  if vim.fn.has("win32") == 1 then
    local tmp = vim.env.TEMP or vim.env.TMP
    return tmp and (tmp:gsub("\\", "/") .. "/pi-nvim-sockets") or nil
  end
  return "/tmp/pi-nvim-sockets"
end

--- @class pi_nvim.Config
--- @field socket_path string|nil  Override socket path (default: auto-discover)
--- @field set_default_keymaps boolean|nil  Whether to create the default <leader>p mappings (default: true)
--- @field diff table|nil  Diff review configuration
M.config = {
  socket_path = nil,
  set_default_keymaps = true,
  diff = {
    enabled = true,
    keys = {
      accept = "<Leader>da",
      reject = "<Leader>dr",
      edit_note = "<Leader>dn",
      delete_note = "<Leader>dx",
      list_notes = "<Leader>dN",
      expand_context = "<Leader>de",
      shrink_context = "<Leader>ds",
    },
  },
}

--- @type table<number, { socket: string, client: uv_pipe_t, tabId: number, connected: boolean, registered: boolean }>
M.tab_sockets = {}

--- @type number|nil
M.current_tab_id = nil

--- @type table<string, fun(err: string|nil, resp: table|nil)>
M.pending_requests = {}

--- @type number
M.request_id_counter = 0

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Setup diff review if enabled
  if M.config.diff and M.config.diff.enabled then
    require("pi-nvim.diff")
  end

  -- Auto-reload buffers when files are changed externally (e.g. by pi agent).
  -- Only polls when a pi session is reachable. Respects existing autoread setting.
  if not vim.o.autoread then
    vim.o.autoread = true
  end
  local reload_timer = vim.uv.new_timer()
  reload_timer:start(0, 1000, vim.schedule_wrap(function()
    if not M.get_any_socket_path() then return end
    -- Per-buffer checktime, skipping modified buffers: a global `checktime`
    -- prompts the W11 "load file?" dialog whenever a modified buffer's file
    -- changed on disk (e.g. the agent already wrote it by the time the diff
    -- review opens). Unknown buffers reload silently, modified ones are left
    -- to their owner.
    for _, buf in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
      if
        buf.loaded
        and not buf.changed
        and buf.name ~= ""
        and vim.fn.filereadable(buf.name) == 1
      then
        pcall(vim.cmd, "silent! checktime " .. vim.fn.fnameescape(buf.name))
      end
    end
  end))

  -- Commands
  vim.api.nvim_create_user_command("PiSend", function()
    M.prompt()
  end, { desc = "Send a prompt to pi" })

  vim.api.nvim_create_user_command("PiSendFile", function()
    M.send_file()
  end, { desc = "Send current file to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendSelection", function()
    M.send_selection()
  end, { range = true, desc = "Send visual selection to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendBuffer", function()
    M.send_buffer()
  end, { desc = "Send entire buffer to pi with a prompt" })

  vim.api.nvim_create_user_command("Pi", function(args)
    local ui = require("pi-nvim.ui")
    local selection = nil
    if args.range == 2 then
      selection = ui.capture_selection()
    end
    ui.open({ selection = selection })
  end, { range = true, desc = "Open pi send dialog" })

  if M.config.set_default_keymaps then
    -- Default keymap: <leader>p in normal and visual mode
    vim.keymap.set("n", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send to pi" })
    vim.keymap.set("v", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send selection to pi" })
  end

  vim.api.nvim_create_user_command("PiPing", function()
    M.ping()
  end, { desc = "Ping the pi session" })

  vim.api.nvim_create_user_command("PiSessions", function()
    M.list_sessions()
  end, { desc = "List running pi sessions" })

  -- Per-tab socket management
  M.init_tab_socket_management()
end

--- Initialize per-tab socket connection management
function M.init_tab_socket_management()
  local aug = vim.api.nvim_create_augroup("PiNvimTabSockets", { clear = true })

  -- On tab enter, ensure we have a socket connection for this tab
  vim.api.nvim_create_autocmd("TabEnter", {
    group = aug,
    callback = function()
      local tabId = vim.api.nvim_get_current_tabpage()
      M.ensure_tab_socket(tabId)
    end,
  })

  -- On tab close, clean up socket
  vim.api.nvim_create_autocmd("TabClosed", {
    group = aug,
    callback = function(args)
      local tabId = tonumber(args.match)
      if tabId and tabId > 0 then
        pcall(M.close_tab_socket, tabId)
      end
    end,
  })

  -- Initialize socket for current tab
  local currentTab = vim.api.nvim_get_current_tabpage()
  M.ensure_tab_socket(currentTab)
end

--- Ensure a socket connection exists for the given tab
--- @param tabId number
function M.ensure_tab_socket(tabId)
  if M.tab_sockets[tabId] and M.tab_sockets[tabId].connected then
    M.current_tab_id = tabId
    -- Re-register tab in case pi session restarted
    if M.tab_sockets[tabId].client and not M.tab_sockets[tabId].registered then
      M.register_tab(tabId)
    end
    return
  end

  -- Find socket for the current cwd (shared across tabs)
  local sock_path = M.get_shared_socket_path()
  if not sock_path then
    -- No pi session in this cwd tree yet
    M.tab_sockets[tabId] = { socket = nil, client = nil, tabId = tabId, connected = false, registered = false }
    M.current_tab_id = tabId
    vim.notify(
      string.format("No pi session in this directory tree. Start pi here or use :PiSessions to pick one."),
      vim.log.levels.INFO
    )
    return
  end

  M.connect_to_socket(tabId, sock_path)
  M.current_tab_id = tabId
end

--- Get the shared socket path for the current cwd (used by all tabs)
--- @return string|nil
function M.get_shared_socket_path()
  if M.config.socket_path then
    return M.config.socket_path
  end

  local sd = sockets_dir()
  if not sd then return nil end
  local cwd = vim.uv.cwd()

  local ok, files = pcall(vim.fn.glob, sd .. "/*.info", false, true)
  if ok and files then
    local sep = package.config:sub(1, 1)
    local best_sock, best_mtime = nil, 0
    for _, info_path in ipairs(files) do
      local content_ok, content = pcall(vim.fn.readfile, info_path)
      if content_ok and content and content[1] then
        local parsed_ok, info = pcall(vim.json.decode, content[1])
        if parsed_ok and info then
          local sock_file = info_path:sub(1, -6)
          local stat = vim.uv.fs_stat(sock_file)
          local addr = info.socket or sock_file
          if stat then
            -- Only match pi sessions in this cwd or an ancestor (pi in repo root,
            -- Neovim opened in a subdir). Unrelated dirs require a manual pick
            -- via :PiSessions — auto-discovery must not bridge into them.
            local scwd = info.cwd or ""
            local in_cwd_tree = cwd == scwd
              or (scwd ~= "" and cwd:sub(1, #scwd + 1) == scwd .. sep)
            if in_cwd_tree and stat.mtime.sec > best_mtime then
              best_mtime = stat.mtime.sec
              best_sock = addr
            end
          end
        end
      end
    end
    if best_sock then return best_sock end
  end

  -- No cwd-matching pi session found. Caller will mark the tab as unconnected;
  -- the user can pick a session deliberately with :PiSessions.
  return nil
end

--- Connect to the shared socket for a specific tab
--- @param tabId number
--- @param sock_path string
function M.connect_to_socket(tabId, sock_path)
  local client = vim.uv.new_pipe(false)
  if not client then
    vim.notify("Failed to create pipe for tab " .. tabId, vim.log.levels.ERROR)
    return
  end

  client:connect(sock_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Failed to connect to pi for tab " .. tabId .. ": " .. err, vim.log.levels.ERROR)
        M.tab_sockets[tabId] = { socket = sock_path, client = nil, tabId = tabId, connected = false, registered = false }
      end)
      return
    end

    -- Register this tab with the pi session
    M.tab_sockets[tabId] = { socket = sock_path, client = client, tabId = tabId, connected = true, registered = false }
    M.register_tab(tabId)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        client:close()
        vim.schedule(function()
          M.handle_disconnect(tabId, read_err)
        end)
        return
      end
      if data then
        buf = buf .. data
        local nl = buf:find("\n")
        while nl do
          local line = buf:sub(1, nl - 1)
          buf = buf:sub(nl + 1)
          -- Socket callbacks run in a fast event context where most nvim API
          -- calls (nvim_set_hl, nvim_open_win, ...) are forbidden. Defer to the
          -- main loop; vim.schedule preserves ordering.
          vim.schedule(function()
            M.handle_socket_message(tabId, line)
          end)
          nl = buf:find("\n")
        end
      else
        -- EOF
        client:close()
        vim.schedule(function()
          M.handle_disconnect(tabId, "EOF")
        end)
      end
    end)
  end)
end

--- Register this tab with the pi session
--- @param tabId number
function M.register_tab(tabId)
  local sock = M.tab_sockets[tabId]
  if not sock or not sock.connected or not sock.client then
    return
  end

  local cwd = vim.uv.cwd()
  local nvimPid = vim.fn.getpid()
  local payload = vim.json.encode({ type = "register_tab", tabId = tabId, cwd = cwd, nvimPid = nvimPid }) .. "\n"
  sock.client:write(payload)
  sock.registered = true
end

--- Handle incoming message from pi socket
--- @param tabId number
--- @param line string
function M.handle_socket_message(tabId, line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or not msg then return end

  -- Check if this is a response to a pending request
  if msg.request_id and M.pending_requests[msg.request_id] then
    local cb = M.pending_requests[msg.request_id]
    M.pending_requests[msg.request_id] = nil
    cb(nil, msg)
    return
  end

  if msg.type == "diff_review" then
    -- Handle diff review request from pi
    local diff = require("pi-nvim.diff")
    diff.handle_diff_review(msg, M)
  elseif msg.type == "pong" then
    -- Ping response (handled via request_id above)
  end
end

--- Handle socket disconnect
--- @param tabId number
--- @param err string
function M.handle_disconnect(tabId, err)
  local sock = M.tab_sockets[tabId]
  if sock and sock.client then
    sock.client:close()
  end
  M.tab_sockets[tabId] = { socket = sock and sock.socket or nil, client = nil, tabId = tabId, connected = false, registered = false }
  vim.notify("Pi disconnected from tab " .. tabId .. ": " .. err, vim.log.levels.WARN)
end

--- Close socket for a tab
--- @param tabId number
function M.close_tab_socket(tabId)
  local sock = M.tab_sockets[tabId]
  if not sock then return end
  if sock.client then
    local ok, err = pcall(function() sock.client:close() end)
    if not ok then
      vim.notify("Error closing pi socket: " .. err, vim.log.levels.WARN)
    end
  end
  M.tab_sockets[tabId] = nil
end

--- Get the socket path for the current tab (uses shared socket)
--- @return string|nil
function M.get_socket_path()
  local tabId = M.current_tab_id or vim.api.nvim_get_current_tabpage()
  local sock = M.tab_sockets[tabId]
  if sock and sock.connected then
    return sock.socket
  end
  -- Fallback to shared socket discovery
  return M.get_shared_socket_path()
end

--- Get any available socket path (fallback for backwards compatibility)
--- @return string|nil
function M.get_any_socket_path()
  return M.get_shared_socket_path()
end

--- Send a raw JSON message to the pi socket for the current tab
--- @param msg table
--- @param cb fun(err: string|nil, response: table|nil)|nil
function M.send_raw(msg, cb)
  local tabId = M.current_tab_id or vim.api.nvim_get_current_tabpage()
  local sock = M.tab_sockets[tabId]

  if not sock or not sock.connected or not sock.client then
    -- Try to connect
    M.ensure_tab_socket(tabId)
    sock = M.tab_sockets[tabId]
    if not sock or not sock.connected or not sock.client then
      local err = "No pi session found for tab " .. tabId .. ". Is pi running with pi-nvim extension?"
      vim.notify(err, vim.log.levels.ERROR)
      if cb then cb(err, nil) end
      return
    end
  end

  -- When a callback is wanted, attach a request_id so the response can be
  -- correlated — and write the message EXACTLY ONCE. Sending it twice (once
  -- plain, once with request_id) dispatches every prompt/ping twice to the pi
  -- side, and two concurrent dispatches can race into agent.prompt()'s
  -- "already processing" guard, dropping one prompt into a <runtime> error.
  local out_msg = msg
  if cb then
    M.request_id_counter = M.request_id_counter + 1
    out_msg = vim.tbl_extend("force", msg, { request_id = tostring(M.request_id_counter) })
    M.pending_requests[out_msg.request_id] = cb
  end
  sock.client:write(vim.json.encode(out_msg) .. "\n")
end

--- Build a prompt message for the socket, prefixed with structured metadata
--- (origin, file, dirty state) so the pi-side bridge extension can react to
--- prompts requested from Neovim (review flow) vs typed in the pi terminal.
--- The prefix is stripped by the bridge before the agent sees the prompt.
--- @param message string
--- @return string
function M.build_prompt_message(message)
  local rel = vim.fn.expand("%:.")
  if rel == "" then
    return message
  end
  local meta = vim.json.encode({
    origin = "nvim",
    file = rel,
    dirty = vim.bo.modified,
    tabId = M.current_tab_id or vim.api.nvim_get_current_tabpage(),
  })
  return string.format("[pi-nvim-meta] %s\n%s", meta, message)
end

--- Send a prompt string to pi.
--- @param message string|nil  If nil, prompts the user for input
function M.prompt(message)
  if not message then
    vim.ui.input({ prompt = "Pi prompt: " }, function(input)
      if input and input ~= "" then
        M.prompt(input)
      end
    end)
    return
  end

  M.send_raw({ type = "prompt", message = M.build_prompt_message(message) }, function(err, resp)
    if err then return end
    if resp and resp.ok then
      vim.notify("Sent to pi", vim.log.levels.INFO)
    else
      vim.notify("pi error: " .. (resp and resp.error or "unknown"), vim.log.levels.ERROR)
    end
  end)
end

--- Send the current file path with optional prompt.
function M.send_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("No file open", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Pi prompt (file: " .. vim.fn.expand("%:.") .. "): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file: %s", file)
    else
      message = string.format("File: %s\n\n%s", file, input)
    end
    M.prompt(message)
  end)
end

--- Send the visual selection with a prompt.
function M.send_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getregion(start_pos, end_pos, { type = vim.fn.visualmode() })
  local selection = table.concat(lines, "\n")

  if selection == "" then
    vim.notify("Empty selection", vim.log.levels.WARN)
    return
  end

  local file = vim.fn.expand("%:.")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (selection): " }, function(input)
    if not input then return end

    local header = string.format("%s lines %d-%d", file, start_line, end_line)
    local message
    if input == "" then
      message = string.format("Look at this code from %s:\n\n```%s\n%s\n```", header, ft, selection)
    else
      message = string.format("%s\n\nFrom %s:\n```%s\n%s\n```", input, header, ft, selection)
    end
    M.prompt(message)
  end)
end

--- Send the entire buffer contents with a prompt.
function M.send_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(lines, "\n")
  local file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (buffer): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file %s:\n\n```%s\n%s\n```", file, ft, content)
    else
      message = string.format("%s\n\nFile: %s\n```%s\n%s\n```", input, file, ft, content)
    end
    M.prompt(message)
  end)
end

--- Ping the pi session to check connectivity.
function M.ping()
  M.send_raw({ type = "ping" }, function(err, resp)
    if err then
      vim.notify("Pi not reachable: " .. err, vim.log.levels.ERROR)
    elseif resp and resp.type == "pong" then
      vim.notify("Pi is alive! ✓", vim.log.levels.INFO)
    else
      vim.notify("Unexpected response from pi", vim.log.levels.WARN)
    end
  end)
end

--- List all running pi sessions (per tab).
function M.list_sessions()
  local sd = sockets_dir()
  if not sd then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end
  local ok, files = pcall(vim.fn.glob, sd .. "/*.info", false, true)
  if not ok or not files or #files == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local sessions = {}
  for _, info_path in ipairs(files) do
    local content_ok, content = pcall(vim.fn.readfile, info_path)
    if content_ok and content and content[1] then
      local parsed_ok, info = pcall(vim.json.decode, content[1])
      if parsed_ok and info then
        local sock_file = info_path:sub(1, -6)
        local alive = vim.uv.fs_stat(sock_file) ~= nil
        if alive then
          local started = ""
          if info.startedAt then
            local ok2, ts = pcall(function()
              local y, mo, d, h, mi, s = info.startedAt:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
              if h and mi then
                return string.format("%s:%s", h, mi)
              end
              return info.startedAt
            end)
            if ok2 then started = ts end
          end
          table.insert(sessions, {
            cwd = info.cwd or "?",
            pid = info.pid or "?",
            tabId = info.tabId or "?",
            started = started,
            socket = info.socket or sock_file,
          })
        end
      end
    end
  end

  -- Collect unique pi sessions by cwd (from manifests)
  local session_map = {}
  for _, info_path in ipairs(files) do
    local content_ok, content = pcall(vim.fn.readfile, info_path)
    if content_ok and content and content[1] then
      local parsed_ok, info = pcall(vim.json.decode, content[1])
      if parsed_ok and info then
        local sock_file = info_path:sub(1, -6)
        local alive = vim.uv.fs_stat(sock_file) ~= nil
        if alive then
          local started = ""
          if info.startedAt then
            local ok2, ts = pcall(function()
              local y, mo, d, h, mi, s = info.startedAt:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
              if h and mi then
                return string.format("%s:%s", h, mi)
              end
              return info.startedAt
            end)
            if ok2 then started = ts end
          end
          local cwd = info.cwd or "?"
          if not session_map[cwd] then
            session_map[cwd] = {
              cwd = cwd,
              pid = info.pid or "?",
              started = started,
              socket = info.socket or sock_file,
            }
          end
        end
      end
    end
  end

  if vim.tbl_isempty(session_map) then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  -- Build items: one per pi session (cwd), showing registered tabs
  local items = {}
  for cwd, session in pairs(session_map) do
    -- Find registered tabs for this cwd
    local registered_tabs = {}
    for tabId, sock in pairs(M.tab_sockets) do
      if sock.connected and sock.registered and sock.socket == session.socket then
        table.insert(registered_tabs, tabId)
      end
    end

    local time_str = session.started ~= "" and string.format(" started %s", session.started) or ""
    local tab_str = #registered_tabs > 0 and table.concat(registered_tabs, ",") or "none"

    table.insert(items, string.format("%s [pid %s%s] tabs: %s", cwd, session.pid, time_str, tab_str))
  end

  vim.ui.select(items, { prompt = "Pi sessions (per cwd):" }, function(choice, idx)
    if not choice or not idx then return end
    local cwd_list = {}
    for cwd, _ in pairs(session_map) do table.insert(cwd_list, cwd) end
    local session = session_map[cwd_list[idx]]
    if session then
      M.config.socket_path = session.socket
      vim.notify(string.format("Switched to pi session at %s [pid %s]", session.cwd, session.pid), vim.log.levels.INFO)
    end
  end)
end

return M