# maki-vim-mode

Prompt-only vim mode for the maki TUI: normal/insert/replace/visual modes,
motions, operators, text objects, registers, undo/redo, dot-repeat, and a
per-mode status-hint indicator. Starts in insert mode, matching upstream's
default.

Ported to maki's Lua plugin API from
[opencode-vim-plugin](https://github.com/leohenon/opencode-vim-plugin)
(MIT © opencode, see [LICENSE](./LICENSE)).

Visual mode is emulated: maki exposes no selection/highlight API, so the
anchor lives in Lua and the range shows in the hint (`VISUAL 3c`,
`V-LINE 2L`, `-` prefix when extending backwards). No highlight and no
block cursor (no cursor-style API on the host).

## Install

Declare the package in your global `init.lua` (normally
`~/.config/maki/init.lua`), per
[maki's package docs](https://maki.sh/docs/packages/#install-from-git):

```lua
maki.pack.add({
  "https://github.com/MrBanh/maki-vim-mode",
})
```

Pin a release instead of tracking the default branch:

```lua
maki.pack.add({
  {
    src = "https://github.com/MrBanh/maki-vim-mode",
    version = "v0.1.0",
  },
})
```

On first start maki shows one install prompt, then records the commit in
`pack-lock.json` in your config directory — commit that file to pin every
machine to the same revision. A recorded lockfile entry wins over
`version`; to move, delete the package's lockfile entry and restart maki.

### Install with configuration

Pass options through `data` with a custom `load` function (it runs as the
package owner, so `require` resolves inside the checkout):

```lua
maki.pack.add({
  {
    src = "https://github.com/MrBanh/maki-vim-mode",
    version = "v0.1.0",
    data = {
      module = "vim-mode",
      config = {
        clipboard = "yank",
      },
    },
  },
}, {
  load = function(package)
    require(package.spec.data.module).setup(package.spec.data.config)
  end,
})
```

The package requests `run` + `fs_read` (clipboard tool probing and
`jobstart`/`jobwait`, only used when `clipboard` is `"all"` or `"yank"`).
Maki asks about these in a separate permissions prompt on first install.

Update later with:

```
/packupdate maki-vim-mode
```

## Configuration

Every field is optional; without `setup()` all defaults hold. Defaults:

```lua
{
  escape_sequence = nil,      -- e.g. "jk": two-key escape from insert (exactly 2 bytes)
  escape_timeout_ms = 750,    -- max gap (ms) between the two keys
  langmap = {},               -- pressed key -> matched identity, e.g. { H = "^", L = "$" }
  normal_leader = nil,        -- one-key leader prefix, e.g. "space" / "<Space>"
  normal_keybinds = {},       -- e.g. { ["<leader>s"] = "/sessions" } (bare "s" also ok)
  enter_submit = true,        -- false: <CR> in insert inserts a newline
  insert_after_submit = true, -- false: fresh prompts keep normal mode
  clipboard = "never",        -- "all" | "yank" | "never" (see below)
  mode_styles = nil,          -- nil = built-ins; else per-mode theme style names
}
```

| Option | Meaning |
|---|---|
| `escape_sequence` | Two-key escape from insert (e.g. `"jk"`), detected via `InputChanged`. Must be exactly 2 bytes. |
| `escape_timeout_ms` | Max gap between the two keys. |
| `langmap` | Remap pressed keys before matching, e.g. `{ H = "^", L = "$" }`. |
| `normal_leader` | One-key prefix in normal mode (`"space"`, `"<Space>"`, or any single key). The next key runs a slash command. Counts never apply to leader sequences. |
| `normal_keybinds` | Map of `"<leader>x"` (or bare `"x"`) to slash commands. |
| `enter_submit` | `false` binds `<CR>` in insert to insert a newline instead of submitting. |
| `insert_after_submit` | `false` keeps normal mode on fresh prompts instead of resetting to insert. |
| `clipboard` | Which unnamed writes mirror to the system clipboard (and seed `p`/`P` from it): `"all"` mirrors everything, `"yank"` mirrors yanks only, `"never"` keeps writes internal. `system_clipboard_register = true` is still accepted as the legacy spelling of `"all"`. Probes `pbcopy`/`powershell`/`wl-copy`/`xclip`/`xsel`. |
| `mode_styles` | Theme style name per mode, e.g. `{ normal = "warning" }`. Keys: `normal`, `insert`, `replace`, `visual`, `visual_line`. |

Built-in mode colors (`<mode> <selection-size>` in the status hint):

| Mode | Style | Looks like |
|---|---|---|
| normal | `success` | green |
| insert | `warning` | yellow |
| replace | `accent` | orange |
| visual / visual_line | `error` | red |

The selection size (`3c`, `2L`, `-9c` backwards) always matches its mode
color. Unknown style names fall back to the default style, so any theme
stays readable.

## License

See [LICENSE](./LICENSE).
