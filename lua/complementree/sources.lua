local M = {}

local utils = require "complementree.utils"
local comb = require "complementree.combinators"
local api = vim.api
local lsp = vim.lsp

local cache = {}

function M.invalidate_cache()
  cache = {}
end

local function cached(kind, func)
  return function(...)
    if not cache[kind] then
      cache[kind] = func(...)
    end
    local new = {}
    for _, v in pairs(cache[kind]) do
      table.insert(new, v)
    end
    return new
  end
end

M.luasnip_matches = cached("luasnip", function(_, _, _, _)
  local snippets = require("luasnip").available()

  local items = {}

  -- Luasnip format:
  -- {
  --  description = table(string),
  --  name = string,
  --  regTrig = bool,
  --  trigger = string,
  --  wordTrig = bool
  -- }
  local function add_snippet(s)
    table.insert(items, {
      word = s.trigger,
      abbr = s.name,
      kind = "S",
      menu = table.concat(s.description or {}),
      icase = 1,
      dup = 1,
      empty = 1,
      user_data = { source = "luasnip" },
    })
  end

  vim.tbl_map(add_snippet, snippets.all)
  vim.tbl_map(add_snippet, snippets[api.nvim_buf_get_option(0, "filetype")])

  return items
end)

-- Shamelessly stollen from https://github.com/mfussenegger/nvim-lsp-compl with small adaptations
M.lsp_matches = cached("lsp", function(_, _, _, _)
  local params = lsp.util.make_position_params()
  local result_all, err = lsp.buf_request_sync(0, "textDocument/completion", params)
  assert(not err, vim.inspect(err))
  if not result_all then
    return
  end

  local matches = {}
  for client_id, result in pairs(result_all) do
    local items = lsp.util.extract_completion_items(result.result)
    for _, item in pairs(items or {}) do
      local kind = lsp.protocol.CompletionItemKind[item.kind] or ""
      local word
      if kind == "Snippet" then
        word = item.label
      elseif item.insertTextFormat == 2 then
        if item.textEdit then
          word = item.insertText or item.textEdit.newText
        elseif item.insertText then
          if #item.label < #item.insertText then
            word = item.label
          else
            word = item.insertText
          end
        else
          word = item.label
        end
      else
        word = (item.textEdit and item.textEdit.newText) or item.insertText or item.label
      end
      item.client_id = client_id
      item.source = "lsp"
      table.insert(matches, {
        word = word,
        abbr = item.label,
        kind = kind,
        menu = item.detail or "",
        icase = 1,
        dup = 1,
        empty = 1,
        user_data = item,
      })
    end
  end
  return matches
end)

local function apply_snippet(item, suffix)
  local luasnip = require "luasnip"
  if item.textEdit then
    luasnip.lsp_expand(item.textEdit.newText .. suffix)
  elseif item.insertText then
    luasnip.lsp_expand(item.insertText .. suffix)
  elseif item.label then
    luasnip.lsp_expand(item.label .. suffix)
  end
end

local function lsp_completedone(completed_item)
  local lnum, col = unpack(api.nvim_win_get_cursor(0))
  lnum = lnum - 1
  local item = completed_item.user_data
  local bufnr = api.nvim_get_current_buf()
  local expand_snippet = item.insertTextFormat == 2
  local client = lsp.get_client_by_id(item.client_id)
  if not client then
    return
  end

  local resolveEdits = (client.server_capabilities.completionProvider or {}).resolveProvider

  local tidy = function() end
  local suffix = nil
  if expand_snippet then
    local line = api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, true)[1]
    tidy = function()
      -- Remove the already inserted word
      local start_char = col - #completed_item.word
      local l = line
      api.nvim_buf_set_text(bufnr, lnum, start_char, lnum, #l, { "" })
    end
    suffix = line:sub(col + 1)
  end

  if item.additionalTextEdits then
    tidy()
    lsp.util.apply_text_edits(item.additionalTextEdits, bufnr)
    if expand_snippet then
      apply_snippet(item, suffix)
    end
  elseif resolveEdits and type(item) == "table" then
    local v = client.request_sync("completionItem/resolve", item, 1000, bufnr)
    assert(not v.err, vim.inspect(v.err))
    if v.result.additionalTextEdits then
      tidy()
      tidy = function() end
      lsp.util.apply_text_edits(v.result.additionalTextEdits, bufnr)
    end
    if expand_snippet then
      tidy()
      apply_snippet(item, suffix)
    end
  elseif expand_snippet then
    tidy()
    apply_snippet(item, suffix)
  end
end

M.create_filepath_source = function(opts)
  local relpath = utils.make_relative_path -- TODO: use vims relpath?
  local scan_dir = utils.scan_dir

  opts = opts or {}
  local config = {
    max_depth = opts.max_depth or 8,
    ignore_hidden = opts.ignore_hidden or true,
    relative_paths = opts.relative_paths or true,
    root_dirs = opts.root_dirs,
    match_patterns = opts.match_patterns or {}
  }

  local src = function(_, _, _, _)
    local included_root_dirs = {}

    if config.root_dirs then
      included_root_dirs = config.root_dirs
    else
      local lsp_buf_clients = vim.lsp.buf_get_clients()
      if #lsp_buf_clients > 0 then
        for _, client in pairs(lsp_buf_clients) do
          included_root_dirs[#included_root_dirs + 1] = client.config.root_dir
        end
      else
        included_root_dirs[1] = "."
      end
    end

    local items = {}
    local path_entries
    for _, root_dir in ipairs(included_root_dirs) do
      path_entries = scan_dir(root_dir, { max_depth = config.max_depth, ignore_hidden = config.ignore_hidden, match_patterns = config.match_patterns })
      for _, path in ipairs(path_entries) do
        items[#items + 1] = { root_dir = root_dir, path = path }
      end
    end

    local display_path
    local matches = {}
    for _, i in ipairs(items) do
      display_path = config.relative_paths and relpath(i.path, i.root_dir) or i.path

      matches[#matches + 1] = {
        word = i.path,
        abbr = display_path,
        kind = "[path]",
        icase = 1,
        dup = 1,
        empty = 1,
        user_data = { source = "filepath" },
      }
      display_path = nil
    end

    return matches
  end

  return src
end

M.filepath = M.create_filepath_source()

-- CompleteDone handlers

local function luasnip_completedone(_)
  if require("luasnip").expandable() then
    require("luasnip").expand()
  end
end

M.complete_done_cbs = {
  lsp = lsp_completedone,
  luasnip = luasnip_completedone,
}

return M
