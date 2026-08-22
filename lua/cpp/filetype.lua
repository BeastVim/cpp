-- Extensionless C++ header detection.
--
-- Neovim resolves `.h/.hh/.hpp/.cc/...` to `cpp` from the extension alone, but
-- C++ libraries also ship headers with NO extension at all — the standard
-- library (`<vector>`, `<memory>`) and Eigen (`Eigen/Core`, `Eigen/Dense`, 28
-- such files in the wqmeta tree) being the two that matter here.
--
-- Neovim handles the stdlib case by matching the Emacs `-*- C++ -*-` mode line
-- those headers carry (see the `['%-%*%-.*[cC]%+%+.*%-%*%-']` content pattern
-- in $VIMRUNTIME/lua/vim/filetype/detect.lua). Eigen's headers have no such
-- marker, so they fall through to the generic content sniffer and land on
-- `conf`, `text`, or nothing — meaning no highlighting, no clangd, and (since
-- this plugin lazy-loads on filetype) no chance for it to load at all.
--
-- So we sniff the content ourselves. This module is required from the spec's
-- `init` (which runs eagerly at startup), NOT from `setup()` — the rule has to
-- be installed before the first file is opened, and it is what produces the
-- `cpp` filetype that triggers the rest of the plugin to load.

local M = {}

-- Lines to sample. Eigen module headers are short; the license banner on the
-- longest of them clears 40 lines, so 64 gives the signals room to appear
-- without reading whole translation units.
local SAMPLE_LINES = 64

--- Does this buffer look like C++ source?
---
--- Two tiers, both requiring a preprocessor signal — prose and config files
--- never have one, which is what keeps the false-positive rate at zero:
---   * 2+ `#include` lines. Enough on its own: an include list that long is
---     not something a config file produces. (`Eigen/Dense` is exactly this —
---     seven includes and nothing else.)
---   * 1+ `#include`/include-guard, corroborated by a C++-ish line (template,
---     namespace, `::`, or a `//` / `/*` comment).
---@param bufnr integer
---@return boolean
local function looks_like_cpp(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, SAMPLE_LINES, false)

  -- A shebang means some other language owns this file. Bail before scoring:
  -- `vim.filetype.add` patterns are consulted *before* Neovim's own shebang
  -- detection, so without this a Perl or PHP script whose body happens to use
  -- `::` and `#`-comments would be claimed as C++.
  if (lines[1] or ""):find("^#!") then
    return false
  end

  local includes, guards, corroborating = 0, 0, 0
  for _, line in ipairs(lines) do
    if line:find("^%s*#%s*include%s*[<\"]") then
      includes = includes + 1
    end
    if line:find("^%s*#%s*pragma%s+once") or line:find("^%s*#%s*ifndef%s+[%w_]") or line:find("^%s*#%s*define%s+[%w_]") then
      guards = guards + 1
    end
    if
      line:find("^%s*template%s*<")
      or line:find("^%s*namespace%s+[%w_]")
      or line:find("^%s*//")
      or line:find("^%s*/%*")
      or line:find("::")
    then
      corroborating = corroborating + 1
    end
  end

  if includes >= 2 then
    return true
  end
  return (includes + guards) > 0 and corroborating > 0
end

M._installed = false

--- Install the detection rule. Idempotent.
function M.setup()
  if M._installed then
    return
  end
  M._installed = true

  vim.filetype.add({
    pattern = {
      -- `priority = -math.huge` puts this last among pattern rules, so
      -- every filename- and extension-based rule Neovim (or the user)
      -- already has keeps winning. This only ever fills a gap.
      [".*"] = {
        priority = -math.huge,
        ---@param path string
        ---@param bufnr integer
        ---@return string?
        function(path, bufnr)
          -- Extension-bearing files are already handled; only files
          -- with no `.` in their name reach the scoring below.
          if vim.fn.fnamemodify(path, ":t"):find("%.", 1, true) then
            return nil
          end
          if looks_like_cpp(bufnr) then
            return "cpp"
          end
          return nil
        end,
      },
    },
  })
end

return M
