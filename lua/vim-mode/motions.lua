-- vim-motions: pure text-math port of opencode-vim's src/vim/motions.ts.
-- No maki dependency. All offsets are 0-based BYTE offsets into Lua strings
-- (which is exactly the unit maki.ui.input/input_edit use).
--
-- Upstream indexes JS strings (UTF-16 code units); the port is byte-based.
-- To avoid landing inside multi-byte characters, cursor motions that step
-- horizontally use whole UTF-8 characters (char_next/char_prev) and every
-- computed cursor passes through M.snap (back to a character start).

local M = {}

-- ---------------------------------------------------------------------------
-- UTF-8 / byte helpers
-- ---------------------------------------------------------------------------

local function byte_at(text, off)
  if off < 0 or off >= #text then
    return nil
  end
  return text:byte(off + 1)
end

local function is_cont_byte(b)
  return b ~= nil and b >= 0x80 and b < 0xC0
end

-- Start offset of the character after the one containing 0-based `off`.
function M.char_next(text, off)
  if off >= #text then
    return #text
  end
  local q = off + 1
  while q < #text and is_cont_byte(byte_at(text, q)) do
    q = q + 1
  end
  return q
end

-- Start offset of the character containing / before 0-based `off`.
function M.char_prev(text, off)
  if off <= 0 then
    return 0
  end
  local q = off - 1
  while q > 0 and is_cont_byte(byte_at(text, q)) do
    q = q - 1
  end
  return q
end

-- Snap a 0-based offset back to a character start (no-op on boundaries).
function M.snap(text, pos)
  if pos >= #text then
    return #text
  end
  if pos <= 0 then
    return 0
  end
  while pos > 0 and is_cont_byte(byte_at(text, pos)) do
    pos = pos - 1
  end
  return pos
end

function M.char_at(text, off)
  return text:sub(off + 1, M.char_next(text, off))
end

local function swap_char(ch)
  local lo = ch:lower()
  local up = ch:upper()
  if ch == lo and ch ~= up then
    return up
  end
  if ch == up and ch ~= lo then
    return lo
  end
  return ch
end

local function is_space_byte(b)
  if b == nil then
    return false
  end
  local ch = string.char(b)
  return ch == " " or ch == "\t" or ch == "\n" or ch == "\r" or ch == "\v" or ch == "\f"
end

-- ---------------------------------------------------------------------------
-- Lines
-- ---------------------------------------------------------------------------

function M.line_start(text, off)
  if off <= 0 then
    return 0
  end
  local last = nil
  local from = 1
  while true do
    local i = text:find("\n", from, true)
    if i == nil or i > off then
      break
    end
    last = i
    from = i + 1
  end
  if last == nil then
    return 0
  end
  return last
end

function M.line_end(text, off)
  local i = text:find("\n", off + 1, true)
  if i == nil then
    return #text
  end
  return i - 1
end

function M.line_last(text, off)
  local start = M.line_start(text, off)
  local bend = M.line_end(text, off)
  if bend > start then
    return bend - 1
  end
  return start
end

local function prev_line_start(text, off)
  local start = M.line_start(text, off)
  if start == 0 then
    return nil
  end
  return M.line_start(text, start - 1)
end

local function next_line_start(text, off)
  local bend = M.line_end(text, off)
  if bend >= #text then
    return nil
  end
  return bend + 1
end

function M.line_column(text, off)
  return off - M.line_start(text, off)
end

function M.first_non_whitespace(text, off)
  local start = M.line_start(text, off)
  local bend = M.line_end(text, off)
  local pos = start
  while pos < bend and is_space_byte(byte_at(text, pos)) do
    pos = pos + 1
  end
  return pos
end

-- ---------------------------------------------------------------------------
-- Plain cursor motions (return new cursor)
-- ---------------------------------------------------------------------------

function M.move_left(text, cursor)
  local start = M.line_start(text, cursor)
  local prev = M.char_prev(text, cursor)
  if prev < start then
    return start
  end
  return prev
end

function M.move_right(text, cursor)
  local last = M.line_last(text, cursor)
  local nxt = M.char_next(text, cursor)
  if nxt > last then
    return last
  end
  return nxt
end

local function move_up(text, off, col)
  local target_start = prev_line_start(text, off)
  if target_start == nil then
    return off
  end
  local target_last = M.line_last(text, target_start)
  local c = col
  if c == "end" then
    c = target_last - target_start
  end
  local want = target_start + c
  if want > target_last then
    return target_last
  end
  return want
end

local function move_down(text, off, col)
  local target_start = next_line_start(text, off)
  if target_start == nil then
    return off
  end
  local target_last = M.line_last(text, target_start)
  local c = col
  if c == "end" then
    c = target_last - target_start
  end
  local want = target_start + c
  if want > target_last then
    return target_last
  end
  return want
end

function M.move_line_up(text, cursor, col)
  local c = col
  if c == nil then
    c = M.line_column(text, cursor)
  end
  return M.snap(text, move_up(text, cursor, c))
end

function M.move_line_down(text, cursor, col)
  local c = col
  if c == nil then
    c = M.line_column(text, cursor)
  end
  return M.snap(text, move_down(text, cursor, c))
