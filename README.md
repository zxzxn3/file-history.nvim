# file-history.nvim

Browse a file's Git versions in the focused Neovim window, without replacing its working buffer.

Requires Neovim 0.12+, Git, and Gitsigns with the documented `attach(ctx)` and `b:gitsigns_status_dict` APIs. Configure Gitsigns before this plugin. No default keymaps, installation hooks, or background processes.

```lua
vim.pack.add({ 'https://github.com/lewis6991/gitsigns.nvim', 'file:///absolute/path/to/file-history.nvim' })
require('gitsigns').setup {}
require('file-history').setup {}
vim.keymap.set('n', '[v', function() require('file-history').step(1) end)
vim.keymap.set('n', ']v', function() require('file-history').step(-1) end)
vim.keymap.set('n', '<leader>hl', function() require('file-history').log() end)
vim.keymap.set('n', '<leader>hd', function() require('file-history').diff() end)
```

For lazy.nvim, use `{ dir = '/absolute/path/to/file-history.nvim', dependencies = { { 'lewis6991/gitsigns.nvim', opts = {} } }, config = function() require('file-history').setup {} end }`.

## Options

`setup()` accepts `max_width=100`, `max_height=30`, `show_stat=true`, and `history_signs=true`. Repository identity comes from Gitsigns' public buffer status. For bare dotfiles repositories, configure Gitsigns/baredot normally; no repository list or context callback is needed in this plugin. Git subprocesses clear inherited `GIT_*` variables and use the attached repository explicitly. If Gitsigns has not attached yet, navigation asks you to wait.

## Navigation and diff

Commands: `:FileHistoryOlder`, `:FileHistoryNewer`, `:FileHistoryDiff`, `:FileHistoryLog`. They mirror the Lua functions above.

- Navigation order: working buffer → newest file commit → older file commits.
- INDEX navigation is kept separately on `experiment/index`; it is not part of the current master implementation.
- `diff()` delegates to Gitsigns' `diffthis('HEAD')`, opening HEAD on the left and retaining the invoking view on the right. `[v` / `]v` can navigate either side independently. Close either window with `:q`, or use `:diffoff!` to stop diff mode. Closing the worktree side leaves a clearly labeled read-only revision. As with Gitsigns, invoking diff again while already in diff mode does not create another split.
- Historical signs compare against the next older file commit. Signs are suppressed while presenting a revision in diff mode.
- `log()` shows metadata, message and colored diffstat; Index has no commit message. Working files use HEAD.

`label(buffer)` returns a display-only `[revision] filename` label, or nil. Use it in your statusline/tabline formatter; the plugin does not modify those plugins. Read-only revisions cannot be written, but consumers should also disable their own staging/reset shortcuts for buffers with `b:file_history` metadata.

Historical buffers are wiped when hidden. Only commits touching the current path are navigated, deletion commits are skipped, and renames are not followed. Repositories must have a HEAD commit; unborn repositories and binary previews are outside the supported scope. `diff()` requires the file to exist in HEAD. Sessions cannot serialize their contents: discard empty `history://` placeholders after session restore, or navigate again to rehydrate them. Async results are ignored after the requesting window changes file/version. Rapid steps invalidate pending requests rather than accumulate a requested step count.

The independent implementation is preserved on `experiment/standalone`; INDEX navigation is preserved on `experiment/index`. These branches are experiments, not runtime fallbacks.

The implementation was extracted from a personal configuration. The user reports that the independent tester found no major defects before these branch separations. The Gitsigns dependency refactor requires a new targeted runtime check.
