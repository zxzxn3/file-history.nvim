# file-history.nvim

Browse a file's Git versions in the focused Neovim window, without replacing its working buffer.

Requires Neovim 0.12+ and Git. Gitsigns is optional for historical change markers; its documented `attach(ctx)` API must be available. No default keymaps, installation hooks, or background processes.

```lua
vim.pack.add({ 'file:///absolute/path/to/file-history.nvim' })
require('file-history').setup {}
vim.keymap.set('n', '[v', function() require('file-history').step(1) end)
vim.keymap.set('n', ']v', function() require('file-history').step(-1) end)
vim.keymap.set('n', '<leader>hl', function() require('file-history').log() end)
```

For lazy.nvim, use `{ dir = '/absolute/path/to/file-history.nvim', config = function() require('file-history').setup {} end }`.

## Options

`setup()` accepts `max_width=100`, `max_height=30`, `show_stat=true`, `history_signs=true`, and an optional `context(buffer)` callback returning `{gitdir, root, path?}`. Ordinary repositories are discovered first with Git; the callback supplies context for bare dotfiles repositories. `path` is relative to `root` and is derived from the file name when omitted.

`label(buffer)` returns a display-only `[revision] filename` label, or nil. Use it in your statusline/tabline formatter; the plugin does not modify those plugins. Read-only revisions cannot be written, but consumers should also disable their own staging/reset shortcuts for buffers with `b:file_history` metadata.

Historical buffers are wiped when hidden. Only commits touching the current path are navigated, deletion commits are skipped, and renames are not followed. Sessions cannot serialize their contents: discard empty `history://` placeholders after session restore, or navigate again to rehydrate them. Async results are ignored after the requesting window changes file/version.

The implementation was extracted from a personal configuration. Independent validation of the extracted plugin is pending.
