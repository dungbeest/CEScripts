---@param _ Object? # event receiver not used
---@param force boolean # Whether to force compact view
function CycleFullCompact(_, force)
  ---@type boolean  
  local state = not(COMPACT_MENU_ITEM.Caption == 'Compact View Mode')
  if force~=nil then state = not force end
  COMPACT_MENU_ITEM.Caption = state and 'Compact View Mode' or 'Full View Mode'
  local mf = getMainForm()
  mf.Splitter1.Visible = state
  mf.Panel4.Visible = state
  mf.Panel5.Visible = state
end

function AddCompactMenu()
  if COMPACT_MENU_ALREADY_EXISTS then return end
  local parent = getMainForm().Menu.Items
  COMPACT_MENU_ITEM = createMenuItem(parent)
  parent.add(COMPACT_MENU_ITEM)
  COMPACT_MENU_ITEM.Caption = 'Compact View Mode'
  COMPACT_MENU_ITEM.OnClick = CycleFullCompact
  COMPACT_MENU_ALREADY_EXISTS = true
end
