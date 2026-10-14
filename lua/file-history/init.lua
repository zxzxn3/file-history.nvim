local M = {}
M.options = {
  max_width = 100, max_height = 30, -- Commit popup size limits, in cells.
  show_stat = true, -- Include changed files and insertion/deletion statistics.
  history_signs = true, -- Compare single-window historical files with their preceding version.
}
local gitsigns = require('gitsigns')
local tickets = {}
local function legacy_revision(name)
  local tail = name:match('^gitsigns://.-//(.+)$')
  if not tail then return end
  local revision, path = tail:match('^(:%d+):(.+)$')
  if not revision then revision, path = tail:match('^([^:]+):(.+)$') end
  return revision, path
end
local function environment()
  local env = vim.fn.environ()
  for key in pairs(env) do if key:match('^GIT_') then env[key] = nil end end
  return env
end
-- Let Gitsigns compare a read-only historical buffer with its preceding file version.
local function attach_history(buf, context, base, in_diff)
  gitsigns.detach(buf)
  if in_diff or not M.options.history_signs then return end
  gitsigns.attach({
    bufnr = buf, force = true,
    ctx = { file = context.path, gitdir = context.gitdir, toplevel = context.root, base = base },
  })
end

-- Read Git only; discard asynchronous results after this window changes file/version.
local function git(context, args, callback)
  local argv = { 'git', '--literal-pathspecs', '-C', context.root, '--git-dir=' .. context.gitdir, '--work-tree=' .. context.root }
  vim.list_extend(argv, args)
  local ok, err = pcall(vim.system, argv, { text = true, stdin = '', env = environment(), clear_env = true }, function(result)
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(context.win) or tickets[context.win] ~= context.ticket
        or vim.api.nvim_win_get_buf(context.win) ~= context.buffer then return end
      if result.code ~= 0 then
        vim.notify(vim.trim(result.stderr), vim.log.levels.ERROR)
      else callback(result.stdout) end
    end)
  end)
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
end

-- Gitsigns supplies repository identity; revisions retain it after signs detach in diff mode.
local function context_for(callback)
  local win, buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local context = vim.b[buffer].file_history
  local revision, path = legacy_revision(vim.api.nvim_buf_get_name(buffer))
  if not context then
    local status = vim.b[buffer].gitsigns_status_dict
    if not status or not status.gitdir or not status.root then
      vim.notify('File history: wait for Gitsigns to attach to this file', vim.log.levels.WARN)
      return
    end
    path = path or vim.fs.relpath(status.root, vim.api.nvim_buf_get_name(buffer))
    if not path then
      vim.notify('File history: file is outside the attached worktree', vim.log.levels.WARN)
      return
    end
    context = { gitdir = status.gitdir, root = status.root, path = path }
  end
  tickets[win] = (tickets[win] or 0) + 1
  context = vim.deepcopy(context)
  context.win, context.buffer, context.ticket = win, buffer, tickets[win]
  context.revision = vim.b[buffer].file_history_commit or revision
  callback(context)
end

