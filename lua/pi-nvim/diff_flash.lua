local M = {}

--- @class pi_nvim.DiffFlashConfig
--- @field enabled boolean|nil
--- @field duration_ms integer|nil

M._ns = vim.api.nvim_create_namespace("pi_nvim_diff_flash")

--- @type table<integer, { lines: string[], timer: uv_timer_t|nil }>
M._snapshots = {}

--- @type pi_nvim.DiffFlashConfig
M._config = {
  enabled = true,
  duration_ms = 3000,
}

--- Capture the current buffer lines as the baseline for future diffs.
--- @param bufnr integer
function M.snapshot(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local existing = M._snapshots[bufnr]
  local timer = existing and existing.timer or nil
  M._snapshots[bufnr] = {
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    timer = timer,
  }
end

--- Diff the current buffer against its snapshot, paint added/changed hunks,
--- and schedule a clear. Skips deletions. Idempotent on rapid re-fires
--- (cancels the in-flight timer and repaints).
--- @param bufnr integer
function M.flash(bufnr)
  if not M._config.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local snap = M._snapshots[bufnr]
  if not snap or not snap.lines then
    -- No baseline yet (e.g. buffer first reloaded). Establish one for next time.
    M.snapshot(bufnr)
    return
  end

  -- Trailing "\n" matters: without it, vim.diff merges adjacent hunks (e.g. a
  -- modified line and an appended line collapse into one, breaking add/change
  -- distinction). The newline gives the diff a stable line boundary.
  local old = table.concat(snap.lines, "\n") .. "\n"
  local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Buffer became empty (e.g. pi truncated the file). Spec: don't highlight pure deletions.
  if #new_lines == 1 and new_lines[1] == "" then
    M.snapshot(bufnr)
    return
  end

  local new = table.concat(new_lines, "\n") .. "\n"

  if old == new then return end

  local ok, hunks = pcall(vim.diff, old, new, { result_type = "indices" })
  if not ok or type(hunks) ~= "table" then return end

  -- Cancel any pending timer and clear previous extmarks before repainting.
  if snap.timer then
    snap.timer:stop()
    snap.timer:close()
    snap.timer = nil
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)

  for _, hunk in ipairs(hunks) do
    local _start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
    if count_b > 0 then
      local hl = (count_a == 0) and "DiffAdd" or "DiffChange"
      for line = start_b, start_b + count_b - 1 do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M._ns, line - 1, 0, {
          line_hl_group = hl,
        })
      end
    end
  end

  local timer = vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)
      M.snapshot(bufnr)
    end
    local s = M._snapshots[bufnr]
    if s then s.timer = nil end
  end, M._config.duration_ms)

  -- Re-fetch snapshot record in case snapshot() was called during paint.
  -- If clear() ran between scheduling and now, cancel the orphan immediately
  -- so it can't outlive the buffer (and possibly fire on a recycled bufnr).
  local current = M._snapshots[bufnr]
  if current then
    current.timer = timer
  else
    timer:stop()
    timer:close()
  end
end

--- Remove any pending highlights and timer for a buffer, drop its snapshot.
--- @param bufnr integer
function M.clear(bufnr)
  local snap = M._snapshots[bufnr]
  if snap and snap.timer then
    snap.timer:stop()
    snap.timer:close()
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)
  end
  M._snapshots[bufnr] = nil
end

--- @param opts pi_nvim.DiffFlashConfig|nil
function M.setup(opts)
  M._config = vim.tbl_deep_extend("force", M._config, opts or {})

  -- Always reset the augroup so a re-call with enabled=false fully tears down
  -- any autocmds registered by a previous setup() call.
  local group = vim.api.nvim_create_augroup("PiNvimDiffFlash", { clear = true })
  if not M._config.enabled then return end

  -- Snapshot any already-loaded buffers so we have a baseline immediately.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.snapshot(bufnr)
    end
  end

  -- BufReadPost intentionally omitted: it fires *before* FileChangedShellPost
  -- on external reloads, so snapshotting there would clobber the pre-change
  -- baseline and flash() would diff identical buffers. Initial baselines come
  -- from the list_bufs() loop above; flash() self-heals via snapshot() when
  -- snap is nil for buffers loaded after setup.
  vim.api.nvim_create_autocmd({ "BufNewFile", "BufWritePost" }, {
    group = group,
    callback = function(args) M.snapshot(args.buf) end,
  })

  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    group = group,
    callback = function(args) M.flash(args.buf) end,
  })

  -- BufUnload included so a re-`:edit` of the same bufnr starts from a fresh
  -- baseline (otherwise the next FileChangedShellPost would diff against
  -- stale lines from before the unload).
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete", "BufUnload" }, {
    group = group,
    callback = function(args) M.clear(args.buf) end,
  })
end

return M
