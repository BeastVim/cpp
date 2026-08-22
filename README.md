# cpp

C/C++ language support for [BeastVim](https://github.com/loctvl842/BeastVim). Registers
the `clangd` language server via `Lsp.register`, ensures the `c`/`cpp` treesitter parsers
via `Treesitter.ensure_parser`, and wires `clang-format` into conform.nvim for projects
that carry a `.clang-format`.

Not usable standalone — it calls `Lsp.register`, `Treesitter.ensure_parser`, and
`Mason.ensure_package`, provided globally by BeastVim's `beast.libs.lsp`,
`beast.libs.treesitter`, and `beast.libs.mason`.

## Install

```lua
{
  name = "cpp",
  src = gh("BeastVim/cpp"),
  lazy = { filetype = { "c", "cpp", "objc", "objcpp", "cuda" } },
  init = function() require("cpp.filetype").setup() end,
  config = function() require("cpp").setup() end,
}
```

`init` must be present. It installs the extensionless-header filetype rule at startup —
without it, `Eigen/Core` and friends never get the `cpp` filetype, so the `filetype`
lazy-trigger above never fires for them.

## Behaviour notes

**Binaries are system-first.** `clangd` and `clang-format` are used straight from `PATH`
when present, and only downloaded through Mason when missing. A toolchain's own clangd
knows the matching libstdc++ include paths; a generic LLVM build does not.

**Extensionless headers.** C++ ships headers with no extension — the standard library
(`<vector>`, `<memory>`) and Eigen (`Eigen/Core`, `Eigen/Dense`, …). Neovim catches the
stdlib case via the `-*- C++ -*-` mode line those files carry, but Eigen's have no such
marker and fall through to `conf`/`text`/nothing. `lua/cpp/filetype.lua` adds a
lowest-priority content sniffer that requires a preprocessor signal (`#include`, include
guard) plus corroboration, and skips anything with a shebang so other languages keep
their own detection.

**Formatting is opt-in per project.** `clang-format` runs only where a `.clang-format`
exists on the path to the buffer. Without one it would silently apply LLVM style and
rewrite files written to a different house style. Where no config is found the formatter
list is empty and conform's `lsp_format = "fallback"` lets clangd answer instead.

**`--header-insertion=never`.** Projects that resolve includes through `-I` flags in a
non-CMake build expose none of that to clangd, so inferred `#include` lines are wrong
more often than not.

## Keymaps

Bound buffer-locally on `LspAttach`:

| Key | Action |
| --- | --- |
| `K` | Hover |
| `<leader>rn` | Rename |
| `<leader>la` | Code action (n, v) |
| `<leader>lh` | Switch between source and header |

## Getting full cross-file analysis

clangd needs to know the compile flags. With CMake:

```sh
cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -B build
ln -s build/compile_commands.json .
```

For non-CMake builds, a `compile_flags.txt` at the project root with one flag per line is
enough:

```
-xc++
-std=c++17
-I.
-Iinclude
```

Without either, clangd still parses each file on its own — hover, completion, and
same-file navigation work — but reports `'foo.hh' file not found` for includes it cannot
resolve.
