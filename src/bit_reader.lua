-- Read data that are not byte-alligned
local modname = ...
if not modname then error("Warn: This is a lib for deflate_split.lua, do not use directly.") end

local M = {}

local BitReader = {}
BitReader.__index = BitReader

function M.new_reader(data, start_byte, start_bit)
  local r = setmetatable({
    data  = data,
    len   = #data,
    pos   = start_byte or 1,
    buf   = 0,
    nbits = 0,
  }, BitReader)
  if start_bit and start_bit > 0 then
    r:_prime_start(start_bit)
  end
  return r
end

function BitReader:_prime_start(start_bit)
  if self.pos > self.len then return end
  local b = self.data:byte(self.pos)
  self.buf = (b >> start_bit) & 0xFF
  self.nbits = 8 - start_bit
  self.pos = self.pos + 1
end

function BitReader:fill()
  local buf, nbits, pos, len, data = self.buf, self.nbits, self.pos, self.len, self.data
  while nbits <= 48 and pos <= len do
    buf = buf | (data:byte(pos) << nbits)
    nbits = nbits + 8
    pos = pos + 1
  end
  self.buf, self.nbits, self.pos = buf, nbits, pos
end

function BitReader:read(n)
  if self.nbits < n then
    self:fill()
    if self.nbits < n then error("bitstream out of range") end
  end
  local v = self.buf & ((1 << n) - 1)
  self.buf   = self.buf >> n
  self.nbits = self.nbits - n
  return v
end

function BitReader:align()
  local rem = self.nbits & 7          -- nbits % 8
  if rem ~= 0 then
    self.buf   = self.buf >> rem
    self.nbits = self.nbits - rem
  end
end

function BitReader:read_bytes(n)
  if n == 0 then return "" end

  local parts = {}

  local avail = self.nbits >> 3
  local take  = avail < n and avail or n
  if take > 0 then
    for _ = 1, take do
      parts[#parts + 1] = string.char(self.buf & 0xFF)
      self.buf = self.buf >> 8
    end
    self.nbits = self.nbits - take * 8
    n = n - take
  end
  if n == 0 then return table.concat(parts) end

  if self.nbits ~= 0 then
    error("read_bytes: not byte-aligned")
  end

  if self.pos + n - 1 > self.len then
    error("bytestream out of range")
  end
  parts[#parts + 1] = self.data:sub(self.pos, self.pos + n - 1)
  self.pos = self.pos + n
  return table.concat(parts)
end

function BitReader:bit_offset()
  return (self.pos - 1) * 8 - self.nbits
end

function BitReader:bit_in_byte()
  return ((self.pos - 1) * 8 - self.nbits) & 7
end

function BitReader:snapshot()
  return {
    pos   = self.pos,
    buf   = self.buf,
    nbits = self.nbits,
  }
end

function BitReader:restore(s)
  self.pos   = s.pos
  self.buf   = s.buf
  self.nbits = s.nbits
end

function BitReader:has_bits(n)
  if self.nbits < n then
    self:fill()
  end
  return self.nbits >= n
end

function BitReader:remaining_bits()
  return self.nbits + (self.len - self.pos + 1) * 8
end

function BitReader:can_read(n)
  return self:remaining_bits() >= n
end

M.BitReader = BitReader

--==
return M
