---Utility functions missing from Lua stdlib

---@generic T
---@param arr T[]
---@return T[]
function ReverseArray(arr)
  local n, m = #arr, #arr / 2
  for i = 1, m do
    arr[i], arr[n - i + 1] = arr[n - i + 1], arr[i]
  end
  return arr
end

---@generic T
---@param ... T[]
---@return T[]
function ConcatArrays(...)
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
