local exec = require("fzf-lua").fzf_exec
local builtin_previewer = require("fzf-lua.previewer.builtin")
local ansi_codes = require("fzf-lua").utils.ansi_codes
local actions = require("fzf-lua").actions
local note_cache = {} -- DEBUG: NEED THIS ?

local M = {}

local delimiter = "\x01"

local fzf_lua_previewer = builtin_previewer.buffer_or_file:extend()

local function index_notes_by_path(notes)
  local tbl = {}
  for _, note in ipairs(notes) do
    tbl[note.absPath] = note
  end
  return tbl
end

function fzf_lua_previewer:new(o, opts, fzf_win)
  fzf_lua_previewer.super.new(self, o, opts, fzf_win)
  setmetatable(self, fzf_lua_previewer)
  return self
end

function fzf_lua_previewer:parse_entry(entry)
  local path = entry:match("([^" .. delimiter .. "]+)")
  return { path = path }
end

local function path_from_selected(selected)
  return vim.tbl_map(function(line)
    return string.match(line, "([^" .. delimiter .. "]+)")
  end, selected)
end

M.note_picker_list_api_selection = { "title", "absPath", "path" }

function M.show_note_picker(notes, options, cb)
  options = options or {}
  local notes_by_path = {}
  local fzf_opts = vim.tbl_deep_extend("force", {
    prompt = options.title .. " ❯ ",
    previewer = fzf_lua_previewer,
    fzf_opts = {
      ["--delimiter"] = delimiter,
      ["--tiebreak"] = "index",
      ["--with-nth"] = 2,
      ["--tabstop"] = 4,
      ["--header"] = ansi_codes.blue("CTRL-E: create a note with the query as title"),
    },
    -- we rely on `fzf-lua` to open notes in any other case than the default (pressing enter)
    -- to take advantage of the plugin builtin actions like opening in a split
    actions = {
      ["default"] = function(selected, opts)
        local selected_notes = vim.tbl_map(function(line)
          local path = string.match(line, "([^" .. delimiter .. "]+)")
          return notes_by_path[path]
        end, selected)
        if options.multi_select then
          cb(selected_notes)
        else
          cb(selected_notes[1])
        end
      end,
      ["ctrl-s"] = function(selected, opts)
        local entries = path_from_selected(selected)
        actions.file_split(entries, opts)
      end,
      ["ctrl-v"] = function(selected, opts)
        local entries = path_from_selected(selected)
        actions.file_vsplit(entries, opts)
      end,
      ["ctrl-t"] = function(selected, opts)
        local entries = path_from_selected(selected)
        actions.file_tabedit(entries, opts)
      end,
      ["ctrl-e"] = function()
        local query = require("fzf-lua").config.__resume_data.last_query
        options["title"] = query
        require("zk").new(options)
      end,
    },
  }, options.fzf_lua or {})

  exec(function(fzf_cb)
    for _, note in ipairs(notes) do
      local title = note.title or note.path
      local entry = table.concat({ note.absPath, title }, delimiter)
      notes_by_path[note.absPath] = note
      fzf_cb(entry)
    end
    fzf_cb() --EOF
  end, fzf_opts)
end

function M.show_tag_picker(tags, options, cb)
  options = options or {}
  local tags_by_name = {}
  local fzf_opts = vim.tbl_extend("force", {
    prompt = options.title .. "> ",
    fzf_opts = {
      ["--delimiter"] = delimiter,
      ["--tiebreak"] = "index",
      ["--nth"] = 2,
      ["--exact"] = "",
      ["--tabstop"] = 4,
    },
    actions = {
      ["default"] = function(selected, _)
        local selected_tags = vim.tbl_map(function(line)
          local name = string.match(line, "%d+%s+" .. delimiter .. "(.+)")
          return tags_by_name[name]
        end, selected)
        if options.multi_select then
          cb(selected_tags)
        else
          cb(selected_tags[1])
        end
      end,
    },
  }, options.fzf_lua or {})

  exec(function(fzf_cb)
    for _, tag in ipairs(tags) do
      -- formatting the note count to have some color, and adding a bit of space
      local note_count = ansi_codes.bold(ansi_codes.magenta(string.format("%-4d", tag.note_count)))
      local entry = table.concat({
        note_count,
        tag.name,
      }, delimiter)
      tags_by_name[tag.name] = tag
      fzf_cb(entry)
    end
    fzf_cb() --EOF
  end, fzf_opts)
end