end

function M.move_line_beginning(text, cursor)
  return M.line_start(text, cursor)
end

function M.move_first_non_whitespace(text, cursor)
  return M.first_non_whitespace(text, cursor)
end

function M.move_line_end(text, cursor)
  return M.line_last(text, cursor)
end

function M.clamp_cursor_to_line(text, cursor)
  local last = M.line_last(text, cursor)
  if cursor > last then
    return last
  end
  return cursor
end

function M.append_after_cursor(text, cursor)
  local bend = M.line_end(text, cursor)
  local nxt = M.char_next(text, cursor)
  if nxt > bend then
    return bend
  end
  return nxt
end

function M.append_line_end(text, cursor)
  return M.line_end(text, cursor)
end

function M.insert_line_start(text, cursor)
  return M.first_non_whitespace(text, cursor)
end

-- ---------------------------------------------------------------------------
-- Paragraphs
-- ---------------------------------------------------------------------------

local function is_blank_line(text, line_start_off)
  return M.line_end(text, line_start_off) == line_start_off
end

-- vim treats a trailing \n as EOL of the last line, not a new empty line.
local function paragraph_advance(text, line_off)
  local bend = M.line_end(text, line_off)
  if bend >= #text - 1 then
    return nil
  end
  return bend + 1
end

local function paragraph_retreat(text, line_off)
  if line_off <= 0 then
    return nil
  end
  return M.line_start(text, line_off - 1)
end

