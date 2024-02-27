CE_pkg = CE_pkg or {}

do
------------------------------------------------------------------------------
------------------------------------ Utils -----------------------------------
  local MARKER_DG = 0x10

  ---@class ClassSymbolMap
  ---@field namespace string
  ---@field class_name string


  ---@class ClassAndFieldSymbolMap
  ---@field base_name string
  ---@field fields ClassField[]

  ---@class ClassField
  ---@field name string
  ---@field offset Address


  ---@generic T
  ---@param ... T[]
  ---@return T[]
  local function ConcatArrays(...)
    local t = {}
    local i = 1
    for _, tb in ipairs({...}) do
      for _, el in ipairs(tb) do
        t[i] = el
        i = i + 1
      end
    end
    return t
  end

  ---Creates a unique-ish symbol to register to the CE symbol resolver from a ClassSymbolMap
  ---@param class_map ClassSymbolMap
  ---@param field string? # a field name to add to the end
  ---@param suffixes string[]? # suffixes to add to symbol, separated by an underscore
  local function BuildUniqueSymbolFromClass(class_map, field, suffixes)
    local split = ""
    for match in string.gmatch(class_map.namespace, "[^%.]+") do
      split = split .. (string.match(match, "%w") or "")
    end
    split = "dg_" .. split .. "_" .. class_map.class_name
    if suffixes ~= nil then
      for _, str in ipairs(suffixes) do
        split = split .. "_" .. str
      end
    end
    if field ~= nil then
      split = split .. "." .. field
    end
    return split
  end

  ---Attempts to register the base symbol name for a static class
  ---@param image Address the class' image address
  ---@param class_addr Address? the static class' known class address
  ---@param symbol_name string the symbol to register
  ---@param class_map ClassSymbolMap the map with the class' name and namespace
  local function CheckAndRegisterSymbol(image, class_addr, symbol_name, class_map)
    if class_addr ~= nil and class_addr ~= 0 then
      local static_addr = mono_class_getStaticFieldAddress(class_addr)
      if static_addr ~= nil and static_addr ~= 0 then
        registerSymbol(symbol_name, static_addr-MARKER_DG, true)
        if DEBUG_DUNG then
          printf("Registered %s for address %x", symbol_name, static_addr-MARKER_DG)
        end
      else
        printf(
          "Static field addresses for class %s at namespace %s not found",
          class_map.class_name, class_map.namespace
        )
      end
    else
      printf(
        "Did not find class %s at namespace %s, image %x",
        class_map.class_name, class_map.namespace, image
      )
    end
  end

  ---Takes a MonoClass as resolved by CE's mono functions and replaces inner classes'
  ---name by reconstructing the full name as shown in mono dissect or .net view.
  ---Uses a format "%F+%I+%I.." where %F is the outer class name and %I are each subsequent inner class names
  ---@param class MonoClass the mono class instance
  ---@return MonoClass? # full name of class in format "%F+%I+%I.." where %F is the outer class name and %I are each subsequent inner class names
  local function ResolveInnerClasses(class)
    local nested = class.classname
    local prev_class = class.class
    local nested_parent = mono_class_getNestingType(class.class)
    while nested_parent ~= 0 do
      nested = mono_class_getName(nested_parent) .. "+" .. nested
      prev_class = nested_parent
      nested_parent = mono_class_getNestingType(prev_class)
    end
    local result = nil
    if class.class ~= prev_class then
      result = {
        class = class.class,
        classname = nested,
        namespace = mono_class_getNamespace(prev_class)
      }
      if DEBUG_DUNG then
        printf(
          "ResolveInnerClass - class \"%s\" at namespace \"%s\"",
          result.classname, result.namespace
        )
        printf(
          "ResolveInnerClass - resolved from class \"%s\" at namespace: \"%s\"",
          class.classname, class.namespace
        )
      end
    end
    return result
  end


  ---Converts a bunch of strings in pairs of namespace and class name to proper
  ---ClassSymbolMap for a given mono image.
  ---@param class_pairs string[]
  ---@return ClassSymbolMap[]
  local function ConvertNamespacesToImageClassSymbolMap(class_pairs)
    local ics_map = {}
    for i = 1, #class_pairs, 2 do
      table.insert(ics_map, {
        namespace = class_pairs[i],
        class_name = class_pairs[i+1]
      })
    end
    return ics_map
  end

  ---Replaces a backing field for an artificial property with a more
  ---usable name.
  ---Uses the final format "%B_bk" where %B is the actual property name.
  ---@param field MonoClassField
  ---@return MonoClassField
  local function ReplaceBackingField(field)
    local id_m = "<([%p%w]+)>"
    local bf_m = "[%p%w]+[bB]acking(_?)[fF]ield"
    ---@type integer?
    local bk = string.find(field.name, bf_m)
    if bk ~= nil then
      ---@type string?
      local s = string.match(field.name, id_m)
      if s ~= nil then
        local f_name = s .. "__bk"
        if DEBUG_DUNG then
          printf(
            "ReplaceBackingField - Replacing %s for %s",
            field.name, f_name
          )
        end
        field.name = f_name
      else
        printf(
          "Found backing field but couldn't match: %s",
          field.name
        )
      end
    end
    return field
  end


  ---Generates ClassSymbolMaps for all the commonly used mscorlib types
  ---@return ClassSymbolMap[]
  local function DefaultCollectionsAndUtils()
    return {
      {
        namespace = "System",
        class_name = "String"
      },
      {
        namespace = "System",
        class_name = "DateTime"
      },
      {
        namespace = "System",
        class_name = "Decimal"
      },
      --Does not exist in very old mscorlib versions
      {
        namespace = "System",
        class_name = "Tuple`7"
      },
      {
        namespace = "System.Collections.Generic",
        class_name = "List`1"
      },
      {
        namespace = "System.Collections.Generic",
        class_name = "Dictionary`2"
      },
      --Does not exist in very old mscorlib versions
      {
        namespace = "System.Collections.Generic",
        class_name = "Dictionary`2+Entry"
      }
      --This is the very old version of entries
      --[[
        {
          namespace = "System.Collections.Generic"
          class_name = "KeyValuePair`2"
        }
      --]]
    }
  end


  ---Generates ClassAndFieldSymbolMap for the classes which can't 
  ---be automatically dissected.
  ---This basically applies only to arrays and other natively optimized
  ---types which do not have an actual defined boxed class.
  ---@return ClassAndFieldSymbolMap[]
  local function DefaultCollectionsAndUtilsExtra()
    return {
      {
        base_name = "QWordArray", fields = {
          { name = "count", offset = 0x18 },
          { name = "item", offset = 0x20 },
          { name = "item_offset", offset = 0x8 }
        }
      },
      {
        base_name = "DWordArray", fields = {
          { name = "count", offset = 0x18 },
          { name = "item", offset = 0x20 },
          { name = "item_offset", offset = 0x4 }
        }
      },
      {
        base_name = "WordArray", fields = {
          { name = "count", offset = 0x18 },
          { name = "item", offset = 0x20 },
          { name = "item_offset", offset = 0x2 }
        }
      },
      {
        base_name = "ByteArray", fields = {
          { name = "count", offset = 0x18 },
          { name = "item", offset = 0x20 },
          { name = "item_offset", offset = 0x1 }
        }
      }
    }
  end

