-- deflate_reassemble.lua
local component = require("component")
local M = {}

function M.remove_stream_header_zlib(data) -- can't be used for string
  local cmf = string.byte(data:read(1))
  local flg = string.byte(data:read(1))
  if (cmf & 0x0F) ~= 8 then
    error(("not a zlib deflate stream (CMF=0x%02X)"):format(cmf))
  end
  if (flg & 0x20) ~= 0 then
    data:read(4)
  end
  return data
end

local function read_u16_le(s, pos)
  local b1, b2 = s:byte(pos, pos + 1)
  if not b1 or not b2 then return nil end
  return b1 + b2 * 256
end

function M.remove_stream_header(data) -- can't be used for string
  -- gzip
  local b1 = string.byte(data:read(1))
  local b2 = string.byte(data:read(1))
  if b1 ~= 0x1f or b2 ~= 0x8b then
    error("not a gzip deflate stream (bad magic)")
  end
  data:read(1) -- compression method
  local flg = string.byte(data:read(1))
  local pos = 11
  data:read(6) -- rest of fixed header

  if flg & 0x01 > 0 then
    if #data < pos + 1 then return nil, "truncated FEXTRA" end
    local xlen = read_u16_le(data, pos)
    if not xlen then return nil, "truncated FEXTRA length" end
    pos = pos + 2 + xlen
  end

  if flg & 0x02 > 0 then
    local z = data:find("\0", pos, true)
    if not z then return nil, "unterminated FNAME" end
    pos = z + 1
  end

  if flg & 0x04 > 0 then
    local z = data:find("\0", pos, true)
    if not z then return nil, "unterminated FCOMMENT" end
    pos = z + 1
  end

  if flg & 0x08 > 0 then
    pos = pos + 2
  end

  if pos > #data then
    return nil, "header extends past end of data"
  end
  return data:sub(pos)
end

function M.remove_header(data) -- for string
  -- gzip
  local len = #data
  if len < 10 then return nil, "truncated gzip header" end
  local b1 = data:byte(1)
  local b2 = data:byte(2)
  if b1 ~= 0x1f or b2 ~= 0x8b then
    error("not a gzip deflate stream (bad magic)")
  end
  local cm = data:byte(3) -- compression method (must be 8 = deflate)
  if cm ~= 8 then
    error(("unsupported gzip compression method 0x%02X"):format(cm))
  end
  local flg = data:byte(4)
  local pos = 11 -- 1-based index right after the 10-byte fixed header

  if (flg & 0x01) ~= 0 then
    if len < pos + 1 then return nil, "truncated FEXTRA" end
    local xlen = read_u16_le(data, pos)
    if not xlen then return nil, "truncated FEXTRA length" end
    pos = pos + 2 + xlen
  end

  if (flg & 0x02) ~= 0 then
    local z = data:find("\0", pos, true)
    if not z then return nil, "unterminated FNAME" end
    pos = z + 1
  end

  if (flg & 0x04) ~= 0 then
    local z = data:find("\0", pos, true)
    if not z then return nil, "unterminated FCOMMENT" end
    pos = z + 1
  end

  if (flg & 0x08) ~= 0 then
    pos = pos + 2
  end

  if pos > len then
    return nil, "header extends past end of data"
  end
  return data:sub(pos)
end

local function take_bits(s, total_bits)
  local b = total_bits >> 3
  local r = total_bits & 7
  if r == 0 then return s:sub(1, b) end
  local partial = (s:byte(b + 1) or 0) & ((1 << r) - 1)
  return s:sub(1, b) .. string.char(partial)
end

local function shift_low_bits(s, n)
  if n == 0 then return s end
  local out, len = "", #s
  for i = 1, len do
    local cur = s:byte(i) or 0
    local nxt = i < len and s:byte(i + 1) or 0
    out = out .. string.char(((cur >> n) | (nxt << (8 - n))) & 0xFF)
  end
  return out
end

function M.slice(data, boundaries, start_bit)
  local n = #boundaries
  if n == 0 then
    return "", data, start_bit
  end
  local first, last = boundaries[1], boundaries[n]
  local first_off = first.byte * 8 + first.bit
  local last_off  = last.byte  * 8 + last.bit
  local b, r = first_off >> 3, first_off & 7
  local output
  if first.kind == "stored" and n >= 2 then
    -- stored block on start, with following compressed blocks
    local len_byte = (first_off >> 3) + ((r >= 6) and 2 or 1)
    output = string.char(first.final and 1 or 0)
           .. take_bits(data:sub(len_byte + 1), last_off - len_byte * 8)
  else
    local end_byte = (last_off >> 3) + 1
    local base = shift_low_bits(data:sub(b + 1, end_byte), r)
    output = take_bits(base, last_off - first_off)
  end
  if last.kind == "EOS" then return output, "", 0 end
  return output, data:sub((last_off >> 3) + 1), (last_off & 7)
end

--==
local function zlib_header(flevel)
  local cmf = 0x78 -- CM = 8, CINFO = 7
  local flg = (flevel or 0) << 6
  -- FDICT bit (bit 5) stays 0
  local rem = ((cmf << 8) | flg) % 31
  local fcheck = (31 - rem) % 31
  flg = flg | fcheck
  return string.char(cmf, flg)
end

function M.assemble(refrence, data)
  if refrence == nil then
    -- use nil for the first slice
    local composed = zlib_header(2) .. data
    print("cp" .. #composed)
    return component.data.inflate(composed)
  end
  if #refrence < (1 << 15) then
    print(#refrence)
    error("refrence should be longer than 32KiB")
  end
  refrence = refrence:sub(#refrence - (1 << 15) + 1) -- last 32KiB

  local len  = 1 << 15
  local nlen = (~len) & 0xFFFF
  local composed = zlib_header(2) .. string.char(0)
      .. string.char(len & 0xFF, (len >> 8) & 0xFF,
                     nlen & 0xFF, (nlen >> 8) & 0xFF)
      .. refrence
      .. data
  print("cp" .. #composed)
  return (component.data.inflate(composed)):sub((1 << 15) + 1)
end

--==
return M
