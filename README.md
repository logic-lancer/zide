# zide

A fast, tiny, modal TUI code editor written in [Zig](https://ziglang.org) — vim keybindings, tree-sitter syntax highlighting, and a sub-1 MB static binary.

Built on [libvaxis](https://github.com/rockorager/libvaxis) (vxfw widget framework) and [tree-sitter](https://tree-sitter.github.io/tree-sitter/), taking cues from [Neovim](https://neovim.io)/[NvChad](https://nvchad.com) for UX and [Flow Control](https://github.com/neurocyte/flow) for architecture.

## Features

- **Vim modal editing** — `NORMAL` / `INSERT` / `COMMAND` modes
  - Motions: `h j k l`, `w b e`, `0 ^ $`, `gg G`, `Ctrl-d`/`Ctrl-u`
  - Edits: `x`, `dd`, `i a A I o O`
  - Ex commands: `:w` `:q` `:q!` `:wq` `:x` `:<line>`
- **Incremental tree-sitter highlighting** — every keystroke goes through
  `ts_tree_edit` + incremental reparse, Neovim-style; no full rescans while typing
- **One Dark theme**, truecolor, mode-colored statusline, block/beam cursor per mode
- **UTF-8 aware** — cursor movement stays on codepoint boundaries, grapheme-width rendering
- **Single static binary** — grammar and queries compiled in, zero runtime files,
  **< 1 MB** with `ReleaseSmall`
- Kitty keyboard protocol *and* legacy terminal input

## Building

Requires **Zig 0.14.1** (dependencies are pinned for it — see `build.zig.zon`).

```sh
zig build                          # debug build
zig build -Doptimize=ReleaseSmall  # ~1 MB stripped binary
zig build run -- path/to/file.zig
```

## Keys

| Mode | Key | Action |
|---|---|---|
| normal | `h j k l` / arrows | move |
| normal | `w` / `b` / `e` | word forward / back / end |
| normal | `0` / `^` / `$` | line start / first non-blank / end |
| normal | `gg` / `G` / `:42` | first line / last line / line 42 |
| normal | `Ctrl-d` / `Ctrl-u` | half page down / up |
| normal | `x` / `dd` | delete char / line |
| normal | `i a A I o O` | enter insert mode |
| normal | `:` | command mode |
| insert | `Esc` | back to normal |
| command | `w`, `q`, `q!`, `wq`, `x` | write / quit |

## Architecture

```
src/
├── main.zig     entry: load file, wire Highlighter + Editor into vxfw App
├── editor.zig   modal Editor widget: buffer, cursor, motions, edits, statusline
├── syntax.zig   Highlighter: tree-sitter parse → per-byte style table, theme
└── queries/     vendored tree-sitter highlight queries (nvim-treesitter capture names)
```

The buffer is a plain byte array with a rebuilt line table; every edit produces a
`TSInputEdit` so the parser reuses the previous syntax tree. Highlight captures
(`@keyword`, `@function.builtin`, …) map to theme colors by name, with
Neovim-style base-name fallback.

## Roadmap

- [ ] undo/redo, yank/paste, counts, `/` search, visual mode
- [ ] theme system with `:theme` live switching
- [ ] multiple buffers + tabline
- [ ] file tree, fuzzy finder, toggleable terminal
- [ ] more grammars (C, Markdown, …) and query predicate evaluation
- [ ] LSP client

## License

MIT
