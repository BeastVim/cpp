local M = {}

local FILETYPES = { "c", "cpp", "objc", "objcpp", "cuda" }

--- Resolve a binary, preferring one already on PATH. Returns nil when neither
--- the system nor the Mason copy is present.
---@param name string
---@return string?
local function resolve_bin(name)
  if vim.fn.executable(name) == 1 then
    return name
  end
  local mason_bin = Mason.bin(name)
  if vim.fn.executable(mason_bin) == 1 then
    return mason_bin
  end
  return nil
end

--- Run `callback` once `name` is available, installing it via Mason only if it
--- isn't already on PATH.
---
--- The Mason path exists to satisfy the contract in beast.libs.mason: a
--- vim.lsp client that fails to spawn once (ENOENT) is left permanently broken
--- by Neovim and never retries, so registration must not happen before the
--- binary exists. When the binary is already on PATH that proof is immediate,
--- and we skip the download entirely — a toolchain's own clangd knows its
--- matching libstdc++ include paths, which a generic LLVM build does not.
---@param name string
---@param mason_package string
---@param callback fun()
local function with_binary(name, mason_package, callback)
  if vim.fn.executable(name) == 1 then
    callback()
  else
    Mason.ensure_package({ mason_package }, callback)
  end
end

function M.setup()
  local missing = {}
  if not Lsp then
    table.insert(missing, "Lsp")
  end
  if not Treesitter then
    table.insert(missing, "Treesitter")
  end
  if not Mason then
    table.insert(missing, "Mason")
  end
  if #missing > 0 then
    vim.notify(
      "cpp requires BeastVim's global " .. table.concat(missing, ", ") .. " (this plugin only works in...",
      vim.log.levels.ERROR,
      { title = "cpp" }
    )
    return
  end

  -- Both grammars: cpp's highlights.scm carries `; inherits: c`, which the
  -- installer resolves on its own, but requesting `c` explicitly means plain
  -- C buffers work too rather than only C++ ones.
  Treesitter.ensure_parser("c")
  Treesitter.ensure_parser("cpp")

  -- Late safety net for the extensionless-header rule. `init` in the plugin
  -- spec installs it at startup; this covers a manual `require("cpp").setup()`
  -- where `init` never ran. Idempotent.
  require("cpp.filetype").setup()

  with_binary("clangd", "clangd", function()
    Lsp.register("clangd", {
      cmd = function(dispatchers)
        local cmd = resolve_bin("clangd") or "clangd"
        return vim.lsp.rpc.start({
          cmd,
          "--background-index",
          "--clang-tidy",
          -- Header resolution here comes from `-I` flags in a custom
          -- .make build, which clangd can't see. Letting it insert
          -- `#include` lines it inferred without that context
          -- produces paths that don't compile.
          "--header-insertion=never",
          "--completion-style=detailed",
          -- Takes a value ('=0'/'=1'), not a bare flag — passing it
          -- bare makes clangd exit with "requires a value!". Enabled
          -- is the default, so it's simply omitted.
        }, dispatchers)
      end,
      filetypes = FILETYPES,
      root_markers = {
        ".clangd",
        "compile_commands.json",
        "compile_flags.txt",
        ".clang-format",
        "CMakeLists.txt",
        "Makefile",
        ".git",
      },

      -- clangd defaults to UTF-8 offsets while Neovim assumes UTF-16; on
      -- any line with non-ASCII the two disagree and positions land in
      -- the wrong column. Advertise the extension, then adopt whatever
      -- the server picked in on_init.
      --
      -- Done via before_init rather than `capabilities` on purpose:
      -- Lsp.register only auto-fills capabilities and installs its
      -- late-contributor re-resolution hook when `capabilities = nil`,
      -- so setting that field directly would drop blink.cmp's
      -- contribution (added later, on InsertEnter). Our hook is chained
      -- after Lsp's, so params.capabilities is already resolved.
      before_init = function(params, conf)
        params.capabilities = vim.tbl_deep_extend("force", params.capabilities or {}, {
          offsetEncoding = { "utf-8", "utf-16" },
          textDocument = { completion = { editsNearCursor = true } },
        })
        conf.capabilities = params.capabilities
      end,
      on_init = function(client, init_result)
        if init_result.offsetEncoding then
          client.offset_encoding = init_result.offsetEncoding
        end
      end,
      keys = {
        { "K", vim.lsp.buf.hover, desc = "Hover", cond = "textDocument/hover" },
        { "<leader>rn", vim.lsp.buf.rename, desc = "Rename", cond = "textDocument/rename" },
        {
          "<Leader>la",
          vim.lsp.buf.code_action,
          mode = { "n", "v" },
          desc = "Code action",
          cond = "textDocument/codeAction",
        },
        {
          "<leader>lh",
          function()
            M.switch_source_header(vim.api.nvim_get_current_buf())
          end,
          desc = "Switch source/header",
          -- No `cond`: switchSourceHeader is a clangd extension, not
          -- a standard capability, so supports_method never sees it.
        },
      },
    })
  end)

  -- clang-format is wired in only for projects that actually carry a
  -- .clang-format (see pick_formatters) — but the formatter list is a
  -- function evaluated per buffer, so registering it here costs nothing for
  -- projects without one.
  with_binary("clang-format", "clang-format", function()
    local conform = require("conform")
    for _, ft in ipairs(FILETYPES) do
      conform.formatters_by_ft[ft] = M.pick_formatters
    end
  end)
end

-- Per-project-root formatter list cache, so repeated saves in the same project
-- don't re-walk the tree looking for a .clang-format every time.
local root_formatters_cache = {}

--- Formatters for a C/C++ buffer: clang-format only where the project has
--- committed to a style.
---
--- Without a .clang-format, clang-format silently falls back to LLVM style —
--- which for a codebase written to a different house style (and with no
--- committed config to compare against) rewrites whole files on save and
--- buries the actual change in noise. Returning `{}` leaves the buffer alone;
--- conform's `lsp_format = "fallback"` default then lets clangd's own
--- formatting answer if the server offers it.
---@param bufnr integer
---@return string[]
function M.pick_formatters(bufnr)
  local root = vim.fs.root(vim.api.nvim_buf_get_name(bufnr), ".clang-format")
  if not root then
    return {}
  end

  local formatters = root_formatters_cache[root]
  if not formatters then
    formatters = { "clang-format" }
    root_formatters_cache[root] = formatters
  end
  return formatters
end

--- Jump between a translation unit and its header via clangd's
--- `textDocument/switchSourceHeader` extension.
---@param bufnr integer
function M.switch_source_header(bufnr)
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })[1]
  if not client then
    vim.notify("clangd is not attached to this buffer", vim.log.levels.WARN, { title = "cpp" })
    return
  end

  local params = { uri = vim.uri_from_bufnr(bufnr) }
  client:request("textDocument/switchSourceHeader", params, function(err, result)
    if err then
      vim.notify("switchSourceHeader failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
      return
    end
    if not result or result == "" then
      vim.notify("No corresponding source/header found", vim.log.levels.INFO, { title = "cpp" })
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(vim.uri_to_fname(result)))
  end, bufnr)
end

return M