-- Keep only visible buffers in Neovim's diff set when replacing a revision.
local function display(context, buffer)
  local win, diff_windows = context.win, {}
  if vim.wo[win].diff then
    for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
      if vim.wo[other].diff then diff_windows[#diff_windows + 1] = other end
    end
    vim.api.nvim_win_call(win, function() vim.cmd('diffoff!') end)
  end
  local ok, err = pcall(vim.api.nvim_win_set_buf, win, buffer)
  for _, other in ipairs(diff_windows) do
    if vim.api.nvim_win_is_valid(other) then
      vim.api.nvim_win_call(other, function() vim.cmd.diffthis() end)
    end
  end
  if not ok then
    if vim.api.nvim_buf_is_valid(buffer) and #vim.fn.win_findbuf(buffer) == 0
      and vim.b[buffer].file_history then vim.api.nvim_buf_delete(buffer, { force = true }) end
    vim.notify(tostring(err), vim.log.levels.ERROR)
    return false
  end
  if #diff_windows > 0 then vim.api.nvim_win_call(win, function() vim.cmd.diffupdate() end) end
  return true
end

-- Read-only snapshots retain the original file identity for navigation and display.
local function snapshot(context, revision, object, text)
  local name = 'history://' .. context.gitdir .. '//' .. object .. ':' .. context.path
  local buffer = vim.fn.bufnr(name)
  if buffer == -1 then
    buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buffer, name)
  end
  vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile = 'nowrite', 'wipe', false
  vim.bo[buffer].modifiable = true
  local lines = vim.split(text, '\n')
  if lines[#lines] == '' then table.remove(lines) end
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.b[buffer].file_history = { gitdir = context.gitdir, root = context.root, path = context.path }
  vim.b[buffer].file_history_commit = revision
  vim.bo[buffer].filetype = vim.filetype.match({ filename = context.path }) or ''
  vim.bo[buffer].modified, vim.bo[buffer].modifiable = false, false
  return buffer
end

-- Switch only the focused window; working buffers retain their contents and lifecycle.
function M.step(direction)
  assert(direction == 1 or direction == -1, 'direction must be 1 (older) or -1 (newer)')
  context_for(function(context)
    git(context, { 'log', '--diff-filter=d', '--format=%H', '--', context.path }, function(output)
      local nodes = vim.split(vim.trim(output), '\n', { trimempty = true })
      local revision = context.revision
      local function select(commit)
        local position = commit and (vim.fn.index(nodes, commit) + 1) or 0
        if commit and position == 0 and #nodes > 0 then
          vim.notify('File history: revision is outside the current branch history', vim.log.levels.WARN)
          return
        end
        local target = position + direction
        if target < 0 or target > #nodes then
          vim.notify('File history: no further version', vim.log.levels.INFO)
          return
        end
        if target == 0 then
          local source = vim.fn.bufadd(context.root .. '/' .. context.path)
          vim.fn.bufload(source)
          display(context, source)
          return
        end
        local hash = nodes[target]
        git(context, { 'show', hash .. ':' .. context.path }, function(text)
          local function present(base)
            local buffer = snapshot(context, hash, hash, text)
            if display(context, buffer) then attach_history(buffer, context, base, vim.wo[context.win].diff) end
          end
          if nodes[target + 1] then present(nodes[target + 1])
          elseif vim.wo[context.win].diff or not M.options.history_signs then present(nil)
          else
            git(context, { 'hash-object', '-t', 'tree', '--stdin' }, function(base) present(vim.trim(base)) end)
          end
        end)
      end
      if not revision then select()
      elseif vim.tbl_contains(nodes, revision) then select(revision)
      elseif revision:sub(1, 1) == ':' then
        vim.notify('File history: open a working file or committed revision first', vim.log.levels.WARN)
      else
        git(context, { 'log', '-1', '--diff-filter=d', '--format=%H', revision, '--', context.path },
          function(hash) select(vim.trim(hash)) end)
      end
    end)
  end)
end

-- Delegate split creation to Gitsigns; keep its read-only revisions navigable after detach.
function M.diff()
  context_for(function(context)
    local function open(err)
      if err then vim.notify(tostring(err), vim.log.levels.ERROR); return end
      if not vim.api.nvim_win_is_valid(context.win) or tickets[context.win] ~= context.ticket
        or vim.api.nvim_win_get_buf(context.win) ~= context.buffer then return end
      vim.api.nvim_win_call(context.win, function()
        gitsigns.diffthis('HEAD', { vertical = true, split = 'aboveleft', unified = false }, function(error)
          if error then vim.notify(tostring(error), vim.log.levels.ERROR); return end
          vim.schedule(function()
            if not vim.api.nvim_win_is_valid(context.win) then return end
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(context.win))) do
              local buffer = vim.api.nvim_win_get_buf(win)
              local name = 'gitsigns://' .. context.gitdir .. '//HEAD:' .. context.path
              if vim.wo[win].diff and vim.api.nvim_buf_get_name(buffer) == name then
                vim.b[buffer].file_history = { gitdir = context.gitdir, root = context.root, path = context.path }
                vim.b[buffer].file_history_commit = 'HEAD'
                gitsigns.detach(buffer)
              end
            end
          end)
        end)
      end)
    end
    if vim.b[context.buffer].file_history then
      gitsigns.attach({ bufnr = context.buffer, force = true,
        ctx = { file = context.path, gitdir = context.gitdir, toplevel = context.root,
          base = context.revision } }, open)
    else open() end
  end)
end

-- Show commit metadata, message and file statistics; working files use HEAD.
function M.log()
  context_for(function(context)
    local revision = context.revision or 'HEAD'
    if revision:sub(1, 1) == ':' then
      vim.notify('Index has no commit message', vim.log.levels.INFO)
      return
    end
    git(context, { 'show', M.options.show_stat and '--stat' or '--no-patch', '--format=fuller', revision }, function(text)
      local lines = vim.split(vim.trim(text), '\n')
      local buf, popup = vim.lsp.util.open_floating_preview(lines, 'git', {
        border = 'rounded', title = ' Commit ', max_width = M.options.max_width, max_height = M.options.max_height,
        focus_id = 'file_history_commit', close_events = {},
      })
      local size = vim.api.nvim_win_get_config(popup)
      vim.api.nvim_win_set_config(popup, { relative = 'editor',
        row = math.max(0, math.floor((vim.o.lines - size.height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - size.width) / 2)), anchor = 'NW' })
      vim.wo[popup].diff, vim.wo[popup].wrap = false, true
      -- Git syntax does not highlight diffstat bars; reuse its added/removed colors.
      vim.api.nvim_win_call(popup, function()
        vim.fn.matchadd('diffAdded', [[^ .* |\s\+\d\+\s\+\zs[+]\+]])
        vim.fn.matchadd('diffRemoved', [[^ .* |\s\+\d\+\s\+[+]*\zs-\+]])
      end)
      vim.api.nvim_set_current_win(popup)
      vim.keymap.set('n', '<Esc>', '<cmd>close<cr>', { buffer = buf, desc = 'Close commit details' })
    end)
  end)
end

function M.setup(options)
  M.options = vim.tbl_deep_extend('force', M.options, options or {})
  for name, action in pairs({ Older = function() M.step(1) end, Newer = function() M.step(-1) end,
    Diff = M.diff, Log = M.log }) do
    vim.api.nvim_create_user_command('FileHistory' .. name, action, {})
  end
end

-- A display label only: never rename the buffer or change its write target.
function M.label(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) then return nil end
  local context = vim.b[buffer].file_history
  local revision, path = vim.b[buffer].file_history_commit, context and context.path
  if not revision then
    revision, path = legacy_revision(vim.api.nvim_buf_get_name(buffer):gsub('^history://', 'gitsigns://'))
  end
  if not revision then return nil end
  if revision == ':0' then revision = 'Index'
  elseif revision:match('^%x+$') and #revision > 8 then revision = revision:sub(1, 8) end
  return '[' .. revision .. '] ' .. vim.fn.fnamemodify(path, ':t')
end

return M
