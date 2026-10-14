-- vim-handler: prompt-only vim core for the maki vim-mode plugin.
-- Port of the prompt-relevant subset of opencode-vim's src/vim/handler.ts.
-- Pure Lua, no maki dependency.
--
-- Model: handle(st, buf, ev) mutates the scratch buffer buf = { text, cursor }
-- (0-based byte offsets) and the state, and returns a result describing what
-- the integration layer must do:
--   {
--     handled = bool,
--     edits = { { start, stop, text, cursor }, ... },  -- applied to buf already
--     jump = nil | "top" | "bottom",     -- gg / G (transcript iff buf empty)
--     scroll = nil | "half-down" | "half-up" | "page-down" | "page-up"
--              | "line-down" | "line-up",
--     flash = nil | string,               -- message for maki.ui.flash
--   }
-- Text edits are exactly what maki.ui.input_edit takes (plus version /
-- session_id, which the integration layer adds).
--
-- Dot-repeat: every text change records either { kind="keys", keys } (pure
-- normal-mode ops, replayed by re-feeding the keys) or { kind="change",
-- keys, text } (insert-mode changes: opener keys + typed text) or
-- { kind="replace", edits } (R mode). Counts are baked into the recorded
-- keys, so `2.` never multiplies (matches upstream's repeat-count test).
-- Replays run with st.replaying set: undo units are pushed, repeat is not
-- re-recorded, and the key sequence tracker is untouched.
--
-- Visual mode is emulated (no host selection API): the anchor lives in
-- state (visual_anchor / visual_line_anchor), motions move the cursor, and
-- operators consume the anchor..cursor span. The integration layer shows
-- the range in the status hint. Cut list (mirrors the documented scope):
-- display (gj/gk degrade to j/k), H/M/L viewport jumps, window
-- navigation, search, system clipboard, langmap, autocomplete, : commands
-- (':' inserts '/' at column 0 and enters insert mode instead).

local motions = require("vim-mode.motions")
local vstate = require("vim-mode.state")

local H = {}

local SPECIAL = {
  escape = true,
  BS = true,
  delete = true,
  up = true,
  down = true,
  left = true,
  right = true,
}

local function is_printable(ev)
  if ev.ctrl then
    return false
  end
  return SPECIAL[ev.key] == nil
end

local function snap_cursor(buf)
  buf.cursor = motions.snap(buf.text, buf.cursor)
  if buf.cursor < 0 then
    buf.cursor = 0
  end
  if buf.cursor > #buf.text then
    buf.cursor = #buf.text
  end
end

local function snap_of(buf)
  return { text = buf.text, cursor = buf.cursor }
end

-- Apply one motions-style edit ({ start, stop, text, cursor }) to the
-- scratch buffer and record it for the integration layer.
local function apply_edit(buf, res, edit)
  buf.text = motions.apply_edit(buf.text, edit)
  buf.cursor = edit.cursor
  snap_cursor(buf)
  res.edits[#res.edits + 1] = {
    start = edit.start,
    stop = edit.stop,
    text = edit.text,
    cursor = buf.cursor,
  }
end

local function new_result(handled)
  return { handled = handled or false, edits = {} }
end

local function copy_keys(keys)
  local out = {}
  for i, k in ipairs(keys) do
    out[i] = k
  end
  return out
end

-- ---------------------------------------------------------------------------
-- small helpers mirroring handler.ts locals
-- ---------------------------------------------------------------------------

local function take_count(st, dv)
  return vstate.take_count(st, dv)
end

local function take_op_count(st)
  local count = vstate.take_count(st, st.op_count)
  st.op_count = 1
  return count
end

local function start_operator(st, op)
  local display = st.count .. op
  st.op_count = vstate.take_count(st, 1)
  vstate.set_pending(st, op, display)
end

-- Tag the unnamed register with how it was written so the integration
-- layer can mirror selectively (clipboard = "yank" mirrors yanks only).
-- kind: "yank" | "delete" | "change" | "paste".
local function set_register(st, reg, kind)
  if reg == nil then
    return
  end
  st.register = { text = reg.text, linewise = reg.linewise, kind = kind }
end

local function line_motion_anchor(text, cursor, direction, count)
  local c = cursor
  for _ = 1, count do
    if direction == "down" then
      c = motions.move_line_down(text, c, 0)
    else
      c = motions.move_line_up(text, c, 0)
    end
  end
  if motions.line_start(text, c) == motions.line_start(text, cursor) then
    return nil
  end
  return c
end

-- Record dot-repeat for a pure normal-mode change from the consumed keys.
local function record_keys_repeat(st)
  if st.replaying then
    return
  end
  st.rep = { kind = "keys", keys = copy_keys(st.key_seq) }
  st.key_seq = {}
end

-- Commit a normal-mode text change: one undo unit + dot-repeat.
local function commit_change(st, buf, res, before)
  vstate.push(st, before, snap_of(buf))
  record_keys_repeat(st)
end

-- Enter insert mode. setup_edits are opener edits applied first (cw's word
-- deletion, o's newline, ...). before is the snapshot from before the
-- opener ran (the undo unit starts there).
local function enter_insert(st, buf, res, setup_edits, before)
  for _, e in ipairs(setup_edits or {}) do
    apply_edit(buf, res, e)
  end
  st.insert_before = { text = before.text, cursor = before.cursor }
  st.insert_base = snap_of(buf)
  if st.replaying then
    st.insert_setup_keys = {}
  else
    st.insert_setup_keys = copy_keys(st.key_seq)
  end
  st.key_seq = {}
  st.insert_norepeat = st.insert_norepeat or false
  vstate.set_mode(st, "insert")
end

-- ---------------------------------------------------------------------------
-- emulated visual mode (anchor in Lua; hint shows the range)
-- ---------------------------------------------------------------------------

-- Visual char span: inclusive of the char under the cursor, like vim.
local function visual_char_span(buf, st)
  local anchor = st.visual_anchor
  if anchor == nil then
    return nil
  end
  local s = math.min(anchor, buf.cursor)
  local e = math.max(anchor, buf.cursor)
  -- empty prompt: nothing selected
  if s == e and #buf.text == 0 then
    return nil
  end
  e = motions.char_next(buf.text, e)
  if e <= s then
    return nil
  end
  return { start = s, stop = e }
end

-- Visual-line span: whole lines from the anchor line through the cursor line.
local function visual_line_span(buf, st)
  if st.visual_line_anchor == nil then
    return nil
  end
  local a_line = motions.line_start(buf.text, st.visual_line_anchor)
  local c_line = motions.line_start(buf.text, buf.cursor)
  local s = math.min(a_line, c_line)
  local e = motions.line_end(buf.text, math.max(a_line, c_line))
  if e <= s then
    return nil
  end
  return { start = s, stop = e }
end

local function visual_span(buf, st)
  if st.mode == "visual_line" then
    return visual_line_span(buf, st)
  end
  return visual_char_span(buf, st)
end

-- Track visual navigation keys for dot-repeat.
local function visual_track_key(st, key)
  if st.replaying then
    return
  end
  if st.visual_keys == nil then
    st.visual_keys = {}
  end
  st.visual_keys[#st.visual_keys + 1] = key
end

-- Leave visual mode, clearing anchors but keeping dot-repeat recording.
local function exit_visual(st)
  vstate.set_mode(st, "normal")
end

-- ---------------------------------------------------------------------------
-- operator application
-- ---------------------------------------------------------------------------

local function apply_op_yank(st, result)
  if result.register ~= nil then
    set_register(st, result.register, "yank")
  end
  vstate.clear_pending(st)
end

local function apply_op_edit(st, buf, res, result_fn, operation, before)
  local next = result_fn()
  if next.span == nil and next.register == nil then
    vstate.clear_pending(st)
    return false
  end
  if next.span ~= nil and next.span.stop > next.span.start then
    apply_edit(buf, res, motions.delete_span(buf.text, next.span))
  elseif next.span ~= nil then
    if buf.cursor ~= next.span.start then
      buf.cursor = next.span.start
      snap_cursor(buf)
      res.cursor_only = true
    end
  end
  if next.register ~= nil then
    local kind = "delete"
    if operation == "y" then
      kind = "yank"
    elseif operation == "c" then
      kind = "change"
    end
    set_register(st, next.register, kind)
  end
  vstate.clear_pending(st)
  if operation == "c" then
    enter_insert(st, buf, res, {}, before)
    return true
  end
  commit_change(st, buf, res, before)
  return true
end

local function apply_op_result(st, buf, res, result_fn, operation, before)
  local initial = result_fn()
  if initial.span == nil and initial.register == nil then
    vstate.clear_pending(st)
    return false
  end
  if operation == "y" then
    apply_op_yank(st, initial)
    return true
  end
  return apply_op_edit(st, buf, res, result_fn, operation, before)
end

-- ---------------------------------------------------------------------------
-- operator pieces
-- ---------------------------------------------------------------------------

local function next_paragraph_count_op(buf, operation, count)
  if count == 1 then
    return function()
      return motions.next_paragraph_operation(buf.text, buf.cursor, operation)
    end
  end
  local cursor = buf.cursor
  for _ = 1, count - 1 do
    cursor = motions.move_next_paragraph(buf.text, cursor)
  end
  local saved = buf.cursor
  local probe = cursor
  local next = (function()
    local b = { text = buf.text, cursor = probe }
    return motions.next_paragraph_operation(b.text, b.cursor, operation)
  end)()
  if next.span == nil then
    return function()
      return next
    end
  end
  if next.register ~= nil and next.register.linewise then
    local span = {
      start = motions.line_start(buf.text, saved),
      stop = next.span.stop,
    }
    return function()
      local slice = buf.text:sub(span.start + 1, span.stop)
      if slice:sub(-1) ~= "\n" then
        slice = slice .. "\n"
      end
      return { span = span, register = { text = slice, linewise = true } }
    end
  end
  return function()
    return {
      span = { start = saved, stop = next.span.stop },
      register = {
        text = buf.text:sub(saved + 1, next.span.stop),
        linewise = false,
      },
    }
  end
end

local function previous_paragraph_count_op(buf, operation, count)
  if count == 1 then
    return function()
      return motions.previous_paragraph_operation(buf.text, buf.cursor, operation)
    end
  end
  local cursor = buf.cursor
  for _ = 1, count - 1 do
    cursor = motions.move_previous_paragraph(buf.text, cursor)
  end
  local saved = buf.cursor
  local next = motions.previous_paragraph_operation(buf.text, cursor, operation)
  if next.span == nil then
    return function()
      return next
    end
  end
  if next.register == nil or not next.register.linewise then
    return function()
      return {
        span = { start = next.span.start, stop = saved },
        register = {
          text = buf.text:sub(next.span.start + 1, saved),
          linewise = false,
        },
      }
    end
  end
  return function()
    local bend = saved
    if buf.text:sub(saved, saved) == "\n" and operation == "c" then
      bend = saved - 1
    end
    if bend > next.span.start then
      local slice = buf.text:sub(next.span.start + 1, bend)
      if slice:sub(-1) ~= "\n" then
        slice = slice .. "\n"
      end
      return {
        span = { start = next.span.start, stop = bend },
        register = { text = slice, linewise = true },
      }
    end
    return { span = nil, register = nil }
  end
end

local function paragraph_operator(st, buf, res, key, operation, before)
  if key ~= "{" and key ~= "}" then
    return false
  end
  local count = take_op_count(st)
  local result_fn
  if key == "}" then
    result_fn = next_paragraph_count_op(buf, operation, count)
  else
    result_fn = previous_paragraph_count_op(buf, operation, count)
  end
  apply_op_result(st, buf, res, result_fn, operation, before)
  return true
end

local function matching_bracket_operator(st, buf, res, key, operation, before)
  if key ~= "%" then
    return false
  end
  st.op_count = 1
  apply_op_result(st, buf, res, function()
    return motions.matching_bracket_operation(buf.text, buf.cursor)
  end, operation, before)
  return true
end

local function yank_line_motion(buf, direction, count)
  local anchor = line_motion_anchor(buf.text, buf.cursor, direction, count)
  if anchor == nil then
    return { span = nil, register = nil }
  end
  local cursor_line = motions.line_start(buf.text, buf.cursor)
  local anchor_line = motions.line_start(buf.text, anchor)
  local s = math.min(cursor_line, anchor_line)
  local e = motions.line_end(buf.text, math.max(cursor_line, anchor_line))
  return {
    span = { start = s, stop = e },
    register = { text = buf.text:sub(s + 1, e), linewise = true },
  }
end

local function vertical_motion_operator(st, buf, res, key, operation, before)
  local direction = nil
  if key == "j" or key == "down" then
    direction = "down"
  elseif key == "k" or key == "up" then
    direction = "up"
  end
  if direction == nil then
    return false
  end
  local count = take_op_count(st)
  if operation == "y" then
    local result = yank_line_motion(buf, direction, count)
    if result.register ~= nil then
      set_register(st, result.register, "yank")
    end
    vstate.clear_pending(st)
    return true
  end
  if operation == "d" then
    local anchor = line_motion_anchor(buf.text, buf.cursor, direction, count)
    local reg = nil
    if anchor ~= nil then
      local r = motions.delete_line(buf.text, buf.cursor, anchor)
      if r ~= nil then
        apply_edit(buf, res, r.edit)
        reg = r.register
      end
    end
    vstate.clear_pending(st)
    if reg == nil then
      return true
    end
    set_register(st, reg, "delete")
    commit_change(st, buf, res, before)
    return true
  end
  -- change: substitute the lines, enter insert
  local anchor = line_motion_anchor(buf.text, buf.cursor, direction, count)
  local reg = nil
  if anchor ~= nil then
    local r = motions.substitute_line(buf.text, buf.cursor, anchor)
    if r ~= nil then
      apply_edit(buf, res, r.edit)
      reg = r.register
    end
  end
  vstate.clear_pending(st)
  if reg == nil then
    return true
  end
  set_register(st, reg, "change")
  enter_insert(st, buf, res, {}, before)
  return true
end

local function word_operator(st, buf, res, key, operation, before)
  if key == "w" or key == "W" then
    local big = key == "W"
    local count = take_op_count(st)
    if operation == "c" then
      apply_op_result(st, buf, res, function()
        return motions.change_word_operation(buf.text, buf.cursor, big, count)
      end, operation, before)
    else
      apply_op_result(st, buf, res, function()
        return motions.next_word_operation(buf.text, buf.cursor, big, count)
      end, operation, before)
    end
    return true
  end
  -- NOTE: upstream only handles lowercase "b" here and excludes yank, so
  -- dB / yb / yB fall through (parity quirk, documented in vim-mode.lua).
  if key == "b" and operation ~= "y" then
    local count = take_op_count(st)
    apply_op_result(st, buf, res, function()
      return motions.previous_word_operation(buf.text, buf.cursor, count)
    end, operation, before)
    return true
  end
  if key == "e" or key == "E" then
    local big = key == "E"
    local count = take_op_count(st)
    apply_op_result(st, buf, res, function()
      return motions.word_end_operation(buf.text, buf.cursor, big, count)
    end, operation, before)
    return true
  end
  return false
end

local function line_end_count_op(buf, count)
  local start = buf.cursor
  local target = motions.line_start_for_count(buf.text, start, count)
  local bend = motions.line_end(buf.text, target)
  if bend > start then
    return {
      span = { start = start, stop = bend },
      register = { text = buf.text:sub(start + 1, bend), linewise = false },
    }
  end
  return { span = nil, register = nil }
end

local function line_boundary_motion(st, buf, res, key, operation, before)
  if key == "$" then
    local count = take_op_count(st)
    apply_op_result(st, buf, res, function()
      return line_end_count_op(buf, count)
    end, operation, before)
    return true
  end
  if key == "0" then
    st.op_count = 1
    apply_op_result(st, buf, res, function()
      return motions.line_beginning_operation(buf.text, buf.cursor)
    end, operation, before)
    return true
  end
  if key == "^" then
    st.op_count = 1
    apply_op_result(st, buf, res, function()
      return motions.first_non_whitespace_operation(buf.text, buf.cursor)
    end, operation, before)
    return true
  end
  return false
end

local function start_op_find(st, op, find)
  st.op_find = { operation = op, find = find }
  vstate.set_pending(st, find, (st.pending_display ~= "" and st.pending_display or op) .. find)
end

local function operator_find(st, key, operation)
  if key == "f" or key == "F" or key == "t" or key == "T" then
    start_op_find(st, operation, key)
    return true
  end
  return false
end

local function start_text_object(st, op, scope)
  local display = (st.pending_display ~= "" and st.pending_display or op)
    .. (scope == "around" and "a" or "i")
  take_op_count(st)
  st.text_object = { operation = op, scope = scope }
  vstate.set_pending(st, op, display)
end

local function operator_text_object(st, key, operation)
  if key == "i" then
    start_text_object(st, operation, "inner")
    return true
  end
  if key == "a" then
    start_text_object(st, operation, "around")
    return true
  end
  return false
end

local function resolve_text_object(buf, key, scope, operation)
  local around = scope == "around"
  if key == "w" or key == "W" then
    local big = key == "W"
    return function()
      return motions.word_text_object_operation(buf.text, buf.cursor, around, big)
    end
  end
  if key == '"' or key == "'" or key == "`" then
    return function()
      return motions.quote_text_object_operation(buf.text, buf.cursor, around, key)
    end
  end
  if key == "(" or key == ")" or key == "[" or key == "]"
    or key == "{" or key == "}" or key == "<" or key == ">" then
    return function()
      return motions.bracket_text_object_operation(buf.text, buf.cursor, around, key, operation)
    end
  end
  return nil
end

local function pending_text_object_operator(st, buf, res, key, before)
  if st.text_object == nil then
    return false
  end
  if st.pending ~= st.text_object.operation then
    st.text_object = nil
    return false
  end
  local tobj = st.text_object
  local operation = resolve_text_object(buf, key, tobj.scope, tobj.operation)
  st.text_object = nil
  if operation ~= nil then
    st.op_count = 1
    apply_op_result(st, buf, res, operation, tobj.operation, before)
    return true
  end
  st.op_count = 1
  vstate.clear_pending(st)
  return true
end

local function pending_find_operator(st, buf, res, ev, before)
  if st.op_find == nil then
    return false
  end
  if st.pending ~= st.op_find.find then
    st.op_find = nil
    st.op_count = 1
    return false
  end
  if is_printable(ev) then
    local find = st.op_find.find
    local forward = find == "f" or find == "t"
    local till = find == "t" or find == "T"
    local char = ev.key
    local operation = st.op_find.operation
    local count = take_op_count(st)
    st.op_find = nil
    apply_op_result(st, buf, res, function()
      return motions.find_operation(buf.text, buf.cursor, char, forward, till, count)
    end, operation, before)
    st.last_find = { char = char, forward = forward, till = till }
    return true
  end
  st.op_find = nil
  st.op_count = 1
  vstate.clear_pending(st)
  return true
end

local function doubled_operator(st, buf, res, op, before)
  if op == "c" then
    local count = take_op_count(st)
    local r = motions.substitute_line_count(buf.text, buf.cursor, count)
    local setup = {}
    if r ~= nil then
      setup = { r.edit }
      if r.register ~= nil then
        set_register(st, r.register, "change")
      end
    end
    vstate.clear_pending(st)
    enter_insert(st, buf, res, setup, before)
    return
  end
  if op == "d" then
    local count = take_op_count(st)
    local r = motions.delete_line_count(buf.text, buf.cursor, count)
    vstate.clear_pending(st)
    if r == nil then
      return
    end
    apply_edit(buf, res, r.edit)
    if r.register ~= nil then
      set_register(st, r.register, "delete")
    end
    commit_change(st, buf, res, before)
    return
  end
  local result = motions.yank_line_count(buf.text, buf.cursor, take_op_count(st))
  if result.register ~= nil then
    set_register(st, result.register, "yank")
  end
  vstate.clear_pending(st)
end

-- Handles a key while a c/d/y operator is pending. Returns true/false when
-- the key resolved the operator, or nil to fall through to normal dispatch.
local function operator_pending(st, buf, res, ev, key, op, before)
  if ev.ctrl then
    st.op_count = 1
    vstate.clear_pending(st)
    return false
  end
  if st.op_count == 1
    and ((key >= "1" and key <= "9") or (key == "0" and st.count ~= "")) then
    local prev = st.count
    vstate.append_count_digit(st, key)
    if st.count ~= prev then
      vstate.set_pending(st, op, (st.pending_display ~= "" and st.pending_display or op) .. key)
    end
    return true
  end
  if key == op then
    doubled_operator(st, buf, res, op, before)
    return true
  end
  if vertical_motion_operator(st, buf, res, key, op, before) then
    return true
  end
  if word_operator(st, buf, res, key, op, before) then
    return true
  end
  if line_boundary_motion(st, buf, res, key, op, before) then
    return true
  end
  if operator_text_object(st, key, op) then
    return true
  end
  if paragraph_operator(st, buf, res, key, op, before) then
    return true
  end
  if matching_bracket_operator(st, buf, res, key, op, before) then
    return true
  end
  if operator_find(st, key, op) then
    return true
  end
  st.op_count = 1
  st.text_object = nil
  vstate.clear_pending(st)
  return nil
end

-- ---------------------------------------------------------------------------
-- undo / redo
-- ---------------------------------------------------------------------------

local function do_undo(st, buf, res)
  local next = vstate.undo(st, snap_of(buf))
  if next == nil then
    return false
  end
  vstate.set_mode(st, "normal")
  apply_edit(buf, res, { start = 0, stop = #buf.text, text = next.text, cursor = next.cursor })
  return true
end

local function do_redo(st, buf, res)
  local next = vstate.redo(st, snap_of(buf))
  if next == nil then
    return false
  end
  vstate.set_mode(st, "normal")
  apply_edit(buf, res, { start = 0, stop = #buf.text, text = next.text, cursor = next.cursor })
  return true
end

-- ---------------------------------------------------------------------------
-- dot-repeat
-- ---------------------------------------------------------------------------

local function feed_keys(st, buf, res, keys)
  for _, k in ipairs(keys) do
    local r = H.handle(st, buf, { key = k, ctrl = false })
    for _, e in ipairs(r.edits) do
      res.edits[#res.edits + 1] = e
    end
    if r.cursor_only then
      res.cursor_only = true
    end
  end
end

local function run_repeat(st, buf, res)
  local rep = st.rep
  if rep == nil then
    return false
  end
  vstate.clear_count(st)
  st.replaying = true
  if rep.kind == "keys" then
    feed_keys(st, buf, res, rep.keys)
  elseif rep.kind == "change" then
    feed_keys(st, buf, res, rep.keys)
    if st.mode == "insert" then
      if rep.text ~= nil and rep.text ~= "" then
        apply_edit(buf, res, {
          start = buf.cursor,
          stop = buf.cursor,
          text = rep.text,
          cursor = buf.cursor + #rep.text,
        })
      end
      vstate.push(st, st.insert_before or snap_of(buf), snap_of(buf))
      vstate.set_mode(st, "normal")
      st.insert_before = nil
      st.insert_base = nil
      st.insert_setup_keys = nil
    end
  elseif rep.kind == "replace" then
    local snap_before = snap_of(buf)
    local base = buf.cursor
    for _, e in ipairs(rep.edits or {}) do
      local at = base + (e.rel or 0)
      if at < 0 then
        at = 0
      end
      if at > #buf.text then
        at = #buf.text
      end
      if e.kind == "rep" then
        local ch = buf.text:sub(at + 1, at + 1)
        if at >= #buf.text or ch == "\n" then
          apply_edit(buf, res, { start = at, stop = at, text = e.text, cursor = at + #e.text })
        else
          local stop = motions.char_next(buf.text, at)
          apply_edit(buf, res, { start = at, stop = stop, text = e.text, cursor = at + #e.text })
        end
      else -- "ins"
        apply_edit(buf, res, { start = at, stop = at, text = e.text, cursor = at + #e.text })
      end
    end
    snap_cursor(buf)
    vstate.push(st, snap_before, snap_of(buf))
  end
  st.replaying = false
  return true
end

-- ---------------------------------------------------------------------------
-- insert / replace exit
-- ---------------------------------------------------------------------------

local function exit_insert(st, buf, res)
  vstate.set_mode(st, "normal")
  local before = st.insert_before
  local base = st.insert_base
  st.insert_before = nil
  st.insert_base = nil
  local setup_keys = st.insert_setup_keys
  st.insert_setup_keys = nil
  local norepeat = st.insert_norepeat
  st.insert_norepeat = false
  if before ~= nil then
    vstate.push(st, before, snap_of(buf))
  end
  if not norepeat and not st.replaying and base ~= nil and setup_keys ~= nil then
    local diff = motions.extract_insert(base.text, buf.text)
    if diff ~= nil then
      if diff.text ~= "" or base.text ~= (before and before.text or base.text) then
        st.rep = { kind = "change", keys = copy_keys(setup_keys), text = diff.text }
      else
        st.rep = nil
      end
    else
      st.rep = nil
    end
  elseif not st.replaying then
    if not norepeat then
      st.rep = nil
    end
  end
  local c = motions.move_left(buf.text, buf.cursor)
  if c ~= buf.cursor then
    buf.cursor = c
    res.cursor_only = true
  end
end

local function exit_replace(st, buf, res)
  local start = st.replace_start
  local typed = st.replace_typed
  vstate.set_mode(st, "normal")
  if typed and start ~= nil then
    local prev = motions.char_prev(buf.text, buf.cursor)
    local c = start
    if prev > start then
      c = prev
    end
    if c ~= buf.cursor then
      buf.cursor = c
      res.cursor_only = true
    end
  end
  if st.insert_before ~= nil then
    vstate.push(st, st.insert_before, snap_of(buf))
  end
  st.insert_before = nil
  st.insert_base = nil
  local edits = st.replace_edits
  st.replace_start = nil
  st.replace_typed = false
  st.replace_edits = nil
  if not st.replaying and edits ~= nil and #edits > 0 then
    local out = {}
    for _, e in ipairs(edits) do
      out[#out + 1] = { kind = e.kind, rel = e.rel, text = e.text }
    end
    st.rep = { kind = "replace", edits = out }
  elseif not st.replaying then
    st.rep = nil
  end
end

-- Called by the integration layer when InputChanged reports a change the
-- plugin itself did not write while in replace mode (e.g. Enter inserting
-- a newline through the native path). Records it for dot-repeat; any
-- non-insertion edit invalidates replace repeat for this session.
function H.note_external_insert(st, old_text, new_text)
  if st.mode ~= "replace" or st.replace_start == nil then
    return
  end
  if st.replace_edits == nil then
    return
  end
  local diff = motions.extract_insert(old_text, new_text)
  if diff == nil then
    st.replace_edits = nil
    return
  end
  if diff.text ~= "" then
    st.replace_edits[#st.replace_edits + 1] = {
      kind = "ins",
      rel = diff.start - st.replace_start,
      text = diff.text,
    }
  end
end

-- ---------------------------------------------------------------------------
-- replace mode key handling
-- ---------------------------------------------------------------------------

local function handle_replace(st, buf, res, ev)
  if ev.key == "escape" then
    exit_replace(st, buf, res)
    res.handled = true
    return res
  end
  if is_printable(ev) then
    local value = ev.key
    local rel = buf.cursor - (st.replace_start or buf.cursor)
    local edit = motions.replace_under_cursor(buf.text, buf.cursor, value)
    apply_edit(buf, res, edit)
    st.replace_typed = true
    if st.replace_edits ~= nil and not st.replaying then
      st.replace_edits[#st.replace_edits + 1] = { kind = "rep", rel = rel, text = value }
    end
    res.handled = true
    return res
  end
  res.handled = false
  return res
end

-- ---------------------------------------------------------------------------
-- normal mode dispatch (mirrors handler.ts dispatch, prompt subset)
-- ---------------------------------------------------------------------------

-- Apply a visual selection operator shared by y/d/c/x/s:
-- linewise in visual_line, charwise in visual.
local function visual_apply(st, buf, res, before, enter_insert_after)
  local span = visual_span(buf, st)
  local linewise = st.mode == "visual_line"
  if span == nil then
    exit_visual(st)
    res.handled = true
    return res
  end
  local slice = buf.text:sub(span.start + 1, span.stop)
  local reg_text = slice
  if linewise and slice ~= "" and slice:sub(-1) ~= "\n" then
    reg_text = slice .. "\n"
  end
  if enter_insert_after then
    set_register(st, { text = reg_text, linewise = linewise }, "change")
  else
    set_register(st, { text = reg_text, linewise = linewise }, "delete")
  end
  local keys = st.visual_keys
  local was_line = st.mode == "visual_line"
  -- linewise delete/change eats the trailing newline, matching dd/cc.
  local del_span = span
  if linewise then
    local e = span.stop
    if e < #buf.text and buf.text:sub(e + 1, e + 1) == "\n" then
      e = e + 1
    elseif span.start > 0 and span.stop >= #buf.text then
      del_span = { start = span.start - 1, stop = span.stop }
    end
    if e ~= span.stop then
      del_span = { start = span.start, stop = e }
    end
  end
  if enter_insert_after then
    apply_edit(buf, res, motions.delete_span(buf.text, del_span))
    exit_visual(st)
    enter_insert(st, buf, res, {}, before)
    -- dot-repeat replays the visual navigation + the operator key.
    if keys ~= nil and not st.replaying then
      local setup = { "v" }
      for _, k in ipairs(keys) do
        setup[#setup + 1] = k
      end
      st.insert_setup_keys = setup
    end
    res.handled = true
    return res
  end
  apply_edit(buf, res, motions.delete_span(buf.text, del_span))
  exit_visual(st)
  commit_change(st, buf, res, before)
  -- dot-repeat: replay the visual navigation + the caller-tracked op key
  -- (the key itself was tracked before visual_apply ran).
  if keys ~= nil and not st.replaying then
    local seq = { was_line and "V" or "v" }
    for _, k in ipairs(keys) do
      seq[#seq + 1] = k
    end
    st.rep = { kind = "keys", keys = seq }
  end
  st.key_seq = {}
  res.handled = true
  return res
end

-- Move the cursor for a visual-mode motion key. Returns true when the key
-- was a motion (cursor moved/stayed, anchor kept, key tracked).
local function visual_motion(st, buf, key, count)
  for _ = 1, count do
    if key == "h" or key == "left" then
      buf.cursor = motions.move_left(buf.text, buf.cursor)
    elseif key == "l" or key == "right" then
      buf.cursor = motions.move_right(buf.text, buf.cursor)
    elseif key == "j" or key == "down" then
      local col = st.wanted_column
      if col == nil then
        col = motions.line_column(buf.text, buf.cursor)
      end
      buf.cursor = motions.move_line_down(buf.text, buf.cursor, col)
      st.wanted_column = col
    elseif key == "k" or key == "up" then
      local col = st.wanted_column
      if col == nil then
        col = motions.line_column(buf.text, buf.cursor)
      end
      buf.cursor = motions.move_line_up(buf.text, buf.cursor, col)
      st.wanted_column = col
    elseif key == "w" then
      buf.cursor = motions.move_word_next(buf.text, buf.cursor)
    elseif key == "b" then
      buf.cursor = motions.move_word_prev(buf.text, buf.cursor)
    elseif key == "e" then
      buf.cursor = motions.move_word_end(buf.text, buf.cursor)
    elseif key == "W" then
      buf.cursor = motions.move_big_word_next(buf.text, buf.cursor)
    elseif key == "B" then
      buf.cursor = motions.move_big_word_prev(buf.text, buf.cursor)
    elseif key == "E" then
      buf.cursor = motions.move_big_word_end(buf.text, buf.cursor)
    elseif key == "0" then
      buf.cursor = motions.move_line_beginning(buf.text, buf.cursor)
    elseif key == "^" or key == "_" then
      buf.cursor = motions.move_first_non_whitespace(buf.text, buf.cursor)
    elseif key == "$" then
      buf.cursor = motions.move_line_end(buf.text, buf.cursor)
      st.wanted_column = "end"
    elseif key == "{" then
      buf.cursor = motions.move_previous_paragraph(buf.text, buf.cursor)
    elseif key == "}" then
      buf.cursor = motions.move_next_paragraph(buf.text, buf.cursor)
    elseif key == "%" then
      local target, ok = motions.move_matching_bracket(buf.text, buf.cursor)
      if ok then
        buf.cursor = target
      end
    elseif key == "G" then
      buf.cursor = #buf.text
    else
      return false
    end
  end
  snap_cursor(buf)
  return true
end

local SCROLL_OF = {
  e = "line-down",
  y = "line-up",
  d = "half-down",
  u = "half-up",
  f = "page-down",
  b = "page-up",
}

-- Visual-mode dispatch: extend the selection with motions, operate with
-- y/d/c/x/s/p/r/u/U/~/J, toggle with v/V, swap ends with o. Dot-repeat
-- replays the navigation keys plus the operator.
local function dispatch_visual(st, buf, res, ev, before)
  local key = ev.key
  local ctrl = ev.ctrl

  if key == "escape" and not ctrl then
    exit_visual(st)
    res.handled = true
    res.cursor_only = true
    return res
  end

  -- v toggles charwise off (or converts linewise to charwise);
  -- V toggles linewise off (or converts charwise to linewise).
  if key == "v" and not ctrl then
    if st.mode == "visual" then
      exit_visual(st)
    else
      st.mode = "visual"
      st.visual_anchor = buf.cursor
      st.visual_line_anchor = nil
    end
    res.handled = true
    res.cursor_only = true
    return res
  end
  if key == "V" and not ctrl then
    if st.mode == "visual_line" then
      exit_visual(st)
    else
      st.mode = "visual_line"
      st.visual_line_anchor = motions.line_start(buf.text, buf.cursor)
      st.visual_anchor = nil
      buf.cursor = st.visual_line_anchor
      snap_cursor(buf)
    end
    res.handled = true
    res.cursor_only = true
    return res
  end

  -- o swaps the active end with the anchor.
  if key == "o" and not ctrl then
    if st.mode == "visual_line" and st.visual_line_anchor ~= nil then
      local cur_line = motions.line_start(buf.text, buf.cursor)
      buf.cursor = st.visual_line_anchor
      st.visual_line_anchor = cur_line
    elseif st.visual_anchor ~= nil then
      local cur = buf.cursor
      buf.cursor = st.visual_anchor
      st.visual_anchor = cur
    end
    snap_cursor(buf)
    visual_track_key(st, key)
    res.handled = true
    res.cursor_only = true
    return res
  end

  -- pending f/F/t/T find motion.
  local pend = st.pending
  if pend == "f" or pend == "F" or pend == "t" or pend == "T" then
    if is_printable(ev) then
      local forward = pend == "f" or pend == "t"
      local till = pend == "t" or pend == "T"
      local count = vstate.take_count(st, 1)
      buf.cursor = motions.find_motion(buf.text, buf.cursor, ev.key, forward, till, count, false)
      snap_cursor(buf)
      visual_track_key(st, pend)
      visual_track_key(st, ev.key)
      st.last_find = { char = ev.key, forward = forward, till = till }
      vstate.clear_pending(st)
      if buf.cursor ~= before.cursor then
        res.cursor_only = true
      end
      res.handled = true
      return res
    end
    vstate.clear_pending(st)
    res.handled = true
    return res
  end
  if (key == "f" or key == "t" or key == "F" or key == "T") and not ctrl then
    vstate.set_pending(st, key, st.count .. key)
    res.handled = true
    return res
  end
  if key == ";" and not ctrl then
    local last = st.last_find
    if last ~= nil then
      buf.cursor = motions.find_motion(
        buf.text, buf.cursor, last.char, last.forward, last.till, vstate.take_count(st, 1), true)
      snap_cursor(buf)
      visual_track_key(st, key)
      if buf.cursor ~= before.cursor then
        res.cursor_only = true
      end
    end
    res.handled = true
    return res
  end
  if key == "," and not ctrl then
    local last = st.last_find
    if last ~= nil then
      buf.cursor = motions.find_motion(
        buf.text, buf.cursor, last.char, not last.forward, last.till, vstate.take_count(st, 1), true)
      snap_cursor(buf)
      visual_track_key(st, key)
      if buf.cursor ~= before.cursor then
        res.cursor_only = true
      end
    end
    res.handled = true
    return res
  end

  -- i/a text objects: reselect to the object (vim visual behavior).
  if not ctrl and (key == "i" or key == "a") then
    local tag = "vi"
    if key == "a" then
      tag = "va"
    end
    vstate.set_pending(st, tag, tag)
    res.handled = true
    return res
  end
  if st.pending == "vi" or st.pending == "va" then
    local around = st.pending == "va"
    local obj_key = key
    vstate.clear_pending(st)
    local result = nil
    if obj_key == "w" or obj_key == "W" then
      local big = obj_key == "W"
      result = motions.word_text_object_operation(buf.text, buf.cursor, around, big)
    elseif obj_key == '"' or obj_key == "'" or obj_key == "`" then
      result = motions.quote_text_object_operation(buf.text, buf.cursor, around, obj_key)
    elseif obj_key == "(" or obj_key == ")" or obj_key == "[" or obj_key == "]"
      or obj_key == "{" or obj_key == "}" or obj_key == "<" or obj_key == ">" then
      result = motions.bracket_text_object_operation(buf.text, buf.cursor, around, obj_key, "v")
    end
    if result ~= nil and result.span ~= nil and result.span.stop > result.span.start then
      st.mode = "visual"
      st.visual_anchor = result.span.start
      st.visual_line_anchor = nil
      buf.cursor = result.span.stop - 1
      snap_cursor(buf)
      if around then
        visual_track_key(st, "a")
      else
        visual_track_key(st, "i")
      end
      visual_track_key(st, obj_key)
    end
    res.handled = true
    res.cursor_only = true
    return res
  end

  -- yank: copy the span, back to normal.
  if key == "y" and not ctrl then
    local span = visual_span(buf, st)
    local linewise = st.mode == "visual_line"
    if span ~= nil then
      local slice = buf.text:sub(span.start + 1, span.stop)
      local reg_text = slice
      if linewise and slice ~= "" and slice:sub(-1) ~= "\n" then
        reg_text = slice .. "\n"
      end
      set_register(st, { text = reg_text, linewise = linewise }, "yank")
    end
    local keys = st.visual_keys
    local was_line = st.mode == "visual_line"
    exit_visual(st)
    if keys ~= nil and not st.replaying then
      local seq = { was_line and "V" or "v" }
      for _, k in ipairs(keys) do
        seq[#seq + 1] = k
      end
      seq[#seq + 1] = "y"
      st.rep = { kind = "keys", keys = seq }
    end
    st.key_seq = {}
    res.handled = true
    res.cursor_only = true
    return res
  end

  -- operators that delete the selection (c/s enter insert after).
  if not ctrl and (key == "d" or key == "x") then
    visual_track_key(st, key)
    return visual_apply(st, buf, res, before, false)
  end
  if not ctrl and (key == "c" or key == "s") then
    visual_track_key(st, key)
    return visual_apply(st, buf, res, before, true)
  end

  -- r: replace every selected char with the typed one.
  if st.pending == "" and key == "r" and not ctrl then
    vstate.set_pending(st, "r")
    res.handled = true
    return res
  end
  if st.pending == "r" then
    if ctrl then
      vstate.clear_pending(st)
      res.handled = false
      return res
    end
    if is_printable(ev) then
      local value = ev.key
      local span = visual_span(buf, st)
      vstate.clear_pending(st)
      if span ~= nil and span.stop > span.start then
        local fill = string.rep(value, span.stop - span.start)
        apply_edit(buf, res, {
          start = span.start, stop = span.stop, text = fill, cursor = span.start,
        })
        local keys = st.visual_keys
        exit_visual(st)
        commit_change(st, buf, res, before)
        if keys ~= nil and not st.replaying then
          local seq = { "v" }
          for _, k in ipairs(keys) do
            seq[#seq + 1] = k
          end
          seq[#seq + 1] = "r"
          seq[#seq + 1] = value
          st.rep = { kind = "keys", keys = seq }
        end
        st.key_seq = {}
      else
        exit_visual(st)
      end
      res.handled = true
      return res
    end
    vstate.clear_pending(st)
    res.handled = true
    return res
  end

  -- u/U: case-convert the selection in place (one undo unit).
  if not ctrl and (key == "u" or key == "U") then
    local span = visual_span(buf, st)
    if span ~= nil and span.stop > span.start then
      local slice = buf.text:sub(span.start + 1, span.stop)
      local out
      if key == "u" then
        out = slice:lower()
      else
        out = slice:upper()
      end
      apply_edit(buf, res, {
        start = span.start, stop = span.stop, text = out, cursor = span.start,
      })
      local keys = st.visual_keys
      exit_visual(st)
      commit_change(st, buf, res, before)
      if keys ~= nil and not st.replaying then
        local seq = { "v" }
        for _, k in ipairs(keys) do
          seq[#seq + 1] = k
        end
        seq[#seq + 1] = key
        st.rep = { kind = "keys", keys = seq }
      end
      st.key_seq = {}
    else
      exit_visual(st)
    end
    res.handled = true
    return res
  end

  -- ~: toggle case across the selection.
  if key == "~" and not ctrl then
    local span = visual_span(buf, st)
    if span ~= nil and span.stop > span.start then
      local parts = {}
      local off = span.start
      while off < span.stop do
        local nxt = motions.char_next(buf.text, off)
        if nxt > span.stop then
          nxt = span.stop
        end
        local ch = buf.text:sub(off + 1, nxt)
        local lo = ch:lower()
        local up = ch:upper()
        if ch == lo and ch ~= up then
          parts[#parts + 1] = up
        elseif ch == up and ch ~= lo then
          parts[#parts + 1] = lo
        else
          parts[#parts + 1] = ch
        end
        off = nxt
      end
      apply_edit(buf, res, {
        start = span.start, stop = span.stop,
        text = table.concat(parts), cursor = span.start,
      })
      local keys = st.visual_keys
      exit_visual(st)
      commit_change(st, buf, res, before)
      if keys ~= nil and not st.replaying then
        local seq = { "v" }
        for _, k in ipairs(keys) do
          seq[#seq + 1] = k
        end
        seq[#seq + 1] = "~"
        st.rep = { kind = "keys", keys = seq }
      end
      st.key_seq = {}
    else
      exit_visual(st)
    end
    res.handled = true
    return res
  end

  -- p/P: replace the selection with the register.
  if not ctrl and (key == "p" or key == "P") then
    local reg = motions.counted_register(st.register, vstate.take_count(st, 1))
    local span = visual_span(buf, st)
    if reg ~= nil and span ~= nil then
      local old = buf.text:sub(span.start + 1, span.stop)
      apply_edit(buf, res, {
        start = span.start, stop = span.stop, text = reg.text, cursor = span.start,
      })
      set_register(st, { text = old, linewise = false }, "paste")
      local keys = st.visual_keys
      exit_visual(st)
      commit_change(st, buf, res, before)
      if keys ~= nil and not st.replaying then
        local seq = { "v" }
        for _, k in ipairs(keys) do
          seq[#seq + 1] = k
        end
        seq[#seq + 1] = key
        st.rep = { kind = "keys", keys = seq }
      end
      st.key_seq = {}
    else
      exit_visual(st)
      vstate.clear_count(st)
    end
    res.handled = true
    return res
  end

  -- J: join the selected lines.
  if key == "J" and not ctrl then
    local span = visual_span(buf, st)
    if span ~= nil then
      local s = motions.line_start(buf.text, span.start)
      local e = motions.line_end(buf.text, math.max(s, span.stop - 1))
      local slice = buf.text:sub(s + 1, e)
      local joined = slice:gsub("\n%s*", " ")
      apply_edit(buf, res, { start = s, stop = e, text = joined, cursor = s })
      local keys = st.visual_keys
      exit_visual(st)
      commit_change(st, buf, res, before)
      if keys ~= nil and not st.replaying then
        local seq = { "v" }
        for _, k in ipairs(keys) do
          seq[#seq + 1] = k
        end
        seq[#seq + 1] = "J"
        st.rep = { kind = "keys", keys = seq }
      end
      st.key_seq = {}
    else
      exit_visual(st)
    end
    res.handled = true
    return res
  end

  -- counts: apply to the following motion.
  if not ctrl and ((key >= "1" and key <= "9") or (key == "0" and st.count ~= "")) then
    vstate.append_count_digit(st, key)
    res.handled = true
    return res
  end

  -- gg: extend to the prompt start.
  if key == "g" and not ctrl then
    if st.pending == "g" then
      vstate.clear_pending(st)
      buf.cursor = 0
      snap_cursor(buf)
      visual_track_key(st, "g")
      visual_track_key(st, "g")
      res.handled = true
      res.cursor_only = true
      return res
    end
    vstate.set_pending(st, "g", st.count .. "g")
    res.handled = true
    return res
  end
  if st.pending == "g" then
    vstate.clear_pending(st)
    res.handled = true
    return res
  end

  -- selection motions.
  if not ctrl and visual_motion(st, buf, key, vstate.take_count(st, 1)) then
    visual_track_key(st, key)
    if buf.cursor ~= before.cursor then
      res.cursor_only = true
    end
    res.handled = true
    return res
  end

  if is_printable(ev) then
    -- unhandled printable: keep the selection, swallow the key.
    res.handled = true
    return res
  end
  res.handled = false
  return res
end


local function dispatch_normal(st, buf, res, ev, before)
  local key = ev.key
  local ctrl = ev.ctrl

  -- j/k column memory: cleared unless this key preserves it
  local preserves_col = false
  if key == "g" and not ctrl then
    preserves_col = true
  end
  if (key == "j" or key == "k" or key == "down" or key == "up") and not ctrl then
    preserves_col = true
  end
  if not preserves_col then
    st.wanted_column = nil
  end

  -- pending r: single-char replace
  if st.pending == "r" then
    if ctrl then
      vstate.clear_pending(st)
      res.handled = false
      return res
    end
    if is_printable(ev) then
      local value = ev.key
      local r = motions.delete_under_cursor(buf.text, buf.cursor)
      if r ~= nil then
        local off = buf.cursor
        apply_edit(buf, res, r.edit)
        buf.cursor = off
        snap_cursor(buf)
        local cursor = off
        if value == "\n" then
          cursor = off + 1
        end
        apply_edit(buf, res, { start = off, stop = off, text = value, cursor = cursor })
        set_register(st, r.register, "change")
        vstate.clear_pending(st)
        commit_change(st, buf, res, before)
      else
        vstate.clear_pending(st)
      end
      res.handled = true
      return res
    end
    vstate.clear_pending(st)
    res.handled = true
    return res
  end

  if pending_find_operator(st, buf, res, ev, before) then
    res.handled = true
    return res
  end
  if pending_text_object_operator(st, buf, res, key, before) then
    res.handled = true
    return res
  end

  -- pending f/F/t/T motion
  local pend = st.pending
  if pend == "f" or pend == "F" or pend == "t" or pend == "T" then
    if is_printable(ev) then
      local forward = pend == "f" or pend == "t"
      local till = pend == "t" or pend == "T"
      local char = ev.key
      local count = take_count(st, 1)
      buf.cursor = motions.find_motion(buf.text, buf.cursor, char, forward, till, count, false)
      snap_cursor(buf)
      if buf.cursor ~= before.cursor then
        res.cursor_only = true
      end
      st.last_find = { char = char, forward = forward, till = till }
      vstate.clear_pending(st)
      res.handled = true
      return res
    end
    vstate.clear_pending(st)
    res.handled = true
    return res
  end

  -- ctrl scroll (vimScroll)
  if ctrl and SCROLL_OF[key] ~= nil then
    st.op_display = nil
    vstate.clear_pending(st)
    st.op_count = 1
    res.handled = true
    res.scroll = SCROLL_OF[key]
    return res
  end

  -- operator + g (display motions degrade to plain motions)
  if (st.pending == "c" or st.pending == "d" or st.pending == "y")
    and key == "g" and not ctrl then
    st.op_display = st.pending
    vstate.set_pending(st, "g", (st.pending_display ~= "" and st.pending_display or st.pending) .. "g")
    res.handled = true
    return res
  end

  if st.pending == "g" and not ctrl then
    local op = st.op_display
    if key == "j" or key == "k" or key == "down" or key == "up" then
      st.op_display = nil
      if op ~= nil then
        vertical_motion_operator(st, buf, res, key, op, before)
      else
        local count = take_count(st, 1)
        local col = st.wanted_column
        if col == nil then
          col = motions.line_column(buf.text, buf.cursor)
        end
        for _ = 1, count do
          if key == "j" or key == "down" then
            buf.cursor = motions.move_line_down(buf.text, buf.cursor, col)
          else
            buf.cursor = motions.move_line_up(buf.text, buf.cursor, col)
          end
        end
        st.wanted_column = col
        snap_cursor(buf)
        res.cursor_only = true
        vstate.clear_pending(st)
      end
      res.handled = true
      return res
    end
    if key == "0" or key == "^" or key == "$" then
      st.op_display = nil
      if op ~= nil then
        line_boundary_motion(st, buf, res, key, op, before)
      else
        take_count(st, 1)
        vstate.clear_pending(st)
        st.wanted_column = nil
        if key == "0" then
          buf.cursor = motions.move_line_beginning(buf.text, buf.cursor)
        elseif key == "^" then
          buf.cursor = motions.move_first_non_whitespace(buf.text, buf.cursor)
        else
          buf.cursor = motions.move_line_end(buf.text, buf.cursor)
          st.wanted_column = "end"
        end
        snap_cursor(buf)
        res.cursor_only = true
      end
      res.handled = true
      return res
    end
  end

  if st.pending == "g" then
    st.op_display = nil
    st.op_count = 1
  end

  -- jumps: G bottom, gg top (parity quirk: dgx loses the operator, like upstream)
  if key == "G" and not ctrl then
    vstate.clear_pending(st)
    st.wanted_column = nil
    res.handled = true
    res.jump = "bottom"
    return res
  end
  if key == "g" and not ctrl then
    if st.pending == "g" then
      vstate.clear_pending(st)
      st.wanted_column = nil
      res.handled = true
      res.jump = "top"
      return res
    end
    vstate.set_pending(st, "g", st.count .. "g")
    res.handled = true
    return res
  end
  if st.pending == "g" then
    vstate.clear_pending(st)
  end

  if key == "escape" then
    if st.pending == "" and st.count == "" then
      res.handled = false
      return res
    end
    if st.pending == "" then
      vstate.clear_count(st)
      res.handled = true
      return res
    end
    vstate.clear_pending(st)
    res.handled = true
    return res
  end

  -- counts (upstream isCountInput: only with no pending operator/find)
  if st.pending == "" and not ctrl and ((key >= "1" and key <= "9") or (key == "0" and st.count ~= "")) then
    vstate.append_count_digit(st, key)
    res.handled = true
    res.count_key = true
    return res
  end

  -- dot repeat
  if key == "." and not ctrl and st.pending == "" then
    local ok = run_repeat(st, buf, res)
    vstate.clear_count(st)
    res.handled = true
    res.did_repeat = ok
    return res
  end

  -- undo
  if key == "u" and not ctrl and st.pending == "" then
    do_undo(st, buf, res)
    res.handled = true
    return res
  end

  -- redo
  if key == "r" and ctrl and st.pending == "" then
    do_redo(st, buf, res)
    res.handled = true
    return res
  end

  -- operator pending dispatch
  local pop = st.pending
  if pop == "c" or pop == "d" or pop == "y" then
    local handled = operator_pending(st, buf, res, ev, key, pop, before)
    if handled ~= nil then
      res.handled = handled
      return res
    end
  end

  -- "/" and "@": insert at column 0 of an empty prompt, else swallow
  if (key == "/" or key == "@") and not ctrl then
    if buf.cursor == 0 and #buf.text == 0 then
      local b = snap_of(buf)
      st.insert_norepeat = true
      enter_insert(st, buf, res, { { start = 0, stop = 0, text = key, cursor = 1 } }, b)
      res.handled = true
      return res
    end
    res.handled = true
    return res
  end
  if key == "?" and not ctrl then
    res.handled = true
    return res
  end

  if key == "c" and not ctrl then
    start_operator(st, "c")
    res.handled = true
    return res
  end
  if key == "d" and not ctrl then
    start_operator(st, "d")
    res.handled = true
    return res
  end
  if key == "y" and not ctrl then
    start_operator(st, "y")
    res.handled = true
    return res
  end

  if key == "r" and not ctrl then
    vstate.set_pending(st, "r")
    res.handled = true
    return res
  end

  if key == "p" and not ctrl then
    local reg = motions.counted_register(st.register, take_count(st, 1))
    local edit = motions.paste_after(buf.text, buf.cursor, reg)
    if edit ~= nil then
      apply_edit(buf, res, edit)
      commit_change(st, buf, res, before)
    end
    res.handled = true
    return res
  end

  if key == "P" and not ctrl then
    local reg = motions.counted_register(st.register, take_count(st, 1))
    local edit = motions.paste_before(buf.text, buf.cursor, reg)
    if edit ~= nil then
      apply_edit(buf, res, edit)
      commit_change(st, buf, res, before)
    end
    res.handled = true
    return res
  end

  if (key == "f" or key == "t" or key == "F" or key == "T") and not ctrl then
    vstate.set_pending(st, key, st.count .. key)
    res.handled = true
    return res
  end

  if key == ";" and not ctrl then
    local last = st.last_find
    if last ~= nil then
      buf.cursor = motions.find_motion(
        buf.text, buf.cursor, last.char, last.forward, last.till, take_count(st, 1), true)
      snap_cursor(buf)
      res.cursor_only = true
    end
    res.handled = true
    return res
  end

  if key == "," and not ctrl then
    local last = st.last_find
    if last ~= nil then
      buf.cursor = motions.find_motion(
        buf.text, buf.cursor, last.char, not last.forward, last.till, take_count(st, 1), true)
      snap_cursor(buf)
      res.cursor_only = true
    end
    res.handled = true
    return res
  end

  if key == "S" and not ctrl then
    local r = motions.substitute_line(buf.text, buf.cursor, nil)
    local setup = {}
    if r ~= nil then
      setup = { r.edit }
      if r.register ~= nil then
        set_register(st, r.register, "change")
      end
    end
    vstate.clear_pending(st)
    enter_insert(st, buf, res, setup, before)
    res.handled = true
    return res
  end

  if key == "D" and not ctrl then
    local r = motions.delete_line_end(buf.text, buf.cursor)
    if r ~= nil then
      apply_edit(buf, res, r.edit)
      if r.register ~= nil then
        set_register(st, r.register, "delete")
      end
      commit_change(st, buf, res, before)
    end
    res.handled = true
    return res
  end

  if key == "C" and not ctrl then
    local r = motions.substitute_line_end(buf.text, buf.cursor)
    local setup = {}
    if r ~= nil then
      setup = { r.edit }
      if r.register ~= nil then
        set_register(st, r.register, "change")
      end
    end
    enter_insert(st, buf, res, setup, before)
    res.handled = true
    return res
  end

  if key == "R" and not ctrl then
    st.insert_before = snap_of(buf)
    st.insert_base = snap_of(buf)
    st.replace_start = buf.cursor
    st.replace_typed = false
    st.replace_edits = {}
    st.key_seq = {}
    vstate.set_mode(st, "replace")
    res.handled = true
    return res
  end

  -- enter visual / visual-line mode (emulated: anchor in Lua).
  if key == "v" and not ctrl then
    st.mode = "visual"
    st.visual_anchor = buf.cursor
    st.visual_line_anchor = nil
    st.visual_keys = {}
    vstate.clear_pending(st)
    vstate.clear_count(st)
    res.handled = true
    res.cursor_only = true
    return res
  end
  if key == "V" and not ctrl then
    st.mode = "visual_line"
    st.visual_line_anchor = motions.line_start(buf.text, buf.cursor)
    st.visual_anchor = nil
    st.visual_keys = {}
    vstate.clear_pending(st)
    vstate.clear_count(st)
    buf.cursor = st.visual_line_anchor
    snap_cursor(buf)
    res.handled = true
    res.cursor_only = true
    return res
  end

  if key == "i" and not ctrl then
    enter_insert(st, buf, res, {}, before)
    res.handled = true
    return res
  end
  if key == "I" and not ctrl then
    local c = motions.insert_line_start(buf.text, buf.cursor)
    buf.cursor = c
    if c ~= before.cursor then
      res.cursor_only = true
    end
    enter_insert(st, buf, res, {}, before)
    res.handled = true
    return res
  end
  if key == "a" and not ctrl then
    local c = motions.append_after_cursor(buf.text, buf.cursor)
    buf.cursor = c
    if c ~= before.cursor then
      res.cursor_only = true
    end
    enter_insert(st, buf, res, {}, before)
    res.handled = true
    return res
  end
  if key == "A" and not ctrl then
    local c = motions.append_line_end(buf.text, buf.cursor)
    buf.cursor = c
    if c ~= before.cursor then
      res.cursor_only = true
    end
    enter_insert(st, buf, res, {}, before)
    res.handled = true
    return res
  end
  if key == "o" and not ctrl then
    local edit = motions.open_line_below(buf.text, buf.cursor)
    enter_insert(st, buf, res, { edit }, before)
    res.handled = true
    return res
  end
  if key == "O" and not ctrl then
    local edit = motions.open_line_above(buf.text, buf.cursor)
    enter_insert(st, buf, res, { edit }, before)
    res.handled = true
    return res
  end

  -- ":": no command line on the host; insert "/" at column 0 and enter
  -- insert mode so the slash-command palette stays reachable.
  if key == ":" and not ctrl then
    st.insert_norepeat = true
    enter_insert(st, buf, res, { { start = 0, stop = 0, text = "/", cursor = 1 } }, before)
    res.handled = true
    return res
  end

  if (key == "h" or key == "left") and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_left(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if (key == "l" or key == "right") and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_right(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end

  if key == "J" and not ctrl then
    local edit = motions.join_lines(buf.text, buf.cursor)
    if edit ~= nil then
      apply_edit(buf, res, edit)
      commit_change(st, buf, res, before)
    end
    res.handled = true
    return res
  end

  if (key == "j" or key == "down") and not ctrl then
    local count = take_count(st, 1)
    local col = st.wanted_column
    if col == nil then
      col = motions.line_column(buf.text, buf.cursor)
    end
    for _ = 1, count do
      buf.cursor = motions.move_line_down(buf.text, buf.cursor, col)
    end
    st.wanted_column = col
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if (key == "k" or key == "up") and not ctrl then
    local count = take_count(st, 1)
    local col = st.wanted_column
    if col == nil then
      col = motions.line_column(buf.text, buf.cursor)
    end
    for _ = 1, count do
      buf.cursor = motions.move_line_up(buf.text, buf.cursor, col)
    end
    st.wanted_column = col
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end

  if key == "0" and not ctrl then
    buf.cursor = motions.move_line_beginning(buf.text, buf.cursor)
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if (key == "^" or key == "_") and not ctrl then
    buf.cursor = motions.move_first_non_whitespace(buf.text, buf.cursor)
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if key == "$" and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count - 1 do
      buf.cursor = motions.move_line_down(buf.text, buf.cursor, 0)
    end
    buf.cursor = motions.move_line_end(buf.text, buf.cursor)
    st.wanted_column = "end"
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end

  if key == "%" and not ctrl then
    local target, ok = motions.move_matching_bracket(buf.text, buf.cursor)
    if ok then
      buf.cursor = target
      res.cursor_only = true
    end
    res.handled = true
    return res
  end

  if key == "{" and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_previous_paragraph(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if key == "}" and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_next_paragraph(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end

  if key == "s" and not ctrl then
    local r = motions.delete_under_cursor(buf.text, buf.cursor)
    local setup = {}
    if r ~= nil then
      -- upstream keeps the cursor where the char was
      setup = { { start = r.edit.start, stop = r.edit.stop, text = "", cursor = before.cursor } }
      if r.register ~= nil then
        set_register(st, r.register, "change")
      end
    end
    enter_insert(st, buf, res, setup, before)
    res.handled = true
    return res
  end

  if key == "x" and not ctrl then
    local r = motions.delete_under_cursor(buf.text, buf.cursor)
    if r ~= nil then
      apply_edit(buf, res, r.edit)
      if r.register ~= nil then
        set_register(st, r.register, "delete")
      end
      commit_change(st, buf, res, before)
    end
    res.handled = true
    return res
  end

  if key == "~" and not ctrl then
    local count = take_count(st, 1)
    local changed = false
    for _ = 1, count do
      local prev = buf.cursor
      local r = motions.toggle_case(buf.text, buf.cursor)
      if r == nil then
        break
      end
      apply_edit(buf, res, r.edit)
      if r.changed or buf.cursor ~= prev then
        changed = true
      end
      if buf.cursor == prev then
        break
      end
    end
    vstate.push(st, before, snap_of(buf))
    if changed then
      record_keys_repeat(st)
    end
    res.handled = true
    return res
  end

  if key == "w" and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_word_next(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if key == "b" and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_word_prev(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if key == "e" and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_word_end(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if key == "W" and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_big_word_next(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if key == "B" and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_big_word_prev(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end
  if key == "E" and not ctrl then
    local count = take_count(st, 1)
    for _ = 1, count do
      buf.cursor = motions.move_big_word_end(buf.text, buf.cursor)
    end
    snap_cursor(buf)
    res.cursor_only = true
    res.handled = true
    return res
  end

  -- C-w has no window to navigate in the prompt: clear and swallow.
  if key == "w" and ctrl then
    vstate.clear_pending(st)
    res.handled = true
    return res
  end

  if key == "BS" or key == "delete" then
    res.handled = true
    return res
  end

  if is_printable(ev) then
    res.handled = true
    return res
  end

  res.handled = false
  return res
end

-- ---------------------------------------------------------------------------
-- entry point
-- ---------------------------------------------------------------------------

-- ev = { key = string, ctrl = bool }. Arrow keys arrive as
-- up/down/left/right and are treated as k/j/h/l.
function H.handle(st, buf, ev)
  if ev.key == "up" and not ev.ctrl then
    ev = { key = "k", ctrl = false }
  elseif ev.key == "down" and not ev.ctrl then
    ev = { key = "j", ctrl = false }
  elseif ev.key == "left" and not ev.ctrl then
    ev = { key = "h", ctrl = false }
  elseif ev.key == "right" and not ev.ctrl then
    ev = { key = "l", ctrl = false }
  end

  if st.mode == "replace" then
    local res = new_result(false)
    return handle_replace(st, buf, res, ev)
  end

  if st.mode == "insert" then
    local res = new_result(false)
    if ev.key == "escape" then
      exit_insert(st, buf, res)
      res.handled = true
      return res
    end
    return res
  end

  -- visual modes: motions extend the anchor; operators consume it.
  -- key_seq is untouched (visual records its own repeat via visual_keys).
  if st.mode == "visual" or st.mode == "visual_line" then
    local before = snap_of(buf)
    local res = new_result(false)
    dispatch_visual(st, buf, res, ev, before)
    if res.handled and st.count ~= "" and st.pending == "" and not res.count_key then
      vstate.clear_count(st)
    end
    res.count_key = nil
    return res
  end

  -- normal mode: accumulate the key sequence for dot-repeat, then dispatch.
  if not st.replaying then
    st.key_seq[#st.key_seq + 1] = ev.key
  end
  local before = snap_of(buf)
  local res = new_result(false)
  dispatch_normal(st, buf, res, ev, before)

  -- upstream tail: a leftover count with no pending input is dropped once
  -- the key was handled by something other than count input.
  if res.handled and st.count ~= "" and st.pending == "" and not res.count_key then
    vstate.clear_count(st)
  end
  res.count_key = nil

  -- Without an open operator or insert session the sequence is spent:
  -- a change already banked it as repeat, anything else drops it. A
  -- partially typed count (st.count ~= "") keeps it: `3dw` banks {3,d,w}.
  if not st.replaying and st.pending == "" and st.mode == "normal" and st.count == "" then
    st.key_seq = {}
  end
  return res
end

return H
