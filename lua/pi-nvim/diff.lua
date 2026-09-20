local M = {}

-- Diff review module: handles diff_review messages from pi extension
-- Opens a diff view in a new tab for reviewing proposed edits
-- Supports accept/reject/modify with notes and context expansion

--- @class pi_nvim.DiffReviewNote
--- @field buf integer
--- @field mark_ids integer[]
--- @field side "original"|"proposed"
--- @field start_row integer 0-indexed inclusive
--- @field end_row integer 0-indexed inclusive
--- @field note string
--- @field seq integer

local note_ns = vim.api.nvim_create_namespace("pi_nvim_diff_review_notes")
local NOTE_TEXT_PREFIX = "  │ "
local NOTE_SEPARATOR_PREFIX = "  "
local NOTE_SEPARATOR_CHAR = "─"

--- @param value integer
--- @param min integer
--- @param max integer
--- @return integer
local function clamp(value, min, max)
  return math.max(min, math.min(max, value))
end

--- @param note string
--- @return string
local function note_preview(note)
  local first = vim.split(note, "\n", { plain = true })[1] or ""
  if vim.fn.strdisplaywidth(first) > 80 then
    return vim.fn.strcharpart(first, 0, 77) .. "…"
  end
  return first
end

--- @param text string
--- @param width integer
--- @return string[]
local function wrap_note_line(text, width)
  width = math.max(1, width)
  if text == "" then
    return { "" }
  end

  local lines = {}
  local rest = text
  while rest ~= "" do
    local chunk = vim.fn.strcharpart(rest, 0, width)
    if chunk == "" then
      break
    end
    lines[#lines + 1] = chunk
    rest = vim.fn.strcharpart(rest, vim.fn.strchars(chunk))
  end
  return lines
end

--- @param width integer
--- @return table
local function note_separator_virt_line(width)
  local sep_width = math.max(1, width - vim.fn.strdisplaywidth(NOTE_SEPARATOR_PREFIX))
  return { { NOTE_SEPARATOR_PREFIX .. string.rep(NOTE_SEPARATOR_CHAR, sep_width), "PiNvimDiffReviewNote" } }
end

--- @param note string
--- @param width integer
--- @param separator_before boolean
--- @return table[]
local function note_virt_lines(note, width, separator_before)
  local lines = {}
  local text_width = math.max(1, width - vim.fn.strdisplaywidth(NOTE_TEXT_PREFIX))
  if separator_before then
    lines[#lines + 1] = note_separator_virt_line(width)
  end
  for _, line in ipairs(vim.split(note, "\n", { plain = true })) do
    for _, wrapped in ipairs(wrap_note_line(line, text_width)) do
      lines[#lines + 1] = { { NOTE_TEXT_PREFIX .. wrapped, "PiNvimDiffReviewNote" } }
    end
  end
  return lines
end

--- @param buf integer
--- @param row integer
--- @param virt_lines table[]
--- @param priority integer
--- @return integer
local function set_note_group_text_mark(buf, row, virt_lines, priority)
  return vim.api.nvim_buf_set_extmark(buf, note_ns, row, 0, {
    virt_lines = virt_lines,
    priority = priority,
  })
end

--- @param buf integer
--- @param row integer
--- @param text string
--- @param priority integer
--- @return integer
local function set_note_sign_mark(buf, row, text, priority)
  return vim.api.nvim_buf_set_extmark(buf, note_ns, row, 0, {
    sign_text = text,
    sign_hl_group = "PiNvimDiffReviewNote",
    priority = priority,
  })
end

--- @type table<string, { tabId: number, reviewId: string, proposedBuf: integer, currentBuf: integer, path: string, proposedWin: integer, currentWin: integer, reviewTab: integer, notes: pi_nvim.DiffReviewNote[], nextNoteSeq: number, context: { base: number, step: number, current: number } }>
local activeReviews = {}

--- Setup highlights for diff review
local function setup_highlights()
  vim.api.nvim_set_hl(0, "PiNvimDiffWinbar", { link = "WinBar" })
  vim.api.nvim_set_hl(0, "PiNvimDiffWinbarCurrent", { bold = true, fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "PiNvimDiffWinbarProposed", { bold = true, fg = "#f9e2af" })
  vim.api.nvim_set_hl(0, "PiNvimDiffWinbarHint", { fg = "#6c7086" })
  vim.api.nvim_set_hl(0, "PiNvimDiffReviewNote", { fg = "#f9e2af", bg = "#313244" })
  vim.api.nvim_set_hl(0, "PiNvimDiffReviewNoteSign", { fg = "#f9e2af" })
end

--- Read file content from disk
--- Refresh diff windows
--- @param left_win integer
--- @param right_win integer
local function refresh_diff_windows(left_win, right_win)
  for _, win in ipairs({ left_win, right_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffupdate")
      end)
    end
  end
end

--- Set diff context
--- @param context integer
local function set_diff_context(context)
  context = math.max(0, context)
  local items = {}
  for _, item in ipairs(vim.split(vim.go.diffopt, ",", { plain = true, trimempty = true })) do
    if not item:match("^context:%d+$") then
      items[#items + 1] = item
    end
  end
  items[#items + 1] = "context:" .. context
  vim.go.diffopt = table.concat(items, ",")
end

--- Get current diff context
--- @return integer
local function get_diff_context()
  for _, item in ipairs(vim.split(vim.go.diffopt, ",", { plain = true, trimempty = true })) do
    local value = item:match("^context:(%d+)$")
    if value then
      return tonumber(value) or 6
    end
  end
  return 6
end

--- Open diff review for a tool call
--- @param payload table { id, path, proposed, original, tool, edits }
--- @param send_response fun(action: string, content?: string)
function M.open_review(payload, send_response)
  setup_highlights()

  local path = payload.path
  local proposed = payload.proposed
  local original = payload.original
  local reviewId = payload.id

  -- Both sides come from the extension payload (disk state at tool-call time).
  -- NOT from the live nvim buffer: the edit tool has already run by the time
  -- the review opens, so a live buffer would already contain the edit and the
  -- diff would be empty ("reversed"/no-op).
  local proposed_lines = vim.split(proposed, "\n", { plain = true })

  -- Handle trailing newline
  local proposed_eol = #proposed_lines > 0 and proposed_lines[#proposed_lines] == ""
  if proposed_eol then
    table.remove(proposed_lines)
  end

  local rel_path = vim.fn.fnamemodify(path, ":~:.")
  local after_name = "pi-nvim://review" .. path
  local prev_diffopt = vim.go.diffopt
  local diff_context_config = { base = 6, step = 5 }
  local initial_context = diff_context_config.base
  local context_step = diff_context_config.step
  local notes = {} ---@type pi_nvim.DiffReviewNote[]

  set_diff_context(initial_context)

  local prev_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local review_tab = vim.api.nvim_get_current_tabpage()

  -- Left: frozen snapshot of the original (pre-edit) content. A scratch buffer,
  -- not the live file buffer — the user's buffer is left fully alone (no more
  -- write-protecting it during review), and the diff cannot drift if the buffer
  -- later reloads from disk.
  local left_win = vim.api.nvim_get_current_win()
  -- :tabnew created an empty no-name buffer in this window; once we swap in the
  -- snapshot it lingers in the buffer list after the review. Capture and remove it.
  local tabnew_buf = vim.api.nvim_win_get_buf(left_win)
  local before_name = "pi-nvim://original" .. path
  local stale_orig = vim.fn.bufnr(before_name)
  if stale_orig ~= -1 then
    vim.api.nvim_buf_delete(stale_orig, { force = true })
  end
  local original_lines = vim.split(original, "\n", { plain = true })
  local original_eol = #original_lines > 0 and original_lines[#original_lines] == ""
  if original_eol then
    table.remove(original_lines)
  end
  local current_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, original_lines)
  vim.bo[current_buf].eol = original_eol
  vim.bo[current_buf].modified = false
  vim.bo[current_buf].bufhidden = "wipe"
  vim.bo[current_buf].modifiable = false
  vim.bo[current_buf].readonly = true
  vim.api.nvim_buf_set_name(current_buf, before_name)
  local ft = vim.filetype.match({ filename = path }) or ""
  vim.api.nvim_win_set_buf(left_win, current_buf)

  -- Clean up the empty [No Name] buffer that :tabnew left behind
  if tabnew_buf ~= current_buf and vim.api.nvim_buf_is_valid(tabnew_buf) then
    local nm = vim.api.nvim_buf_get_name(tabnew_buf)
    local lc = vim.api.nvim_buf_line_count(tabnew_buf)
    local empty_text = lc == 0
      or (lc == 1 and vim.api.nvim_buf_get_lines(tabnew_buf, 0, 1, false)[1] == "")
    if nm == "" and empty_text then
      pcall(vim.api.nvim_buf_delete, tabnew_buf, { force = true })
    end
  end

  -- Right: proposed changes (editable)
  local stale = vim.fn.bufnr(after_name)
  if stale ~= -1 then
    vim.api.nvim_buf_delete(stale, { force = true })
  end
  local proposed_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(proposed_buf, 0, -1, false, proposed_lines)
  vim.bo[proposed_buf].eol = proposed_eol
  vim.bo[proposed_buf].buftype = "acwrite"
  -- Filling via nvim_buf_set_lines marks the buffer modified; this is review
  -- data, not user edits, so don't prompt to save it on exit (E676 on acwrite).
  vim.bo[proposed_buf].modified = false
  -- Wipe the buffer once the review tab closes; leaving it loaded (acwrite +
  -- modified) makes :q/:qa prompt to save it and then fail with E676.
  vim.bo[proposed_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(proposed_buf, after_name)
  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  -- :vsplit puts the new window left or right depending on 'splitright';
  -- pin the layout so ORIGINAL is always left and PROPOSED always right.
  if
    vim.api.nvim_win_call(right_win, function() return vim.fn.winnr() end) == 1
  then
    vim.api.nvim_set_current_win(right_win)
    vim.cmd("wincmd L")
  end
  vim.api.nvim_win_set_buf(right_win, proposed_buf)
  if ft ~= "" then
    vim.bo[proposed_buf].filetype = ft
  end

  local is_markdown = ft == "markdown"

  local function apply_wrap_options()
    for _, w in ipairs({ left_win, right_win }) do
      if vim.api.nvim_win_is_valid(w) then
        vim.wo[w].wrap = is_markdown or vim.go.wrap
        vim.wo[w].linebreak = is_markdown or vim.go.linebreak
      end
    end
  end

  -- Reset window options
  for _, w in ipairs({ left_win, right_win }) do
    vim.wo[w].number = true
    vim.wo[w].relativenumber = vim.go.relativenumber
    vim.wo[w].signcolumn = vim.go.signcolumn
    vim.wo[w].conceallevel = 0
    vim.wo[w].concealcursor = ""
    vim.wo[w].wrap = is_markdown or vim.go.wrap
    vim.wo[w].linebreak = is_markdown or vim.go.linebreak
    vim.wo[w].list = vim.go.list
    vim.wo[w].cursorline = vim.go.cursorline
    vim.wo[w].winfixbuf = false
    vim.wo[w].winhighlight = "DiffAdd:DiffAdd,DiffChange:DiffChange,DiffDelete:DiffDelete,DiffText:DiffText"
  end
  vim.cmd("wincmd =")

  local function first_valid_review_win()
    for _, win in ipairs({ right_win, left_win }) do
      if vim.api.nvim_win_is_valid(win) then
        return win
      end
    end
    return nil
  end

  -- Enable diff
  vim.api.nvim_set_current_win(left_win)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(right_win)
  vim.cmd("diffthis")
  apply_wrap_options()

  -- Post-render fixup
  vim.defer_fn(function()
    if not vim.api.nvim_tabpage_is_valid(review_tab) then
      return
    end
    if vim.api.nvim_win_is_valid(left_win) then
      vim.api.nvim_set_current_win(left_win)
      vim.cmd("diffthis")
    end
    if vim.api.nvim_win_is_valid(right_win) then
      vim.api.nvim_set_current_win(right_win)
      pcall(function()
        vim.cmd("normal! gg]c")
      end)
      vim.cmd("syncbind")
    end
    apply_wrap_options()
  end, 200)

  -- Keymap config (matching pi.nvim's diff.keys structure)
  local diff_keys = {
    accept = "<Leader>da",
    reject = "<Leader>dr",
    edit_note = "<Leader>dn",
    delete_note = "<Leader>dx",
    list_notes = "<Leader>dN",
    expand_context = "<Leader>de",
    shrink_context = "<Leader>ds",
  }

  -- Also check user config
  local pi_nvim = require("pi-nvim")
  if pi_nvim.config and pi_nvim.config.diff and pi_nvim.config.diff.keys then
    for k, v in pairs(pi_nvim.config.diff.keys) do
      diff_keys[k] = v
    end
  end

  local function resolve_keys(key)
    if type(key) == "string" then
      return { key }
    elseif type(key) == "table" and key[1] then
      return key
    elseif type(key) == "table" and key.modes then
      return { key }
    end
    return {}
  end

  local accept_keys = resolve_keys(diff_keys.accept)
  local reject_keys = resolve_keys(diff_keys.reject)
  local edit_note_keys = resolve_keys(diff_keys.edit_note)
  local delete_note_keys = resolve_keys(diff_keys.delete_note)
  local list_notes_keys = resolve_keys(diff_keys.list_notes)
  local expand_context_keys = resolve_keys(diff_keys.expand_context)
  local shrink_context_keys = resolve_keys(diff_keys.shrink_context)

  local actions = {
    { label = "Accept", hint = "accept", keys = accept_keys },
    { label = "Reject", hint = "reject", keys = reject_keys },
    { label = "Add/edit note", hint = "note", keys = edit_note_keys },
    { label = "Delete note", hint = "del-note", keys = delete_note_keys },
    { label = "List notes", hint = "notes", keys = list_notes_keys },
    { label = "Expand context", hint = "expand", keys = expand_context_keys },
    { label = "Shrink context", hint = "shrink", keys = shrink_context_keys },
  }

  local function lhs_values(keys)
    local values = {}
    for _, key in ipairs(keys) do
      if type(key) == "string" then
        values[#values + 1] = key
      elseif type(key) == "table" and key[1] then
        values[#values + 1] = key[1]
      end
    end
    return values
  end

  local function normalize_lhs(lhs)
    return lhs:gsub("<Leader>", "\\<Leader>"):gsub("<[^>]+>", function(m)
      return m:lower()
    end)
  end

  local function lhs_collides(lhs)
    if lhs == "" then return false end
    local normalized = normalize_lhs(lhs)
    for _, action in ipairs(actions) do
      for _, action_lhs in ipairs(lhs_values(action.keys)) do
        if normalize_lhs(action_lhs) == normalized then
          return true
        end
      end
    end
    return false
  end

  local help_key = "?"
  local help_lhs = help_key
  local help_collides = lhs_collides(help_lhs)

  vim.wo[left_win].winbar = "%#PiNvimDiffWinbar# %#PiNvimDiffWinbarCurrent#ORIGINAL: " .. rel_path .. "%#PiNvimDiffWinbar#"
  local proposed_winbar = "%#PiNvimDiffWinbar# %#PiNvimDiffWinbarProposed# PROPOSED: " .. rel_path
  proposed_winbar = proposed_winbar .. " %#PiNvimDiffWinbar# %#PiNvimDiffWinbarHint#["
  for i, action in ipairs(actions) do
    local first_lhs = lhs_values(action.keys)[1] or ""
    if i > 1 then
      proposed_winbar = proposed_winbar .. "  "
    end
    proposed_winbar = proposed_winbar .. first_lhs .. "=" .. action.hint
  end
  if not help_collides then
    proposed_winbar = proposed_winbar .. "  " .. help_lhs .. "=keymaps"
  end
  proposed_winbar = proposed_winbar .. "]%#PiNvimDiffWinbar#"
  vim.wo[right_win].winbar = proposed_winbar

  local function show_keymap_dialog()
    local lines = {}
    for _, action in ipairs(actions) do
      local values = lhs_values(action.keys)
      local keys_text = #values > 0 and table.concat(values, ", ") or "(unbound)"
      lines[#lines + 1] = action.label .. ": " .. keys_text
    end
    vim.ui.select(lines, { prompt = "Diff review keymaps" }, function() end)
  end

  local responded = false
  local cleaned_up = false
  local tracked_keymaps = {} ---@type table<string, { buf: integer, mode: string, lhs: string, original: table|false }>

  local function keymap_id(buf, mode, lhs)
    return tostring(buf) .. ":" .. mode .. ":" .. normalize_lhs(lhs)
  end

  local function current_buf_keymap(buf, mode, lhs)
    local ok, existing = pcall(vim.api.nvim_buf_call, buf, function()
      return vim.fn.maparg(lhs, mode, false, true)
    end)
    if ok and existing and existing.buffer == 1 then
      return existing
    end
    return false
  end

  local function bind_review_key(buf, key, handler, opts)
    opts = opts or {}
    local keys = resolve_keys(key)
    local modes = opts.modes or "n"
    if type(modes) == "string" then modes = { modes } end
    for _, lhs in ipairs(keys) do
      for _, mode in ipairs(modes) do
        local id = keymap_id(buf, mode, lhs)
        if tracked_keymaps[id] == nil then
          tracked_keymaps[id] = {
            buf = buf,
            mode = mode,
            lhs = lhs,
            original = vim.api.nvim_buf_is_valid(buf) and current_buf_keymap(buf, mode, lhs) or false,
          }
        end
      end
    end
    for _, lhs in ipairs(keys) do
      vim.keymap.set(modes, lhs, handler, { buffer = buf, noremap = true, silent = true, desc = opts.desc })
    end
  end

  local function unbind_all()
    for _, km in pairs(tracked_keymaps) do
      pcall(vim.keymap.del, km.mode, km.lhs, { buffer = km.buf })
      if km.original and km.original ~= false then
        pcall(vim.fn.mapset, km.mode, "buf", { km.original })
      end
    end
    tracked_keymaps = {}
  end

  local function update_context(delta)
    local next_context = math.max(initial_context, get_diff_context() + delta)
    set_diff_context(next_context)
    refresh_diff_windows(left_win, right_win)
  end

  local note_refresh_group = vim.api.nvim_create_augroup("pi_nvim_diff_review_notes_" .. tostring(proposed_buf), { clear = true })
  local next_note_seq = 0

  ---@param note pi_nvim.DiffReviewNote
  ---@return "original"|"proposed"?
  local function note_side(note)
    if note.buf == current_buf then return "original" end
    if note.buf == proposed_buf then return "proposed" end
    return nil
  end

  ---@param note pi_nvim.DiffReviewNote
  local function clear_note_marks(note)
    if not vim.api.nvim_buf_is_valid(note.buf) then
      note.mark_ids = {}
      return
    end
    for _, mark_id in ipairs(note.mark_ids or {}) do
      pcall(vim.api.nvim_buf_del_extmark, note.buf, note_ns, mark_id)
    end
    note.mark_ids = {}
  end

  ---@param note pi_nvim.DiffReviewNote
  local function delete_note(note)
    clear_note_marks(note)
    for i, existing in ipairs(notes) do
      if existing == note then
        table.remove(notes, i)
        break
      end
    end
  end

  local function refresh_all_notes()
    for i = #notes, 1, -1 do
      local entry = notes[i]
      clear_note_marks(entry)
      if not vim.api.nvim_buf_is_valid(entry.buf) then
        table.remove(notes, i)
      else
        local line_count = vim.api.nvim_buf_line_count(entry.buf)
        if line_count <= 0 then
          table.remove(notes, i)
        else
          entry.start_row = clamp(entry.start_row, 0, line_count - 1)
          entry.end_row = clamp(entry.end_row, entry.start_row, line_count - 1)
          if not entry.seq then
            next_note_seq = next_note_seq + 1
            entry.seq = next_note_seq
          end
        end
      end
    end

    table.sort(notes, function(a, b)
      if a.buf == b.buf then
        if a.end_row == b.end_row then
          if a.start_row == b.start_row then
            return a.seq < b.seq
          end
          return a.start_row < b.start_row
        end
        return a.end_row < b.end_row
      end
      return a.buf < b.buf
    end)

    local i = 1
    while i <= #notes do
      local first = notes[i]
      local group = {}
      local j = i
      while j <= #notes and notes[j].buf == first.buf and notes[j].end_row == first.end_row do
        group[#group + 1] = notes[j]
        j = j + 1
      end

      table.sort(group, function(a, b)
        if a.start_row == b.start_row then
          return a.seq < b.seq
        end
        return a.start_row > b.start_row
      end)

      local width = math.max(20, vim.api.nvim_win_get_width(vim.fn.bufwinid(first.buf)) - 8)
      local virt_lines = {}
      for group_index, entry in ipairs(group) do
        if group_index > 1 then
          virt_lines[#virt_lines + 1] = note_separator_virt_line(width)
        end
        for _, line in ipairs(note_virt_lines(entry.note, width, false)) do
          virt_lines[#virt_lines + 1] = line
        end
      end
      first.mark_ids[#first.mark_ids + 1] = set_note_group_text_mark(first.buf, first.end_row, virt_lines, 200)

      local icon = "󰆈"
      if icon then
        for note_index, entry in ipairs(group) do
          local priority = 200 + note_index
          entry.mark_ids[#entry.mark_ids + 1] = set_note_sign_mark(entry.buf, entry.start_row, icon, priority)
          for row = entry.start_row + 1, entry.end_row do
            entry.mark_ids[#entry.mark_ids + 1] = set_note_sign_mark(entry.buf, row, "·", priority)
          end
        end
      end

      i = j
    end
  end

  ---@param entry pi_nvim.DiffReviewNote
  ---@return string
  local function note_range_label(entry)
    local start_line = entry.start_row + 1
    local end_line = entry.end_row + 1
    if start_line == end_line then
      return tostring(start_line)
    end
    return tostring(start_line) .. "-" .. tostring(end_line)
  end

  ---@param buf integer
  ---@param row integer
  ---@return pi_nvim.DiffReviewNote[]
  local function find_notes_at(buf, row)
    local found = {}
    for _, entry in ipairs(notes) do
      if entry.buf == buf and row >= entry.start_row and row <= entry.end_row then
        found[#found + 1] = entry
      end
    end
    return found
  end

  ---@param win integer
  ---@param buf integer
  ---@param forced_start integer?
  ---@param forced_end integer?
  ---@return integer, integer, boolean
  local function selected_range(win, buf, forced_start, forced_end)
    if vim.api.nvim_win_get_buf(win) ~= buf then
      local row = vim.api.nvim_win_get_cursor(win)[1] - 1
      return row, row, false
    end

    if forced_start and forced_end then
      local line_count = vim.api.nvim_buf_line_count(buf)
      return clamp(math.min(forced_start, forced_end), 0, line_count - 1),
          clamp(math.max(forced_start, forced_end), 0, line_count - 1),
          true
    end

    if vim.fn.mode() ~= "V" then
      local row = vim.api.nvim_win_get_cursor(win)[1] - 1
      return row, row, false
    end

    local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1
    local visual_pos = vim.fn.getpos("v")
    local visual_row = (visual_pos[2] or cursor_row + 1) - 1
    local line_count = vim.api.nvim_buf_line_count(buf)
    local start_row = clamp(math.min(cursor_row, visual_row), 0, line_count - 1)
    local end_row = clamp(math.max(cursor_row, visual_row), 0, line_count - 1)
    return start_row, end_row, true
  end

  ---@param entries pi_nvim.DiffReviewNote[]
  ---@param title string
  ---@param callback fun(entry: pi_nvim.DiffReviewNote?)
  local function choose_note(entries, title, callback)
    if #entries == 0 then
      callback(nil)
      return
    end
    if #entries == 1 then
      callback(entries[1])
      return
    end

    local options = {}
    local option_entries = {}
    for _, entry in ipairs(entries) do
      local label = tostring(#options + 1) .. ". " .. note_preview(entry.note) .. " (lines " .. note_range_label(entry) .. ")"
      options[#options + 1] = label
      option_entries[#option_entries + 1] = entry
    end

    vim.ui.select(options, { prompt = title }, function(choice, idx)
      if not choice or not idx then
        callback(nil)
      else
        callback(option_entries[idx])
      end
    end)
  end

  local function respond_and_close(action, content)
    if responded then return end
    responded = true

    -- Clean up
    unbind_all()
    vim.go.diffopt = prev_diffopt

    -- Clean up notes
    for _, entry in ipairs(notes) do
      clear_note_marks(entry)
    end

    -- Close the review tab (nvim_tabpage_close was removed in 0.10+). The
    -- proposed buffer is acwrite and may be modified (user edits for the
    -- modify action) — closing a modified acwrite buffer without a write
    -- raises E37 and aborts the response. Its content is already captured
    -- by the caller, so clear the flag and close silently.
    if vim.api.nvim_buf_is_valid(proposed_buf) then
      vim.bo[proposed_buf].modified = false
    end
    if vim.api.nvim_tabpage_is_valid(review_tab) then
      vim.api.nvim_set_current_tabpage(review_tab)
      vim.cmd.tabclose()
    end

    -- Restore previous tab
    if vim.api.nvim_tabpage_is_valid(prev_tab) then
      vim.api.nvim_set_current_tabpage(prev_tab)
    end

    -- Refresh the real file buffer when the outcome lands on disk, but only
    -- if it is open AND unmodified — checktime on a modified buffer fires the
    -- interactive "load file?" W11 prompt. Unsaved local edits stay untouched.
    -- Reject reverts the file in the extension, so wait a moment for that.
    local delay = action == "reject" and 300 or 0
    vim.defer_fn(function()
      local bufnr = vim.fn.bufnr(path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and not vim.bo[bufnr].modified then
        pcall(vim.cmd, "checktime " .. vim.fn.fnameescape(path))
      end
    end, delay)

    send_response(action, content)
  end

  -- Bind keys
  bind_review_key(proposed_buf, accept_keys, function()
    respond_and_close("accept")
  end, { desc = "Accept diff" })

  bind_review_key(proposed_buf, reject_keys, function()
    respond_and_close("reject")
  end, { desc = "Reject diff" })

  bind_review_key(proposed_buf, expand_context_keys, function()
    update_context(context_step)
  end, { desc = "Expand diff context" })

  bind_review_key(proposed_buf, shrink_context_keys, function()
    update_context(-context_step)
  end, { desc = "Shrink diff context" })

  bind_review_key(proposed_buf, edit_note_keys, function()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    local found = find_notes_at(buf, row)

    local function do_edit_note(entry)
      vim.ui.input({ prompt = "Note: ", default = entry and entry.note or "" }, function(input)
        if input == nil then return end
        if entry then
          if input == "" then
            delete_note(entry)
          else
            entry.note = input
          end
        elseif input ~= "" then
          local start_row, end_row = selected_range(win, buf)
          local new_note = {
            buf = buf,
            mark_ids = {},
            side = buf == current_buf and "original" or "proposed",
            start_row = start_row,
            end_row = end_row,
            note = input,
            seq = 0,
          }
          notes[#notes + 1] = new_note
        end
        refresh_all_notes()
      end)
    end

    choose_note(found, "Edit note", do_edit_note)
  end, { desc = "Add/edit diff note" })

  bind_review_key(proposed_buf, delete_note_keys, function()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    local found = find_notes_at(buf, row)
    choose_note(found, "Delete note", function(entry)
      if entry then delete_note(entry) end
      refresh_all_notes()
    end)
  end, { desc = "Delete diff note" })

  bind_review_key(proposed_buf, list_notes_keys, function()
    if #notes == 0 then
      vim.notify("No notes", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, entry in ipairs(notes) do
      local side = note_side(entry) or "?"
      items[#items + 1] = string.format("[%s] lines %s: %s", side, note_range_label(entry), note_preview(entry.note))
    end
    vim.ui.select(items, { prompt = "Diff notes" }, function() end)
  end, { desc = "List diff notes" })

  -- Help key
  if not help_collides then
    bind_review_key(proposed_buf, help_key, show_keymap_dialog, { desc = "Show diff review keymaps" })
  end

  -- Track active review
  activeReviews[reviewId] = {
    tabId = 0, -- will be set by caller
    reviewId = reviewId,
    proposedBuf = proposed_buf,
    currentBuf = current_buf,
    path = path,
    proposedWin = right_win,
    currentWin = left_win,
    reviewTab = review_tab,
    notes = notes,
    nextNoteSeq = next_note_seq,
    context = { base = initial_context, step = context_step, current = initial_context },
  }

  -- Handle proposed buffer write (for "modify" action)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = proposed_buf,
    once = true,
    callback = function()
      if responded then return end
      local lines = vim.api.nvim_buf_get_lines(proposed_buf, 0, -1, false)
      local content = table.concat(lines, "\n")
      if vim.bo[proposed_buf].eol then
        content = content .. "\n"
      end
      respond_and_close("modify", content)
    end,
  })

  -- Handle tab close
  vim.api.nvim_create_autocmd("TabClosed", {
    pattern = tostring(review_tab),
    once = true,
    callback = function()
      if not responded then
        respond_and_close("reject")
      end
    end,
  })

  -- Focus proposed window
  vim.api.nvim_set_current_win(right_win)
end

--- Handle incoming diff_review message from pi
--- @param msg table
--- @param pi_nvim table
function M.handle_diff_review(msg, pi_nvim)
  local reviewId = msg.id
  -- Capture the current tabId BEFORE opening the review tab
  local sourceTabId = pi_nvim.current_tab_id or vim.api.nvim_get_current_tabpage()
  M.open_review(msg, function(action, content)
    -- Send response back to pi using the ORIGINAL tab's socket
    local sock = pi_nvim.tab_sockets[sourceTabId]
    if sock and sock.connected and sock.client then
      local payload = vim.json.encode({
        type = "diff_review_response",
        id = reviewId,
        action = action,
        content = content,
      }) .. "\n"
      sock.client:write(payload)
    else
      -- Fallback to send_raw (may use wrong tab if in review tab)
      pi_nvim.send_raw({
        type = "diff_review_response",
        id = reviewId,
        action = action,
        content = content,
      }, function() end)
    end
  end)
end

return M