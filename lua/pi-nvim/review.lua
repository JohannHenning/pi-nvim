local M = {}

-- pi review protocol: when a prompt is sent from Neovim, the pi bridge
-- extension writes a "review bundle" next to the session socket. This module
-- picks it up and flips the affected buffers into a snapshot-diff mode so the
-- user can review exactly what pi changed (and only that) with the local diff
-- viewer (mini.diff), regardless of their own uncommitted edits.
--
-- Reference text = the file content just before pi edited it (pre-image), NOT
-- the git index, so unrelated working-tree changes never pollute the review.
--
-- Bundle format (JSON): { "id": string, "origin": "nvim", "files": [
--   { "path": "/abs/file", "before": ["line", ...] }
-- ] }
--
-- Locations (unix): <socket>.review.json and /tmp/pi-nvim-latest.sock.review.json
-- The bundle is kept on disk after being applied so :PiReview can re-apply it
-- to buffers opened later; :PiReviewClear removes it.

--- Canonicall resolves symlinks to an absolute path, or nil when missing.
--- Uses vim.uv.fs_realpath (luv's name for realpath) with a resolve() fallback.
local realpath = vim.uv.fs_realpath or function(p)
  local r = vim.fn.resolve(p)
  return (r ~= "") and r or nil
end

--- @type table<number, { prev_config: table|nil }>
local reviewed = {}

--- @type string|nil
local last_bundle_id = nil

local META_NOTIFY = "Pi review: %d buffer(s) switched to snapshot diff — <leader>go to inspect, :PiReviewClear to end"
local NO_MINIDIFF_NOTIFY = "Pi review: found edits, but mini.diff is not loaded (LazyVim extra: mini-diff) — install it to view them"
local warned_no_minidiff = false

--- @param core table pi-nvim main module (for get_socket_path)
function M.init(core)
  M.core = core

  vim.api.nvim_create_user_command("PiReview", function()
    M.process_pending()
  end, { desc = "Apply pending pi review bundle to open buffers" })

  vim.api.nvim_create_user_command("PiReviewClear", function()
    M.clear()
  end, { desc = "Restore git-source diff and remove pending review bundles" })

  local aug = vim.api.nvim_create_augroup("PiNvimReview", { clear = true })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = aug,
    callback = function(ev)
      reviewed[ev.buf] = nil
    end,
  })

  M.timer = vim.uv.new_timer()
  M.timer:start(0, 1000, vim.schedule_wrap(function()
    -- Only poll while a pi session is reachable (same gate as the reload timer).
    if M.core and M.core.get_socket_path() then
      M.process_pending()
    end
  end))
end

--- Candidate bundle paths for the current session.
--- Windows: the socket is a named pipe, review bundles are unsupported there.
--- @return string[]
function M.bundle_candidates()
  if vim.fn.has("win32") == 1 then return {} end
  local out = {}
  local sock = M.core and M.core.get_socket_path()
  if sock then
    table.insert(out, sock .. ".review.json")
  end
  -- Fallback when get_socket_path resolved to the latest symlink.
  table.insert(out, "/tmp/pi-nvim-latest.sock.review.json")
  return out
end

--- Check for a pending review bundle and apply it (once per bundle id).
function M.process_pending()
  for _, candidate in ipairs(M.bundle_candidates()) do
    if vim.uv.fs_stat(candidate) then
      M.process_bundle(candidate)
    end
  end
end

--- @param bundle_path string
function M.process_bundle(bundle_path)
  local ok_read, content = pcall(vim.fn.readfile, bundle_path)
  if not ok_read or not content then return end
  local ok_json, bundle = pcall(vim.json.decode, table.concat(content, "\n"))
  if not ok_json or type(bundle) ~= "table" or type(bundle.files) ~= "table" then
    vim.notify("Pi review: ignored invalid bundle: " .. bundle_path, vim.log.levels.WARN)
    return
  end

  -- Skip if this bundle was already applied (prevents notify spam on the poll).
  if bundle.id and bundle.id == last_bundle_id then return end

  local ok_diff, minidiff = pcall(require, "mini.diff")
  if not ok_diff then
    if not warned_no_minidiff then
      warned_no_minidiff = true
      vim.notify(NO_MINIDIFF_NOTIFY, vim.log.levels.WARN)
    end
    last_bundle_id = bundle.id
    return
  end

  local applied = 0
  for _, file in ipairs(bundle.files) do
    if type(file.path) == "string" and type(file.before) == "table" then
      applied = applied + M.apply_to_buffers(file.path, file.before, minidiff)
    end
  end

  if applied > 0 then
    vim.notify(string.format(META_NOTIFY, applied), vim.log.levels.INFO)
  end
  last_bundle_id = bundle.id
end

--- Switch every open buffer matching `path` into snapshot-diff mode.
--- @param path string absolute path from the bundle
--- @param before string[] pre-image lines
--- @param minidiff table mini.diff module
--- @return integer number of buffers switched
function M.apply_to_buffers(path, before, minidiff)
  local target = realpath(path)
  if not target then return 0 end

  local applied = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local bname = vim.api.nvim_buf_get_name(buf)
      if bname ~= "" then
        local bpath = realpath(bname)
        if bpath == target then
          if M.apply_to_buffer(buf, before, minidiff) then
            applied = applied + 1
          end
        end
      end
    end
  end
  return applied
end

--- @param buf integer
--- @param before string[]
--- @param minidiff table
--- @return boolean true if the buffer is now in snapshot-diff mode
function M.apply_to_buffer(buf, before, minidiff)
  if vim.b[buf].minidiff_review then
    -- Already in review mode (e.g. :PiReview on a later-opened buffer):
    -- just refresh the reference text.
    pcall(minidiff.set_ref_text, buf, before)
    return true
  end

  reviewed[buf] = { prev_config = vim.b[buf].minidiff_config }
  vim.b[buf].minidiff_review = true
  vim.b[buf].minidiff_config = { source = { minidiff.gen_source.none() } }
  pcall(minidiff.disable, buf)
  pcall(minidiff.enable, buf)
  pcall(minidiff.set_ref_text, buf, before)
  return true
end

--- Restore git-source diff on reviewed buffers and drop pending bundles.
function M.clear()
  local ok_diff, minidiff = pcall(require, "mini.diff")
  for buf in pairs(reviewed) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].minidiff_review = nil
      vim.b[buf].minidiff_config = nil
      if ok_diff then
        pcall(minidiff.disable, buf)
        pcall(minidiff.enable, buf)
      end
    end
    reviewed[buf] = nil
  end

  for _, candidate in ipairs(M.bundle_candidates()) do
    pcall(vim.fn.delete, candidate)
  end
  last_bundle_id = nil
  warned_no_minidiff = false
  vim.notify("Pi review: cleared — git-source diff restored", vim.log.levels.INFO)
end

return M