-- local uv = vim.uv or vim.loop
-- local path = require "fzf-lua.path"
local fzf_core = require("fzf-lua.core")
local fzf_utils = require("fzf-lua.utils")
local fzf_config = require("fzf-lua.config")
local make_entry = require("fzf-lua.make_entry")

local get_grep_cmd = make_entry.get_grep_cmd

local function normalize_live_grep_opts(opts)
  -- disable treesitter as it collides with cmd regex highlighting
  opts = opts or {}
  opts._treesitter = false

  ---@type fzf-lua.config.Grep
  opts = fzf_config.normalize_opts(opts, "grep")
  if not opts then
    return
  end

  -- we need this for `actions.grep_lgrep`
  opts.__ACT_TO = opts.__ACT_TO or M.grep

  -- used by `actions.toggle_ignore', normalize_opts sets `__call_fn`
  -- to the calling function  which will resolve to this fn), we need
  -- to deref one level up to get to `live_grep_{mt|st}`
  opts.__call_fn = fzf_utils.__FNCREF2__()

  -- NOTE: no longer used since we hl the query with `FzfLuaLivePrompt`
  -- prepend prompt with "*" to indicate "live" query
  -- opts.prompt = type(opts.prompt) == "string" and opts.prompt or "> "
  -- if opts.live_ast_prefix ~= false then
  --   opts.prompt = opts.prompt:match("^%*") and opts.prompt or ("*" .. opts.prompt)
  -- end

  -- when using live_grep there is no "query", the prompt input
  -- is a regex expression and should be saved as last "search"
  -- this callback overrides setting "query" with "search"
  opts.__resume_set = function(what, val, o)
    if what == "query" then
      fzf_config.resume_set("search", val, { __resume_key = o.__resume_key })
      fzf_config.resume_set("no_esc", true, { __resume_key = o.__resume_key })
      fzf_utils.map_set(fzf_config, "__resume_data.last_query", val)
      -- also store query for `fzf_resume` (#963)
      fzf_utils.map_set(fzf_config, "__resume_data.opts.query", val)
      -- store in opts for convenience in action callbacks
      o.last_query = val
    else
      fzf_config.resume_set(what, val, { __resume_key = o.__resume_key })
    end
  end
  -- we also override the getter for the quickfix list name
  opts.__resume_get = function(what, o)
    return fzf_config.resume_get(what == "query" and "search" or what, { __resume_key = o.__resume_key })
  end

  -- when using an empty string grep (as in 'grep_project') or
  -- when switching from grep to live_grep using 'ctrl-g' users
  -- may find it confusing why is the last typed query not
  -- considered the last search so we find out if that's the
  -- case and use the last typed prompt as the grep string
  if not opts.search or #opts.search == 0 and (opts.query and #opts.query > 0) then
    -- fuzzy match query needs to be regex escaped
    opts.no_esc = nil
    opts.search = opts.query
    -- also replace in `__call_opts` for `resume=true`
    opts.__call_opts.query = nil
    opts.__call_opts.no_esc = nil
    opts.__call_opts.search = opts.query
  end

  -- interactive interface uses 'query' parameter
  opts.query = opts.search or ""
  if opts.search and #opts.search > 0 then
    -- escape unless the user requested not to
    if not opts.no_esc then
      opts.query = fzf_utils.rg_escape(opts.search)
    end
  end

  return opts
end

function M.show_grep_picker(opts, cb)
  opts = opts or {}
  opts = normalize_live_grep_opts(opts)
  if not opts then
    return
  end
  print("opts: " .. vim.inspect(opts))

  -- register opts._cmd, toggle_ignore/title_flag/--fixed-strings
  local cmd0 = get_grep_cmd(opts, fzf_core.fzf_query_placeholder, 2)
  -- local cmd = "rg --line-number --column --color=always" -- DEBUG: REMOVE THIS

  -- if multiprocess is optional (=1) and no prpocessing is required
  -- use string contents (shell command), stringify_mt will use the
  -- command as is without the neovim headless wrapper
  local contents
  if
    opts.multiprocess == 1
    and not opts.fn_transform
    and not opts.fn_preprocess
    and not opts.fn_postprocess
  then
    contents = cmd0
  else
    -- since we're using function contents force multiprocess if optional
    opts.multiprocess = opts.multiprocess == 1 and true or opts.multiprocess
    contents = function(s, o)
      return FzfLua.make_entry.lgrep(s, o)
    end
  end

  -- DEBUG: 呼ばれない...
  -- -- opts.fn_transform = function(line) -- これもよくわからん。
  -- opts.fn_postprocess = function(opts) -- 引数が opts って...
  --   local path = line:match("([^:]+):")
  --   local note = notes_cached[path]
  --   if note and note.title then
  --     -- path:title:rest に差し替えたい場合など
  --     -- return line:gsub(path, note.title)
  --     print(path)
  --     return line:gsub(path, note.title)
  --   end
  --   print(line)
  --   return line
  -- end

  -- opts.fn_transform = function(line)
  --   -- vim.schedule(function()
  --   --   vim.notify("fn_transform", vim.log.levels.INFO, { title = "zk-nvim: fzf_lua: show_grep_picker()" })
  --   -- end)
  --   -- path:lnum:col:content をパース
  --   local path, lnum, col, content = line:match("^([^:]+):(%d+):(%d+):(.*)$")
  --   if not path then
  --     return line
  --   end
  --
  --   -- title を lookup
  --   local note = notes_cached[path]
  --   local title = note and note.title or path -- title が無ければ path
  --
  --   -- path:lnum:col:content:title に変換
  --   return table.concat({ path, lnum, col, content, title }, ":")
  -- end

  -- opts.fn_transform = function(line)
  --   -- あなたの grep 出力が "path:line:text" 形式なら
  --   -- 必要な部分だけ抜き出して整形する
  --   vim.schedule(function()
  --     print(vim.inspect(line))
  --   end)
  --   local path, lnum, text = line:match("^(.-):(%d+):(.*)$")
  --   if not path then
  --     -- print("not matched")
  --     return line -- マッチしない時はそのまま
  --   end
  --   -- print("matched")
  --
  --   -- 好きに整形
  --   return string.format("%s:%s %s", path, lnum, text)
  -- end

  -- local strip_ansi = function(s)
  --   return s:gsub("\27%[[0-9;]*m", "")
  -- end

  opts.fn_transform = function(line) -- DEBUG: 表示の変換はできたが、配色が消える。
    line = line:gsub("\27%[[0-9;]*m", "")
    local path, lnum, col, text = line:match("^(.-):(%d+):(.*)$")
    if not path then
      return line
    end
    return string.format("%s:%s:%s:%s", path, lnum, col, text)
  end

  -- -- local notes_by_path = {}
  -- fzf_opts = vim.tbl_deep_extend("force", {
  --   prompt = opts.title .. " ❯ ",
  --   previewer = fzf_lua_previewer,

  --   -- fzf_opts = { -- DEBUG: Use rg, right ?
  --   --   ["--delimiter"] = delimiter,
  --   --   ["--tiebreak"] = "index",
  --   --   ["--with-nth"] = 2,
  --   --   ["--tabstop"] = 4,
  --   --   ["--header"] = ansi_codes.blue("CTRL-E: create a note with the query as title"),
  --   -- },
  --   -- we rely on `fzf-lua` to open notes in any other case than the default (pressing enter)
  --   -- to take advantage of the plugin builtin actions like opening in a split
  --   actions = {
  --     ["default"] = function(selected, opts)
  --       local selected_notes = vim.tbl_map(function(line)
  --         local path = string.match(line, "([^" .. delimiter .. "]+)")
  --         return notes_cached[path]
  --       end, selected)
  --       if opts.multi_select then
  --         cb(selected_notes)
  --       else
  --         cb(selected_notes[1])
  --       end
  --     end,
  --     ["ctrl-s"] = function(selected, opts)
  --       local entries = path_from_selected(selected)
  --       actions.file_split(entries, opts)
  --     end,
  --     ["ctrl-v"] = function(selected, opts)
  --       local entries = path_from_selected(selected)
  --       actions.file_vsplit(entries, opts)
  --     end,
  --     ["ctrl-t"] = function(selected, opts)
  --       local entries = path_from_selected(selected)
  --       actions.file_tabedit(entries, opts)
  --     end,
  --     ["ctrl-e"] = function()
  --       local query = require("fzf-lua").config.__resume_data.last_query
  --       opts["title"] = query
  --       require("zk").new(opts)
  --     end,
  --   },
  -- }, opts.fzf_lua or {})

  -- exec(function(fzf_cb)

  local root = opts.notebook_path or nil
  if not root then
    local zk_util = require("zk.util")
    local path = zk_util.resolve_notebook_path(0)
    root = zk_util.notebook_root(path or vim.fn.getcwd()) or vim.fn.getcwd()
  end

  -- local query = opts.query or ""

  -- print("opts: " .. vim.inspect(opts))
  -- print("cmd: " .. vim.inspect(cmd))

  require("zk.api").list(root, { select = M.note_picker_list_api_selection }, function(err, notes)
    if not err then
      notes_cached = index_notes_by_path(notes) -- DEBUG: NEED THIS ???
      -- for _, note in ipairs(notes) do
      --   local title = note.title or note.path
      --   local entry = table.concat({ note.absPath, title }, delimiter)
      --   fzf_cb(entry)
      -- end
      -- fzf_cb() --EOF
      -- require("fzf-lua").fzf_live(cmd,, fzf_opts)

      -- require("fzf-lua").live_grep(fzf_opts) -- DEBUG: いみないっしょ
      -- require("fzf-lua").live_grep()
      -- search query in header line
      opts = fzf_core.set_title_flags(opts, { "cmd", "live" })
      opts = fzf_core.set_fzf_field_index(opts)
      fzf_core.fzf_live(contents, opts)
    end
  end)
end

-- function M.show_grep_picker(opts, cb)
--   opts = opts or {}
--   local root = opts.notebook_path or vim.fn.getcwd()
--   local query = opts.query or ""
--
--   local cmd = {
--     "rg",
--     "--line-number",
--     "--column",
--     "--color=always",
--     query,
--     root,
--   }
--
--   require("fzf-lua").fzf_live(cmd, {
--     prompt = "ZkGrep ❯ ",
--     previewer = "builtin",
--     actions = {
--       ["default"] = function(selected)
--         local path, lnum = selected[1]:match("([^:]+):(%d+)")
--         cb({ path = path, line = tonumber(lnum) })
--       end,
--     },
--   })
-- end

--------------------------------------------------------------------------------

-- local DELIM = "\x1f"
-- local zk = require("zk")
-- local fzf = require("fzf-lua")
-- local Path = require("plenary.path")
--
-- -- -- zk list を index 化
-- -- local function index_notes_by_path(notes)
-- --   local map = {}
-- --   for _, note in ipairs(notes) do
-- --     map[note.absPath] = note
-- --   end
-- --   return map
-- -- end
--
-- -- rg の1行を entry に変換する
-- local function make_entry(line, notes)
--   -- rg 出力は基本: path:lnum:col:match
--   local path, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
--   if not path then
--     return nil
--   end
--
--   local note = notes[path]
--   local title = note and note.title or Path:new(path):make_relative()
--
--   return table.concat({
--     path,
--     title,
--     lnum,
--     text,
--   }, DELIM)
-- end
--
-- -- 表示は title
-- local function with_nth()
--   return {
--     ["--delimiter"] = DELIM,
--     ["--with-nth"] = 2, -- タイトルだけ表示
--     ["--nth"] = 2, -- あいまい検索もタイトル対象
--   }
-- end
--
-- -- previewer: path & lnum でプレビュー
-- local function previewer()
--   return function(line)
--     if not line or line == "" then
--       return { path = nil, lnum = 1, preview = "" }
--     end
--
--     -- 2 カラム対応
--     local path, title = line:match("^(.-)" .. DELIM .. "(.-)$")
--
--     if not path or path == "" then
--       return { path = nil, lnum = 1, preview = "" }
--     end
--
--     return {
--       path = path,
--       lnum = 1,
--       preview = path,
--     }
--   end
-- end
--
-- function M.show_grep_picker(opts)
--   opts = opts or {}
--
--   -- notebook path
--   local root = require("zk.util").resolve_notebook_path(0)
--
--   require("zk.api").list(root, { select = { "title", "absPath" } }, function(err, notes)
--     if err then
--       vim.notify("zk list failed", vim.log.levels.ERROR)
--       return
--     end
--
--     local notes_by_path = index_notes_by_path(notes)
--
--     fzf.live_grep({
--       prompt = "ZkGrep ❯ ",
--       fzf_opts = with_nth(),
--       previewer = previewer(),
--       -- grep 出力を transform
--       fn_transform = function(lines)
--         local out = {}
--         for _, line in ipairs(lines) do
--           local entry = make_entry(line, notes_by_path)
--           if entry then
--             table.insert(out, entry)
--           end
--         end
--         return out
--       end,
--       -- 選択時：path だけ抜く
--       actions = {
--         ["default"] = function(selected)
--           for _, line in ipairs(selected) do
--             local path = line:match("^(.-)" .. DELIM)
--             vim.cmd("edit " .. fzf.shell.escape(path))
--           end
--         end,
--       },
--     })
--   end)
-- end

return M
