CE_pkg = CE_pkg or {}

do
------------------------------------------------------------------------------
--------------------------- Globals Setup & Memory ---------------------------

  ---@param init_alloc_size Address
  ---@param map_name string
  local function SetupMemory(init_alloc_size, map_name)
    if map_name == nil then map_name = "index_map" end
    do
      local address = getAddressSafe(map_name)
      if address ~= nil then
        deAlloc(address)
        unregisterSymbol(map_name)
      end
      address = allocateMemory(init_alloc_size)
      registerSymbol(map_name, address, true)
    end
  end

  ---@param map_name string
  ---@param block_maps table<string, Address>
  ---@param extend_memory Address
  local function SetupMemoryFromMap(map_name, block_maps, extend_memory)
    if map_name == nil then map_name = "index_map" end
    do
      local address = getAddressSafe(map_name)
      if address ~= nil then
        deAlloc(address)
        unregisterSymbol(map_name)
      end

      local total = 0
      for id, block_size in pairs(block_maps) do
        total = total + math.abs(block_size)
        address = getAddressSafe(id)
        if address ~= nil then
          if DEBUG_DUNG then
            printf(
              "Unregistering symbol: \"%s\"  at address: %x - offset %d",
              id, address, total
            )
          end
          unregisterSymbol(id)
        end
      end
      total = math.min(2147483647, math.max(0, total + extend_memory))
      address = allocateMemory(total)

      registerSymbol(map_name, address, true)
      local tally = 0
      for id, block_size in pairs(block_maps) do
        registerSymbol(id, address + tally, true)
        if DEBUG_DUNG then
          printf(
            "Registering symbol: \"%s\"  at address: %x",
            id, address + tally
          )
        end
        tally = tally + math.abs(block_size)
      end
    end
  end

  CE_pkg.memory_allocs = {
    SetupMemory = SetupMemory,
    SetupMemoryFromMap = SetupMemoryFromMap
  }
end
