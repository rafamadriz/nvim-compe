local Debug = require'compe.utils.debug'
local Async = require'compe.utils.async'
local Cache = require'compe.utils.cache'
local String = require'compe.utils.string'
local Config = require'compe.config'
local Context = require'compe.context'
local Matcher = require'compe.matcher'
local VimBridge = require'compe.vim_bridge'

local Completion = {}

Completion._get_sources_cache_key = 0
Completion._sources = {}
Completion._context = Context.new_empty()
Completion._current_offset = 0
Completion._current_items = {}
Completion._selected_item = nil
Completion._history = {}

--- register_source
Completion.register_source = function(source)
  Completion._sources[source.id] = source
  Completion._get_sources_cache_key = Completion._get_sources_cache_key + 1
end

--- unregister_source
Completion.unregister_source = function(id)
  Completion._sources[id] = nil
  Completion._get_sources_cache_key = Completion._get_sources_cache_key + 1
end

--- get_sources
Completion.get_sources = function()
  return Cache.ensure('Completion.get_sources', Completion._get_sources_cache_key, function()
    local sources = {}
    for _, source in pairs(Completion._sources) do
      if Config.is_source_enabled(source.name) then
        table.insert(sources, source)
      end
    end

    table.sort(sources, function(source1, source2)
      local meta1 = source1:get_metadata()
      local meta2 = source2:get_metadata()
      if meta1.priority ~= meta2.priority then
        return meta1.priority > meta2.priority
      end
    end)

    return sources
  end)
end

--- enter_insert
Completion.enter_insert = function()
  Completion.close()
  Completion._get_sources_cache_key = Completion._get_sources_cache_key + 1
end

--- leave_insert
Completion.leave_insert = function()
  Completion.close()
  Completion._get_sources_cache_key = Completion._get_sources_cache_key + 1
end

--- confirm
Completion.confirm = function()
  local completed_item = Completion._selected_item
  if completed_item then
    Completion._history[completed_item.abbr] = Completion._history[completed_item.abbr] or 0
    Completion._history[completed_item.abbr] = Completion._history[completed_item.abbr] + 1

    for _, source in ipairs(Completion.get_sources()) do
      if source.id == completed_item.source_id then
        source:confirm(completed_item)
        break
      end
    end
  end

  Completion.close()
end

--- select
Completion.select = function(args)
  local completed_item = Completion._current_items[(args.index == -2 and 0 or args.index) + 1]
  if completed_item then
    Completion._selected_item = completed_item

    if args.documentation and Config.get().documentation then
      for _, source in ipairs(Completion.get_sources()) do
        if source.id == completed_item.source_id then
          source:documentation(completed_item)
          break
        end
      end
    end
  end
end

--- close
Completion.close = function()
  for _, source in ipairs(Completion.get_sources()) do
    source:clear()
  end

  VimBridge.clear()
  vim.call('compe#documentation#close')
  Completion._show(0, {})
  Completion._context = Context.new({})
  Completion._selected_item = nil
end

--- complete
Completion.complete = function(manual)
  if Completion:_should_ignore() then
    Async.throttle('display:filter', 0, function() end)
    return
  end

  -- Check the new context should be completed.
  local context = Context.new({ manual = manual })

  -- Restore pum (sometimes vim closes pum automatically).
  local is_completing = Completion._is_completing(context)
  if is_completing and vim.call('pumvisible') == 0 then
    Completion._show(Completion._current_offset, Completion._current_items)
  end

  local is_manual_completing = is_completing and not Config.get().autocomplete
  if context.manual or is_manual_completing or Completion._context:should_auto_complete(context) then
    if not Completion._trigger(context) then
      Completion._display(context)
    end
  else
    vim.call('compe#documentation#close')
  end
  Completion._context = context
end

--- _trigger
Completion._trigger = function(context)
  if Completion:_should_ignore() then
    return false
  end

  local trigger = false
  for _, source in ipairs(Completion.get_sources()) do
    local status, value = pcall(function()
      trigger = source:trigger(context, function()
          Completion._display(Context.new({}))
      end) or trigger
    end)
    if not status then
      Debug.log(value)
    end
  end
  return trigger
end

