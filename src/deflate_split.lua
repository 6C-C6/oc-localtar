-- deflate_split.lua
package.loaded["huffman_build"]    = nil
package.loaded["bit_reader"]    = nil
local component = require("component")
local HB        = require("huffman_build")
local BR        = require("bit_reader")
local os=require("os")
print("data limit:" .. component.data.getLimit())

local lit_tbl, lit_max   = HB.lit_tbl,  HB.lit_max
local dist_tbl, dist_max = HB.dist_tbl, HB.dist_max

--==
local LEN_EXTRA = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,
4,4,4,4,5,5,5,5,0}
local DIST_EXTRA= {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,
9,9,10,10,11,11,12,12,13,13}

--==

local function safe_read(reader, snap, n)
  if n == 0 then return true end
  if not reader:can_read(n) then
    reader:restore(snap)
    return false
  end
  reader:read(n)
  return true
end

local function skip_compressed_block(reader, ltbl, lmax, dtbl, dmax)
  local cnt = 0
  local snap = reader:snapshot()
  while true do
    cnt = cnt + 1
    local sym = HB.decode_symbol(reader, ltbl, lmax)
    if sym == nil then
      reader:restore(snap)
      return false
    end
    if sym < 256 then
      -- literal
    elseif sym == 256 then
      return true
    else
      local li = sym - 257 + 1
      if li < 1 or li > #LEN_EXTRA then
        error("invalid length symbol " .. sym)
      end
      if not safe_read(reader, snap, LEN_EXTRA[li]) then return false end

      local dsym = HB.decode_symbol(reader, dtbl, dmax)
      if dsym == nil then
        reader:restore(snap)
        return false
      end
      local di = dsym + 1
      if di < 1 or di > #DIST_EXTRA then
        error("invalid distance symbol " .. dsym)
      end
      if not safe_read(reader, snap, DIST_EXTRA[di]) then return false end
    end
    if cnt > 65536 then
      print("go through 64k symbols in one block")
      os.sleep(0)
      cnt = 0
    end
  end
end

--==

local CL_ORDER = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}

local function parse_dynamic_header(reader)
  if not reader:can_read(5 + 5 + 4) then return nil end
  local hlit  = reader:read(5) + 257
  local hdist = reader:read(5) + 1
  local hclen = reader:read(4) + 4

  if not reader:can_read(hclen * 3) then return nil end
  local cl_lengths = {}
  for i = 1, 19 do cl_lengths[i] = 0 end
  for i = 1, hclen do
    cl_lengths[CL_ORDER[i] + 1] = reader:read(3)
  end

  local cl_tbl, cl_max = HB.build_huffman_table(cl_lengths, 7)
  if cl_max == 0 then error("empty code-length huffman table") end

  local total   = hlit + hdist
  local lengths = {}
  local i = 1

  while i <= total do
    if not reader:can_read(7+7) then return nil end
    local sym = HB.decode_symbol(reader, cl_tbl, cl_max)

    if sym < 16 then
      lengths[i] = sym
      i = i + 1
    elseif sym == 16 then
      if i == 1 then error("code-length 16 without previous") end
      local prev = lengths[i - 1]
      local n = reader:read(2) + 3
      if i + n - 1 > total then return nil end
      for _ = 1, n do lengths[i] = prev; i = i + 1 end
    elseif sym == 17 then
      local n = reader:read(3) + 3
      if i + n - 1 > total then return nil end
      for _ = 1, n do lengths[i] = 0; i = i + 1 end
    else
      local n = reader:read(7) + 11
      if i + n - 1 > total then return nil end
      for _ = 1, n do lengths[i] = 0; i = i + 1 end
    end
  end

  local lit_lengths  = {}
  for j = 1, hlit do lit_lengths[j] = lengths[j] end
  local dist_lengths = {}
  for j = 1, hdist do dist_lengths[j] = lengths[hlit + j] end

  local ltbl, lmax = HB.build_huffman_table(lit_lengths,  15)
  local dtbl, dmax = HB.build_huffman_table(dist_lengths, 15)
  return ltbl, lmax, dtbl, dmax
end

--==

local function find_block_boundaries(data, start_bit,limit)
  local MAX_LIMIT=component.data.getLimit()-(1<<16) --inflate max 1MB, minus the prefix 32KB times 2 (x2 for safety)
  limit=limit or MAX_LIMIT
  limit=math.min(limit,MAX_LIMIT)
  print("FB limit: "..limit)
  local reader     = BR.new_reader(data, 1, start_bit or 0)
  local boundaries = {}
  local final = 0
  local chunk_cnt=0
  repeat
    chunk_cnt=chunk_cnt+1
    if chunk_cnt%1==0 then
      io.write("\rPosition in currnet part: "..reader.pos) 
      --go through 16 chunks
      os.sleep(0)
    end
    if not reader:can_read(3) then
      -- data breaks exactly at a boundary
      break
    end
    local block_snap = reader:snapshot()
    local boff       = reader:bit_offset()
    local block_start_byte = boff >> 3
    local block_start_bit  = boff & 7
    local ok_read
    final = reader:read(1)
    local btype = reader:read(2)

    local kind
    if btype == 0 then
      kind = "stored"
      reader:align()
      if not reader:can_read(16 + 16) then
        ok_read = false
      else
        local len  = reader:read(16)
        local nlen = reader:read(16)
        if ((len + nlen) & 0xFFFF) ~= 0xFFFF then
          error("stored block LEN/NLEN mismatch")
        end
        local avail = reader.nbits // 8 + (reader.len - reader.pos + 1)
        if len > avail then
          ok_read = false
        else
          reader:read_bytes(len)
          ok_read = true
        end
      end
      if not ok_read then
        --rewind happened
        reader:restore(block_snap)
        break
      end
      if #boundaries>0 then
        table.insert(boundaries, {
          byte  = block_start_byte,
          bit   = block_start_bit,
          kind  = kind,
          final = (final == 1),
        })
        break -- in current design, store block can only be on the slice's start
      end
    elseif btype == 1 then
      kind = "fixed"
      ok_read = skip_compressed_block(reader, lit_tbl, lit_max, dist_tbl, dist_max)

    elseif btype == 2 then
      kind = "dynamic"
      local ltbl, lmax, dtbl, dmax = parse_dynamic_header(reader)
      if ltbl == nil then
        ok_read = false
      else
        ok_read = skip_compressed_block(reader, ltbl, lmax, dtbl, dmax)
      end
    else
      error("invalid block type 3")
    end
    if not ok_read then
      --rewind happened
      reader:restore(block_snap)
      break
    end
    table.insert(boundaries, {
      byte  = block_start_byte,
      bit   = block_start_bit,
      kind  = kind,
      final = (final == 1),
    })
    if final==1 then break end
  until reader.pos>limit
  -- the latest block can't be contained, except for final, final may also too large to be contained
  if #boundaries>0 and boundaries[#boundaries].final then
    local boff       = reader:bit_offset()
    local block_start_byte = boff >> 3
    local block_start_bit  = boff & 7
    if block_start_byte<limit and (#boundaries==1 or not boundaries[#boundaries].kind=="stored") then
      -- final block can be contained
      -- it's not a stored block, unless there's only one
      table.insert(boundaries, {
        byte  = block_start_byte,
        bit   = block_start_bit,
        kind  = "EOS",
        final = true,
      })
    end
  end
  return boundaries
end

return {
  find_block_boundaries = find_block_boundaries,
}