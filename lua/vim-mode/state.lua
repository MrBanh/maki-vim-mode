-- vim-state: prompt-only vim state for the maki vim-mode plugin.
-- Port of the prompt-relevant subset of opencode-vim's src/vim/state.ts.
-- Pure Lua, no maki dependency (unit-testable with plain lua).
--
-- Modes: "normal" | "insert" | "replace" | "visual" | "visual_line".
-- Register: { text, linewise, kind } where kind is "yank" | "delete" |
-- "change" | "paste" | nil (nil = legacy/test state, mirrors like a yank
-- under clipboard = "all" and never under "yank").
-- Visual is emulated: no host selection/highlight API exists, so the anchor
-- lives in Lua (st.visual.anchor) and the range shows in the status hint.
-- Pending keys: "" | "c" | "d" | "g" | "f" | "F" | "t" | "T" | "y" | "r".
-- Offsets everywhere are 0-based byte offsets (matches maki.ui.input).

local M = {}

M.COUNT_MAX = 9999
M.UNDO_CAP = 100

function M.new(initial_mode)
  return {
    mode = initial_mode or "insert",
    pending = "",
    pending_display = "",
    count = "",
    last_find = nil, -- { char, forward, till } | nil
    register = nil, -- { text, linewise } | nil
    undos = {}, -- list of { before = snap, after = snap }
    redos = {}, -- list of snap
    edit = nil, -- open insert/replace entry snapshot | nil
    rep = nil, -- dot-repeat descriptor | nil (see vim-handler)
    replaying = false,
    wanted_column = nil, -- number | "end" | nil (j/k column memory)
    -- operator-pending helpers (mirror handler.ts locals)
    op_count = 1,
    op_find = nil, -- { operation, find } | nil
    op_display = nil, -- "c"|"d"|"y" | nil (operator waiting behind a "g")
    text_object = nil, -- { operation, scope } | nil
    -- insert/replace session bookkeeping
    insert_before = nil, -- snapshot before the opener ran (undo unit start)
    insert_base = nil, -- snapshot after the opener ran (repeat diff base)
    insert_setup_keys = nil, -- key list replaying the opener, e.g. {"c","w"}
    insert_norepeat = false, -- ":/"-style entries never build dot-repeat
    key_seq = {}, -- normal-mode keys consumed since the last change/motion
    replace_start = nil, -- cursor where R was pressed
    replace_typed = false,
    replace_edits = nil, -- list of { kind = "rep"|"ins", rel, text }
    visual_anchor = nil, -- 0-based offset where v/V was pressed | nil
    visual_line_anchor = nil, -- line-start offset where V was pressed | nil
    visual_keys = nil, -- keys pressed in visual mode (for dot-repeat)
  }
end

local function is_table(v)
  return type(v) == "table"
end

local function copy_snapshot(snap)
  if snap == nil then
    return nil
  end
  return { text = snap.text, cursor = snap.cursor }
end

local function copy_register(reg)
  if reg == nil then
    return nil
  end
  return { text = reg.text, linewise = reg.linewise, kind = reg.kind }
end

-- Deep-ish copy for the read->compute->write retry path: a failed write
-- restores this and re-runs the core on a fresh read.
function M.snapshot(st)
  local undos = {}
  for i, item in ipairs(st.undos) do
    undos[i] = { before = copy_snapshot(item.before), after = copy_snapshot(item.after) }
  end
  local redos = {}
  for i, snap in ipairs(st.redos) do
    redos[i] = copy_snapshot(snap)
  end
  local setup_keys = nil
  if st.insert_setup_keys ~= nil then
    setup_keys = {}
    for i, k in ipairs(st.insert_setup_keys) do
      setup_keys[i] = k
    end
  end
  local key_seq = {}
  for i, k in ipairs(st.key_seq or {}) do
    key_seq[i] = k
  end
  local replace_edits = nil
  if st.replace_edits ~= nil then
    replace_edits = {}
    for i, e in ipairs(st.replace_edits) do
      replace_edits[i] = { kind = e.kind, rel = e.rel, text = e.text }
    end
  end
  local visual_keys = nil
  if st.visual_keys ~= nil then
    visual_keys = {}
    for i, k in ipairs(st.visual_keys) do
      visual_keys[i] = k
    end
  end
  return {
    mode = st.mode,
    pending = st.pending,
    pending_display = st.pending_display,
    count = st.count,
    last_find = st.last_find ~= nil
        and { char = st.last_find.char, forward = st.last_find.forward, till = st.last_find.till }
      or nil,
    register = copy_register(st.register),
    undos = undos,
    redos = redos,
    edit = copy_snapshot(st.edit),
    rep = st.rep, -- descriptors are treated as immutable once stored
    replaying = st.replaying,
    wanted_column = st.wanted_column,
    op_count = st.op_count,
    op_find = st.op_find ~= nil and { operation = st.op_find.operation, find = st.op_find.find } or nil,
    op_display = st.op_display,
    text_object = st.text_object ~= nil
        and { operation = st.text_object.operation, scope = st.text_object.scope }
      or nil,
    insert_before = copy_snapshot(st.insert_before),
    insert_base = copy_snapshot(st.insert_base),
    insert_setup_keys = setup_keys,
    insert_norepeat = st.insert_norepeat,
    key_seq = key_seq,
    replace_start = st.replace_start,
    replace_typed = st.replace_typed,
    replace_edits = replace_edits,
    visual_anchor = st.visual_anchor,
    visual_line_anchor = st.visual_line_anchor,
    visual_keys = visual_keys,
  }
