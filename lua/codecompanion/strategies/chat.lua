local adapters = require("codecompanion.adapters")
local client = require("codecompanion.http")
local config = require("codecompanion.config")
local keymaps = require("codecompanion.utils.keymaps")
local schema = require("codecompanion.schema")

local hash = require("codecompanion.utils.hash")
local log = require("codecompanion.utils.log")
local ui = require("codecompanion.utils.ui")
local util = require("codecompanion.utils.util")
local yaml = require("codecompanion.utils.yaml")

local api = vim.api

local CONSTANTS = {
  NS_HEADER = "CodeCompanion-headers",
  NS_INTRO = "CodeCompanion-intro_message",
  NS_TOKENS = "CodeCompanion-tokens",
  NS_VIRTUAL_TEXT = "CodeCompanion-virtual_text",

  AUTOCMD_GROUP = "codecompanion.chat",

  STATUS_ERROR = "error",
  STATUS_SUCCESS = "success",

  BLANK_DESC = "[No messages]",
}

local llm_role = config.strategies.chat.roles.llm
local user_role = config.strategies.chat.roles.user

---@param bufnr integer
---@return nil
local function lock_buf(bufnr)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
end

---@param bufnr integer
---@return nil
local function unlock_buf(bufnr)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = true
end

---Make an id from a string or table
---@param val string|table
---@return number
local function make_id(val)
  return hash.hash(val)
end

local _cached_settings = {}

---Parse the chat buffer for settings
---@param bufnr integer
---@param adapter? CodeCompanion.Adapter
---@param ts_query? string
---@return table
local function buf_parse_settings(bufnr, adapter, ts_query)
  if _cached_settings[bufnr] then
    return _cached_settings[bufnr]
  end

  -- If the user has disabled settings in the chat buffer, use the default settings
  if not config.display.chat.show_settings then
    if adapter then
      _cached_settings[bufnr] = adapter:get_default_settings()

      return _cached_settings[bufnr]
    end
  end

  local settings = {}
  local parser = vim.treesitter.get_parser(bufnr, "yaml", { ignore_injections = false })
  local query = vim.treesitter.query.get("yaml", "chat")
  local root = parser:parse()[1]:root()

  for _, match in query:iter_matches(root, bufnr, nil, nil, { all = false }) do
    local value = vim.treesitter.get_node_text(match[1], bufnr)

    settings = yaml.decode(value)
    break
  end

  if not settings then
    log:error("Failed to parse settings in chat buffer")
    return {}
  end

  return settings
end

---Parse the chat buffer for the last message
---@param bufnr integer
---@return table{content: string}
local function buf_parse_message(bufnr)
  local parser = vim.treesitter.get_parser(bufnr, "markdown")
  local query = vim.treesitter.query.get("markdown", "chat")

  local tree = parser:parse()[1]
  local root = tree:root()

  local last_section = nil
  local contents = {}

  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    if query.captures[id] == "content" then
      last_section = node
      contents = {}
    elseif query.captures[id] == "text" and last_section then
      table.insert(contents, vim.treesitter.get_node_text(node, bufnr))
    end
  end

  if #contents > 0 then
    return { content = vim.trim(table.concat(contents, "\n\n")) }
  end

  return {}
end

---Parse the chat buffer for a code block
---returns the code block that the cursor is in or the last code block
---@param bufnr integer
---@param cursor? table
---@return TSNode | nil
local function buf_find_codeblock(bufnr, cursor)
  local parser = vim.treesitter.get_parser(bufnr, "markdown")
  local root = parser:parse()[1]:root()
  local query = vim.treesitter.query.get("markdown", "chat")
  if query == nil then
    return nil
  end

  local last_match = nil
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    if query.captures[id] == "code" then
      if cursor then
        local start_row, start_col, end_row, end_col = node:range()
        if cursor[1] >= start_row and cursor[1] <= end_row and cursor[2] >= start_col and cursor[2] <= end_col then
          return node
        end
      end
      last_match = node
    end
  end

  return last_match
end

