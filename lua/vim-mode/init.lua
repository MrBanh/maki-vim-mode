-- vim-mode: prompt-only vim mode for the maki TUI.
-- Modeled on https://github.com/leohenon/opencode-vim-plugin (prompt-vim.ts
-- + src/vim/*), ported to maki's Lua plugin API.
--
-- How it works:
--   * maki.keymap.set bindings run BEFORE the chat input sees the key, and a
--     claimed key is consumed. In normal/replace mode every printable key is
--     bound, so typing never reaches the input box. In insert mode only
--     <Esc> (and the <M-v> toggle) stay bound, so typing flows through the
--     native path at full speed.
--   * Key callbacks receive zero arguments, so each key gets a closure
--     capturing its key. Pending state (g/d/c/y/f + counts) accumulates in
--     Lua, mirroring upstream handler.ts.
--   * Writes go through maki.ui.input (read) + maki.ui.input_edit (write,
--     byte offsets). input_edit refuses on a stale version, so every write
--     is read -> compute -> write with up to 2 retries, behind a Lua-side
--     serial mutex (callbacks are async, max ~8 in-flight per plugin).
--   * <CR> is deliberately left unbound: native submit works in both modes,
--     matching upstream's default (normal-Enter submits).
--
-- Scope (prompt-only, same as upstream):
--   Delivered: normal/insert/replace/visual/visual-line modes, hjkl +
--   arrows, wbe/WBE, 0$^_, fFtT + ;/,, counts, operators c/d/y + cc/dd/yy,
--   text objects iw/aw/iW/aW/quotes/brackets, x/s/C/D/o/O/i/a/I/A/R/r,
--   p/P with charwise/linewise registers, internal registers,
--   u/<C-r> undo-redo (self-contained snapshot stacks), dot-repeat,
--   /vim toggle, status-hint indicator with per-mode colors. Starts in
--   insert mode (upstream default).
--   Visual is emulated: no host selection/highlight API exists, so the
--   anchor lives in Lua and the range shows in the hint ("-- VISUAL -- 3c",
--   "-- V-LINE -- 2L"). v/V enter/toggle, o swaps ends, motions extend,
--   y/d/c/x/s/r/u/U/~/p/P/J operate, text objects reselect. No
--   highlight and no block cursor (no cursor-style API).
--   Optional via M.setup(opts) (defaults preserve the behavior above):
--   escape_sequence ("jk" two-key escape from insert, via InputChanged),
--   langmap (pressed-key remap at the top of on_key), normal_leader +
--   normal_keybinds (one-key leader prefix running slash commands),
--   enter_submit = false (bind <CR> in insert to insert a newline),
--   insert_after_submit = false (fresh-prompt resets keep normal mode),
--   clipboard ("all"/"yank"/"never", default "never"): which unnamed
--   writes mirror to the system clipboard (and seed p/P from it).
--   system_clipboard_register = true is the legacy spelling of "all".
--   Without setup() every option stays at its default.
--   CUT (documented): selection highlight + block cursor (no cursor-style
--   or selection API on the host), gj/gk (degrade to j/k), `:`
--   commands (':' inserts '/' at column 0 and enters insert mode),
--   H/M/L viewport jumps, C-w window navigation.
--
-- Permissions: keymap/ui/autocmd/command APIs are ungated. The defaults
-- touch no maki.fn job APIs; clipboard = "all"/"yank" probes clipboard
-- tools via maki.fn.executable and shells out via maki.fn.jobstart, which
-- the package plugin.toml grants (run + fs_read).
--
-- Options reference (all fields optional):
--   setup({
--     escape_sequence = "jk",          -- string|nil (exactly 2 bytes)
--     escape_timeout_ms = 750,         -- max gap between the two keys
--     langmap = { H = "^", L = "$" },  -- pressed key -> matched identity
--     normal_leader = "space",         -- "space"/"<Space>" (or any 1 key)
--     normal_keybinds = { ["<leader>s"] = "/sessions" }, -- bare "s" also ok
--     enter_submit = true,             -- false: <CR> inserts a newline
--     insert_after_submit = true,      -- false: resets keep normal mode
--     clipboard = "yank", -- or "all" | "never"
--     mode_styles = { normal = "warning" }, -- theme style per vim mode
--   })
--   system_clipboard_register = true is still accepted as clipboard = "all".
--   mode_styles keys: normal/insert/replace/visual/visual_line; values are
--   theme style names ("accent", "success", "warning", "error", "dim", ...).
--   Defaults: normal=warning, insert=success, replace=error,
--   visual(+line)=accent.
--
-- Key pipeline notes (verified against maki-ui/src/app/mod.rs):
--   * Bindings are GLOBAL: they no-op cheaply when the input is not live
--     (fail closed on input() error).
--   * Overlays/modals consume keys first, so open pickers are safe.
--   * <Esc> while streaming is host-reserved (cancel wins); normal mode via
--     <Esc> is unavailable mid-stream.
--   * <C-c>/<C-z> can never be bound (host-reserved).

local vim_state = require("vim-mode.state")
local vim_handler = require("vim-mode.handler")
local vim_motions = require("vim-mode.motions")

local PLUGIN_NAME = "maki-vim-mode" -- package owner name (input_edit source)
local TOGGLE_KEY = "<M-v>"
local MAX_ATTEMPTS = 3 -- 1 initial write + 2 retries on stale version

local state = vim_state.new("insert")
local enabled = true
local cur_session = nil
local last_known = { text = "", cursor = 0, version = nil }

local mutex = maki.async.semaphore(1)

local M = {}

-- ---------------------------------------------------------------------------
-- user options (M.setup is defined at the end so it sees every local)
-- ---------------------------------------------------------------------------

local DEFAULT_ESCAPE_TIMEOUT_MS = 750
local CLIP_READ_TIMEOUT_MS = 1000

local cfg = {
  escape_sequence = nil, -- string|nil, e.g. "jk" (exactly 2 bytes)
  escape_timeout_ms = DEFAULT_ESCAPE_TIMEOUT_MS,
  langmap = {}, -- pressed key -> matched identity, e.g. { H = "^" }
  normal_leader = nil, -- normalized single key, e.g. " " for "space"
  normal_keybinds = {}, -- e.g. { ["<leader>s"] = "/sessions" }
  enter_submit = true, -- false: bind <CR> in insert to insert a newline
  insert_after_submit = true, -- false: fresh-prompt resets keep normal mode
  system_clipboard_register = false, -- legacy spelling of clipboard = "all"
  clipboard = nil, -- nil = unset; "all" | "yank" | "never" (see header)
  mode_styles = nil, -- nil = defaults below; else { normal=?, insert=?, replace=?, visual=?, visual_line=? }
}

-- Semantic theme names (see maki-ui/src/theme.rs style_by_name). Per-mode
-- indicator colors; unknown names resolve to the default style, so any
-- theme stays readable. Bold variants would need inline tables, which the
-- host hint store does not accept -- it keeps Vec<(String, String)> -- so
-- plain semantic names are the ceiling here.
local MODE_STYLES = {
  normal = "warning", -- yellow-ish (todo_in_progress)
  insert = "success", -- green-ish (todo_completed)
  replace = "error", -- red
  visual = "accent", -- orange-ish theme accent
  visual_line = "accent",
}

-- Clipboard mode resolution. An explicit clipboard value wins; otherwise
-- the legacy system_clipboard_register = true maps to "all"; default "never".
local function clipboard_mode()
  if cfg.clipboard == "all" or cfg.clipboard == "yank" or cfg.clipboard == "never" then
    return cfg.clipboard
  end
  if cfg.system_clipboard_register then
    return "all"
  end
  return "never"
end

local function clipboard_on()
  return clipboard_mode() ~= "never"
end

-- Should an unnamed write of this kind mirror outward? "all" mirrors every
-- unnamed write; "yank" mirrors yanks only; "never" mirrors nothing.
-- Non-mirrored writes stay local for p / P.
local function should_mirror(kind)
  local mode = clipboard_mode()
  if mode == "all" then
    return true
  end
  if mode == "yank" then
    return kind == "yank"
  end
  return false
end

-- May p/P seed the register from the system clipboard? Only when the
-- current content is mirror-eligible (or there is none): a local delete
-- under clipboard = "yank" must survive for p instead of being clobbered.
local function should_prefetch(reg)
  if not clipboard_on() then
    return false
  end
  if reg == nil then
    return true
  end
  return should_mirror(reg.kind)
end

-- one-key leader prefix armed while waiting for the key after the leader
local leader_armed = false
-- last single-char insert-mode insertion for escape_sequence detection
local esc_prev = nil -- { char, t } | nil

-- clock for the escape gap; os.time (1s resolution) fallback, nil if none
local clock_fn = nil
do
  if type(os) == "table" then
    if type(os.clock) == "function" then
      clock_fn = os.clock
    elseif type(os.time) == "function" then
      clock_fn = function()
        return os.time()
      end
    end
  end
end

local function normalize_leader(s)
  if type(s) ~= "string" then
    return nil
  end
  local inner = s:match("^%s*<%s*(.-)%s*>%s*$") or s:match("^%s*(.-)%s*$")
  if inner == nil or inner == "" then
    return nil
  end
  if inner:lower() == "space" then
    return " "
  end
  if #inner == 1 then
    return inner
  end
  return nil
end

local function fresh_mode()
  if cfg.insert_after_submit then
    return "insert"
  end
  return "normal"
end

-- internal key -> keymap notation, for "<leader><...>" bind candidates
local SPECIAL_NOTATION = {
  [" "] = "<Space>",
  escape = "<Esc>",
  BS = "<BS>",
  delete = "<Del>",
  up = "<Up>",
  down = "<Down>",
  left = "<Left>",
  right = "<Right>",
}

local function leader_lookup(key, ctrl)
  local binds = cfg.normal_keybinds
  local hit = binds["<leader>" .. key]
  if type(hit) == "string" then
    return hit
  end
  hit = binds[key]
  if type(hit) == "string" then
    return hit
  end
  if ctrl then
    hit = binds["<C-" .. key .. ">"]
  else
    local notation = SPECIAL_NOTATION[key]
    if notation ~= nil then
      hit = binds["<leader>" .. notation]
    end
  end
  if type(hit) == "string" then
    return hit
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- system clipboard (fire-and-forget writes, sync reads with fallback)
-- ---------------------------------------------------------------------------

local clip_tool = nil -- nil = unprobed, false = none found, else { name }

local function detect_clipboard_tool()
  if clip_tool ~= nil then
    return clip_tool
  end
  clip_tool = false
  if type(maki.fn) ~= "table" or type(maki.fn.executable) ~= "function" then
    return false
  end
  local function present(bin)
    local pok, v = pcall(maki.fn.executable, bin)
    return pok and v == 1
  end
  -- first match wins: pbcopy (macos), powershell (windows),
  -- wl-copy -> xclip -> xsel (linux)
  for _, bin in ipairs({ "pbcopy", "powershell", "wl-copy", "xclip", "xsel" }) do
    if present(bin) then
      clip_tool = { name = bin }
      break
    end
  end
  if not clip_tool then
    maki.log.debug("vim-mode: no system clipboard tool found")
  end
  return clip_tool
end

-- jobstart has no stdin support, so writes pipe through sh (powershell
-- takes the text as an argument instead). Key callbacks have no active
-- task, so both directions pass scope = "plugin" (the default "task"
-- scope dies with the dispatch and the write never lands).
local function clipboard_write_argv(tool, text)
  if tool.name == "powershell" then
    return { "powershell", "-NoProfile", "-NonInteractive", "-Command",
      "Set-Clipboard -Value $args[0]", text }
  end
  local sink = tool.name -- pbcopy | wl-copy
  if tool.name == "xclip" then
    sink = "xclip -selection clipboard"
  elseif tool.name == "xsel" then
    sink = "xsel -b -i"
  end
  return { "sh", "-c", "printf '%s' \"$1\" | " .. sink, "sh", text }
end

local function clipboard_read_argv(tool)
  if tool.name == "pbcopy" then
    return { "pbpaste" }
  end
  if tool.name == "powershell" then
    return { "powershell", "-NoProfile", "-NonInteractive", "-Command", "Get-Clipboard" }
  end
  if tool.name == "wl-copy" then
    return { "wl-paste" }
  end
  if tool.name == "xclip" then
    return { "xclip", "-o", "-selection", "clipboard" }
  end
  if tool.name == "xsel" then
    return { "xsel", "-b", "-o" }
  end
  return nil
end

-- jobwait stdout arrives as a string in some builds and a line list in
-- others; accept string, stdout table, or stdout_lines table.
local function job_stdout_text(res)
  if type(res.stdout) == "string" then
    return res.stdout
  end
  if type(res.stdout) == "table" then
    return table.concat(res.stdout, "\n")
  end
  if type(res.stdout_lines) == "table" then
    return table.concat(res.stdout_lines, "\n")
  end
  return nil
end

local function clipboard_write_text(text)
  if not clipboard_on() then
    return
  end
  if type(text) ~= "string" or text == "" then
    return
  end
  local tool = detect_clipboard_tool()
  if not tool then
    return
  end
  local argv = clipboard_write_argv(tool, text)
  if argv == nil then
    return
  end
  local pok, id = pcall(maki.fn.jobstart, argv, { stdout = false, stderr = false, scope = "plugin" })
  if not pok or id == nil then
    maki.log.debug("vim-mode: clipboard write spawn failed: " .. tostring(id))
  end
end

local function clipboard_read_text()
  if not clipboard_on() then
    return nil
  end
  local tool = detect_clipboard_tool()
  if not tool then
    return nil
  end
  local argv = clipboard_read_argv(tool)
  if argv == nil then
    return nil
  end
  local pok, id = pcall(maki.fn.jobstart, argv, { scope = "plugin" })
  if not pok or id == nil then
    maki.log.debug("vim-mode: clipboard read spawn failed")
    return nil
  end
  local wok, res = pcall(maki.fn.jobwait, id, CLIP_READ_TIMEOUT_MS)
  if not wok or type(res) ~= "table" or res.exit_code ~= 0 then
    maki.log.debug("vim-mode: clipboard read failed")
    return nil
  end
  local text = job_stdout_text(res)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  if tool.name == "powershell" then
    text = text:gsub("\r\n$", ""):gsub("\n$", "")
  end
  if text == "" then
    return nil
  end
  return text
end

-- Exactly-one-UTF-8-char appended at the end (old must be a prefix of new)?
-- Returns the added char or nil. Multi-char appends (pastes) return nil.
local function single_appended_char(old_text, new_text)
  if #new_text <= #old_text then
    return nil
  end
  if new_text:sub(1, #old_text) ~= old_text then
    return nil
  end
  local added = new_text:sub(#old_text + 1)
  if vim_motions.char_next(added, 0) ~= #added then
    return nil
  end
  return added
end

-- ---------------------------------------------------------------------------
-- key table
-- ---------------------------------------------------------------------------

local SYMBOLS = {
  "!", '"', "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-",
  ".", "/", ":", ";", "<", "=", ">", "?", "@", "[", "\\", "]", "^",
  "_", "`", "{", "|", "}", "~",
}

-- Each entry: { notation, key, ctrl }. `key` is what the core matches on:
-- printable literals, "escape"/"BS"/"delete"/arrow names, or a
-- lowercase letter with ctrl = true.
local FULL_KEYS = {}
do
  local function add(notation, key, ctrl)
    FULL_KEYS[#FULL_KEYS + 1] = { notation = notation, key = key, ctrl = ctrl and true or false }
  end
  for i = 97, 122 do
    add(string.char(i), string.char(i), false)
  end
  for i = 65, 90 do
    add(string.char(i), string.char(i), false)
  end
  for i = 48, 57 do
    add(string.char(i), string.char(i), false)
  end
  for _, s in ipairs(SYMBOLS) do
    add(s, s, false)
  end
  add("<Space>", " ", false)
  add("<Esc>", "escape", false)
  add("<BS>", "BS", false)
  add("<Del>", "delete", false)
  add("<Up>", "up", false)
  add("<Down>", "down", false)
  add("<Left>", "left", false)
  add("<Right>", "right", false)
  for _, c in ipairs({ "d", "u", "f", "b", "e", "y", "r", "w" }) do
    add("<C-" .. c .. ">", c, true)
  end
end

local MINIMAL_KEYS = {
  { notation = "<Esc>", key = "escape", ctrl = false },
}

-- insert mode with enter_submit = false: <CR> inserts a newline instead of
-- submitting. The key identity is a newline byte; only this binding sends it.
local CR_BIND = { notation = "<CR>", key = "\n", ctrl = false }

local MINIMAL_KEYS_NO_SUBMIT = {
  { notation = "<Esc>", key = "escape", ctrl = false },
  CR_BIND,
}

-- ---------------------------------------------------------------------------
-- host helpers
-- ---------------------------------------------------------------------------

local function read_input()
  local st, err = maki.ui.input()
  if type(st) ~= "table" then
    return nil
  end
  if type(st.text) ~= "string" then
    return nil
  end
  return {
    text = st.text,
    cursor = tonumber(st.cursor) or 0,
    version = st.version,
    session_id = st.session_id,
  }
end

local function write_edit(e, version, session_id)
  return maki.ui.input_edit({
    start = e.start,
    stop = e.stop,
    text = e.text,
    cursor = e.cursor,
    version = version,
    session_id = session_id,
  })
end

local function mode_style()
  local m = state.mode
  if cfg.mode_styles ~= nil and cfg.mode_styles[m] ~= nil then
    return cfg.mode_styles[m]
  end
  return MODE_STYLES[m] or ""
end

-- Selection summary for visual modes: "3c" / "2L" / line range.
-- Computed here (not in state) because it needs the buffer text.
local function visual_summary()
  local cur = nil
  if last_known.text ~= nil then
    cur = { text = last_known.text, cursor = last_known.cursor or 0 }
  else
    cur = read_input()
    if cur == nil then
      return ""
    end
  end
  local text = cur.text
  local cursor = cur.cursor
  if state.mode == "visual_line" then
    local anchor = state.visual_line_anchor
    if anchor == nil then
      return ""
    end
    local a_line = vim_motions.line_start(text, anchor)
    local c_line = vim_motions.line_start(text, cursor)
    local s = math.min(a_line, c_line)
    local e = vim_motions.line_end(text, math.max(a_line, c_line))
    if e <= s then
      return ""
    end
    -- count lines in [s, e)
    local n = 1
    local off = s
    while true do
      local nl = text:find("\n", off + 1, true)
      if nl == nil or nl > e then
        break
      end
      n = n + 1
      off = nl
    end
    if n == 1 then
      return "1L"
    end
    return n .. "L"
  end
  local anchor = state.visual_anchor
  if anchor == nil then
    return ""
  end
  local s = math.min(anchor, cursor)
  local e = math.max(anchor, cursor)
  if s == e and #text == 0 then
    return ""
  end
  e = vim_motions.char_next(text, e)
  local n = e - s
  if n <= 0 then
    return ""
  end
  return n .. "c"
end

local function update_hint()
  if not enabled then
    maki.ui.set_status_hint(nil)
    return
  end
  local mode_label, ctx = vim_state.indicator(state)
  if state.mode == "visual" or state.mode == "visual_line" then
    local sel = visual_summary()
    if sel ~= "" then
      ctx = sel
    else
      ctx = ""
    end
  end
  if ctx ~= nil and ctx ~= "" then
    maki.ui.set_status_hint({ { mode_label, mode_style() }, { " " .. ctx, "" } })
  else
    maki.ui.set_status_hint({ { mode_label, mode_style() } })
  end
end

-- ---------------------------------------------------------------------------
-- bindings
-- ---------------------------------------------------------------------------

local bound = {} -- notation -> true (bindings this plugin currently holds)
local handlers = {} -- notation -> function (stable closures)

local function desired_keys()
  if not enabled then
    return {}
  end
  if state.mode == "insert" then
    if cfg.enter_submit then
      return MINIMAL_KEYS
    end
    return MINIMAL_KEYS_NO_SUBMIT
  end
  return FULL_KEYS -- normal + replace + visual share the full set
end

local function sync_bindings()
  local want = {}
  for _, b in ipairs(desired_keys()) do
    want[b.notation] = b
  end
  -- the toggle is always bound while this file is loaded
  want[TOGGLE_KEY] = { notation = TOGGLE_KEY, toggle = true }
  for notation in pairs(bound) do
    if want[notation] == nil then
      maki.keymap.del("n", notation)
      bound[notation] = nil
    end
  end
  for notation, b in pairs(want) do
    if bound[notation] == nil then
      local h = handlers[notation]
      maki.keymap.set("n", notation, h, { desc = "vim-mode" })
      bound[notation] = true
    end
  end
end

-- ---------------------------------------------------------------------------
-- transcript scroll / jump (gg/G on empty prompt, C-d/u/f/b/e/y)
-- ---------------------------------------------------------------------------

local function transcript_view()
  local view, _ = maki.fn.winsaveview()
  if type(view) ~= "table" then
    return nil
  end
  return view
end

local function do_jump(which)
  local view = transcript_view()
  if view == nil then
    return
  end
  local topline = 1
  if which == "bottom" then
    topline = tonumber(view.line_count) or 1
  end
    maki.fn.winrestview({ topline = topline })
end

local function do_scroll(kind)
  local view = transcript_view()
  if view == nil then
    return
  end
  local height = tonumber(view.height) or 10
  if height < 1 then
    height = 1
  end
  local delta = 1
  if kind == "half-down" or kind == "half-up" then
    delta = math.floor(height / 2)
    if delta < 1 then
      delta = 1
    end
  elseif kind == "page-down" or kind == "page-up" then
    delta = height
  end
  local dir = 1
  if kind == "half-up" or kind == "page-up" or kind == "line-up" then
    dir = -1
  end
  local topline = (tonumber(view.topline) or 1) + dir * delta
  if topline < 1 then
    topline = 1
  end
  maki.fn.winrestview({ topline = topline })
end

-- ---------------------------------------------------------------------------
-- session tracking
-- ---------------------------------------------------------------------------

local function on_session_id(sid)
  cur_session = sid
  vim_state.reset_history(state)
  vim_state.set_mode(state, fresh_mode())
  state.key_seq = {}
  leader_armed = false
  esc_prev = nil
  sync_bindings()
  update_hint()
end

-- ---------------------------------------------------------------------------
-- main key path: read -> compute -> write (+retries)
-- ---------------------------------------------------------------------------

local function build_writes(buf, res, read_cursor)
  local writes = {}
  for _, e in ipairs(res.edits) do
    writes[#writes + 1] = e
  end
  if res.jump ~= nil and #buf.text > 0 then
    local target = 0
    if res.jump == "bottom" then
      target = #buf.text
    end
    if target ~= buf.cursor then
      buf.cursor = target
      writes[#writes + 1] = {
        start = read_cursor,
        stop = read_cursor,
        text = "",
        cursor = target,
      }
    end
  elseif #writes == 0 and buf.cursor ~= read_cursor then
    writes[1] = { start = read_cursor, stop = read_cursor, text = "", cursor = buf.cursor }
  end
  return writes
end

local function on_key(key, ctrl)
  if not ctrl then
    local mapped = cfg.langmap[key]
    if mapped ~= nil then
      key = mapped
    end
  end
  local permit = mutex:acquire()
  if not enabled then
    permit:release()
    return
  end
  local cur = read_input()
  if cur == nil then
    -- input not live (overlay, split, no UI): fail closed, keep state.
    permit:release()
    return
  end
  if cur.session_id ~= nil and cur_session ~= nil and cur.session_id ~= cur_session then
    on_session_id(cur.session_id)
  elseif cur_session == nil then
    cur_session = cur.session_id
  end

  -- <CR> with enter_submit = false: newline at the cursor, no submit.
  if key == "\n" and not ctrl and state.mode == "insert" then
    local attempt = 1
    while attempt <= MAX_ATTEMPTS do
      local e = { start = cur.cursor, stop = cur.cursor, text = "\n", cursor = cur.cursor + 1 }
      local wok, _ = write_edit(e, cur.version, cur.session_id)
      if wok then
        last_known = {
          text = cur.text:sub(1, cur.cursor) .. "\n" .. cur.text:sub(cur.cursor + 1),
          cursor = e.cursor,
          version = cur.version,
        }
        sync_bindings()
        update_hint()
        permit:release()
        return
      end
      attempt = attempt + 1
      cur = read_input()
      if cur == nil then
        break
      end
      if cur.session_id ~= nil and cur_session ~= nil and cur.session_id ~= cur_session then
        on_session_id(cur.session_id)
      elseif cur_session == nil then
        cur_session = cur.session_id
      end
    end
    maki.ui.flash("vim-mode: input changed under me, key dropped")
    permit:release()
    return
  end

  -- normal-mode leader: one-key prefix; the next key runs a slash command.
  if cfg.normal_leader ~= nil and state.mode == "normal" and not ctrl then
    if leader_armed then
      leader_armed = false
      state.key_seq = {}
      if key == "escape" then
        vim_state.clear_count(state)
        sync_bindings()
        update_hint()
        permit:release()
        return
      end
      local cmd = leader_lookup(key, ctrl)
      if cmd ~= nil then
        local pok, ok, run_err = pcall(maki.api.run_command, cmd)
        if not pok then
          maki.ui.flash("vim-mode: leader command failed: " .. tostring(ok))
        elseif not ok then
          maki.ui.flash("vim-mode: leader command failed: " .. tostring(run_err))
        end
      else
        vim_state.clear_count(state)
        maki.ui.flash("vim-mode: undefined leader key")
      end
      sync_bindings()
      update_hint()
      permit:release()
      return
    elseif key == cfg.normal_leader then
      vim_state.clear_pending(state) -- fresh prefix: drop g/f/operator state
      vim_state.clear_count(state) -- counts never apply to leader sequences
      state.key_seq = {}
      leader_armed = true
      sync_bindings()
      update_hint()
      permit:release()
      return
    end
  end

  -- p/P with the system clipboard: prefer the clipboard, fall back silent.
  -- Only when the current register is mirror-eligible; non-mirrored
  -- writes (e.g. a local delete under clipboard = "yank") stay local.
  if (state.mode == "normal" or state.mode == "visual" or state.mode == "visual_line")
    and not ctrl and (key == "p" or key == "P")
    and should_prefetch(state.register) then
    local clip_text = clipboard_read_text()
    if clip_text ~= nil then
      state.register = { text = clip_text, linewise = false }
    end
  end

  local saved = vim_state.snapshot(state)
  local buf = { text = cur.text, cursor = cur.cursor }
  local ok, res = pcall(vim_handler.handle, state, buf, { key = key, ctrl = ctrl })
  if not ok then
    vim_state.restore(state, saved)
    maki.log.warn("vim-mode: " .. tostring(res))
    permit:release()
    return
  end
  if not res.handled then
    permit:release()
    return
  end

  -- write with retries: on any refusal, re-read and re-run the core from
  -- the pre-key state (proves the retry path against racing typists).
  local attempt = 1
  local success = false
  while attempt <= MAX_ATTEMPTS do
    if attempt > 1 then
      vim_state.restore(state, saved)
      cur = read_input()
      if cur == nil then
        break
      end
      if cur.session_id ~= nil and cur_session ~= nil and cur.session_id ~= cur_session then
        on_session_id(cur.session_id)
      end
      buf = { text = cur.text, cursor = cur.cursor }
      local ok2, res2 = pcall(vim_handler.handle, state, buf, { key = key, ctrl = ctrl })
      if not ok2 then
        vim_state.restore(state, saved)
        maki.log.warn("vim-mode: " .. tostring(res2))
        break
      end
      if not res2.handled then
        break
      end
      res = res2
    end
    local writes = build_writes(buf, res, cur.cursor)
    local stale = false
    for i, e in ipairs(writes) do
      if i > 1 then
        local fresh = read_input()
        if fresh == nil then
          stale = true
          break
        end
        cur = fresh
      end
      local wok, _ = write_edit(e, cur.version, cur.session_id)
      if not wok then
        stale = true
        break
      end
    end
    if not stale then
      success = true
      break
    end
    attempt = attempt + 1
  end

  if not success then
    vim_state.restore(state, saved)
    maki.ui.flash("vim-mode: input changed under me, key dropped")
    permit:release()
    return
  end

  last_known = { text = buf.text, cursor = buf.cursor, version = cur.version }

  -- mirror the unnamed register to the system clipboard (fire-and-forget).
  if clipboard_on() and state.register ~= nil then
    local before_text = saved.register ~= nil and saved.register.text or nil
    if state.register.text ~= before_text then
      if should_mirror(state.register.kind) then
        clipboard_write_text(state.register.text)
      end
    end
  end

  -- host intents (run after the text writes landed)
  if res.jump ~= nil and #buf.text == 0 then
    do_jump(res.jump)
  end
  if res.scroll ~= nil then
    do_scroll(res.scroll)
  end
  if res.flash ~= nil then
    maki.ui.flash(res.flash)
  end

  sync_bindings()
  update_hint()
  permit:release()
end

for _, b in ipairs(FULL_KEYS) do
  local key, ctrl = b.key, b.ctrl
  handlers[b.notation] = function()
    on_key(key, ctrl)
  end
end
for _, b in ipairs(MINIMAL_KEYS) do
  if handlers[b.notation] == nil then
    local key, ctrl = b.key, b.ctrl
    handlers[b.notation] = function()
      on_key(key, ctrl)
    end
  end
end
do
  local key, ctrl = CR_BIND.key, CR_BIND.ctrl
  handlers[CR_BIND.notation] = function()
    on_key(key, ctrl)
  end
end

-- ---------------------------------------------------------------------------
-- toggle (/vim command + <M-v> binding; both sync, never park)
-- ---------------------------------------------------------------------------

local function set_enabled(on)
  enabled = on
  vim_state.reset(state)
  state.key_seq = {}
  leader_armed = false
  esc_prev = nil
  sync_bindings()
  update_hint()
  if on then
    maki.ui.flash("vim-mode on (-- INSERT --)")
  else
    maki.ui.flash("vim-mode off")
  end
end

local function toggle()
  set_enabled(not enabled)
end

handlers[TOGGLE_KEY] = function()
  toggle()
end

maki.api.register_command({
  name = "/vim",
  description = "Toggle vim-mode for the prompt (normal/insert/replace). <M-v> also toggles.",
  handler = function()
    toggle()
  end,
})

-- ---------------------------------------------------------------------------
-- autocmds: external input tracking, per-session reset
-- ---------------------------------------------------------------------------

maki.api.create_autocmd("InputChanged", {
  callback = function(ev)
    local d = ev and ev.data
    if type(d) ~= "table" then
      return
    end
    if d.source == PLUGIN_NAME then
      return -- echo of our own input_edit; last_known was set at write time
    end
    if type(d.text) ~= "string" then
      return
    end
    if d.session_id ~= nil then
      if cur_session == nil then
        cur_session = d.session_id
      elseif d.session_id ~= cur_session then
        on_session_id(d.session_id)
        last_known = { text = d.text, cursor = tonumber(d.cursor) or 0, version = d.version }
        return
      end
    end
    if not enabled then
      esc_prev = nil
    elseif cfg.escape_sequence ~= nil and clock_fn ~= nil and state.mode == "insert" then
      local at_end = (tonumber(d.cursor) or 0) == #d.text
        and (tonumber(last_known.cursor) or 0) == #(last_known.text or "")
      local added = single_appended_char(last_known.text or "", d.text)
      if added ~= nil and at_end then
        local now = clock_fn()
        local seq = cfg.escape_sequence
        if esc_prev ~= nil
          and (now - esc_prev.t) * 1000 <= cfg.escape_timeout_ms
          and esc_prev.char .. added == seq
          and d.text:sub(-#seq) == seq then
          esc_prev = nil
          -- two consecutive single-char appends completed the sequence at
          -- end-of-text: delete both chars and run a real escape through
          -- the core so undo/repeat bookkeeping matches.
          local stripped = d.text:sub(1, #d.text - #seq)
          local buf = { text = stripped, cursor = #stripped }
          local saved = vim_state.snapshot(state)
          local ok, res = pcall(vim_handler.handle, state, buf, { key = "escape", ctrl = false })
          if ok and res.handled then
            local wok, _ = write_edit(
              { start = 0, stop = #d.text, text = buf.text, cursor = buf.cursor },
              d.version,
              d.session_id
            )
            if wok then
              local fresh = read_input()
              if fresh ~= nil and fresh.text == buf.text then
                last_known = { text = fresh.text, cursor = fresh.cursor, version = fresh.version }
              else
                last_known = { text = buf.text, cursor = buf.cursor, version = d.version }
              end
              sync_bindings()
              update_hint()
              return
            end
          end
          vim_state.restore(state, saved)
          last_known = { text = d.text, cursor = tonumber(d.cursor) or 0, version = d.version }
          return
        end
        esc_prev = { char = added, t = now }
      else
        esc_prev = nil
      end
    elseif state.mode ~= "insert" then
      esc_prev = nil
    end
    if state.mode == "replace" and last_known.text ~= nil and d.text ~= last_known.text then
      -- native typing (e.g. Enter) inside replace mode: record for repeat
      vim_handler.note_external_insert(state, last_known.text, d.text)
    end
    if (state.mode == "normal" or state.mode == "visual" or state.mode == "visual_line")
      and last_known.version ~= nil and d.text ~= last_known.text then
      -- external write while in normal/visual mode (e.g. bracketed paste,
      -- which no binding can intercept): make it a self-contained undo unit
      -- so `u` reverts it instead of losing history coherence.
      vim_state.push(
        state,
        { text = last_known.text, cursor = last_known.cursor },
        { text = d.text, cursor = tonumber(d.cursor) or 0 }
      )
      if state.mode == "visual" or state.mode == "visual_line" then
        vim_state.set_mode(state, "normal")
        sync_bindings()
        update_hint()
      end
    end
    last_known = { text = d.text, cursor = tonumber(d.cursor) or 0, version = d.version }
  end,
})

local function reset_for_fresh_prompt(ev)
  local d = ev and ev.data
  local sid = d and d.session_id or nil
  if sid ~= nil then
    on_session_id(sid)
  else
    vim_state.reset_history(state)
    vim_state.set_mode(state, fresh_mode())
    state.key_seq = {}
    leader_armed = false
    esc_prev = nil
    sync_bindings()
    update_hint()
  end
  last_known = { text = "", cursor = 0, version = nil }
end

maki.api.create_autocmd("TurnStart", { callback = reset_for_fresh_prompt })
maki.api.create_autocmd("SessionFocusChanged", { callback = reset_for_fresh_prompt })
maki.api.create_autocmd("SessionReset", { callback = reset_for_fresh_prompt })

-- ---------------------------------------------------------------------------
-- init: start in insert mode (upstream default) with the minimal set bound
-- ---------------------------------------------------------------------------

sync_bindings()
update_hint()

-- ---------------------------------------------------------------------------
-- setup(opts): module-level options table (this package configures itself
-- through setup() instead of register_options). Every field is optional;
-- without setup() all defaults preserve current behavior. The maki.pack.add
-- custom loader in the user config calls require("vim-mode").setup(config).
-- Returns M so require("vim-mode").setup({...}) works in one line.
-- ---------------------------------------------------------------------------

function M.setup(opts)
  if type(opts) ~= "table" then
    return M
  end
  if opts.escape_sequence ~= nil then
    if type(opts.escape_sequence) == "string" and #opts.escape_sequence == 2 then
      if clock_fn ~= nil then
        cfg.escape_sequence = opts.escape_sequence
      else
        maki.log.debug("vim-mode: no os clock, escape_sequence disabled")
      end
    else
      maki.log.debug("vim-mode: escape_sequence must be a 2-byte string")
    end
  end
  if type(opts.escape_timeout_ms) == "number" and opts.escape_timeout_ms > 0 then
    cfg.escape_timeout_ms = opts.escape_timeout_ms
  end
  if type(opts.langmap) == "table" then
    cfg.langmap = opts.langmap
  end
  if opts.normal_leader ~= nil then
    local leader = normalize_leader(opts.normal_leader)
    if leader ~= nil then
      cfg.normal_leader = leader
    else
      maki.log.debug("vim-mode: ignoring bad normal_leader")
    end
  end
  if type(opts.normal_keybinds) == "table" then
    cfg.normal_keybinds = opts.normal_keybinds
  end
  if type(opts.enter_submit) == "boolean" then
    cfg.enter_submit = opts.enter_submit
  end
  if type(opts.insert_after_submit) == "boolean" then
    cfg.insert_after_submit = opts.insert_after_submit
  end
  if type(opts.system_clipboard_register) == "boolean" then
    cfg.system_clipboard_register = opts.system_clipboard_register
  end
  if type(opts.clipboard) == "string" then
    if opts.clipboard == "all" or opts.clipboard == "yank" or opts.clipboard == "never" then
      cfg.clipboard = opts.clipboard
    else
      maki.log.debug("vim-mode: ignoring bad clipboard value " .. opts.clipboard)
    end
  end
  if type(opts.mode_styles) == "table" then
    cfg.mode_styles = opts.mode_styles
  end
  esc_prev = nil
  leader_armed = false
  sync_bindings()
  update_hint()
  return M
end

return M
