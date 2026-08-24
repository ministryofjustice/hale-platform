-- neovim config for the wp-tools sidecar. Lives at $XDG_CONFIG_HOME/nvim,
-- which the image points at /scratch (uid 65532 cannot write to HOME).
--
-- Deliberately plugin-manager free: the only plugin is the colourscheme, baked
-- into /usr/share/nvim/site/pack/hale/start by the dockerfile.

vim.opt.number = true
vim.opt.cursorline = true
vim.opt.signcolumn = "yes"
vim.opt.scrolloff = 5
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.mouse = "a"

-- 24-bit colour. `docker exec`/`kubectl exec` do not forward COLORTERM, so the
-- usual truecolor probe fails inside the container and neovim would fall back
-- to 256 colours - which onedark renders badly. Skip only for terminals that
-- genuinely cannot do it.
local term = os.getenv("TERM") or ""
if term ~= "" and term ~= "dumb" and term ~= "linux" then
  vim.opt.termguicolors = true
end

-- onedark, matching the local setup. pcall so a missing/renamed theme leaves a
-- usable editor rather than an error on every launch.
if not pcall(vim.cmd.colorscheme, "onedark") then
  vim.cmd.colorscheme("habamax")
end
