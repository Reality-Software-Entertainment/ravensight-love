-- ravensight/transport.lua: how the SDK makes an HTTPS request.
--
-- LÖVE 11 ships LuaSocket, which has no TLS, and the Ravensight API is HTTPS
-- only. So the SDK tries, in order:
--
--   1. require("https")  LÖVE 12's built-in module, or lua-https if you
--                        added it to an 11.x game yourself
--   2. ffi + WinHTTP     on Windows, the HTTP library every Windows ships
--   3. ffi + libcurl     on macOS and Linux, the system's own libcurl
--   4. the curl command  macOS and Linux, if libcurl would not load
--
-- Steps 2 and 3 use LuaJIT's FFI, which LÖVE always has, to call a library
-- the operating system already provides, so there is nothing native to
-- bundle, sign or notarize. If none of them works, select() returns nil and
-- the SDK keeps events queued (and saved on quit) without sending anything.
--
-- Every function here blocks. It runs on the SDK's worker thread
-- (ravensight/worker.lua), never on the thread that draws your game.
--
-- request(req) takes {method, url, headers = {name = value}, body, timeout}
-- and returns status, body, headers, with status 0 and an error string in
-- place of the body on a network failure. Response header names are
-- lowercased.
--
-- MIT licensed, part of ravensight-love.

local transport = {}

local DEFAULT_TIMEOUT = 15

local function lowerHeaders(raw)
  local out = {}
  for line in (raw or ''):gmatch('[^\r\n]+') do
    local name, value = line:match('^([^:]+):%s*(.-)%s*$')
    if name then out[name:lower()] = value end
  end
  return out
end
transport._lowerHeaders = lowerHeaders

-- ------------------------------------------------------------ 1. https

local function httpsModule()
  local ok, https = pcall(require, 'https')
  if not ok or type(https) ~= 'table' or type(https.request) ~= 'function' then return nil end
  return {
    name = 'https',
    request = function(req)
      local options = { method = req.method, headers = req.headers }
      if req.body then options.data = req.body end
      local ok2, code, body, headers = pcall(https.request, req.url, options)
      if not ok2 then return 0, tostring(code), {} end
      local lowered = {}
      for k, v in pairs(headers or {}) do lowered[tostring(k):lower()] = v end
      return tonumber(code) or 0, body or '', lowered
    end,
  }
end

-- --------------------------------------------------------- 2. WinHTTP

