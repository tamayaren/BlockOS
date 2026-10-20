-- User accounts with salted SHA-256 password hashes.

local Config = BlockOS.Require("config")
local Sha256 = BlockOS.Require("sha256")

local Users = {}

Users.Path = "/blockos/data/users.dat"
Users.Home = "/home"

local function RandomSalt()
	local Bytes = {}
	for Index = 1, 16 do
		Bytes[Index] = string.format("%02x", math.random(0, 255))
	end
	return table.concat(Bytes)
end

local function Hash(Salt, Password)
	return Sha256.Hex(Salt .. ":" .. Password)
end

function Users.Load()
	local Data = Config.Read(Users.Path)
	if (type(Data) ~= "table") then return {} end
	return Data
end

function Users.Save(List)
	return Config.Write(Users.Path, List)
end

function Users.HasAny()
	return #Users.Load() > 0
end

function Users.Primary()
	return Users.Load()[1]
end

function Users.Find(Name)
	for _, User in ipairs(Users.Load()) do
		if (User.Name == Name) then return User end
	end
	return nil
end

function Users.Create(Name, Password, Extra)
	local List = Users.Load()
	local Salt = RandomSalt()
	local User = {
		Name = Name,
		Salt = Salt,
		Hash = Hash(Salt, Password or ""),
		HasPassword = (Password or "") ~= "",
		Color = colors.blue
	}
	for Key, Value in pairs(Extra or {}) do
		User[Key] = Value
	end
	table.insert(List, User)
	Users.Save(List)
	Users.EnsureHome()
	return User
end

function Users.Update(Name, Changes)
	local List = Users.Load()
	for _, User in ipairs(List) do
		if (User.Name == Name) then
			for Key, Value in pairs(Changes) do
				User[Key] = Value
			end
			Users.Save(List)
			return User
		end
	end
	return nil
end

function Users.SetPassword(Name, Password)
	local Salt = RandomSalt()
	return Users.Update(Name, { Salt = Salt, Hash = Hash(Salt, Password), HasPassword = Password ~= "" })
end

function Users.Verify(Name, Password)
	local User = Users.Find(Name)
	if (not User) then return false end
	return Hash(User.Salt, Password or "") == User.Hash
end

function Users.EnsureHome()
	for _, Folder in ipairs({ "", "Documents", "Desktop", "Music", "Recordings", "Pictures", "Downloads" }) do
		local Path = fs.combine(Users.Home, Folder)
		if (not fs.exists(Path)) then
			fs.makeDir(Path)
		end
	end
end

return Users