end

function M.restore(st, snap)
  st.mode = snap.mode
  st.pending = snap.pending
  st.pending_display = snap.pending_display
  st.count = snap.count
  st.last_find = snap.last_find
  st.register = snap.register
  st.undos = snap.undos
  st.redos = snap.redos
  st.edit = snap.edit
  st.rep = snap.rep
  st.replaying = snap.replaying
  st.wanted_column = snap.wanted_column
  st.op_count = snap.op_count
  st.op_find = snap.op_find
  st.op_display = snap.op_display
  st.text_object = snap.text_object
  st.insert_before = snap.insert_before
  st.insert_base = snap.insert_base
  st.insert_setup_keys = snap.insert_setup_keys
  st.insert_norepeat = snap.insert_norepeat
  st.key_seq = snap.key_seq or {}
  st.replace_start = snap.replace_start
  st.replace_typed = snap.replace_typed
  st.replace_edits = snap.replace_edits
  st.visual_anchor = snap.visual_anchor
  st.visual_line_anchor = snap.visual_line_anchor
  st.visual_keys = snap.visual_keys
end

function M.set_pending(st, next, display)
  st.pending = next
  st.pending_display = display or ""
end

function M.clear_pending(st)
  if st.pending ~= "" then
    st.pending = ""
  end
  if st.pending_display ~= "" then
    st.pending_display = ""
  end
  M.clear_count(st)
  st.op_find = nil
  st.text_object = nil
  st.op_display = nil
  st.op_count = 1
end

function M.clear_count(st)
  if st.count ~= "" then
    st.count = ""
  end
end

function M.append_count_digit(st, digit)
  if #st.count >= #tostring(M.COUNT_MAX) then
    return
  end
  st.count = st.count .. digit
end

function M.take_count(st, default_value)
  local dv = default_value or 1
  local value = tonumber(st.count) or dv
  M.clear_count(st)
  if value ~= math.floor(value) then
    value = dv
  end
  if value < 1 then
    value = 1
  end
  if value > M.COUNT_MAX then
    value = M.COUNT_MAX
  end
  return value
end

function M.set_mode(st, next)
  M.clear_pending(st)
  M.clear_count(st)
  st.wanted_column = nil
  if next ~= "replace" then
    st.replace_start = nil
    st.replace_typed = false
  end
  if next ~= "visual" and next ~= "visual_line" then
    st.visual_anchor = nil
    st.visual_line_anchor = nil
    st.visual_keys = nil
  end
  st.mode = next
end

function M.push(st, before, after)
  st.edit = nil
  if before.text == after.text and before.cursor == after.cursor then
    return
  end
  st.undos[#st.undos + 1] = {
    before = copy_snapshot(before),
    after = copy_snapshot(after),
  }
  if #st.undos > M.UNDO_CAP then
    table.remove(st.undos, 1)
  end
  st.redos = {}
end

function M.reset_history(st)
  st.edit = nil
  st.undos = {}
  st.redos = {}
  st.rep = nil
  st.insert_before = nil
  st.insert_base = nil
  st.insert_setup_keys = nil
  st.insert_norepeat = false
  st.key_seq = {}
  st.replace_start = nil
  st.replace_typed = false
  st.replace_edits = nil
end

function M.reset(st)
  M.clear_pending(st)
  M.clear_count(st)
  M.reset_history(st)
  st.wanted_column = nil
  st.replaying = false
  st.mode = "insert"
end

function M.undo(st, snap)
  local item = st.undos[#st.undos]
  if item == nil then
    return nil
  end
  table.remove(st.undos)
  st.redos[#st.redos + 1] = copy_snapshot(snap)
  st.edit = nil
  return copy_snapshot(item.before)
end

function M.redo(st, snap)
  local item = st.redos[#st.redos]
  if item == nil then
    return nil
  end
  table.remove(st.redos)
  st.undos[#st.undos + 1] = { before = copy_snapshot(snap), after = copy_snapshot(item) }
  if #st.undos > M.UNDO_CAP then
    table.remove(st.undos, 1)
  end
  st.edit = nil
  return copy_snapshot(item)
end

function M.can_undo(st)
  return #st.undos > 0
end

function M.can_redo(st)
  return #st.redos > 0
end

function M.is_insert(st)
  return st.mode == "insert"
end

function M.is_replace(st)
  return st.mode == "replace"
end

function M.is_normal(st)
  return st.mode == "normal"
end

function M.is_visual(st)
  return st.mode == "visual" or st.mode == "visual_line"
end

-- Status-hint text, mirroring upstream indicator.ts (minus copy mode).
-- Always returns mode_label, context (pending display / count / "").
-- The label is never nil: set_status_hint rejects pairs with a missing key.
function M.indicator(st)
  local label = "-- NORMAL --"
  if st.mode == "insert" then
    label = "-- INSERT --"
  elseif st.mode == "replace" then
    label = "-- REPLACE --"
  elseif st.mode == "visual" then
    label = "-- VISUAL --"
  elseif st.mode == "visual_line" then
    label = "-- V-LINE --"
  end
  if st.pending ~= "" then
    return label, (st.pending_display ~= "" and st.pending_display or st.pending) .. ".."
  end
  if st.count ~= "" then
    return label, st.count
  end
  return label, ""
end

M._is_table = is_table -- exposed for tests

return M
