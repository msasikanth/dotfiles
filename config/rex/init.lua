-- Rex configuration (~/.config/rex/init.lua)

local state_file = (os.getenv("HOME") or "/tmp") .. "/.config/rex/hidden_floats.json"
local hidden_by_window = {}

local function load_state()
  local f = io.open(state_file, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  if content and content ~= "" then
    local decoded = rex.json.decode(content)
    if type(decoded) == "table" then
      hidden_by_window = decoded
    end
  end
end

local function save_state()
  local encoded = rex.json.encode(hidden_by_window, { indent = true })
  if not encoded then return end
  local f = io.open(state_file, "w")
  if f then
    f:write(encoded)
    f:close()
  end
end

-- Collect blocks and split structure from a layout node
local function serialize_layout(node)
  if not node then return nil end
  if node.block_id then
    return { block_id = node.block_id }
  elseif node.split then
    return {
      direction = node.split.direction,
      ratio = node.split.ratio,
      before = serialize_layout(node.split.before),
      after = serialize_layout(node.split.after),
    }
  end
  return nil
end

local function first_block_id(node)
  if not node then return nil end
  if node.block_id then return node.block_id end
  return first_block_id(node.before) or first_block_id(node.after)
end

-- Restore splits inside a layer after its root block is already floated
local function restore_splits(node)
  if not node or node.block_id then return end
  restore_splits(node.before)
  local anchor = first_block_id(node.before)
  local after_first = first_block_id(node.after)
  if anchor and after_first then
    rex.session.move_block{
      block_id = after_first,
      anchor_block_id = anchor,
      direction = node.direction,
      ratio = node.ratio,
      side = "after",
    }
    restore_splits(node.after)
  end
end

rex.action{
  name = "toggle_floats",
  title = "Toggle Floating Panes",
  description = "Hide or show floating panes in the active window",
  keywords = "float layer hide show toggle",
  run = function(ctx, args)
    load_state()

    local view, err = rex.session.view{}
    if not view then error(err or "failed to get session view", 0) end

    local active_win_id = view.active_window_id
    if not active_win_id or not view.windows then
      return { status = "no_active_window" }
    end

    local active_win = nil
    for _, w in ipairs(view.windows) do
      if w.window_id == active_win_id then
        active_win = w
        break
      end
    end
    if not active_win then
      return { status = "window_not_found" }
    end

    local tiled_anchor_id = nil
    local floating_layers = {}

    for _, layer in ipairs(active_win.layers or {}) do
      if layer.kind == "tiled" then
        if layer.blocks and #layer.blocks > 0 then
          tiled_anchor_id = layer.blocks[1].block_id
        end
      elseif layer.kind == "floating" then
        table.insert(floating_layers, layer)
      end
    end

    -- Case 1: Floating layers are currently visible -> hide them
    if #floating_layers > 0 then
      if not tiled_anchor_id then
        error("Cannot hide floating panes when the window has no tiled pane to keep the window open", 0)
      end

      local saved_layers = {}
      local focused_was_floating = false

      for _, layer in ipairs(floating_layers) do
        local block_ids = {}
        for _, b in ipairs(layer.blocks or {}) do
          table.insert(block_ids, b.block_id)
          if b.block_id == active_win.focused_block_id then
            focused_was_floating = true
          end
        end

        table.insert(saved_layers, {
          bounds = layer.bounds,
          layout = serialize_layout(layer.layout),
          block_ids = block_ids,
        })
      end

      -- Detach all blocks in floating layers
      for _, layer in ipairs(saved_layers) do
        for _, bid in ipairs(layer.block_ids) do
          local _, derr = rex.session.detach_block{ block_id = bid }
          if derr then error(derr, 0) end
        end
      end

      hidden_by_window[active_win_id] = {
        layers = saved_layers,
        focused_block_id = focused_was_floating and active_win.focused_block_id or nil,
        previous_tiled_focus = not focused_was_floating and active_win.focused_block_id or tiled_anchor_id,
      }
      save_state()

      return { status = "hidden", count = #saved_layers }
    end

    -- Case 2: No visible floating layers -> restore hidden ones for this window (or any detached blocks)
    if not tiled_anchor_id then
      error("Cannot restore floating panes without a tiled pane in the active window", 0)
    end

    local all_blocks_res = rex.session.list_blocks{}
    local detached_set = {}
    local detached_list = {}
    if all_blocks_res and all_blocks_res.blocks then
      for _, b in ipairs(all_blocks_res.blocks) do
        if b.placement == "detached" then
          detached_set[b.block_id] = true
          table.insert(detached_list, b.block_id)
        end
      end
    end

    local saved = hidden_by_window[active_win_id]
    local restored_count = 0
    local focus_target = nil

    if saved and saved.layers and #saved.layers > 0 then
      for _, layer_info in ipairs(saved.layers) do
        -- Filter to blocks that still exist and are detached
        local valid_blocks = {}
        for _, bid in ipairs(layer_info.block_ids or {}) do
          if detached_set[bid] then
            table.insert(valid_blocks, bid)
            detached_set[bid] = nil
          end
        end

        if #valid_blocks > 0 then
          local root_bid = (layer_info.layout and first_block_id(layer_info.layout)) or valid_blocks[1]
          if not root_bid then root_bid = valid_blocks[1] end

          local _, merr = rex.session.move_block{
            block_id = root_bid,
            anchor_block_id = tiled_anchor_id,
          }
          if merr then error(merr, 0) end

          local bounds = layer_info.bounds or { 0.15, 0.15, 0.7, 0.7 }
          local _, ferr = rex.session.float_block{
            block_id = root_bid,
            bounds = bounds,
          }
          if ferr then error(ferr, 0) end

          if layer_info.layout and #valid_blocks > 1 then
            restore_splits(layer_info.layout)
          end

          restored_count = restored_count + 1
          focus_target = root_bid
        end
      end

      if saved.focused_block_id then
        focus_target = saved.focused_block_id
      end
      hidden_by_window[active_win_id] = nil
      save_state()
    end

    -- Fallback: if no saved state for this window, restore any detached blocks in the session
    if restored_count == 0 and #detached_list > 0 then
      for _, bid in ipairs(detached_list) do
        if detached_set[bid] then
          local _, merr = rex.session.move_block{
            block_id = bid,
            anchor_block_id = tiled_anchor_id,
          }
          if not merr then
            rex.session.float_block{
              block_id = bid,
              bounds = { 0.15, 0.15, 0.7, 0.7 },
            }
            restored_count = restored_count + 1
            focus_target = bid
          end
        end
      end
    end

    if focus_target then
      rex.session.focus_block{ block_id = focus_target }
    end

    return { status = "shown", count = restored_count }
  end,
}

rex.bind("cmd+\\", "toggle_floats")