------------------------------------------------------------------------------
------------------------------- Mono Extensions ------------------------------


  ---@param image Address # the address of the mono image to search in
  ---@param class_map ClassSymbolMap # The table with class name and namespace
  ---@return Address? # The address of the image or nil if it can't be found
  local function FindClassImageCached(image, class_map)
    if(CE_pkg.mono_ext.mono_cached_class_addresses == nil) then
      return nil
    end

    if CE_pkg.mono_ext.mono_cached_class_images[image] == nil then
      CE_pkg.mono_ext.CacheClassesImage(image)
    end

    local md5_cl = stringToMD5String(
      string.format("%x%s%s", image, class_map.namespace, class_map.class_name)
    )

    ---@type integer?
    local cached_addr = CE_pkg.mono_ext.mono_cached_class_addresses[md5_cl]
    if(cached_addr and cached_addr == 0) then
      cached_addr = nil
    end

    if cached_addr == nil then
      printf(
        "FindClassImageCached - Couldn't find class address for class \"%s\" at namespace \"%s\", image \"0x%x\"",
        class_map.class_name, class_map.namespace, image
      )
      printf("FindClassImageCached - MD5: \"%s\"", md5_cl)
    end

    return cached_addr
  end

  ---@param address Address
  ---@param range integer
  ---@return Address[]
  local function FindInstancesOfClassInRange(address, range)

    local klass = mono_object_getClass(address)

    if klass==nil then return {} end

    local vtable = mono_class_getVTable(klass)
    if (vtable) and (vtable ~= 0) then
      local ms = createMemScan()
      local scantype
      if targetIs64Bit() then
        scantype = vtQword
      else
        scantype = vtDword
      end
      local range_start
      local range_end
      do
        local hex = string.format("%x", address)
        local len = string.len(hex)
        local keep_len = string.len(string.format("%x", range)) - 1
        local fill = string.rep("0", keep_len)
        range_start = tonumber(string.sub(hex, 0, math.max(0, len-keep_len)) .. fill, 16) - range
        range_end = range_start + (range * 2)

      end


      ms.firstScan(soExactValue, scantype, rtRounded, string.format('%x', vtable), '', range_start, range_end, '',
        fsmAligned, "8", true, true, false, false)

      ms.waitTillDone()

      local fl = createFoundList(ms)
      fl.initialize()

      local result = {}
      for i = 0, fl.Count - 1 do
        result[i + 1] = tonumber(fl[i], 16)
      end

      fl.destroy()
      ms.destroy()

      return result
    end


    return {}
  end




  ---@param class_addr Address
  ---@param class_map ClassSymbolMap
  ---@param register_static boolean
  local function RegisterSymbolsFields(class_addr, class_map, register_static)
    ---@param full_name string # full symbol name to register
    ---@param field_offset integer # offset of associated field being registered
    local function RegisterAndDebug(full_name, field_offset)
      if DEBUG_DUNG then
        printf("SetupSymbolsRegister - Registered \"%s\" as offset \"0x%x\"", full_name, field_offset)
      end
      registerSymbol(full_name, field_offset, true)
    end

    ---@param class_map ClassSymbolMap
    ---@param field MonoClassField
    local function HandleStatics(class_map, field)
      if(field.isStatic == true) then
        local new_field = ReplaceBackingField(field)
        local full_name = BuildUniqueSymbolFromClass(class_map, new_field.name, { "static" })
        local offset = field.offset+MARKER_DG
        RegisterAndDebug(full_name, offset)
      end
    end

    ---@param class_map ClassSymbolMap
    ---@param field MonoClassField
    local function HandleRegular(class_map, field)
      if(field.isStatic == false) then
        local new_field = ReplaceBackingField(field)
        local full_name = BuildUniqueSymbolFromClass(class_map, new_field.name)
        RegisterAndDebug(full_name, field.offset)
      end
    end


    local fields = mono_class_enumFields(class_addr, false)
    for _, field in ipairs(fields) do
      if register_static then
        HandleStatics(class_map, field)
      else
        HandleRegular(class_map, field)
      end
    end
  end


  ---Registers fields as symbols for programmatic offsets for all the classes from the ClassSymbolMaps.
  ---@param image Address
  ---@param classes_to_register_fields ClassSymbolMap[]
  ---@param register_static boolean
  local function SetupClassSymbolsFromMapImage(image, classes_to_register_fields, register_static)
    for _, v in ipairs(classes_to_register_fields) do
      local class_addr = FindClassImageCached(image, v)
      if class_addr == nil or class_addr == 0 then
        printf(
          "SetupClassSymbolsImage - Couldn't find class address for class \"%s\" at namespace \"%s\", image \"0x%x\"",
          v.class_name, v.namespace, image
        )
      else
        RegisterSymbolsFields(class_addr, v, register_static)
      end
    end
  end



  ---@param classes_to_register_fields ClassAndFieldSymbolMap[]
  local function SetupClassSymbolsForExtra(classes_to_register_fields)
    for _, v in ipairs(classes_to_register_fields) do
      for _, field in ipairs(v.fields) do
        local full_name = "dg_" .. v.base_name .. "." .. field.name
        if DEBUG_DUNG then
          printf(
            "SetupSymbolsExtra - Registered \"%s\" as offset \"0x%x\"",
            full_name, field.offset
          )
        end
        registerSymbol(full_name, field.offset, true)
      end
    end
  end


  ---@param dllNameOrPath string # The name or path of the image DLL (extension will be stripped if present)
  ---@return Address|nil # The address of the image or nil if it can't be found
  local function FindImageByName(dllNameOrPath)
    if(CE_pkg.mono_ext.mono_cached_assemblies == nil) then
      return nil
    end

    if(#CE_pkg.mono_ext.mono_cached_assemblies == 0) then
      CE_pkg.mono_ext.mono_cached_assemblies = mono_enumAssemblies()
      if(#CE_pkg.mono_ext.mono_cached_assemblies == 0) then
        CE_pkg.mono_ext.mono_cached_assemblies = nil
        return nil
      end
    end


    if(CE_pkg.mono_ext.mono_cached_images_count == 0) then
      for _, v in ipairs(CE_pkg.mono_ext.mono_cached_assemblies) do
        local image = mono_getImageFromAssembly(v)
        local name = mono_image_get_name(image)
        if(name == nil) then
          if DEBUG_DUNG then
            printf("FindImageByName - Name was nil for image %x from assembly %x", image, v)
          end
        else
          local stripped = string.gsub(name, ".dll", "")
          CE_pkg.mono_ext.mono_cached_images[stripped] = image
          CE_pkg.mono_ext.mono_cached_images_count = CE_pkg.mono_ext.mono_cached_images_count + 1
        end
      end
    end

    local dll_name = string.gsub(dllNameOrPath, ".dll", "")
    local cached_addr = CE_pkg.mono_ext.mono_cached_images[dll_name]
    if cached_addr and cached_addr ~= 0 then
      return cached_addr
    else
        printf("FindImageByName - Couldn't find \"%s\" in cached images", dllNameOrPath)
    end

    return nil
  end

  ---@param image Address
  local function CacheClassesImage(image)
    local classes = mono_image_enumClasses(image)
    CE_pkg.mono_ext.mono_cached_class_images[image] = {}
    for _, class in ipairs(classes) do
      local class_ = ResolveInnerClasses(class)
      if class_ == nil then
        class_ = class
      end

      local md5_cl = stringToMD5String(
        string.format("%x%s%s", image, class_.namespace, class_.classname)
      )
      if DEBUG_DUNG then
        printf(
          "ClassCaching - Caching class \"%s\" at namespace \"%s\", image \"0x%x\"",
          class_.classname, class_.namespace, image
        )
        printf("ClassCaching - MD5: \"%s\"", md5_cl)
      end
      CE_pkg.mono_ext.mono_cached_class_addresses[md5_cl] = class_.class
    end
  end



  local function ClearCaches()
    CE_pkg.mono_ext.mono_cached_assemblies = {}
    CE_pkg.mono_ext.mono_cached_class_addresses = {}
    CE_pkg.mono_ext.mono_cached_class_images = {}
    CE_pkg.mono_ext.mono_cached_class_images = {}
    CE_pkg.mono_ext.mono_cached_images_count = 0
  end


------------------------------------------------------------------------------
----------------------------- Mono Class Statics -----------------------------


  ---@param class_map ClassSymbolMap
  local function RegisterStaticAddressForClassImage(image, class_map)
    local symbol_name = BuildUniqueSymbolFromClass(class_map, nil, { "static" })

    if getAddressSafe(symbol_name) ~= nil then
      unregisterSymbol(symbol_name)
    end

    local class_addr = FindClassImageCached(image, class_map)
    CheckAndRegisterSymbol(image, class_addr, symbol_name, class_map)
  end



  ---@param image Address
  ---@param classes_to_register_static_address ClassSymbolMap[]
  local function PopulateStaticsImage(image, classes_to_register_static_address)
    for _, tb in ipairs(classes_to_register_static_address) do
      RegisterStaticAddressForClassImage(image, tb)
    end
  end


------------------------------------------------------------------------------
--------------------------------- Mono Setup ---------------------------------

  local function DefaultSetup()
    local image = FindImageByName("mscorlib.dll")
    if image == nil then
      return
    end

    local class_map = DefaultCollectionsAndUtils()
    SetupClassSymbolsFromMapImage(image, class_map, false)

    local extra = DefaultCollectionsAndUtilsExtra()
    SetupClassSymbolsForExtra(extra)
  end

  ---@param dllNameOrPath string
  ---@param class_pairs string[]
  ---@param static_class_pairs string[]
  ---@param both_class_pairs string[]
  local function GameSetup(
    dllNameOrPath, class_pairs, static_class_pairs, both_class_pairs
  )
    local image = FindImageByName(dllNameOrPath)
    if image == nil then
      return
    end

    if DEBUG_DUNG then
      printf("GameSetup - Found image %s: %x", dllNameOrPath, image)
    end

    if #class_pairs == 0 and #both_class_pairs == 0 then
      return
    end


    local merged_pairs = ConcatArrays(class_pairs, both_class_pairs)
    local class_map = ConvertNamespacesToImageClassSymbolMap(merged_pairs)

    if DEBUG_DUNG then
      printf("GameSetup - Setting up regular class symbols\n")
      for _, class in ipairs(class_map) do
        printf("GameSetup - Setting up %s:%s", class.namespace, class.class_name)
      end
    end

    SetupClassSymbolsFromMapImage(image, class_map, false)


    if #static_class_pairs == 0 and #both_class_pairs == 0 then
      return
    end

    merged_pairs = ConcatArrays(static_class_pairs, both_class_pairs)
    local static_class_map = ConvertNamespacesToImageClassSymbolMap(merged_pairs)

    if DEBUG_DUNG then
      printf("GameSetup - Setting up static class symbols\n")
      for _, class in ipairs(static_class_map) do
        printf("GameSetup - Setting up %s:%s", class.namespace, class.class_name)
      end
    end

    SetupClassSymbolsFromMapImage(image, static_class_map, true)
    PopulateStaticsImage(image, static_class_map)
  end

  CE_pkg.mono_ext = {
    FindInstancesOfClassInRange = FindInstancesOfClassInRange,
    SetupClassSymbolsFromMapImage = SetupClassSymbolsFromMapImage,
    SetupClassSymbolsForExtra = SetupClassSymbolsForExtra,
    FindImageByName = FindImageByName,
    CacheClassesImage = CacheClassesImage,
    FindClassImageCached = FindClassImageCached,
    ClearCaches = ClearCaches,
    RegisterStaticAddressForClassImage = RegisterStaticAddressForClassImage,
    PopulateStaticsImage = PopulateStaticsImage,
    DefaultSetup = DefaultSetup,
    GameSetup = GameSetup,
    ---@type Address[]
    mono_cached_assemblies = {},
    ---@type table<string, Address>
    mono_cached_images = {},
    ---@type integer
    mono_cached_images_count = 0,
    ---@type table<string, Address>
    mono_cached_class_addresses = {},
    ---@type table<Address, {}>
    mono_cached_class_images = {}
  }
end
