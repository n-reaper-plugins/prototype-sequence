-- Build:  lua tools/build.lua        (run from the project root)
-- Output: dist/PrototypeSequence.lua  = the ONE file users need
package.path = "./src/?.lua;" .. package.path
local Core = require("ProtoCore")
local MODULES = { "ProtoCore", "ProtoReaper", "ProtoApp", "ProtoUI" }

local function read(p) local f = assert(io.open(p, "rb"), "cannot read " .. p); local s = f:read("*a"); f:close(); return s end
local function write(p, s) local f = assert(io.open(p, "wb"), "cannot write " .. p); f:write(s); f:close() end

local main = read("src/PrototypeSequence.lua"):gsub("@@VERSION@@", Core.VERSION)
local header, body = {}, main
while true do
  local line, rest = body:match("^([^\n]*)\n(.*)$")
  if line and line:match("^%-%-") then header[#header + 1] = line; body = rest else break end
end
local out = { table.concat(header, "\n"),
  "-- BUNDLED BUILD of PrototypeSequence v" .. Core.VERSION .. " - edit the files in src/, not this one.",
  "local __preload = package.preload" }
for _, m in ipairs(MODULES) do
  out[#out + 1] = string.format('__preload["%s"] = function(...)\n%s\nend', m, read("src/" .. m .. ".lua"))
end
out[#out + 1] = body
os.execute("mkdir -p dist")
write("dist/PrototypeSequence.lua", table.concat(out, "\n") .. "\n")
print("built dist/PrototypeSequence.lua v" .. Core.VERSION)
