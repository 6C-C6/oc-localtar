local component = require("component")
if not component.isAvailable("data") then
  error("needs at least one t1 data card")
end
if not component.isAvailable("internet") then
  error("needs at least one internet card")
end
if not component.internet.isHttpEnabled() then
  error("need to enable http in the setting of your minecraft instance")
end
if not component.isAvailable("tape_drive") then
  error("can't find any tape drive")
end
if not component.tape_drive.isReady() then
  error("insert a tape first")
end
local computer = require("computer")
-- package.loaded["deflate_split"] = nil
-- package.loaded["deflate_reassemble"] = nil
-- package.loaded["download2buffer"] = nil
-- !unload packages if they were changed
local ds = require("deflate_split")
local dr = require("deflate_reassemble")
local d2b = require("download2buffer")

local start_time = computer.uptime()
local GZIP_TAIL_BYTE = 8
local ZLIB_TAIL_BYTE = 4
local BUFFER_RAISE = (1 << 19) + 100
local BUFFER_TRIGGER = 320000
local url = "https://github.com/GTNewHorizons/OpenComputers/archive/refs/tags/1.12.64-GTNH.tar.gz"
local opts = { offset = nil }
local result = "/raid/result.bin"
local stream, err = d2b.open(url, opts)
if not stream then error("download open failed: " .. tostring(err)) end
-- local g, err = io.open(result, "wb")
-- if not g then error("target file open failed: " .. tostring(err)) end

local tp = component.tape_drive
local tape_len = tp.getSize()
tp.setLabel("TapeArchive_download")
tp.seek(-1 * tape_len)
local pending_data = stream:extract(BUFFER_RAISE)
pending_data = dr.remove_header(pending_data)
print("lpd: " .. #pending_data)
local pending_start_bit = 0
local slice = ""
local new_data = ""
local prev_part_result = nil

-- dowhile
local sum_out = 0
repeat
  local bd = nil
  local skip = false
  if #pending_data < BUFFER_TRIGGER then
    print("extract")
    new_data = stream:extract(BUFFER_RAISE)
    if new_data == d2b.NEED_MORE then
      -- still need to wait for data
      print("still waiting for data...")
      os.sleep(1)
      skip = true -- do the next repeat
    end
  end
  if not skip then
    if new_data ~= nil then
      pending_data = pending_data .. new_data
    elseif (new_data == nil or #new_data == 0) and #pending_data <= GZIP_TAIL_BYTE then
      -- no more data
      break
    end
    new_data = ""
    print("Part size:" .. #pending_data)
    bd = ds.find_block_boundaries(pending_data:sub(1, BUFFER_TRIGGER), pending_start_bit, 300000) -- set 300kB limit, don't let inflate result use all the memory
    print(" Finished finding boundaries")
    local tmp_data
    slice, tmp_data, pending_start_bit = dr.slice(pending_data:sub(1, BUFFER_TRIGGER), bd, pending_start_bit)
    pending_data = tmp_data .. pending_data:sub(BUFFER_TRIGGER + 1)
    tmp_data = nil
    io.write("\nCurrent slice length: " .. #slice .. ", pending: " .. #pending_data .. ", MEMORY " .. math.ceil((1 - computer.freeMemory() / computer.totalMemory()) * 100) .. "%")
    local inflate_part = dr.assemble(prev_part_result, slice)
    prev_part_result = inflate_part:sub(#inflate_part - (1 << 15) - 10)
    print("Part out size: " .. #inflate_part)
    sum_out = sum_out + #inflate_part
    print("Total out size: " .. math.ceil(sum_out / 1024) .. "kiB\n")
    tp.write(inflate_part)
    -- g:write(inflate_part)
    -- g:flush()
  end
until false
stream:close()
-- g:flush()
-- g:close()
print("\nDone! time usage " .. math.floor((computer.uptime() - start_time) / 60) .. "min" .. math.ceil((computer.uptime() - start_time) % 60) .. "s, write file size " .. math.ceil(sum_out / (1 << 20)) .. "MiB or " .. sum_out .. "byte.\n")