---@class CodeCompanion.Chat
---@return nil
local function buf_parse_tools(chat)
  local assistant_parser = vim.treesitter.get_parser(chat.bufnr, "markdown")
  local assistant_query = vim.treesitter.query.parse(
    "markdown",
    string.format(
      [[
(
  (section
    (atx_heading) @heading
    (#match? @heading "## %s")
  ) @content
)
  ]],
      llm_role
    )
  )
  local assistant_tree = assistant_parser:parse()[1]

  local llm = {}
  for id, node in assistant_query:iter_captures(assistant_tree:root(), chat.bufnr, 0, -1) do
    local name = assistant_query.captures[id]
    if name == "content" then
      local response = vim.treesitter.get_node_text(node, chat.bufnr)
      table.insert(llm, response)
    end
  end

  -- Only work with the last response from the LLM
  local response = llm[#llm]

  local parser = vim.treesitter.get_string_parser(response, "markdown")
  local tree = parser:parse()[1]
  local query = vim.treesitter.query.parse(
    "markdown",
    [[(
 (section
  (fenced_code_block
    (info_string) @lang
    (code_fence_content) @tool
  ) (#match? @lang "xml"))
)
]]
  )

  local tools = {}
  for id, node in query:iter_captures(tree:root(), response, 0, -1) do
    local name = query.captures[id]
    if name == "tool" then
      local tool = vim.treesitter.get_node_text(node, response)
      table.insert(tools, tool)
    end
  end

  log:debug("Tool detected: %s", tools)

  if not vim.tbl_isempty(tools) then
    vim.iter(tools):each(function(t)
      return chat.tools:setup(chat, t)
    end)
  end
end

---Used to store all of the open chat buffers
---@type table<CodeCompanion.Chat>
local chatmap = {}

---Used to record the last chat buffer that was opened
---@type CodeCompanion.Chat|nil
local last_chat = {}

---@class CodeCompanion.Chat
local Chat = {}

---@param args CodeCompanion.ChatArgs
function Chat.new(args)
  local id = math.random(10000000)
  log:trace("Chat created with ID %d", id)

  local self = setmetatable({
    opts = args,
    context = args.context,
    cycle = 0,
    header_ns = api.nvim_create_namespace(CONSTANTS.NS_HEADER),
    id = id,
    last_role = args.last_role or config.constants.USER_ROLE,
    messages = args.messages or {},
    refs = {},
    status = "",
    subscribers = {},
    tokens = args.tokens,
    tools_in_use = {},
    create_buf = function()
      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_name(bufnr, string.format("[CodeCompanion] %d", id))
      vim.bo[bufnr].filetype = "codecompanion"

      return bufnr
    end,
  }, { __index = Chat })

  self.bufnr = self.create_buf()
  self.aug = api.nvim_create_augroup(CONSTANTS.AUTOCMD_GROUP .. ":" .. self.bufnr, {
    clear = false,
  })
  self.References = require("codecompanion.strategies.chat.references").new(self)
  self.tools = require("codecompanion.strategies.chat.tools").new({ bufnr = self.bufnr, messages = self.messages })
  self.variables = require("codecompanion.strategies.chat.variables").new()

  table.insert(chatmap, {
    name = "Chat " .. #chatmap + 1,
    description = CONSTANTS.BLANK_DESC,
    strategy = "chat",
    chat = self,
  })

  self.adapter = adapters.resolve(self.opts.adapter)
  if not self.adapter then
    return log:error("No adapter found")
  end
  util.fire("ChatAdapter", { bufnr = self.bufnr, adapter = self.adapter })
  util.fire("ChatModel", { bufnr = self.bufnr, model = self.adapter.schema.model.default })
  self:apply_settings(self.opts.settings)

  self.close_last_chat()
  self:open():render():set_system_prompt():set_extmarks():set_autocmds()

  if self.opts.auto_submit then
    self:submit()
  end

  last_chat = self
  return self
end

---Apply custom settings to the chat buffer
---@param settings table
---@return self
function Chat:apply_settings(settings)
  _cached_settings = {}
  self.settings = settings or schema.get_default(self.adapter.schema, self.opts.settings)

  return self
end

---Set a model in the chat buffer
---@param model string
---@return self
function Chat:apply_model(model)
  if _cached_settings[self.bufnr] then
    _cached_settings[self.bufnr].model = model
  end

  self.adapter.schema.model.default = model

  return self
end

---Open/create the chat window
---@return CodeCompanion.Chat|nil
function Chat:open()
  if self:is_visible() then
    return
  end
  if config.display.chat.start_in_insert_mode then
    vim.cmd("startinsert")
  end

  local window = config.display.chat.window
  local width = window.width > 1 and window.width or math.floor(vim.o.columns * window.width)
  local height = window.height > 1 and window.height or math.floor(vim.o.lines * window.height)

  if window.layout == "float" then
    local win_opts = {
      relative = window.relative,
      width = width,
      height = height,
      row = window.row or math.floor((vim.o.lines - height) / 2),
      col = window.col or math.floor((vim.o.columns - width) / 2),
      border = window.border,
      title = "Code Companion",
      title_pos = "center",
      zindex = 45,
    }
    self.winnr = api.nvim_open_win(self.bufnr, true, win_opts)
  elseif window.layout == "vertical" then
    local cmd = "vsplit"
    if width ~= 0 then
      cmd = width .. cmd
    end
    vim.cmd(cmd)
    self.winnr = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.winnr, self.bufnr)
  elseif window.layout == "horizontal" then
    local cmd = "split"
    if height ~= 0 then
      cmd = height .. cmd
    end
    vim.cmd(cmd)
    self.winnr = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.winnr, self.bufnr)
  else
    self.winnr = api.nvim_get_current_win()
    api.nvim_set_current_buf(self.bufnr)
  end

  ui.set_win_options(self.winnr, window.opts)
  vim.bo[self.bufnr].textwidth = 0
  self:follow()

  if config.strategies.chat.keymaps then
    keymaps.set(config.strategies.chat.keymaps, self.bufnr, self)
  end

  log:trace("Chat opened with ID %d", self.id)

  return self
end

---Format the header in the chat buffer
---@param tbl table containing the buffer contents
---@param role string The role of the user to display in the header
---@return nil
local function format_header(tbl, role)
  if config.display.chat.show_header_separator then
    table.insert(tbl, string.format("## %s %s", role, config.display.chat.separator))
  else
    table.insert(tbl, string.format("## %s", role))
  end
  table.insert(tbl, "")
end

---Render the settings and any messages in the chat buffer
---@return self
function Chat:render()
  local lines = {}

  local function spacer()
    table.insert(lines, "")
  end

  -- Prevent duplicate headers
  local last_set_role

  local function add_messages_to_buf(msgs)
    for i, msg in ipairs(msgs) do
      if msg.role ~= config.constants.SYSTEM_ROLE or (msg.opts and msg.opts.visible ~= false) then
        if i > 1 and self.last_role ~= msg.role then
          spacer()
        end

        if msg.role == config.constants.USER_ROLE and last_set_role ~= config.constants.USER_ROLE then
          format_header(lines, user_role)
        end
        if msg.role == config.constants.LLM_ROLE and last_set_role ~= config.constants.LLM_ROLE then
          format_header(lines, llm_role)
        end

        for _, text in ipairs(vim.split(msg.content, "\n", { plain = true, trimempty = true })) do
          table.insert(lines, text)
        end

        last_set_role = msg.role
        self.last_role = msg.role

        -- The Chat:Submit method will parse the last message and it to the messages table
        if i == #msgs then
          table.remove(msgs, i)
        end
      end
    end
  end

  if config.display.chat.show_settings then
    log:trace("Showing chat settings")
    lines = { "---" }
    local keys = schema.get_ordered_keys(self.adapter.schema)
    for _, key in ipairs(keys) do
      local setting = self.settings[key]
      if type(setting) == "function" then
        setting = setting(self.adapter)
      end

      table.insert(lines, string.format("%s: %s", key, yaml.encode(setting)))
    end
    table.insert(lines, "---")
    spacer()
  end

  if vim.tbl_isempty(self.messages) then
    log:trace("Setting the header for the chat buffer")
    format_header(lines, user_role)
    spacer()
  else
    log:trace("Setting the messages in the chat buffer")
    add_messages_to_buf(self.messages)
  end

  -- If the user has visually selected some text, add that to the chat buffer
  if self.context and self.context.is_visual and not self.opts.stop_context_insertion then
    log:trace("Adding visual selection to chat buffer")
    table.insert(lines, "```" .. self.context.filetype)
    for _, line in ipairs(self.context.lines) do
      table.insert(lines, line)
    end
    table.insert(lines, "```")
  end

  unlock_buf(self.bufnr)
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  self:render_headers()

  self:follow()

  return self
end

---Set the autocmds for the chat buffer
---@return nil
function Chat:set_autocmds()
  local bufnr = self.bufnr

  if config.display.chat.show_settings then
    api.nvim_create_autocmd("CursorMoved", {
      group = self.aug,
      buffer = bufnr,
      desc = "Show settings information in the CodeCompanion chat buffer",
      callback = function()
        self:on_cursor_moved()
      end,
    })

    -- Validate the settings
    api.nvim_create_autocmd("InsertLeave", {
      group = self.aug,
      buffer = bufnr,
      desc = "Parse the settings in the CodeCompanion chat buffer for any errors",
      callback = function()
        local settings = buf_parse_settings(bufnr, self.adapter, [[((stream (_)) @block)]])

        local errors = schema.validate(self.adapter.schema, settings, self.adapter)
        local node = settings.__ts_node

        local items = {}
        if errors and node then
          for child in node:iter_children() do
            assert(child:type() == "block_mapping_pair")
            local key = vim.treesitter.get_node_text(child:named_child(0), bufnr)
            if errors[key] then
              local lnum, col, end_lnum, end_col = child:range()
              table.insert(items, {
                lnum = lnum,
                col = col,
                end_lnum = end_lnum,
                end_col = end_col,
                severity = vim.diagnostic.severity.ERROR,
                message = errors[key],
              })
            end
          end
        end
        vim.diagnostic.set(config.ERROR_NS, bufnr, items)
      end,
    })
  end

  api.nvim_create_autocmd("InsertEnter", {
    group = self.aug,
    buffer = bufnr,
    once = true,
    desc = "Clear the virtual text in the CodeCompanion chat buffer",
    callback = function()
      local ns_id = api.nvim_create_namespace(CONSTANTS.NS_VIRTUAL_TEXT)
      api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    end,
  })

  api.nvim_create_autocmd("BufEnter", {
    group = self.aug,
    buffer = bufnr,
    desc = "Log the most recent chat buffer",
    callback = function()
      last_chat = self
    end,
  })
end

---Set any extmarks in the chat buffer
---@return CodeCompanion.Chat|nil
function Chat:set_extmarks()
  if self.intro_message or (self.opts.messages and #self.opts.messages > 0) then
    return self
  end

  -- Welcome message
  if not config.display.chat.start_in_insert_mode then
    local ns_intro = api.nvim_create_namespace(CONSTANTS.NS_INTRO)
    local id = api.nvim_buf_set_extmark(self.bufnr, ns_intro, api.nvim_buf_line_count(self.bufnr) - 1, 0, {
      virt_text = { { config.display.chat.intro_message, "CodeCompanionVirtualText" } },
      virt_text_pos = "eol",
    })
    api.nvim_create_autocmd("InsertEnter", {
      buffer = self.bufnr,
      callback = function()
        api.nvim_buf_del_extmark(self.bufnr, ns_intro, id)
      end,
    })
    self.intro_message = true
  end

  return self
end

---Render the headers in the chat buffer and apply extmarks
---@return nil
function Chat:render_headers()
  if not config.display.chat.show_header_separator then
    return
  end

  local separator = config.display.chat.separator
  local lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)

  for line, content in ipairs(lines) do
    if content:match("^## " .. user_role) or content:match("^## " .. llm_role) then
      local col = vim.fn.strwidth(content) - vim.fn.strwidth(separator)

      api.nvim_buf_set_extmark(self.bufnr, self.header_ns, line - 1, col, {
        virt_text_win_col = col,
        virt_text = { { string.rep(separator, vim.go.columns), "CodeCompanionChatSeparator" } },
        priority = 100,
      })

      -- Set the highlight group for the header
      api.nvim_buf_set_extmark(self.bufnr, self.header_ns, line - 1, 0, {
        end_col = col + 1,
        hl_group = "CodeCompanionChatHeader",
      })
    end
  end
  log:trace("Rendering headers in the chat buffer")
end

---Set the system prompt in the chat buffer
---@return CodeCompanion.Chat
function Chat:set_system_prompt()
  local prompt = config.opts.system_prompt
  if prompt ~= "" then
    if type(prompt) == "function" then
      prompt = prompt({
        adapter = self.adapter,
        language = config.opts.language,
      })
    end

    local system_prompt = {
      role = config.constants.SYSTEM_ROLE,
      content = prompt,
    }
    system_prompt.id = make_id(system_prompt)
    system_prompt.opts = { visible = false }
    table.insert(self.messages, 1, system_prompt)
  end
  return self
end

---Toggle the system prompt in the chat buffer
---@return nil
function Chat:toggle_system_prompt()
  if self.messages[1] and self.messages[1].role == config.constants.SYSTEM_ROLE then
    util.notify("Removed system prompt")
    table.remove(self.messages, 1)
  else
    util.notify("Added system prompt")
    self:set_system_prompt()
  end
end

---Get the settings key at the current cursor position
---@param opts? table
function Chat:_get_settings_key(opts)
  opts = vim.tbl_extend("force", opts or {}, {
    lang = "yaml",
    ignore_injections = false,
  })
  local node = vim.treesitter.get_node(opts)
  while node and node:type() ~= "block_mapping_pair" do
    node = node:parent()
  end
  if not node then
    return
  end
  local key_node = node:named_child(0)
  local key_name = vim.treesitter.get_node_text(key_node, self.bufnr)
  return key_name, node
end

---Actions to take when the cursor moves in the chat buffer
---Used to show the LLM settings at the top of the buffer
---@return nil
function Chat:on_cursor_moved()
  local key_name, node = self:_get_settings_key()
  if not key_name or not node then
    vim.diagnostic.set(config.INFO_NS, self.bufnr, {})
    return
  end

  local key_schema = self.adapter.schema[key_name]
  if key_schema and key_schema.desc then
    local lnum, col, end_lnum, end_col = node:range()
    local diagnostic = {
      lnum = lnum,
      col = col,
      end_lnum = end_lnum,
      end_col = end_col,
      severity = vim.diagnostic.severity.INFO,
      message = key_schema.desc,
    }
    vim.diagnostic.set(config.INFO_NS, self.bufnr, { diagnostic })
  end
end

---Parse the last message for any variables
---@param message table
---@return CodeCompanion.Chat
function Chat:parse_msg_for_vars(message)
  local vars = self.variables:parse(self, message)

  if vars then
    message.content = self.variables:replace(message.content)
    message.id = make_id({ role = message.role, content = message.content })
    self:add_message(
      { role = config.constants.USER_ROLE, content = message.content },
      { visible = false, tag = "variable" }
    )
  end

  return self
end

---Add the given tool to the chat buffer
---@param tool table The tool from the config
---@return CodeCompanion.Chat
function Chat:add_tool(tool)
  if self.tools_in_use[tool] then
    return self
  end

  -- Add the overarching agent system prompt first
  if not self:has_tools() then
    self:add_message({
      role = config.constants.SYSTEM_ROLE,
      content = config.strategies.agent.tools.opts.system_prompt,
    }, { visible = false, tag = "tool" })
  end

  self.tools_in_use[tool] = true

  local resolved = self.tools.resolve(tool)
  if resolved then
    self:add_message(
      { role = config.constants.SYSTEM_ROLE, content = resolved.system_prompt(resolved.schema) },
      { visible = false, tag = "tool" }
    )
  end

  util.fire("ChatToolAdded", { bufnr = self.bufnr, tool = tool })

  return self
end

---Add the given variable to the chat buffer
---@param var table The var from the config
---@return CodeCompanion.Chat
function Chat:add_variable(var)
  self:add_message({ role = config.constants.USER_ROLE, content = var }, { visible = false, tag = "variable" })

  return self
end

---Add a message to the message table
---@param data table {role: string, content: string}
---@param opts? table Options for the message
---@return CodeCompanion.Chat
function Chat:add_message(data, opts)
  opts = opts or { visible = true }
  if opts.visible == nil then
    opts.visible = true
  end

  local message = {
    role = data.role,
    content = data.content,
  }
  message.id = make_id(message)
  message.opts = opts
  if opts.index then
    table.insert(self.messages, opts.index, message)
  else
    table.insert(self.messages, message)
  end

  return self
end

---Apply any tools or variables that a user has tagged in their message
---@param message table
---@return nil
function Chat:apply_tools_and_variables(message)
  if self.tools:parse(self, message) then
    message.content = self.tools:replace(message.content)
  end
  if self.variables:parse(self, message) then
    message.content = self.variables:replace(message.content)
  end
end

---Are there any user messages in the chat buffer?
---@param message table
---@return boolean
function Chat:has_user_messages(message)
  if vim.tbl_isempty(message) then
    local has_user_messages = vim
      .iter(self.messages)
      :filter(function(msg)
        return msg.role == config.constants.USER_ROLE
      end)
      :totable()

    if #has_user_messages == 0 then
      return false
    end
  end
  return true
end

---Submit the chat buffer's contents to the LLM
---@param opts? table
---@return nil
function Chat:submit(opts)
  opts = opts or {}

  local bufnr = self.bufnr

  local message = buf_parse_message(bufnr)
  if not self:has_user_messages(message) then
    return log:warn("No messages to submit")
  end

  --- Only send the user's last message if we're not regenerating the response
  if not opts.regenerate and not vim.tbl_isempty(message) then
    self:add_message({ role = config.constants.USER_ROLE, content = message.content })
  end
  message = self.References:clear(self.messages[#self.messages])

  self:apply_tools_and_variables(message)

  -- Check if the user has manually overriden the adapter. This is useful if the
  -- user loses their internet connection and wants to switch to a local LLM
  if vim.g.codecompanion_adapter and self.adapter.name ~= vim.g.codecompanion_adapter then
    self.adapter = adapters.resolve(config.adapters[vim.g.codecompanion_adapter])
  end

  local settings = buf_parse_settings(bufnr, self.adapter)
  settings = self.adapter:map_schema_to_params(settings)

  log:debug("Settings:\n%s", settings)
  log:debug("Messages:\n%s", self.messages)
  log:info("Chat request started")

  lock_buf(bufnr)
  self.cycle = self.cycle + 1
  self.current_request = client
    .new({ adapter = settings })
    :request(self.adapter:map_roles(vim.deepcopy(self.messages)), {
      ---@param err string
      ---@param data table
      callback = function(err, data)
        if err then
          self.status = CONSTANTS.STATUS_ERROR
          return self:done()
        end

        if data then
          self:get_tokens(data)

          local result = self.adapter.handlers.chat_output(self.adapter, data)
          if result and result.status == CONSTANTS.STATUS_SUCCESS then
            if result.output.role then
              result.output.role = config.constants.LLM_ROLE
            end
            self.status = CONSTANTS.STATUS_SUCCESS
            self:add_buf_message(result.output)
          end
        end
      end,
      done = function()
        self:done()
      end,
    }, { bufnr = bufnr })
end

---After the response from the LLM is received...
---@return nil
function Chat:done()
  self.current_request = nil
  self:add_message({ role = config.constants.LLM_ROLE, content = buf_parse_message(self.bufnr).content })

  self:add_buf_message({ role = config.constants.USER_ROLE, content = "" })
  self.References:render()
  self:display_tokens()

  if self.status == CONSTANTS.STATUS_SUCCESS and self:has_tools() then
    buf_parse_tools(self)
  end

  log:info("Chat request completed")
  self:reset()

  if self.has_subscribers then
    local function action_subscription(subscriber)
      subscriber.callback(self)
      if subscriber.type == "once" then
        self:unsubscribe(subscriber.id)
      end
    end

    vim.iter(self.subscribers):each(function(subscriber)
      if subscriber.order and subscriber.order <= self.cycle then
        action_subscription(subscriber)
      elseif not subscriber.order then
        action_subscription(subscriber)
      end
    end)
  end
end

---Regenerate the response from the LLM
---@return nil
function Chat:regenerate()
  if self.messages[#self.messages].role == config.constants.LLM_ROLE then
    table.remove(self.messages, #self.messages)
    self:add_buf_message({ role = config.constants.USER_ROLE, content = "_Regenerating response..._" })
    self:submit({ regenerate = true })
  end
end

---Stop streaming the response from the LLM
---@return nil
function Chat:stop()
  local job
  if self.current_tool then
    job = self.current_tool
    self.current_tool = nil

    _G.codecompanion_cancel_tool = true
    job:shutdown()
  end
  if self.current_request then
    job = self.current_request
    self.current_request = nil
    if job then
      job:shutdown()
    end
  end
end

---Determine if the current chat buffer is active
---@return boolean
function Chat:is_active()
  return api.nvim_get_current_buf() == self.bufnr
end

---Hide the chat buffer from view
---@return nil
function Chat:hide()
  local layout = config.display.chat.window.layout

  if layout == "float" or layout == "vertical" or layout == "horizontal" then
    if self:is_active() then
      vim.cmd("hide")
    else
      api.nvim_win_hide(self.winnr)
    end
  else
    vim.cmd("buffer " .. vim.fn.bufnr("#"))
  end
end

---Close the current chat buffer
---@return nil
function Chat:close()
  if self.current_request then
    self:stop()
  end

  if last_chat and last_chat.bufnr == self.bufnr then
    last_chat = nil
  end

  local index = util.find_key(chatmap, "bufnr", self.bufnr)
  if index then
    table.remove(chatmap, index)
  end

  api.nvim_buf_delete(self.bufnr, { force = true })
  api.nvim_clear_autocmds({ group = self.aug })
  util.fire("ChatClosed", { bufnr = self.bufnr })
  util.fire("ChatAdapter", { bufnr = self.bufnr, adapter = nil })
  util.fire("ChatModel", { bufnr = self.bufnr, model = nil })
  self = nil
end

---Determine if the chat buffer is visible
---@return boolean
function Chat:is_visible()
  return self.winnr and api.nvim_win_is_valid(self.winnr) and api.nvim_win_get_buf(self.winnr) == self.bufnr
end

---Get the last line, column and line count in the chat buffer
---@return integer, integer, integer
function Chat:last()
  local line_count = api.nvim_buf_line_count(self.bufnr)

  local last_line = line_count - 1
  if last_line < 0 then
    return 0, 0, line_count
  end

  local last_line_content = api.nvim_buf_get_lines(self.bufnr, -2, -1, false)
  if not last_line_content or #last_line_content == 0 then
    return last_line, 0, line_count
  end

  local last_column = #last_line_content[1]

  return last_line, last_column, line_count
end

---Add a message directly to the chat buffer. This will be visible to the user
---@param data table
---@param opts? table
function Chat:add_buf_message(data, opts)
  local lines = {}
  local bufnr = self.bufnr
  local new_response = false

  if (data.role and data.role ~= self.last_role) or (opts and opts.force_role) then
    new_response = true
    self.last_role = data.role
    table.insert(lines, "")
    table.insert(lines, "")
    format_header(lines, config.strategies.chat.roles[data.role])
  end

  if data.content then
    for _, text in ipairs(vim.split(data.content, "\n", { plain = true, trimempty = false })) do
      table.insert(lines, text)
    end

    unlock_buf(bufnr)

    local last_line, last_column, line_count = self:last()
    if opts and opts.insert_at then
      last_line = opts.insert_at
      last_column = 0
    end

    local cursor_moved = api.nvim_win_get_cursor(0)[1] == line_count
    api.nvim_buf_set_text(bufnr, last_line, last_column, last_line, last_column, lines)

    if new_response then
      self:render_headers()
    end

    if self.last_role ~= config.constants.USER_ROLE then
      lock_buf(bufnr)
    end

    if cursor_moved and self:is_active() then
      self:follow()
    elseif not self:is_active() then
      self:follow()
    end
  end
end

---Determine if the chat buffer has any tools in use
---@return boolean
function Chat:has_tools()
  return not vim.tbl_isempty(self.tools_in_use)
end

---Follow the cursor in the chat buffer
---@return nil
function Chat:follow()
  if not self:is_visible() then
    return
  end

  local last_line, last_column, line_count = self:last()
  if line_count == 0 then
    return
  end

  api.nvim_win_set_cursor(self.winnr, { last_line + 1, last_column })
end

---When a request has finished, reset the chat buffer
---@return nil
function Chat:reset()
  self.status = ""
  unlock_buf(self.bufnr)
end

---Get the messages from the chat buffer
---@return table
function Chat:get_messages()
  return self.messages
end

---Get the tokens from the adapter
---@param data table
---@return nil
function Chat:get_tokens(data)
  if self.adapter.features.tokens then
    local tokens = self.adapter.handlers.tokens(self.adapter, data)
    if tokens then
      self.tokens = tokens
    end
  end
end

---Display the tokens in the chat buffer
---@return nil
function Chat:display_tokens()
  if config.display.chat.show_token_count and self.tokens then
    local to_display = config.display.chat.token_count
    if type(to_display) == "function" then
      local ns_id = api.nvim_create_namespace(CONSTANTS.NS_TOKENS)
      to_display = to_display(self.tokens, self.adapter)
      require("codecompanion.utils.tokens").display(to_display, ns_id, self.bufnr)
    end
  end
end

---Fold parts of the chat buffer enclosed by a H3 heading
---@param heading string
---@return self
function Chat:fold_heading(heading)
  local parser = vim.treesitter.get_parser(self.bufnr, "markdown")

  local query = vim.treesitter.query.parse(
    "markdown",
    string.format(
      [[
    ((section
      ((atx_heading) @heading)
      (#eq? @heading "### %s")) @content)
  ]],
      heading
    )
  )
  local tree = parser:parse()[1]
  local root = tree:root()

  for _, captures, _ in query:iter_matches(root, self.bufnr, 0, -1, { all = true }) do
    if captures[2] then
      local node = captures[2]
      local start_row, _, end_row, _ = node[1]:range()

      if start_row < end_row then
        vim.wo.foldmethod = "manual"
        api.nvim_buf_call(self.bufnr, function()
          vim.fn.setpos(".", { self.bufnr, start_row + 1, 0, 0 })
          vim.cmd("normal! zf" .. end_row .. "G")
        end)
        self:follow()
      end
    end
  end

  log:trace("Folding H3 header %s", heading)
  return self
end

---Fold code under the user's heading in the chat buffer
---@return self
function Chat:fold_code()
  local query = vim.treesitter.query.parse(
    "markdown",
    [[
(section
(
 (atx_heading
  (atx_h2_marker)
  heading_content: (_) @role
)
([
  (fenced_code_block)
  (indented_code_block)
] @code (#trim! @code))
))
]]
  )

  local parser = vim.treesitter.get_parser(self.bufnr, "markdown")
  local tree = parser:parse()[1]
  vim.o.foldmethod = "manual"

  local role
  for _, matches in query:iter_matches(tree:root(), self.bufnr, nil, nil, { all = false }) do
    local match = {}
    for id, node in pairs(matches) do
      match = vim.tbl_extend("keep", match, {
        [query.captures[id]] = {
          node = node,
        },
      })
    end

    if match.role then
      role = vim.trim(vim.treesitter.get_node_text(match.role.node, self.bufnr))
      if role:match(user_role) and match.code then
        local start_row, _, end_row, _ = match.code.node:range()
        if start_row < end_row then
          api.nvim_buf_call(self.bufnr, function()
            vim.cmd(string.format("%d,%dfold", start_row, end_row))
          end)
        end
      end
    end
  end

  return self
end

---Get currently focused code block or the last one in the chat buffer
---@return TSNode | nil
function Chat:get_codeblock()
  local cursor = api.nvim_win_get_cursor(0)
  return buf_find_codeblock(self.bufnr, cursor)
end

---CodeCompanion models completion source
---@param request table
---@param callback fun(request: table)
---@return nil
function Chat:complete_models(request, callback)
  local items = {}
  local cursor = api.nvim_win_get_cursor(0)
  local key_name, node = self:_get_settings_key({ pos = { cursor[1] - 1, 1 } })
  if not key_name or not node then
    callback({ items = items, isIncomplete = false })
    return
  end

  local key_schema = self.adapter.schema[key_name]
  if key_schema.type == "enum" then
    local choices = key_schema.choices
    if type(choices) == "function" then
      choices = choices(self.adapter)
    end
    for _, choice in ipairs(choices) do
      table.insert(items, {
        label = choice,
        kind = require("cmp").lsp.CompletionItemKind.Keyword,
      })
    end
  end

  callback({ items = items, isIncomplete = false })
end

---Subscribe to a chat buffer
---@param event table {name: string, type: string, callback: fun}
function Chat:subscribe(event)
  table.insert(self.subscribers, event)
end

---Does the chat buffer have any subscribers?
function Chat:has_subscribers()
  return #self.subscribers > 0
end

---Unsubscribe an object from a chat buffer
---@param id integer|string
function Chat:unsubscribe(id)
  for i, subscriber in ipairs(self.subscribers) do
    if subscriber.id == id then
      table.remove(self.subscribers, i)
    end
  end
end

---Clear the chat buffer
---@return nil
function Chat:clear()
  local function clear_ns(ns)
    for _, name in ipairs(ns) do
      local id = api.nvim_create_namespace(name)
      api.nvim_buf_clear_namespace(self.bufnr, id, 0, -1)
    end
  end

  local namespaces = {
    CONSTANTS.NS_HEADER,
    CONSTANTS.NS_INTRO,
    CONSTANTS.NS_TOKENS,
    CONSTANTS.NS_VIRTUAL_TEXT,
  }

  self.messages = {}
  self.tools_in_use = {}
  self.tokens = nil
  clear_ns(namespaces)

  log:trace("Clearing chat buffer")
  self:render():set_system_prompt():set_extmarks()
end

---Display the chat buffer's settings and messages
function Chat:debug()
  if vim.tbl_isempty(self.messages) then
    return
  end

  return buf_parse_settings(self.bufnr, self.adapter), self.messages
end

---Returns the chat object(s) based on the buffer number
---@param bufnr? integer
---@return CodeCompanion.Chat|table
function Chat.buf_get_chat(bufnr)
  if not bufnr then
    return chatmap
  end

  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  return chatmap[util.find_key(chatmap, "bufnr", bufnr)].chat
end

---Returns the last chat that was visible
---@return CodeCompanion.Chat|nil
function Chat.last_chat()
  if not last_chat or vim.tbl_isempty(last_chat) then
    return nil
  end
  return last_chat
end

---Close the last chat buffer
---@return nil
function Chat.close_last_chat()
  if last_chat and not vim.tbl_isempty(last_chat) and last_chat:is_visible() then
    last_chat:hide()
  end
end

return Chat
