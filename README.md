# maki-vim-mode

Prompt-only vim mode for the maki TUI.

Ported to maki's Lua plugin API from
[opencode-vim-plugin](https://github.com/leohenon/opencode-vim-plugin)
(MIT © opencode, see [LICENSE](./LICENSE)) — normal/insert/replace modes,
motions, operators, text objects, registers, undo/redo, dot-repeat, and a
status-hint indicator. Starts in insert mode, matching upstream's default.

## Install

Install as a maki package (e.g. via `maki.pack.add`), or copy
`plugin/vim-mode.lua` and `lua/vim-mode/` into your maki plugins directory.
