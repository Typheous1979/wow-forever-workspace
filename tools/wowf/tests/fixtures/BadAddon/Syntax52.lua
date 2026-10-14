local addonName, ns = ...
local a, b = 7, 2
local q = a // b
local m = a & b
local e = _ENV
for i = 1, 3 do
    if i == 2 then goto continue end
    ::continue::
end
