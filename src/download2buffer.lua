-- download2buffer.lua
-- 206 method currently not impl, since github archive doesn't support it
local component = require("component")
local internet=require("internet")
local computer=require("computer")
local MAX_BUFFER=516*1024--516kiB string buffer, should be larger than BUFFER_RAISE
local READ_SIZE  = 2048
local SLEEP_TIME = 0.05
local WAIT_TIME = 0.2
local MAX_IDLE = 45 --45s without response
local REFRESH_TIME=1.0
local DEFAULT_UA = "OpenComputers-TapeArchive"
local M={}
M.NEED_MORE = setmetatable({}, { __tostring = function() return "NEED_MORE" end })

local Buffer = {}
Buffer.__index = Buffer

function Buffer.new(maxSize)
  return setmetatable({
    data    = "",
    maxSize = maxSize or MAX_BUFFER,
    eof     = false,
  }, Buffer)
end

function Buffer:extract(n)
  local size = #self.data
  if size == 0 then
    if self.eof then return nil end
    return M.NEED_MORE
  end
  if size < n and not self.eof then
    return M.NEED_MORE
  end
  local take  = math.min(n, size)
  local chunk = self.data:sub(1, take)
  self.data   = self.data:sub(take + 1)
  return chunk
end

function Buffer:remain(  )
  return self.maxSize - #self.data
end

function Buffer:push(chunk)
  if not chunk or #chunk == 0 then return 0 end
  if self:remain() < #chunk then 
    error("buffer pushed over max size! should check remain before push.")
  end
  self.data   = self.data .. chunk
  return #chunk
end

function Buffer:setEOF()  self.eof = true end
function Buffer:size()    return #self.data end

--==

local function getHeader(headers, name)
  if not headers then return nil end
  local v = headers[name] or headers[name:lower()] or headers[name:upper()]
  if type(v) == "table" then return v[1] end
  return v
end

--==



local function buildHeaders(opts, startOff)
  local headers = {}

  if startOff > 0 then
    headers["Range"] = "bytes=" .. startOff .. "-"
  end

  if opts.token then
    headers["Authorization"] = "token " .. opts.token
  end

  if opts.headers then
    for k, v in pairs(opts.headers) do
      headers[k] = tostring(v)
    end
  end

  if not headers["User-Agent"] then
    headers["User-Agent"] = opts.userAgent or DEFAULT_UA
  end

  return headers
end

--==

local function connect(url,opts)
  local startOff  = opts.offset    or 0


  local headers = buildHeaders(opts, startOff)

  local ok, handleOrErr = pcall(internet.request, url, nil, headers, "GET")
  if not ok or not handleOrErr then
    return nil, "request failed: " .. tostring(handleOrErr)
  end
  local handle = handleOrErr

  while true do
    local fok, res = pcall(function() return handle.finishConnect() end)
    if not fok then
      handle.close()
      return nil, "connect failed: " .. tostring(res)
    end
    if res then break end
    os.sleep(WAIT_TIME)
  end
  local code, message, respHeaders = handle.response()

  if code >= 300 and code < 400 then
    local location = getHeader(respHeaders, "Location")
    handle:close()
    if location then
      return nil, "redirect to: " .. tostring(location)
    end
    return nil, "redirect (" .. tostring(code) .. ") without Location"
  end

  local actualOffset = startOff
  local mode         = "ab"
  if code == 206 then
    return nil, "currently 206 not supported"
    -- local cr = getHeader(respHeaders, "Content-Range")
    -- if cr then
    --   local startByte = tonumber(cr:match("bytes (%d+)-"))
    --   if startByte then actualOffset = startByte end
    -- end
  elseif code == 200 then
    actualOffset = 0
    mode         = "wb"
  elseif code == 416 then
    handle:close()
    return nil, "range not satisfiable (file may be complete)"
  else
    handle:close()
    return nil, "http " .. tostring(code) .. " " .. tostring(message)
  end

  return {
    handle          = handle,
    code            = code,
    message         = message,
    headers         = respHeaders,
    offset          = actualOffset,
    mode            = mode,
  }
end

local Stream = {}
Stream.__index = Stream

function M.open(url, opts)
  opts = opts or {}
  local readSize  = opts.readSize  or READ_SIZE
  local maxBuffer = opts.maxBuffer or MAX_BUFFER
  local conn,err=connect(url,opts)
  if not conn then return nil, err end

  return setmetatable({
    url        = url,
    baseOpts   = opts,
    handle     = conn.handle,
    buffer     = Buffer.new(maxBuffer),
    readSize   = readSize,
    tmp_chunk  = "",
    code       = conn.code,
    message    = conn.message,
    headers    = conn.headers,
    offset     = conn.offset,
    mode       = conn.mode,

    lastActive = computer.uptime(),
    closed     = false,
  }, Stream)
end

function Stream:extract(n)
  if self.closed then return nil end
  local extracted=self.buffer:extract(n)
  if extracted==M.NEED_MORE then
    self:refill()
    extracted=self.buffer:extract(n)
  end
  if self:idleTime()>MAX_IDLE then
    error("connection reset by peer")
  end
  return extracted
end

function Stream:refill()
  if self.closed or self.buffer.eof then
    return false
  end
  local read_cnt = 0
  
  if self.buffer:remain() < #self.tmp_chunk then
    return false
  end
  local pu_time=self.lastActive
  repeat
    local chunk = self.handle.read(self.readSize)
    if chunk == nil then
      -- EOF: flush any pending chunk if it fits, then mark eof
      if #self.tmp_chunk > 0 then
        if self.buffer:remain() >= #self.tmp_chunk then
          self.buffer:push(self.tmp_chunk)
          self.tmp_chunk = ""
          self.buffer:setEOF()
        end
      else
        self.buffer:setEOF()
      end
      return false
    end
    if #chunk > 0 then
      read_cnt = read_cnt + 1
      self.buffer:push(self.tmp_chunk)
      self.lastActive = computer.uptime()
      self.tmp_chunk = chunk
      if self.lastActive-pu_time>REFRESH_TIME then 
        io.write("\rbuffer "..math.floor(#self.buffer.data/1024).."kiB, MEMORY "..math.ceil((1-computer.freeMemory()/computer.totalMemory())*100).."%")
        pu_time=self.lastActive
      end
    end
    os.sleep(SLEEP_TIME)
  until self.buffer:remain() < #self.tmp_chunk
    or read_cnt > math.ceil(self.buffer.maxSize / self.readSize)*10 -- abnormal slow net
    print("")
  print("refill done with " .. read_cnt .. " steps and remains "..self.buffer:remain().." bytes on buffer")
  return true
end

function Stream:idleTime()
  return computer.uptime() - self.lastActive
end

function Stream:close()
  if self.closed then return end
  self.closed = true
  pcall(function() self.handle.close() end)
  self.handle = nil
end

return M