--- _display
Completion._display = function(context)
  if Completion:_should_ignore() then
    Async.throttle('display:filter', 0, function() end)
    return false
  end

  -- Check for processing source.
  local sources = {}
  Async.debounce('display:processing', 0, function() end)
  for _, source in ipairs(Completion.get_sources()) do
    if source.status == 'processing' then
      local processing_timeout = Config.get().source_timeout - source:get_processing_time()
      if processing_timeout > 0 then
        Async.debounce('display:processing', processing_timeout + 1, function()
          Completion._display(context)
        end)
        return
      end
    elseif source.status == 'completed' then
      table.insert(sources, source)
    end
  end

  local start_offset = Completion._get_start_offset(context)

  -- Gather items and determine start_offset
  local timeout = Completion._is_completing(context) and Config.get().throttle_time or 1
  Async.throttle('display:filter', timeout, function()
    if Completion:_should_ignore() then
      return false
    end

    if start_offset ~= Completion._get_start_offset(context) then
      return
    end

    local items = {}
    local items_uniq = {}
    for _, source in ipairs(sources) do
      local source_items = source:get_filtered_items(context)
      local source_start_offset = source:get_start_offset()
      if #source_items > 0 then
        local gap = string.sub(context.before_line, start_offset, source_start_offset - 1)
        for _, item in ipairs(source_items) do
          if items_uniq[item.original_word] == nil or item.original_dup == 1 then
            items_uniq[item.original_word] = true
            item.word = gap .. item.original_word
            item.abbr = string.rep(' ', #gap) .. item.original_abbr
            item.kind = item.original_kind or ''
            item.menu = item.original_menu or ''

            -- trim to specified width.
            item.abbr = String.trim(item.abbr, Config.get().max_abbr_width)
            item.kind = String.trim(item.kind, Config.get().max_kind_width)
            item.menu = String.trim(item.menu, Config.get().max_menu_width)
            table.insert(items, item)
          end
        end
        if source.is_triggered_by_character then
          break
        end
      end
    end

    --- Sort items
    table.sort(items, function(item1, item2)
      return Matcher.compare(item1, item2, Completion._history)
    end)

    if #items == 0 then
      Completion._show(0, {})
    else
      Completion._show(start_offset, items)
    end
  end)
end

--- _show
Completion._show = function(start_offset, items)
  Async.fast_schedule(function()
    if Completion:_should_ignore() then
      return
    end

    Completion._current_offset = start_offset
    Completion._current_items = items

    local pumvisible = vim.call('pumvisible') == 1
    if not (not pumvisible and #items == 0) then
      local should_preselect = false
      if items[1] then
        should_preselect = should_preselect or (Config.get().preselect == 'enable' and items[1].preselect)
        should_preselect = should_preselect or (Config.get().preselect == 'always')
      end

      local completeopt = vim.o.completeopt
      if should_preselect then
        vim.cmd('set completeopt=menuone,noinsert')
      else
        vim.cmd('set completeopt=menuone,noselect')
      end
      vim.call('complete', math.max(1, start_offset), items) -- start_offset=0 should close pum with `complete(1, [])`
      vim.cmd('set completeopt=' .. completeopt)

      if not pumvisible and should_preselect then
        Completion.select({
          index = 0,
          documentation = true
        })
      end
    end

    -- close documentation if needed.
    if start_offset == 0 or #items == 0 then
      vim.call('compe#documentation#close')
    end
  end)
end

--- _should_ignore
Completion._should_ignore = function()
  local should_ignore = false
  should_ignore = should_ignore or vim.call('compe#_is_selected_manually')
  should_ignore = should_ignore or string.sub(vim.call('mode'), 1, 1) ~= 'i'
  should_ignore = should_ignore or vim.call('getbufvar', '%', '&buftype') == 'prompt'
  return should_ignore
end

--- _get_start_offset
Completion._get_start_offset = function(context)
  local start_offset = context.col
  for _, source in ipairs(Completion.get_sources()) do
    if source.status == 'completed' then
      start_offset = math.min(start_offset, source:get_start_offset())
    end
  end
  return start_offset
end

--- _is_completing
Completion._is_completing = function(context)
  for _, source in ipairs(Completion.get_sources()) do
    if source.status == 'completed' then
      if #source:get_filtered_items(context) ~= 0 then
        return true
      end
    end
  end
  return false
end

return Completion

