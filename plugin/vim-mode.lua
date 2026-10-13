-- maki-vim-mode entry point (default load path).
--
-- Managed installs via maki.pack.add use the custom loader in the user
-- config instead of this file; the loader calls require("vim-mode")
-- .setup(config) with the data.config from the package spec. This entry
-- covers hand-installed copies (site/pack/<group>/start/maki-vim-mode),
-- which start with default options.
require("vim-mode").setup()