local function next_paragraph_target(text, cursor)
  if #text == 0 then
    return 0
  end
  local probe = M.line_start(text, cursor)
  while is_blank_line(text, probe) do
    local nxt = paragraph_advance(text, probe)
    if nxt == nil then
      return probe
    end
    probe = nxt
  end
  while not is_blank_line(text, probe) do
    local nxt = paragraph_advance(text, probe)
    if nxt == nil then
      return M.line_last(text, #text - 1)
    end
    probe = nxt
  end
  return probe
end

local function previous_paragraph_target(text, cursor)
  if #text == 0 or cursor == 0 then
    return 0
  end
  local probe = M.line_start(text, cursor)
  while is_blank_line(text, probe) do
    local prev = paragraph_retreat(text, probe)
    if prev == nil then
      return 0
    end
    probe = prev
  end
  while probe > 0 do
    local prev = paragraph_retreat(text, probe)
    if prev == nil then
      return 0
    end
    if is_blank_line(text, prev) then
      return prev
    end
    probe = prev
  end
  return 0
end

function M.move_next_paragraph(text, cursor)
  return next_paragraph_target(text, cursor)
end

function M.move_previous_paragraph(text, cursor)
  return previous_paragraph_target(text, cursor)
end

-- ---------------------------------------------------------------------------
-- Words
-- ---------------------------------------------------------------------------

local function word_class_byte(b, big)
  if b == nil then
    return "blank"
  end
  local ch = string.char(b)
  local is_space = is_space_byte(b)
  if not is_space then
    if big then
      return "word"
    end
    if ch:match("[A-Za-z0-9_]") then
      return "word"
    end
    return "punct"
  end
  return "blank"
end

local function word_class_at(text, off, big)
  return word_class_byte(byte_at(text, off), big)
end

function M.next_word_start(text, off, big)
  local pos = off
  if pos >= #text then
    return #text
  end
  local start_class = word_class_at(text, pos, big)
  if start_class ~= "blank" then
    while pos < #text and word_class_at(text, pos, big) == start_class do
      pos = pos + 1
    end
  end
  while pos < #text and word_class_at(text, pos, big) == "blank" do
    pos = pos + 1
  end
  return M.snap(text, pos)
end

function M.prev_word_start(text, off, big)
  local pos = off
  if pos > #text then
    pos = #text
  end
  if pos <= 0 then
    return 0
  end
  pos = pos - 1
  while pos > 0 and word_class_at(text, pos, big) == "blank" do
    pos = pos - 1
  end
  local target = word_class_at(text, pos, big)
  while pos > 0 and word_class_at(text, pos - 1, big) == target do
    pos = pos - 1
  end
  return M.snap(text, pos)
end

local function word_run_end(text, off, big)
  local target = word_class_at(text, off, big)
  local pos = off
  while pos + 1 < #text and word_class_at(text, pos + 1, big) == target do
    pos = pos + 1
  end
  return pos
end

function M.word_end(text, off, big)
  if #text == 0 then
    return 0
  end
  local pos = off
  if pos >= #text then
    pos = #text - 1
  end
  local start_class = word_class_at(text, pos, big)
  local at_run_end = start_class == "blank"
    or pos + 1 >= #text
    or word_class_at(text, pos + 1, big) ~= start_class
  if at_run_end then
    pos = pos + 1
    while pos < #text and word_class_at(text, pos, big) == "blank" do
      pos = pos + 1
    end
    if pos >= #text then
      return M.snap(text, #text - 1)
    end
  end
  return M.snap(text, word_run_end(text, pos, big))
end

function M.move_word_next(text, cursor)
  return M.next_word_start(text, cursor, false)
end

function M.move_word_prev(text, cursor)
  return M.prev_word_start(text, cursor, false)
end

function M.move_word_end(text, cursor)
  return M.word_end(text, cursor, false)
end

function M.move_big_word_next(text, cursor)
  return M.next_word_start(text, cursor, true)
end

function M.move_big_word_prev(text, cursor)
  return M.prev_word_start(text, cursor, true)
end

function M.move_big_word_end(text, cursor)
  return M.word_end(text, cursor, true)
end

-- ---------------------------------------------------------------------------
-- Operator result helpers
-- ---------------------------------------------------------------------------

local function as_linewise(slice)
  if slice:sub(-1) == "\n" then
    return slice
  end
  return slice .. "\n"
end

-- span/registerSpan are { start, stop } (0-based, stop exclusive) or nil.
local function build_operator_result(text, span, register_span, linewise)
  if span == nil then
    return { span = nil, register = nil }
  end
  local rspan = register_span or span
  local slice = text:sub(rspan.start + 1, rspan.stop)
  local reg_text = linewise and as_linewise(slice) or slice
  return { span = span, register = { text = reg_text, linewise = linewise } }
end

local function charwise_operation(text, span)
  if span == nil then
    return { span = nil, register = nil }
  end
  return {
    span = span,
    register = { text = text:sub(span.start + 1, span.stop), linewise = false },
  }
end

local function linewise_operation(text, span)
  if span == nil then
    return { span = nil, register = nil }
  end
  local slice = text:sub(span.start + 1, span.stop)
  return { span = span, register = { text = as_linewise(slice), linewise = true } }
end

function M.counted_register(reg, count)
  if reg == nil or count <= 1 then
    return reg
  end
  local separator = ""
  if reg.linewise and reg.text:sub(-1) ~= "\n" then
    separator = "\n"
  end
  local parts = {}
  for _ = 1, count do
    parts[#parts + 1] = reg.text
  end
  return { text = table.concat(parts, separator), linewise = reg.linewise }
end

function M.line_beginning_operation(text, cursor)
  local bend = cursor
  local start = M.line_start(text, bend)
  if start < bend then
    return build_operator_result(text, { start = start, stop = bend }, nil, false)
  end
  return { span = nil, register = nil }
end

function M.first_non_whitespace_operation(text, cursor)
  local target = M.first_non_whitespace(text, cursor)
  if target == cursor then
    return { span = nil, register = nil }
  end
  local s = math.min(target, cursor)
  local e = math.max(target, cursor)
  return build_operator_result(text, { start = s, stop = e }, nil, false)
end

-- ---------------------------------------------------------------------------
-- Paragraph operators (linewise rules derived empirically from nvim)
-- ---------------------------------------------------------------------------

local function classify_next_paragraph(text, cursor)
  local line_start_off = M.line_start(text, cursor)
  local on_blank = is_blank_line(text, line_start_off)
  local target = next_paragraph_target(text, cursor)
  local target_line_start = M.line_start(text, target)
  return {
    line_start = line_start_off,
    on_blank = on_blank,
    line_aligned = on_blank or cursor == line_start_off,
    target = target,
    target_is_blank = target == target_line_start and target < #text and is_blank_line(text, target),
    multi_line = line_start_off ~= target_line_start,
  }
end

local function is_linewise_next(c, op)
  if not c.line_aligned then
    return false
  end
  if op == "d" then
    return c.target_is_blank or c.multi_line
  end
  return c.target_is_blank
end

local function next_linewise_span(text, c, op)
  if op == "d" and not c.target_is_blank then
    local extend_back = text:sub(-1) ~= "\n" and c.line_start > 0
    local s = extend_back and (c.line_start - 1) or c.line_start
    return { start = s, stop = #text }, { start = c.line_start, stop = #text }
  end
  local bend = c.target
  if op == "c" then
    bend = c.target - 1
  end
  if bend <= c.line_start then
    return nil, nil
  end
  return { start = c.line_start, stop = bend }, nil
end

local function next_charwise_span(text, cursor, c)
  local bend
  if c.target_is_blank then
    bend = c.target - 1
  elseif c.on_blank then
    bend = #text
  else
    bend = c.target + 1
  end
  if bend <= cursor then
    return nil
  end
  return { start = cursor, stop = bend }
end

function M.next_paragraph_operation(text, cursor, operation)
  if #text == 0 then
    return { span = nil, register = nil }
  end
  local c = classify_next_paragraph(text, cursor)
  if not is_linewise_next(c, operation) then
    return build_operator_result(text, next_charwise_span(text, cursor, c), nil, false)
  end
  local span, rspan = next_linewise_span(text, c, operation)
  return build_operator_result(text, span, rspan, true)
end

function M.previous_paragraph_operation(text, cursor, operation)
  if #text == 0 or cursor == 0 then
    return { span = nil, register = nil }
  end
  local line_start_off = M.line_start(text, cursor)
  local linewise = is_blank_line(text, line_start_off) or cursor == line_start_off
  local target = previous_paragraph_target(text, cursor)
  if target >= cursor then
    return { span = nil, register = nil }
  end
  if not linewise or operation ~= "c" then
    return build_operator_result(text, { start = target, stop = cursor }, nil, linewise)
  end
  local bend = cursor
  if text:sub(cursor, cursor) == "\n" then
    bend = cursor - 1
  end
  if bend > target then
    return build_operator_result(text, { start = target, stop = bend }, nil, true)
  end
  return { span = nil, register = nil }
end

-- ---------------------------------------------------------------------------
-- Word operators
-- ---------------------------------------------------------------------------

function M.next_word_operation(text, start, big, count)
  local bend = start
  for _ = 1, count or 1 do
    bend = M.next_word_start(text, bend, big)
  end
  if bend > start then
    return charwise_operation(text, { start = start, stop = bend })
  end
  return charwise_operation(text, nil)
end

function M.previous_word_operation(text, cursor, count)
  local bend = cursor
  local start = bend
  for _ = 1, count or 1 do
    start = M.prev_word_start(text, start, false)
  end
  if start < bend then
    return charwise_operation(text, { start = start, stop = bend })
  end
  return charwise_operation(text, nil)
end

function M.word_end_operation(text, start, big, count)
  if start >= #text then
    return charwise_operation(text, nil)
  end
  local bend = start
  for _ = 1, count or 1 do
    bend = M.word_end(text, bend, big) + 1
  end
  if bend > start then
    return charwise_operation(text, { start = start, stop = bend })
  end
  return charwise_operation(text, nil)
end

function M.change_word_operation(text, cursor, big, count)
  local b = byte_at(text, cursor)
  if b ~= nil and not is_space_byte(b) then
    return M.word_end_operation(text, cursor, big, count)
  end
  return M.next_word_operation(text, cursor, big, count)
end

-- ---------------------------------------------------------------------------
-- Word text objects
-- ---------------------------------------------------------------------------

local function word_inner_span(text, cursor, big)
  local len = #text
  if len == 0 then
    return nil
  end
  local pos = cursor
  if pos > len - 1 then
    pos = len - 1
  end
  if text:sub(pos + 1, pos + 1) == "\n" then
    return nil
  end
  local target = word_class_at(text, pos, big)
  local start = pos
  while start > 0 and word_class_at(text, start - 1, big) == target do
    start = start - 1
  end
  local bend = pos + 1
  while bend < len and word_class_at(text, bend, big) == target do
    bend = bend + 1
  end
  if start < bend then
    return { start = start, stop = bend }
  end
  return nil
end

local function word_blank_span(text, cursor, big)
  local len = #text
  local start = cursor
  if start > len - 1 then
    start = len - 1
  end
  if word_class_at(text, start, big) ~= "blank" or text:sub(start + 1, start + 1) == "\n" then
    return nil
  end
  while start > 0 and text:sub(start, start) ~= "\n" and word_class_at(text, start - 1, big) == "blank" do
    start = start - 1
  end
  local bend = start
  while bend < len and text:sub(bend + 1, bend + 1) ~= "\n" and word_class_at(text, bend, big) == "blank" do
    bend = bend + 1
  end
  if start < bend then
    return { start = start, stop = bend }
  end
  return nil
end

local function word_around_blank_span(text, blank, big)
  local len = #text
  local bend = blank.stop
  while bend < len and text:sub(bend + 1, bend + 1) ~= "\n" and word_class_at(text, bend, big) == "blank" do
    bend = bend + 1
  end
  if bend >= len or text:sub(bend + 1, bend + 1) == "\n" then
    return nil
  end
  local inner = word_inner_span(text, bend, big)
  if inner == nil then
    return nil
  end
  bend = inner.stop
  while bend < len and text:sub(bend + 1, bend + 1) ~= "\n" and word_class_at(text, bend, big) == "blank" do
    bend = bend + 1
  end
  return { start = blank.start, stop = bend }
end

function M.word_text_object_operation(text, cursor, around, big)
  big = big or false
  if #text == 0 then
    return { span = nil, register = nil }
  end
  local blank = word_blank_span(text, cursor, big)
  if blank ~= nil then
    if not around then
      return build_operator_result(text, blank, nil, false)
    end
    return build_operator_result(text, word_around_blank_span(text, blank, big), nil, false)
  end
  local inner = word_inner_span(text, cursor, big)
  if inner == nil then
    return { span = nil, register = nil }
  end
  if not around then
    return build_operator_result(text, inner, nil, false)
  end
  local bend = inner.stop
  while bend < #text and text:sub(bend + 1, bend + 1) ~= "\n" and word_class_at(text, bend, big) == "blank" do
    bend = bend + 1
  end
  if bend > inner.stop then
    return build_operator_result(text, { start = inner.start, stop = bend }, nil, false)
  end
  local start = inner.start
  while start > 0 and text:sub(start, start) ~= "\n" and word_class_at(text, start - 1, big) == "blank" do
    start = start - 1
  end
  return build_operator_result(text, { start = start, stop = inner.stop }, nil, false)
end

-- ---------------------------------------------------------------------------
-- Brackets
-- ---------------------------------------------------------------------------

local BRACKET_OPEN = { ["("] = ")", ["["] = "]", ["{"] = "}", ["<"] = ">" }
local BRACKET_CLOSE = { [")"] = "(", ["]"] = "[", ["}"] = "{", [">"] = "<" }

local function bracket_at_or_after(text, off)
  local bend = M.line_end(text, off)
  local pos = off
  if pos < 0 then
    pos = 0
  end
  while pos < bend do
    local ch = text:sub(pos + 1, pos + 1)
    if BRACKET_OPEN[ch] ~= nil or BRACKET_CLOSE[ch] ~= nil then
      return pos
    end
    pos = pos + 1
  end
  return nil
end

local function matching_forward(text, off, open, close)
  local depth = 1
  local pos = off + 1
  while pos < #text do
    local ch = text:sub(pos + 1, pos + 1)
    if ch == open then
      depth = depth + 1
    end
    if ch == close then
      depth = depth - 1
    end
    if depth == 0 then
      return pos
    end
    pos = pos + 1
  end
  return nil
end

local function matching_backward(text, off, open, close)
  local depth = 1
  local pos = off - 1
  while pos >= 0 do
    local ch = text:sub(pos + 1, pos + 1)
    if ch == close then
      depth = depth + 1
    end
    if ch == open then
      depth = depth - 1
    end
    if depth == 0 then
      return pos
    end
    pos = pos - 1
  end
  return nil
end

function M.matching_bracket_target(text, off)
  if #text == 0 then
    return nil
  end
  local clamped = off
  if clamped < 0 then
    clamped = 0
  end
  if clamped > #text - 1 then
    clamped = #text - 1
  end
  local source = bracket_at_or_after(text, clamped)
  if source == nil then
    return nil
  end
  local ch = text:sub(source + 1, source + 1)
  local close = BRACKET_OPEN[ch]
  if close ~= nil then
    return matching_forward(text, source, ch, close)
  end
  local open = BRACKET_CLOSE[ch]
  if open ~= nil then
    return matching_backward(text, source, open, ch)
  end
  return nil
end

function M.move_matching_bracket(text, cursor)
  local target = M.matching_bracket_target(text, cursor)
  if target == nil then
    return cursor, false
  end
  return target, true
end

function M.matching_bracket_operation(text, cursor)
  local target = M.matching_bracket_target(text, cursor)
  if target == nil then
    return { span = nil, register = nil }
  end
  local span
  if target < cursor then
    span = { start = target, stop = cursor + 1 }
  else
    span = { start = cursor, stop = target + 1 }
  end
  return {
    span = span,
    register = { text = text:sub(span.start + 1, span.stop), linewise = false },
  }
end

local function bracket_pair_chars(bracket)
  if bracket == "(" or bracket == ")" then
    return "(", ")"
  end
  if bracket == "[" or bracket == "]" then
    return "[", "]"
  end
  if bracket == "{" or bracket == "}" then
    return "{", "}"
  end
  if bracket == "<" or bracket == ">" then
    return "<", ">"
  end
  return nil, nil
end

local function bracket_containing(text, cursor, start, bend, open, close)
  local stack = {}
  local result = nil
  local index = start
  while index < bend do
    local ch = text:sub(index + 1, index + 1)
    if ch == open then
      stack[#stack + 1] = index
    end
    if ch == close then
      local pair_start = stack[#stack]
      stack[#stack] = nil
      if pair_start ~= nil and pair_start <= cursor and index >= cursor then
        if result == nil or pair_start > result.start then
          result = { start = pair_start, stop = index }
        end
      end
    end
    index = index + 1
  end
  return result
end

local function bracket_close_from(text, start, bend, open, close)
  local depth = 0
  local index = start
  while index < bend do
    local ch = text:sub(index + 1, index + 1)
    if ch == open then
      depth = depth + 1
    end
    if ch == close then
      depth = depth - 1
      if depth == 0 then
        return index
      end
    end
    index = index + 1
  end
  return nil
end

local function bracket_pair(text, cursor, bracket)
  local open, close = bracket_pair_chars(bracket)
  if open == nil then
    return nil
  end
  local containing = bracket_containing(text, cursor, 0, #text, open, close)
  if containing ~= nil then
    return containing
  end
  local i = text:find(open, cursor + 1, true)
  if i == nil then
    return nil
  end
  local pair_start = i - 1
  local pair_end = bracket_close_from(text, pair_start, #text, open, close)
  if pair_end == nil then
    return nil
  end
  return { start = pair_start, stop = pair_end }
end

local function bracket_inner_span(text, pair, operation)
  local start = pair.start + 1
  local bend = pair.stop
  if text:sub(start + 1, start + 1) == "\n" and text:sub(bend, bend) == "\n" then
    if operation == "c" then
      return { start = start + 1, stop = bend - 1 }
    end
    return { start = start + 1, stop = bend }
  end
  return { start = start, stop = bend }
end

function M.bracket_text_object_operation(text, cursor, around, bracket, operation)
  if #text == 0 then
    return { span = nil, register = nil }
  end
  local pair = bracket_pair(text, cursor, bracket)
  if pair == nil then
    return { span = nil, register = nil }
  end
  local span
  local register_span = nil
  if around then
    span = { start = pair.start, stop = pair.stop + 1 }
  else
    span = bracket_inner_span(text, pair, operation)
    register_span = bracket_inner_span(text, pair, "d")
  end
  if span.start < span.stop then
    return build_operator_result(text, span, register_span, false)
  end
  return { span = { start = span.start, stop = span.start }, register = { text = "", linewise = false } }
end

-- ---------------------------------------------------------------------------
-- Quotes
-- ---------------------------------------------------------------------------

local function is_escaped(text, pos)
  local backslashes = 0
  local index = pos - 1
  while index >= 0 and text:sub(index + 1, index + 1) == "\\" do
    backslashes = backslashes + 1
    index = index - 1
  end
  return backslashes % 2 == 1
end

local function quote_pair(text, cursor, quote)
  local start = M.line_start(text, cursor)
  local bend = M.line_end(text, cursor)
  local positions = {}
  local p = start
  while p < bend do
    if text:sub(p + 1, p + 1) == quote and not is_escaped(text, p) then
      positions[#positions + 1] = p
    end
    p = p + 1
  end
  if #positions < 2 then
    return nil
  end
  local index = nil
  for i, pos in ipairs(positions) do
    if pos >= cursor then
      index = i
      break
    end
  end
  if index == nil then
    return nil
  end
  if positions[index] == cursor then
    local pair_index = index
    if index % 2 == 0 then
      pair_index = index - 1
    end
    local pair_end = positions[pair_index + 1]
    if pair_end == nil then
      return nil
    end
    return { start = positions[pair_index], stop = pair_end }
  end
  local previous = positions[index - 1]
  if previous == nil then
    local pair_end = positions[2]
    if pair_end == nil then
      return nil
    end
    return { start = positions[1], stop = pair_end }
  end
  return { start = previous, stop = positions[index] }
end

local function quote_around_span(text, pair)
  local bend = pair.stop + 1
  while bend < #text and text:sub(bend + 1, bend + 1) ~= "\n" do
    local ch = text:sub(bend + 1, bend + 1)
    if ch ~= " " and ch ~= "\t" then
      break
    end
    bend = bend + 1
  end
  if bend > pair.stop + 1 then
    return { start = pair.start, stop = bend }
  end
  local start = pair.start
  while start > 0 and text:sub(start, start) ~= "\n" do
    local ch = text:sub(start, start)
    if ch ~= " " and ch ~= "\t" then
      break
    end
    start = start - 1
  end
  return { start = start, stop = pair.stop + 1 }
end

function M.quote_text_object_operation(text, cursor, around, quote)
  if #text == 0 then
    return { span = nil, register = nil }
  end
  local pair = quote_pair(text, cursor, quote)
  if pair == nil then
    return { span = nil, register = nil }
  end
  local span
  if around then
    span = quote_around_span(text, pair)
  else
    span = { start = pair.start + 1, stop = pair.stop }
  end
  if span.start < span.stop then
    return build_operator_result(text, span, nil, false)
  end
  return { span = { start = span.start, stop = span.start }, register = { text = "", linewise = false } }
end

-- ---------------------------------------------------------------------------
-- Find char in line
-- ---------------------------------------------------------------------------

function M.find_char_target_in_line(line, off, char, forward, skip)
  skip = skip or 1
  local clen = #char
  if forward then
    local i = off + skip
    while i + clen - 1 <= #line do
      if line:sub(i + 1, i + clen) == char then
        return i
      end
      i = i + 1
    end
    return nil
  end
  local i = off - skip
  while i >= 0 do
    if line:sub(i + 1, i + clen) == char then
      return i
    end
    i = i - 1
  end
  return nil
end

-- Line-scoped find used by the prompt handler (mirrors handler.ts
-- findCharTargetOffset: the search never crosses a newline).
-- Returns absolute 0-based offset or nil.
function M.find_in_line(text, cursor, char, forward, till, count, repeat_flag)
  local ls = M.line_start(text, cursor)
  local le = M.line_end(text, cursor)
  local line = text:sub(ls + 1, le)
  local rel = cursor - ls
  local target = nil
  for index = 1, count or 1 do
    local skip = 1
    if till and repeat_flag and index == 1 then
      skip = 2
    end
    target = M.find_char_target_in_line(line, rel, char, forward, skip)
    if target == nil then
      return nil
    end
    rel = target
  end
  return ls + target
end

function M.find_motion(text, cursor, char, forward, till, count)
  local target = M.find_in_line(text, cursor, char, forward, till, count or 1, false)
  if target == nil then
    return cursor
  end
  if till then
    if forward then
      return target - 1
    end
    return target + 1
  end
  return target
end

function M.find_operation(text, cursor, char, forward, till, count)
  local start = cursor
  local target = M.find_in_line(text, cursor, char, forward, till, count or 1, false)
  if target == nil then
    return charwise_operation(text, nil)
  end
  if forward then
    local span_end = target
    if not till then
      span_end = target + #char
    end
    if span_end > start then
      return charwise_operation(text, { start = start, stop = span_end })
    end
    return charwise_operation(text, nil)
  end
  local span_start = target
  if till then
    span_start = target + #char
  end
  if span_start < start then
    return charwise_operation(text, { start = span_start, stop = start })
  end
  return charwise_operation(text, nil)
end

-- ---------------------------------------------------------------------------
-- Line spans with counts
-- ---------------------------------------------------------------------------

function M.line_start_for_count(text, off, count)
  local current = off
  for _ = 1, (count or 1) - 1 do
    local bend = M.line_end(text, current)
    if bend < #text then
      current = bend + 1
    end
  end
  return current
end

function M.line_span_count(text, cursor, count)
  local start = M.line_start(text, cursor)
  local target = M.line_start_for_count(text, cursor, count)
  return { start = start, stop = M.line_end(text, target) }
end

function M.yank_line_count(text, cursor, count)
  local span = M.line_span_count(text, cursor, count)
  local slice = text:sub(span.start + 1, span.stop)
  return { span = span, register = { text = slice, linewise = true } }
end

function M.delete_line_count(text, cursor, count)
  local start = cursor
  local anchor = start
  for _ = 1, (count or 1) - 1 do
    anchor = M.move_line_down(text, anchor, 0)
  end
  return M.delete_line(text, start, anchor)
end

function M.substitute_line_count(text, cursor, count)
  local start = cursor
  local anchor = start
  for _ = 1, (count or 1) - 1 do
    anchor = M.move_line_down(text, anchor, 0)
  end
  return M.substitute_line(text, start, anchor)
end

function M.line_end_count_operation(text, start, count)
  local target = M.line_start_for_count(text, start, count)
  local bend = M.line_end(text, target)
  if bend > start then
    return charwise_operation(text, { start = start, stop = bend })
  end
  return charwise_operation(text, nil)
end

-- ---------------------------------------------------------------------------
-- Primitive edits. Each returns { edit, register } where edit is
-- { start, stop, text, cursor } (0-based byte offsets, stop exclusive) and
-- register is { text, linewise } or nil. A nil edit means "no change".
-- The handler applies edit to its scratch buffer and forwards it to
-- maki.ui.input_edit.
-- ---------------------------------------------------------------------------

function M.apply_edit(text, edit)
  return text:sub(1, edit.start) .. edit.text .. text:sub(edit.stop + 1)
end

function M.delete_under_cursor(text, cursor)
  local bend = M.line_end(text, cursor)
  if cursor >= bend then
    return nil
  end
  local stop = M.char_next(text, cursor)
  local yanked = text:sub(cursor + 1, stop)
  local new_text = text:sub(1, cursor) .. text:sub(stop + 1)
  local c = cursor
  local last = M.line_last(new_text, c)
  if c > last then
    c = last
  end
  return {
    edit = { start = cursor, stop = stop, text = "", cursor = c },
    register = { text = yanked, linewise = false },
  }
end

function M.delete_line(text, cursor, anchor)
  if #text == 0 then
    return nil
  end
  local offset = cursor
  local lo = offset
  local hi = offset
  if anchor ~= nil then
    lo = math.min(anchor, offset)
    hi = math.max(anchor, offset)
  end
  local start = M.line_start(text, lo)
  local finish = M.line_end(text, hi)
  local yanked = text:sub(start + 1, finish)
  local reg = { text = yanked, linewise = true }
  if finish < #text then
    return {
      edit = { start = start, stop = finish + 1, text = "", cursor = start },
      register = reg,
    }
  end
  if start > 0 then
    local new_text = text:sub(1, start - 1) .. text:sub(finish + 1)
    local c = M.line_start(new_text, start - 1)
    return {
      edit = { start = start - 1, stop = finish, text = "", cursor = c },
      register = reg,
    }
  end
  return {
    edit = { start = start, stop = finish, text = "", cursor = start },
    register = reg,
  }
end

function M.delete_line_end(text, cursor)
  local start = cursor
  local bend = M.line_end(text, start)
  if bend <= start then
    return nil
  end
  local yanked = text:sub(start + 1, bend)
  local new_text = text:sub(1, start) .. text:sub(bend + 1)
  local c = M.line_last(new_text, start)
  return {
    edit = { start = start, stop = bend, text = "", cursor = c },
    register = { text = yanked, linewise = false },
  }
end

function M.delete_span(text, span)
  if span == nil or span.stop <= span.start then
    return nil
  end
  return { start = span.start, stop = span.stop, text = "", cursor = span.start }
end

function M.join_lines(text, cursor)
  local bend = M.line_end(text, cursor)
  if bend >= #text then
    return nil
  end
  local nxt = bend + 1
  while nxt < #text do
    local ch = text:sub(nxt + 1, nxt + 1)
    if ch ~= " " and ch ~= "\t" then
      break
    end
    nxt = nxt + 1
  end
  local trailing = false
  if bend > 0 then
    local ch = text:sub(bend, bend)
    trailing = ch == " " or ch == "\t"
  end
  local paren = nxt < #text and text:sub(nxt + 1, nxt + 1) == ")"
  local ins = ""
  if not trailing and not paren then
    ins = " "
  end
  return { start = bend, stop = nxt, text = ins, cursor = bend }
end

function M.substitute_line(text, cursor, anchor)
  local offset = cursor
  local lo = offset
  local hi = offset
  if anchor ~= nil then
    lo = math.min(anchor, offset)
    hi = math.max(anchor, offset)
  end
  local start = M.line_start(text, lo)
  local finish = M.line_end(text, hi)
  if finish <= start then
    return nil
  end
  local yanked = text:sub(start + 1, finish)
  return {
    edit = { start = start, stop = finish, text = "", cursor = start },
    register = { text = yanked, linewise = true },
  }
end

function M.substitute_line_end(text, cursor)
  local start = cursor
  local bend = M.line_end(text, start)
  if bend <= start then
    return nil
  end
  local yanked = text:sub(start + 1, bend)
  return {
    edit = { start = start, stop = bend, text = "", cursor = start },
    register = { text = yanked, linewise = false },
  }
end

-- Replace the char under the cursor with `value` (single-char `r` and
-- replace mode). At EOL/EOF the value is inserted instead. Like upstream's
-- delete+insertText pair, the cursor lands after the replaced/inserted text.
function M.replace_under_cursor(text, cursor, value)
  local ch = text:sub(cursor + 1, cursor + 1)
  if cursor >= #text or ch == "\n" then
    return { start = cursor, stop = cursor, text = value, cursor = cursor + #value }
  end
  local stop = M.char_next(text, cursor)
  return { start = cursor, stop = stop, text = value, cursor = cursor + #value }
end

function M.toggle_case(text, cursor)
  local start = cursor
  local bend = M.line_end(text, start)
  if start >= bend then
    return nil
  end
  local stop = M.char_next(text, start)
  local ch = text:sub(start + 1, stop)
  local next_ch = swap_char(ch)
  local new_text = text
  local edit_text = ch
  local changed = false
  if next_ch ~= ch then
    new_text = text:sub(1, start) .. next_ch .. text:sub(stop + 1)
    edit_text = next_ch
    changed = true
  end
  local nxt = M.char_next(new_text, start)
  local last = M.line_last(new_text, start)
  local c = nxt
  if c > last then
    c = last
  end
  return {
    edit = { start = start, stop = stop, text = edit_text, cursor = c },
    changed = changed,
  }
end

function M.paste_after(text, cursor, reg)
  if reg == nil then
    return nil
  end
  if reg.linewise then
    local bend = M.line_end(text, cursor)
    local value = reg.text
    if value:sub(-1) == "\n" then
      value = value:sub(1, -2)
    end
    return { start = bend, stop = bend, text = "\n" .. value, cursor = bend + 1 }
  end
  local pos = M.char_next(text, cursor)
  if pos > #text then
    pos = #text
  end
  local new_text = text:sub(1, pos) .. reg.text .. text:sub(pos + 1)
  local c = pos + #reg.text
  c = M.snap(new_text, c)
  if c < pos then
    c = pos
  end
  return { start = pos, stop = pos, text = reg.text, cursor = c }
end

function M.paste_before(text, cursor, reg)
  if reg == nil then
    return nil
  end
  if reg.linewise then
    local start = M.line_start(text, cursor)
    local value = reg.text
    if value:sub(-1) == "\n" then
      value = value:sub(1, -2)
    end
    return { start = start, stop = start, text = value .. "\n", cursor = start }
  end
  local new_text = text:sub(1, cursor) .. reg.text .. text:sub(cursor + 1)
  local c = cursor + #reg.text
  c = M.snap(new_text, c)
  if c < cursor then
    c = cursor
  end
  return { start = cursor, stop = cursor, text = reg.text, cursor = c }
end

function M.open_line_below(text, cursor)
  local bend = M.line_end(text, cursor)
  return { start = bend, stop = bend, text = "\n", cursor = bend + 1 }
end

function M.open_line_above(text, cursor)
  local start = M.line_start(text, cursor)
  return { start = start, stop = start, text = "\n", cursor = start }
end

-- Single-contiguous-insertion diff used to capture typed text for dot-repeat:
-- when cur == base with one inserted run, returns { start, text } (0-based).
-- Returns nil for deletions, replacements, or multi-hunk edits.
function M.extract_insert(base, cur)
  if base == cur then
    return { start = 0, text = "" }
  end
  local prefix = 0
  local max_prefix = math.min(#base, #cur)
  while prefix < max_prefix and base:byte(prefix + 1) == cur:byte(prefix + 1) do
    prefix = prefix + 1
  end
  local suffix = 0
  while suffix < (#base - prefix) and suffix < (#cur - prefix) do
    if base:byte(#base - suffix) ~= cur:byte(#cur - suffix) then
      break
    end
    suffix = suffix + 1
  end
  local base_mid = #base - prefix - suffix
  local cur_mid_start = prefix + 1
  local cur_mid_stop = #cur - suffix
  if base_mid == 0 and cur_mid_stop >= cur_mid_start then
    return { start = prefix, text = cur:sub(cur_mid_start, cur_mid_stop) }
  end
  return nil
end

return M
