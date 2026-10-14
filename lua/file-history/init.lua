local M = {}
M.options = {
  max_width = 100, max_height = 30, -- Commit popup size limits, in cells.
  show_stat = true, -- Include changed files and insertion/deletion statistics.
  history_signs = true, -- Compare single-window historical files with their preceding version.
}
local tickets = {}
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
  local argv = { 'git', '--git-dir=' .. context.gitdir, '--work-tree=' .. context.root }
  vim.list_extend(argv, args)
  local ok, err = pcall(vim.system, argv, { text = true, stdin = '' }, function(result)
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
      or vim.api.nvim_buf_get_name(buffer):match('^gitsigns://.-//([^/]+):')
    callback(context)
  end
  if vim.b[buffer].file_history then return ready(vim.b[buffer].file_history) end
  local file = vim.api.nvim_buf_get_name(buffer)
  if vim.bo[buffer].buftype ~= '' or vim.fn.filereadable(file) == 0 then
    vim.notify('File history: open an existing working file', vim.log.levels.WARN)
    return
  end
  local env = vim.fn.environ()
  for key in pairs(env) do if key:match('^GIT_') then env[key] = nil end end
  vim.system({ 'git', '-C', vim.fs.dirname(file), 'rev-parse', '--absolute-git-dir', '--show-toplevel' },
    { text = true, env = env, clear_env = true }, function(result)
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

-- Switch only the focused window; working buffers remain intact, including local edits.
function M.step(direction)
  context_for(function(context)
  local win, revision = context.win, context.revision
  if revision and revision:sub(1, 1) == ':' then
    vim.notify('File history: open a working file or a committed revision first', vim.log.levels.WARN)
    return
  end
  -- Deletion commits have no file contents to display.
  git(context, { 'log', '--diff-filter=d', '--format=%H', '--', context.path }, function(output)
    local commits = vim.split(vim.trim(output), '\n', { trimempty = true })
    local function select(commit)
      local index = 0
      if commit then
        index = vim.fn.index(commits, commit) + 1
        if index == 0 then
          vim.notify('File history: revision is outside the current branch history', vim.log.levels.WARN)
          return
        end
      end
      local target = index + direction
      if target < 0 or target > #commits then
        vim.notify('File history: no further version', vim.log.levels.INFO)
        return
      end
      local function display(buf)
        local diff = vim.wo[win].diff
        local diff_windows = {}
        if diff then
          for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
            if vim.wo[other].diff then diff_windows[#diff_windows + 1] = other end
          end
          -- Hidden historical buffers otherwise accumulate toward Neovim's eight-buffer limit.
          vim.api.nvim_win_call(win, function() vim.cmd('diffoff!') end)
        end
        local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
        for _, other in ipairs(diff_windows) do
          vim.api.nvim_win_call(other, function() vim.cmd.diffthis() end)
        end
        if not ok then vim.notify(tostring(err), vim.log.levels.ERROR); return end
        if diff then vim.api.nvim_win_call(win, function() vim.cmd.diffupdate() end) end
      end
      if target == 0 then
        local file = context.root .. '/' .. context.path
        local source = vim.fn.bufadd(file)
        vim.fn.bufload(source)
        display(source)
        return
      end
      local hash = commits[target]
      git(context, { 'show', hash .. ':' .. context.path }, function(text)
        local label = 'history://' .. context.gitdir .. '//' .. hash .. ':' .. context.path
        local buf = vim.fn.bufnr(label)
        if buf == -1 then
          buf = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_name(buf, label)
        end
        -- Rehydrate existing buffers too: sessions may restore an empty URI placeholder.
        -- A historical view lives only while displayed; working buffers keep their own lifecycle.
        vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nowrite', 'wipe', false
        vim.bo[buf].modifiable = true
        local lines = vim.split(text, '\n')
        if lines[#lines] == '' then table.remove(lines) end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.b[buf].file_history = { gitdir = context.gitdir, root = context.root, path = context.path }
        vim.b[buf].file_history_commit = hash
        vim.bo[buf].filetype = vim.filetype.match({ filename = context.path }) or ''
        vim.bo[buf].modified, vim.bo[buf].modifiable = false, false
        local function present(base)
          display(buf)
          if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_get_buf(win) == buf then
            attach_history(buf, context, base, vim.wo[win].diff)
          end
        end
        if commits[target + 1] then present(commits[target + 1])
        elseif vim.wo[win].diff or not M.options.history_signs then present(nil)
        else
          -- Compute the repository's empty-tree ID without writing an object (also supports SHA-256).
          git(context, { 'hash-object', '-t', 'tree', '--stdin' }, function(base) present(vim.trim(base)) end)
        end
      end)
    end
    -- Our buffers store full hashes; HEAD means the latest version of this file.
    if not revision then select()
    elseif revision == 'HEAD' then select(commits[1])
    elseif vim.tbl_contains(commits, revision) then select(revision)
    else
      -- Resolve manually opened tags/abbreviations to this file's last change.
      git(context, { 'log', '-1', '--diff-filter=d', '--format=%H', revision, '--', context.path },
        function(hash) select(vim.trim(hash)) end)
    end
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
end

-- A display label only: never rename the buffer or change its write target.
function M.label(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) then return nil end
  local name = vim.api.nvim_buf_get_name(buffer):gsub('^history://', 'gitsigns://')
  local revision, path = name:match('^gitsigns://.-//([^/]+):(.+)$')
  if not revision then return nil end
  if revision == ':0' then revision = 'Index'
  elseif revision:match('^%x+$') and #revision > 8 then revision = revision:sub(1, 8) end
  return '[' .. revision .. '] ' .. vim.fn.fnamemodify(path, ':t')
end

return M
