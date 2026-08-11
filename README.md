# zide

**A modal terminal code editor written in [Zig](https://ziglang.org)** — vim keybindings,
incremental [tree-sitter](https://tree-sitter.github.io/tree-sitter/) syntax highlighting,
LSP, git signs, fuzzy finders, and an integrated terminal, in a single static binary with
no runtime dependencies.

If you like Neovim + NvChad but want one file you can `scp` to a box, that's zide.

Built on [libvaxis](https://github.com/rockorager/libvaxis) (vxfw widget framework),
taking cues from [Neovim](https://neovim.io)/[NvChad](https://nvchad.com) for UX and
[Flow Control](https://github.com/neurocyte/flow) for architecture.

<!-- TODO: screenshot / demo GIF goes here — biggest single conversion win on the repo page -->

## Features

**Editing** — vim modal editing with `NORMAL` / `INSERT` / `VISUAL` / `COMMAND` modes

- Motions: `h j k l`, `w b e`, `0 ^ $`, `gg G`, `H M L`, `f F t T`, `Ctrl-d`/`Ctrl-u`,
  `Ctrl-e`/`Ctrl-y`, `zz zt zb`, marks, jumplist (`Ctrl-o`/`Ctrl-i`)
- Operators + text objects: `d c y` with `iw i( a"` …, `dd cc yy`, counts (`3dd`, `5j`)
- Surround: `cs" '`, `ds(`, `S(` in visual mode
- Comments: `gcc`, `gcj`, `gcip`, `gc` over a visual selection, `Space /`
- Registers, macros (`q{a-z}` record, `@{a-z}` replay), undo/redo, `/` search with `n`/`N`
- Visual and visual-line select, yank/delete/put, system clipboard (`Ctrl-Shift-c`)

**Code intelligence**

- **Incremental tree-sitter highlighting** — every keystroke goes through `ts_tree_edit`
  + incremental reparse, Neovim-style; no full rescans while typing
- **LSP client** (zls): go-to-definition, references, hover, rename, completion,
  signature help, inlay hints, live diagnostics with `]d`/`[d` navigation
- Document symbols, symbol breadcrumbs, `:Format` / format-on-save via `zig fmt`

**Workflow**

- **Telescope-style pickers** — find files, live grep, recent files, buffer lines,
  document symbols, quickfix, buffers, themes
- **File tree** sidebar with devicons (`Ctrl-n`, `Space e`)
- **Git integration** — hunk signs, `]c`/`[c` navigation, stage/reset/preview hunk, blame line
- **Integrated terminal** — horizontal, vertical, and floating splits (`Alt-h` / `Alt-v` / `Alt-i`)
- **Multiple buffers** with a tabline, plus a start dashboard and session restore
- **Which-key** popup for pending prefixes and a built-in cheatsheet (`Space c h`)
- **9 themes** — onedark, gruvbox, tokyonight, catppuccin, nord, white, gruvbox-light,
  solarized-light, latte — switched live with `:theme` / `:themes`

**Terminal behaviour**

- UTF-8 aware — cursor stays on codepoint boundaries, grapheme-width rendering
- Truecolor, mode-colored statusline, block/beam cursor per mode
- Kitty keyboard protocol *and* legacy terminal input
- Single static binary — grammar and queries compiled in, zero runtime files

## Building

Requires **Zig 0.14.1** (dependencies are pinned for it — see `build.zig.zon`).

```sh
zig build                          # debug build
zig build -Doptimize=ReleaseSmall  # small stripped binary
zig build run -- path/to/file.zig
```

## Keys

Press `Space c h` inside the editor for the full cheatsheet. The common ones:

| Key | Action |
|---|---|
| `Space f f` / `Space f w` | find files / live grep |
| `Space f o` / `Space f z` | recent files / buffer lines |
| `Space f s` / `Space q` | document symbols / quickfix |
| `Space b` / `Space t` / `Space x` | buffer picker / theme picker / close buffer |
| `Space e` / `Ctrl-n` | focus / toggle file tree |
| `Space g s` `g p` `g r` `g b` | stage / preview / reset hunk, blame line |
| `Space c r` / `Space i` | rename symbol / toggle inlay hints |
| `gd` / `gr` / `K` | goto definition / references / hover |
| `]c` `[c` / `]d` `[d` / `]q` `[q` | git hunk / diagnostic / quickfix nav |
| `Alt-h` / `Alt-v` / `Alt-i` | horizontal / vertical / floating terminal |
| `Tab` / `Shift-Tab` | next / previous buffer |
| `Ctrl-s` / `u` / `Ctrl-r` | save / undo / redo |

Ex commands: `:w` `:q` `:q!` `:wq` `:x` `:qa` `:e` `:bn` `:bp` `:bd` `:ls` `:<line>`
`:theme` `:themes` `:noh` `:Format` `:AutoFormat` `:InlayHints` `:LspRestart`

## Architecture

```
src/
├── main.zig     entry: load file, wire Editor into the vxfw App loop
├── editor.zig   modal Editor widget: modes, motions, operators, pickers, statusline
├── buffer.zig   text model: byte array + line table + per-buffer Highlighter
├── syntax.zig   Highlighter: tree-sitter parse → per-byte style table
├── theme.zig    palettes + capture-name → color mapping
├── tree.zig     file tree sidebar
├── lsp.zig      JSON-RPC client for zls
├── term.zig     integrated terminal splits
└── queries/     vendored tree-sitter highlight queries (nvim-treesitter capture names)
```

The buffer is a plain byte array with a rebuilt line table; every edit produces a
`TSInputEdit` so the parser reuses the previous syntax tree. Highlight captures
(`@keyword`, `@function.builtin`, …) map to theme colors by name, with
Neovim-style base-name fallback.

## Roadmap

- [x] undo/redo, yank/paste, counts, `/` search, visual mode
- [x] theme system with `:theme` live switching
- [x] multiple buffers + tabline
- [x] file tree, fuzzy finder, toggleable terminal
- [x] LSP client
- [ ] more grammars (C, Markdown, …) — only Zig is vendored today
- [ ] tree-sitter query predicate evaluation (`#eq?` / `#match?`)
- [ ] language servers beyond zls, configured per filetype
- [ ] editor window splits (terminal splits exist; buffer splits don't)
- [ ] config file — everything is compile-time defaults today

## License

MIT
