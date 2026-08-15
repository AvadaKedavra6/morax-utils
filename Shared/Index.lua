MoraxUtils = MoraxUtils or {}

local Modules = {
    "Utils/Cleaner.lua",
    "Utils/Promise.lua",
    "Utils/Net.lua",
	"Utils/Component.lua",
}

for _, module_path in ipairs(Modules) do
	local ok, err = pcall(Package.Require, module_path)

	if not ok then
		Console.Error(string.format("[Morax-utils] Loading failed '%s': %s", module_path, tostring(err)))
		break
	end
end

Package.Export("MoraxUtils", MoraxUtils)
