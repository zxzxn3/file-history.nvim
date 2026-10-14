local M = {}
M.options = {
  max_width = 100, max_height = 30, -- Commit popup size limits, in cells.
  show_stat = true, -- Include changed files and insertion/deletion statistics.
  index = true, -- Include a distinct stage-0 snapshot between the worktree and commits.
  history_signs = true, -- Compare single-window historical files with their preceding version.
}
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
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then return end
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

-- Share repository identity between history navigation and commit details.
local function context_for(callback)
  local win, buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  tickets[win] = (tickets[win] or 0) + 1
  local ticket = tickets[win]
  local function ready(context)
    if not vim.api.nvim_win_is_valid(win) or tickets[win] ~= ticket
      or vim.api.nvim_win_get_buf(win) ~= buffer then return end
    context = vim.deepcopy(context)
    context.win, context.buffer, context.ticket = win, buffer, ticket
    context.revision = vim.b[buffer].file_history_commit
      or legacy_revision(vim.api.nvim_buf_get_name(buffer))
    callback(context)
  end
  if vim.b[buffer].file_history then return ready(vim.b[buffer].file_history) end
  local file = vim.api.nvim_buf_get_name(buffer)
  local revision, path = legacy_revision(file)
  if revision and M.options.context then
    local context = M.options.context(buffer)
    if context then context.path = path; return ready(context) end
  end
  if vim.bo[buffer].buftype ~= '' or vim.fn.filereadable(file) == 0 then
    vim.notify('File history: open an existing working file', vim.log.levels.WARN)
    return
  end
  vim.system({ 'git', '-C', vim.fs.dirname(file), 'rev-parse', '--absolute-git-dir', '--show-toplevel' },
    { text = true, env = environment(), clear_env = true }, function(result)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buffer) then return end
        local context
        if result.code == 0 then
          local paths = vim.split(vim.trim(result.stdout), '\n')
          context = { gitdir = paths[1], root = paths[2] }
        elseif M.options.context then context = M.options.context(buffer) end
        if context then
          context.path = context.path or vim.fs.relpath(context.root, file)
          if context.path then return ready(context) end
        end
        if vim.api.nvim_win_is_valid(win) and tickets[win] == ticket
          and vim.api.nvim_win_get_buf(win) == buffer then
          vim.notify('File history: no repository context for this file', vim.log.levels.WARN)
        end
      end)
    end)
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

-- Immutable snapshots: an index change gets a different name even when a previous view stays open.
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

-- A stage-0 blob is a navigation node only when its contents differ from HEAD.
local function versions(context, callback)
  git(context, { 'log', '--diff-filter=d', '--format=%H', '--', context.path }, function(output)
    local commits = vim.split(vim.trim(output), '\n', { trimempty = true })
    if not M.options.index then return callback(commits) end
    git(context, { 'ls-files', '--stage', '-z', '--', context.path }, function(stages)
      local blob = stages:match('^%d+ (%x+) 0\t')
      if not blob then return callback(commits) end
      local function finish(latest)
        if blob ~= latest then table.insert(commits, 1, ':0') end
        callback(commits, blob)
      end
      git(context, { 'ls-tree', '-z', 'HEAD', '--', context.path }, function(latest)
        finish(latest:match('^%d+ blob (%x+)\t'))
      end)
    end)
  end)
end

-- Switch only the focused window; working buffers retain their contents and lifecycle.
function M.step(direction)
  assert(direction == 1 or direction == -1, 'direction must be 1 (older) or -1 (newer)')
  context_for(function(context)
    versions(context, function(nodes, index_blob)
      local revision = context.revision
      local function select(commit)
        local position = commit and (vim.fn.index(nodes, commit) + 1) or 0
        -- An index that now equals HEAD aliases the newest file commit.
        if commit == ':0' and position == 0 then position = #nodes > 0 and 1 or 0 end
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
        local object = hash == ':0' and index_blob or hash .. ':' .. context.path
        git(context, { 'show', object }, function(text)
          local function present(base)
            local name = hash == ':0' and 'INDEX-' .. index_blob or hash
            local buffer = snapshot(context, hash, name, text)
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
      elseif revision == ':0' or vim.tbl_contains(nodes, revision) then select(revision)
      elseif revision:sub(1, 1) == ':' then
        vim.notify('File history: unmerged index stages are not supported', vim.log.levels.WARN)
      else
        git(context, { 'log', '-1', '--diff-filter=d', '--format=%H', revision, '--', context.path },
          function(hash) select(vim.trim(hash)) end)
      end
    end)
  end)
end

-- Open HEAD on the left and keep the invoking view on the right; each side navigates independently.
function M.diff()
  context_for(function(context)
    git(context, { 'log', '-1', '--diff-filter=d', '--format=%H', '--', context.path }, function(output)
      local hash = vim.trim(output)
      if hash == '' then
        vim.notify('File history: no committed version of this file', vim.log.levels.WARN)
        return
      end
      git(context, { 'show', 'HEAD:' .. context.path }, function(text)
        local buffer = snapshot(context, hash, hash, text)
        vim.api.nvim_win_call(context.win, function()
          vim.cmd('leftabove vsplit')
          local left = vim.api.nvim_get_current_win()
          if display({ win = left }, buffer) then
            vim.cmd.diffthis()
            vim.api.nvim_win_call(context.win, function() vim.cmd.diffthis() end)
            local ok, gitsigns = pcall(require, 'gitsigns')
            if ok then gitsigns.detach(buffer) end
          end
        end)
        if vim.api.nvim_win_is_valid(context.win) then vim.api.nvim_set_current_win(context.win) end
      end)
    end)
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
