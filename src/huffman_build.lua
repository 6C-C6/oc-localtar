-- Functions for building a huffman table and build the fixed table for zlib deflate chunk splitting.

local modname = ...
if not modname then error("Warn: This is a lib for deflate_split.lua, do not use directly.") end

local M = {}

--===

local REV_BYTE = {}
for i = 0, 255 do
  local b, r = i, 0
  for _ = 1, 8 do
    r = (r << 1) | (b & 1)
    b = b >> 1
  end
  REV_BYTE[i] = r
end

local function rev16(x)
  local lo = REV_BYTE[x & 0xFF]
  local hi = REV_BYTE[(x >> 8) & 0xFF]
  return (lo << 8) | hi
end

local function reverse_bits(x, n)
  return rev16(x) >> (16 - n)
end

M.rev16        = rev16
M.reverse_bits = reverse_bits

--===

local function build_huffman_table(lengths, max_bits)
  max_bits = max_bits or 15
  local max_len = 0
  for _, l in ipairs(lengths) do
    if l > max_len then max_len = l end
  end
  if max_len == 0 then
    return {}, 0
  end
  local size = 1 << max_len
  -- local codes=build_canonical_codes(lengths,max_bits)
  local bl_count = {}
  for i = 0, max_bits do bl_count[i] = 0 end
  for _, l in ipairs(lengths) do
    if l > 0 then bl_count[l] = bl_count[l] + 1 end
  end

  local next_code = {}
  local code = 0
  for bits = 1, max_bits do
    code = (code + bl_count[bits - 1]) << 1
    next_code[bits] = code
  end

  local codes_by_len = {}
  for L = 1, max_len do codes_by_len[L] = {} end

  for i, l in ipairs(lengths) do
    if l > 0 then
      local sym = i - 1
      local c = next_code[l]
      next_code[l] = c + 1
      codes_by_len[l][reverse_bits(c, l)] = sym
    end
  end

  return codes_by_len, max_len
end

M.build_huffman_table = build_huffman_table

--==

local function build_fixed_table()
  local lit_lengths = {}
  for i = 0, 287 do
    local l
    if     i <= 143 then l = 8
    elseif i <= 255 then l = 9
    elseif i <= 279 then l = 7
    else                 l = 8 end
    lit_lengths[i + 1] = l
  end

  local dist_lengths = {}
  for i = 1, 30 do dist_lengths[i] = 5 end

  local lit_tbl,  lit_max  = build_huffman_table(lit_lengths, 15)
  local dist_tbl, dist_max = build_huffman_table(dist_lengths, 15)
  return lit_tbl, lit_max, dist_tbl, dist_max
end

M.lit_tbl, M.lit_max, M.dist_tbl, M.dist_max = build_fixed_table()

--==
function M.decode_symbol(reader, tbl, max_len)
  if type(max_len) ~= "number" then
    error(("decode_symbol: max_len is %s"):format(type(max_len)))
  end
  if max_len == 0 then error("empty huffman table") end

  if not reader:can_read(1) then
    return nil
  end

  local snap = reader:snapshot()
  local v = 0
  for L = 1, max_len do
    v = v | (reader:read(1) << (L - 1))
    local sym = tbl[L][v]
    if sym ~= nil then return sym end
    if L < max_len and not reader:can_read(1) then
      reader:restore(snap)
      return nil
    end
  end

  reader:restore(snap)
  return nil
end

--==
return M