local function winhttp(ffi)
  if ffi.os ~= 'Windows' then return nil end
  local ok = pcall(ffi.cdef, [[
    typedef void* HINTERNET;
    typedef unsigned long DWORD;
    typedef int BOOL;
    typedef unsigned short INTERNET_PORT;
    typedef struct {
      DWORD dwStructSize;
      wchar_t* lpszScheme; DWORD dwSchemeLength; int nScheme;
      wchar_t* lpszHostName; DWORD dwHostNameLength; INTERNET_PORT nPort;
      wchar_t* lpszUserName; DWORD dwUserNameLength;
      wchar_t* lpszPassword; DWORD dwPasswordLength;
      wchar_t* lpszUrlPath; DWORD dwUrlPathLength;
      wchar_t* lpszExtraInfo; DWORD dwExtraInfoLength;
    } RS_URL_COMPONENTS;
    HINTERNET WinHttpOpen(const wchar_t*, DWORD, const wchar_t*, const wchar_t*, DWORD);
    BOOL WinHttpCrackUrl(const wchar_t*, DWORD, DWORD, RS_URL_COMPONENTS*);
    HINTERNET WinHttpConnect(HINTERNET, const wchar_t*, INTERNET_PORT, DWORD);
    HINTERNET WinHttpOpenRequest(HINTERNET, const wchar_t*, const wchar_t*, const wchar_t*, const wchar_t*, const wchar_t**, DWORD);
    BOOL WinHttpSetTimeouts(HINTERNET, int, int, int, int);
    BOOL WinHttpSendRequest(HINTERNET, const wchar_t*, DWORD, const void*, DWORD, DWORD, uintptr_t);
    BOOL WinHttpReceiveResponse(HINTERNET, void*);
    BOOL WinHttpQueryHeaders(HINTERNET, DWORD, const wchar_t*, void*, DWORD*, DWORD*);
    BOOL WinHttpQueryDataAvailable(HINTERNET, DWORD*);
    BOOL WinHttpReadData(HINTERNET, void*, DWORD, DWORD*);
    BOOL WinHttpCloseHandle(HINTERNET);
    int MultiByteToWideChar(unsigned int, DWORD, const char*, int, wchar_t*, int);
    int WideCharToMultiByte(unsigned int, DWORD, const wchar_t*, int, char*, int, const char*, int*);
    DWORD GetLastError(void);
  ]])
  if not ok then return nil end
  local okLib, lib = pcall(ffi.load, 'winhttp')
  if not okLib then return nil end
  local kernel = ffi.C

  local CP_UTF8 = 65001
  local WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4
  local WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0
  local WINHTTP_FLAG_SECURE = 0x00800000
  local WINHTTP_QUERY_STATUS_CODE = 19
  local WINHTTP_QUERY_RAW_HEADERS_CRLF = 22
  local WINHTTP_QUERY_FLAG_NUMBER = 0x20000000
  local INTERNET_SCHEME_HTTPS = 2

  local function wide(s)
    local n = kernel.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
    local buf = ffi.new('wchar_t[?]', n + 1)
    kernel.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n)
    buf[n] = 0
    return buf, n
  end
  local function narrow(w, len)
    local n = kernel.WideCharToMultiByte(CP_UTF8, 0, w, len, nil, 0, nil, nil)
    if n <= 0 then return '' end
    local buf = ffi.new('char[?]', n)
    kernel.WideCharToMultiByte(CP_UTF8, 0, w, len, buf, n, nil, nil)
    return ffi.string(buf, n)
  end

  -- Windows 8.1 and later understand the automatic proxy flag; older ones
  -- refuse it, so fall back to the default proxy setting.
  local agent = wide('ravensight-love')
  local session = lib.WinHttpOpen(agent, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0)
  if session == nil then session = lib.WinHttpOpen(agent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0) end
  if session == nil then return nil end

  local function request(req)
    local url, urlLen = wide(req.url)
    local parts = ffi.new('RS_URL_COMPONENTS')
    parts.dwStructSize = ffi.sizeof(parts)
    parts.dwHostNameLength = 0xFFFFFFFF
    parts.dwUrlPathLength = 0xFFFFFFFF
    parts.dwExtraInfoLength = 0xFFFFFFFF
    parts.dwSchemeLength = 0xFFFFFFFF
    if lib.WinHttpCrackUrl(url, urlLen, 0, parts) == 0 then return 0, 'bad_url', {} end

    local host = ffi.new('wchar_t[?]', parts.dwHostNameLength + 1)
    ffi.copy(host, parts.lpszHostName, parts.dwHostNameLength * 2)
    local pathLen = parts.dwUrlPathLength + parts.dwExtraInfoLength
    local path = ffi.new('wchar_t[?]', pathLen + 1)
    ffi.copy(path, parts.lpszUrlPath, pathLen * 2)

    local connect = lib.WinHttpConnect(session, host, parts.nPort, 0)
    if connect == nil then return 0, 'connect_failed', {} end
    local flags = parts.nScheme == INTERNET_SCHEME_HTTPS and WINHTTP_FLAG_SECURE or 0
    local handle = lib.WinHttpOpenRequest(connect, wide(req.method or 'GET'), path, nil, nil, nil, flags)
    if handle == nil then lib.WinHttpCloseHandle(connect) return 0, 'open_failed', {} end

    local ms = math.floor((req.timeout or DEFAULT_TIMEOUT) * 1000)
    lib.WinHttpSetTimeouts(handle, ms, ms, ms, ms)

    local lines = {}
    for k, v in pairs(req.headers or {}) do lines[#lines + 1] = k .. ': ' .. v end
    local headerText, headerLen = nil, 0
    if #lines > 0 then headerText, headerLen = wide(table.concat(lines, '\r\n')) end
    local body = req.body or ''
    local result = { 0, 'network_error', {} }
    if lib.WinHttpSendRequest(handle, headerText, headerLen, body, #body, #body, 0) ~= 0
      and lib.WinHttpReceiveResponse(handle, nil) ~= 0 then
      local status = ffi.new('DWORD[1]')
      local size = ffi.new('DWORD[1]', 4)
      lib.WinHttpQueryHeaders(handle, WINHTTP_QUERY_STATUS_CODE + WINHTTP_QUERY_FLAG_NUMBER, nil, status, size, nil)

      local rawLen = ffi.new('DWORD[1]', 0)
      lib.WinHttpQueryHeaders(handle, WINHTTP_QUERY_RAW_HEADERS_CRLF, nil, nil, rawLen, nil)
      local headers = {}
      if rawLen[0] > 0 then
        local chars = math.floor(tonumber(rawLen[0]) / 2)
        local raw = ffi.new('wchar_t[?]', chars + 1)
        if lib.WinHttpQueryHeaders(handle, WINHTTP_QUERY_RAW_HEADERS_CRLF, nil, raw, rawLen, nil) ~= 0 then
          headers = lowerHeaders(narrow(raw, math.floor(tonumber(rawLen[0]) / 2)))
        end
      end

      local chunks = {}
      local available = ffi.new('DWORD[1]')
      local read = ffi.new('DWORD[1]')
      while lib.WinHttpQueryDataAvailable(handle, available) ~= 0 and available[0] > 0 do
        local buf = ffi.new('char[?]', available[0])
        if lib.WinHttpReadData(handle, buf, available[0], read) == 0 then break end
        chunks[#chunks + 1] = ffi.string(buf, read[0])
      end
      result = { tonumber(status[0]), table.concat(chunks), headers }
    end
    lib.WinHttpCloseHandle(handle)
    lib.WinHttpCloseHandle(connect)
    return result[1], result[2], result[3]
  end

  return { name = 'winhttp', request = request }
end

-- --------------------------------------------------------- 3. libcurl

local LIBCURL_NAMES = {
  OSX = { '/usr/lib/libcurl.4.dylib', 'libcurl.4.dylib', 'libcurl.dylib' },
  Linux = { 'libcurl.so.4', 'libcurl.so', 'libcurl-gnutls.so.4' },
  BSD = { 'libcurl.so.4', 'libcurl.so' },
}

local function libcurl(ffi)
  local names = LIBCURL_NAMES[ffi.os]
  if not names then return nil end
  local lib
  for _, name in ipairs(names) do
    local ok, loaded = pcall(ffi.load, name)
    if ok then lib = loaded break end
  end
  if not lib then return nil end
  local ok = pcall(ffi.cdef, [[
    typedef void CURL;
    struct curl_slist;
    int curl_global_init(long);
    CURL* curl_easy_init(void);
    int curl_easy_setopt(CURL*, int, ...);
    int curl_easy_perform(CURL*);
    int curl_easy_getinfo(CURL*, int, ...);
    void curl_easy_cleanup(CURL*);
    const char* curl_easy_strerror(int);
    struct curl_slist* curl_slist_append(struct curl_slist*, const char*);
    void curl_slist_free_all(struct curl_slist*);
    typedef size_t (*rs_curl_write_cb)(char*, size_t, size_t, void*);
  ]])
  if not ok then return nil end

  -- Option numbers are fixed by curl's ABI (curl/curl.h).
  local CURLOPT_URL = 10002
  local CURLOPT_HTTPHEADER = 10023
  local CURLOPT_POSTFIELDS = 10015
  local CURLOPT_POSTFIELDSIZE = 60
  local CURLOPT_CUSTOMREQUEST = 10036
  local CURLOPT_HTTPGET = 80
  local CURLOPT_WRITEFUNCTION = 20011
  local CURLOPT_HEADERFUNCTION = 20079
  local CURLOPT_TIMEOUT_MS = 155
  local CURLOPT_CONNECTTIMEOUT_MS = 156
  local CURLOPT_NOSIGNAL = 99
  local CURLOPT_USERAGENT = 10018
  local CURLINFO_RESPONSE_CODE = 0x200002
  local CURL_GLOBAL_DEFAULT = 3

  if lib.curl_global_init(CURL_GLOBAL_DEFAULT) ~= 0 then return nil end

  -- One body and one header buffer, filled by two callbacks created once:
  -- an FFI callback is a scarce resource, so it is never made per request.
  local bodyChunks, headerChunks = {}, {}
  local writeBody = ffi.cast('rs_curl_write_cb', function(ptr, size, n)
    bodyChunks[#bodyChunks + 1] = ffi.string(ptr, size * n)
    return size * n
  end)
  local writeHeader = ffi.cast('rs_curl_write_cb', function(ptr, size, n)
    headerChunks[#headerChunks + 1] = ffi.string(ptr, size * n)
    return size * n
  end)

  -- curl_easy_setopt is variadic, and LuaJIT passes a plain Lua number to a
  -- variadic C function as a double. Every numeric option is cast to long.
  local function long(n) return ffi.cast('long', n) end

  local function request(req)
    local handle = lib.curl_easy_init()
    if handle == nil then return 0, 'curl_init_failed', {} end
    bodyChunks, headerChunks = {}, {}
    local list = nil
    for k, v in pairs(req.headers or {}) do list = lib.curl_slist_append(list, k .. ': ' .. v) end
    -- curl adds "Expect: 100-continue" to larger POSTs; the API never needs it.
    list = lib.curl_slist_append(list, 'Expect:')
    local ms = math.floor((req.timeout or DEFAULT_TIMEOUT) * 1000)

    lib.curl_easy_setopt(handle, CURLOPT_URL, req.url)
    lib.curl_easy_setopt(handle, CURLOPT_HTTPHEADER, list)
    lib.curl_easy_setopt(handle, CURLOPT_NOSIGNAL, long(1))
    lib.curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, long(ms))
    lib.curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT_MS, long(math.min(ms, 10000)))
    lib.curl_easy_setopt(handle, CURLOPT_USERAGENT, 'ravensight-love')
    lib.curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, writeBody)
    lib.curl_easy_setopt(handle, CURLOPT_HEADERFUNCTION, writeHeader)
    local body = req.body
    if req.method == 'GET' or not req.method then
      lib.curl_easy_setopt(handle, CURLOPT_HTTPGET, long(1))
    else
      body = body or ''
      lib.curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, long(#body))
      lib.curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body)
      if req.method ~= 'POST' then lib.curl_easy_setopt(handle, CURLOPT_CUSTOMREQUEST, req.method) end
    end

    local code = lib.curl_easy_perform(handle)
    local status, responseBody, headers
    if code == 0 then
      local out = ffi.new('long[1]')
      lib.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, out)
      status, responseBody = tonumber(out[0]), table.concat(bodyChunks)
      -- A redirect or 100 response adds a header block; keep the last one.
      local raw = table.concat(headerChunks)
      local last = raw:match('.*\r?\n\r?\n(HTTP/.-)$') or raw
      headers = lowerHeaders(last)
    else
      status, responseBody, headers = 0, ffi.string(lib.curl_easy_strerror(code)), {}
    end
    lib.curl_easy_cleanup(handle)
    if list ~= nil then lib.curl_slist_free_all(list) end
    -- `body` must outlive curl_easy_perform: CURLOPT_POSTFIELDS does not copy.
    local _ = body
    return status, responseBody, headers
  end

  -- curl calls back into Lua from inside curl_easy_perform. LuaJIT cannot
  -- run a callback while the caller is JIT-compiled code, so this one
  -- function always runs in the interpreter.
  if jit then jit.off(request, true) end

  return { name = 'libcurl', request = request }
end

-- ------------------------------------------------------ 4. curl command

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
transport._shellQuote = shellQuote

--- The curl command line for a request, written so nothing from the request
--- reaches the shell unquoted. Exposed for the tests.
function transport._curlCommand(req, bodyFile, headerFile)
  local parts = {
    'curl', '--silent', '--show-error', '--max-time', tostring(req.timeout or DEFAULT_TIMEOUT),
    '--request', shellQuote(req.method or 'GET'),
    '--dump-header', shellQuote(headerFile),
    '--write-out', shellQuote('\n%{http_code}'),
  }
  local names = {}
  for k in pairs(req.headers or {}) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do
    parts[#parts + 1] = '--header'
    parts[#parts + 1] = shellQuote(k .. ': ' .. req.headers[k])
  end
  if bodyFile then
    parts[#parts + 1] = '--data-binary'
    parts[#parts + 1] = shellQuote('@' .. bodyFile)
  end
  parts[#parts + 1] = shellQuote(req.url)
  return table.concat(parts, ' ') .. ' 2>/dev/null'
end

local function curlCommand(ffi)
  -- Windows is left out on purpose: a windowed game that starts a console
  -- program flashes a console window on every request.
  if ffi and ffi.os == 'Windows' then return nil end
  if not io or not io.popen then return nil end
  local probe = io.popen('curl --version 2>/dev/null')
  local version = probe and probe:read('*l')
  if probe then probe:close() end
  if not version or not version:match('^curl') then return nil end

  return {
    name = 'curl',
    request = function(req)
      local bodyFile
      if req.body then
        bodyFile = os.tmpname()
        local f = io.open(bodyFile, 'wb')
        if not f then return 0, 'tempfile_failed', {} end
        f:write(req.body)
        f:close()
      end
      local headerFile = os.tmpname()
      local pipe = io.popen(transport._curlCommand(req, bodyFile, headerFile))
      local output = pipe and pipe:read('*a') or ''
      if pipe then pipe:close() end
      if bodyFile then os.remove(bodyFile) end
      local hf = io.open(headerFile, 'rb')
      local rawHeaders = hf and hf:read('*a') or ''
      if hf then hf:close() end
      os.remove(headerFile)
      local responseBody, code = output:match('^(.*)\n(%d%d%d)$')
      if not code or code == '000' then return 0, 'network_error', {} end
      local last = rawHeaders:match('.*\r?\n\r?\n(HTTP/.-)$') or rawHeaders
      return tonumber(code), responseBody, lowerHeaders(last)
    end,
  }
end

-- ----------------------------------------------------------- selection

--- Returns the first transport that works here, or nil. `prefer` names one
--- ("https", "winhttp", "libcurl" or "curl") to try first.
function transport.select(prefer)
  local okFfi, ffi = pcall(require, 'ffi')
  if not okFfi then ffi = nil end
  local candidates = {
    https = httpsModule,
    winhttp = function() return ffi and winhttp(ffi) end,
    libcurl = function() return ffi and libcurl(ffi) end,
    curl = function() return curlCommand(ffi) end,
  }
  local order = { 'https', 'winhttp', 'libcurl', 'curl' }
  if prefer and candidates[prefer] then table.insert(order, 1, prefer) end
  for _, name in ipairs(order) do
    local ok, chosen = pcall(candidates[name])
    if ok and chosen then return chosen end
  end
  return nil
end

return transport
