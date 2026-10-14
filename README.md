# file-history.nvim

Browse a file's Git versions in the focused Neovim window, without replacing its working buffer.

Requires Neovim 0.12+ and Git. Gitsigns is optional for historical change markers; its documented `attach(ctx)` API must be available. No default keymaps, installation hooks, or background processes.

```lua
vim.pack.add({ 'file:///absolute/path/to/file-history.nvim' })
require('file-history').setup {}
vim.keymap.set('n', '[v', function() require('file-history').step(1) end)
vim.keymap.set('n', ']v', function() require('file-history').step(-1) end)
vim.keymap.set('n', '<leader>hl', function() require('file-history').log() end)
vim.keymap.set('n', '<leader>hd', function() require('file-history').diff() end)
```

For lazy.nvim, use `{ dir = '/absolute/path/to/file-history.nvim', config = function() require('file-history').setup {} end }`.

## Options

`setup()` accepts `max_width=100`, `max_height=30`, `show_stat=true`, `history_signs=true`, `index=true`, and an optional `context(buffer)` callback returning `{gitdir, root, path?}`. Ordinary repositories are discovered first with Git; the callback supplies context for bare dotfiles repositories. `path` is relative to `root` and is derived from the file name when omitted. Git subprocesses clear inherited `GIT_*` variables and use the resolved repository explicitly.

## Navigation and diff

Commands: `:FileHistoryOlder`, `:FileHistoryNewer`, `:FileHistoryDiff`, `:FileHistoryLog`. They mirror the Lua functions above.

- Default order: working buffer → Index (if different from HEAD) → newest file commit → older file commits.
- Identical Index/HEAD contents produce a single commit node. `index=false` disables Index navigation.
- Index views are immutable stage-0 snapshots and show `[Index]` in `label()`. Navigation rereads the index; staging or unstaging changes the available nodes on the next step. Unmerged stages and missing/deleted Index entries are not exposed as separate nodes.
- `diff()` opens HEAD on the left and retains the invoking view on the right. `[v` / `]v` can navigate either side independently. Close either window with `:q`, or use `:diffoff!` to stop diff mode. Closing the worktree side leaves a clearly labeled read-only revision.
- Historical signs compare against the next older file commit; Index signs compare against the newest file commit. Signs are suppressed while presenting a revision in diff mode.
- `log()` shows metadata, message and colored diffstat; Index has no commit message. Working files use HEAD.

`label(buffer)` returns a display-only `[revision] filename` label, or nil. Use it in your statusline/tabline formatter; the plugin does not modify those plugins. Read-only revisions cannot be written, but consumers should also disable their own staging/reset shortcuts for buffers with `b:file_history` metadata.

Historical buffers are wiped when hidden. Only commits touching the current path are navigated, deletion commits are skipped, and renames are not followed. Repositories must have a HEAD commit; unborn repositories and binary previews are outside the supported scope. `diff()` requires the file to exist in HEAD. Sessions cannot serialize their contents: discard empty `history://` placeholders after session restore, or navigate again to rehydrate them. Async results are ignored after the requesting window changes file/version. Rapid steps invalidate pending requests rather than accumulate a requested step count.

The implementation was extracted from a personal configuration. Independent validation of the extracted plugin is pending.
