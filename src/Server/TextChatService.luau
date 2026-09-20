--!strict
--[=[
	Server-first wrapper around Roblox TextChatService.

	@class TextChatService
]=]

local RobloxTextChatService = game:GetService("TextChatService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local require = require(script.Parent.loader).load(script)

local Maid = require("Maid")
local Log = require("Log")
local Signal = require("Signal")
local TextChatServiceConstants = require("TextChatServiceConstants")
local TextChatSharedUtils = require("TextChatSharedUtils")

type ChannelConfig = TextChatServiceConstants.ChannelConfig
type ChatTagConfig = TextChatServiceConstants.ChatTagConfig
type CommandConfig = TextChatServiceConstants.CommandConfig
type CommandContext = TextChatServiceConstants.CommandContext
type MessagePayload = TextChatServiceConstants.MessagePayload
type PermissionResult = TextChatServiceConstants.PermissionResult

type CommandRecord = {
	Config: CommandConfig,
	Instance: TextChatCommand,
	Connections: { RBXScriptConnection },
}

local TextChatService = {}
TextChatService.ServiceName = "TextChatService"

local function createSignal<T...>()
	return Signal.new() :: Signal.Signal<T...>
end

local function getOrCreateFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA("Folder"), `{name} must be a Folder`)
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function getOrCreateRemoteFunction(parent: Instance, name: string): RemoteFunction
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteFunction"), `{name} must be a RemoteFunction`)
		return existing
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function getOrCreateRemoteEvent(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), `{name} must be a RemoteEvent`)
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function getTextChannelsFolder(): Folder
	local folder = RobloxTextChatService:FindFirstChild("TextChannels")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "TextChannels"
		folder.Parent = RobloxTextChatService
	end

	return folder :: Folder
end

local function getTextChatCommandsFolder(): Folder
	local folder = RobloxTextChatService:FindFirstChild("TextChatCommands")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "TextChatCommands"
		folder.Parent = RobloxTextChatService
	end

	return folder :: Folder
end

local function playerFromTextSource(textSource: TextSource?): Player?
	if textSource == nil then
		return nil
	end

	return Players:GetPlayerByUserId(textSource.UserId)
end

function TextChatService:Init(serviceBag)
	assert(not self._serviceBag, "Already initialized")
	self._serviceBag = assert(serviceBag, "No serviceBag")
	self._maid = Maid.new()

	self._registeredTags = {} :: { [string]: ChatTagConfig }
	self._playerTagsByUserId = {} :: { [number]: { string } }
	self._commands = {} :: { [string]: CommandRecord }

	self.MessageReceived = createSignal<MessagePayload>()
	self.MessageSent = createSignal<MessagePayload>()
	self.MessageFailed = createSignal<MessagePayload>()
	self.SystemMessageReceived = createSignal<MessagePayload>()
	self.ChannelAdded = createSignal<TextChannel>()
	self.ChannelRemoved = createSignal<string>()
	self.PlayerTagsChanged = createSignal<Player, { string }>()
	self.CommandExecuted = createSignal<CommandContext>()
	self.ChatPermissionChanged = createSignal<Player, PermissionResult>()

	self._maid:GiveTask(self.MessageReceived)
	self._maid:GiveTask(self.MessageSent)
	self._maid:GiveTask(self.MessageFailed)
	self._maid:GiveTask(self.SystemMessageReceived)
	self._maid:GiveTask(self.ChannelAdded)
	self._maid:GiveTask(self.ChannelRemoved)
	self._maid:GiveTask(self.PlayerTagsChanged)
	self._maid:GiveTask(self.CommandExecuted)
	self._maid:GiveTask(self.ChatPermissionChanged)
end

function TextChatService:Start()
	self:_setupRemotes()
	self:_connectTextChatSignals()

	self._maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self._playerTagsByUserId[player.UserId] = nil
		self:_fireClientEventAll(TextChatServiceConstants.EventNames.PlayerTagsChanged, player.UserId, {})
	end))
end

function TextChatService:_setupRemotes()
	local folder = getOrCreateFolder(ReplicatedStorage, TextChatServiceConstants.RemoteFolderName)
	self._remoteFolder = folder
	self._requestRemote = getOrCreateRemoteFunction(folder, TextChatServiceConstants.RequestRemoteName)
	self._eventRemote = getOrCreateRemoteEvent(folder, TextChatServiceConstants.EventRemoteName)

	self._requestRemote.OnServerInvoke = function(player, requestName: string, ...)
		return self:_handleClientRequest(player, requestName, ...)
	end
end

function TextChatService:_connectTextChatSignals()
	self._maid:GiveTask(RobloxTextChatService.MessageReceived:Connect(function(message: TextChatMessage)
		local payload = self:_messageToPayload(message)
		self.MessageReceived:Fire(payload)
	end))
end

function TextChatService:_messageToPayload(message: TextChatMessage): MessagePayload
	return {
		Text = message.Text,
		Metadata = message.Metadata,
		ChannelName = if message.TextChannel ~= nil then message.TextChannel.Name else nil,
		UserId = if message.TextSource ~= nil then message.TextSource.UserId else nil,
		MessageId = message.MessageId,
		Status = tostring(message.Status),
	}
end

function TextChatService:_fireClientEventAll(eventName: string, ...)
	if self._eventRemote == nil then
		return
	end

	self._eventRemote:FireAllClients(eventName, ...)
end

function TextChatService:_fireClientEvent(player: Player, eventName: string, ...)
	if self._eventRemote == nil then
		return
	end

	self._eventRemote:FireClient(player, eventName, ...)
end

function TextChatService:_handleClientRequest(player: Player, requestName: string, ...)
	local requests = TextChatServiceConstants.Requests

	if requestName == requests.GetCanChat then
		return self:CanUserChatAsync(player)
	elseif requestName == requests.GetCanChatWith then
		local targetUserId = ...
		return self:_canChatWithUserIdAsync(player, targetUserId)
	elseif requestName == requests.SendMessage then
		local channelName = ...
		return self:_prepareClientMessageAsync(player, channelName)
	elseif requestName == requests.SendDirectMessage then
		local toUserIds = ...
		return self:_prepareDirectMessageAsync(player, toUserIds)
	elseif requestName == requests.GetPlayerTags then
		local userId = ...
		return self:GetPlayerTagsByUserId(userId)
	elseif requestName == requests.GetAllPlayerTags then
		return table.clone(self._playerTagsByUserId)
	elseif requestName == requests.GetRegisteredTags then
		return table.clone(self._registeredTags)
	else
		return false, `Unknown request {tostring(requestName)}`
	end
end

function TextChatService:_prepareClientMessageAsync(player: Player, channelName: string)
	local canChat, reason = self:CanUserChatAsync(player)
	if not canChat then
		return false, reason
	end

	local channel = self:GetOrCreateChannel(channelName)
	self:AddUserToChannel(player, channel.Name)
	return true, channel.Name
end

function TextChatService:_prepareDirectMessageAsync(player: Player, toUserIds: { number })
	if typeof(toUserIds) ~= "table" then
		return false, "Invalid recipients"
	end

	local recipients = {}
	local directUserIds = { player.UserId }
	for _, userId in toUserIds do
		if type(userId) ~= "number" then
			return false, "Invalid recipient"
		end

		local recipient = Players:GetPlayerByUserId(userId)
		if recipient == nil then
			return false, "Recipient is not in this server"
		end

		table.insert(recipients, recipient)
		table.insert(directUserIds, userId)
	end

	local directResults = self:CanUsersDirectChatAsync(player, recipients)
	for recipient, allowed in directResults do
		if not allowed then
			return false, `Cannot direct chat with {recipient.UserId}`
		end
	end

	local channelName = TextChatSharedUtils.getDirectChannelName(directUserIds)
	local channel = self:GetOrCreateChannel(channelName)
	pcall(function()
		channel:SetDirectChatRequester(player)
	end)
	self:AddUserToChannel(player, channel.Name)
	for _, recipient in recipients do
		self:AddUserToChannel(recipient, channel.Name)
	end

	return true, channel.Name
end

function TextChatService:_canChatWithUserIdAsync(player: Player, targetUserId: number)
	if type(targetUserId) ~= "number" then
		return false, "Invalid target user id"
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	if target == nil then
		return false, "Target is not in this server"
	end

	return self:CanUsersChatAsync(player, target)
end

function TextChatService:CanUserChatAsync(player: Player): (boolean, string?)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Bad player")

	local ok, result = pcall(function()
		return RobloxTextChatService:CanUserChatAsync(player.UserId)
	end)

	if not ok then
		return false, tostring(result)
	end

	return result == true, if result == true then nil else "User cannot chat"
end

function TextChatService:CanUsersChatAsync(fromPlayer: Player, toPlayer: Player): (boolean, string?)
	assert(typeof(fromPlayer) == "Instance" and fromPlayer:IsA("Player"), "Bad fromPlayer")
	assert(typeof(toPlayer) == "Instance" and toPlayer:IsA("Player"), "Bad toPlayer")

	local ok, result = pcall(function()
		return RobloxTextChatService:CanUsersChatAsync(fromPlayer.UserId, toPlayer.UserId)
	end)

	if not ok then
		return false, tostring(result)
	end

	return result == true, if result == true then nil else "Users cannot chat"
end

function TextChatService:CanUsersDirectChatAsync(fromPlayer: Player, toPlayers: { Player }): { [Player]: boolean }
	assert(typeof(fromPlayer) == "Instance" and fromPlayer:IsA("Player"), "Bad fromPlayer")

	local targetUserIds = table.create(#toPlayers)
	for index, player in toPlayers do
		assert(typeof(player) == "Instance" and player:IsA("Player"), "Bad toPlayers entry")
		targetUserIds[index] = player.UserId
	end

	local resultByPlayer = {}
	local ok, result = pcall(function()
		return RobloxTextChatService:CanUsersDirectChatAsync(fromPlayer.UserId, targetUserIds)
	end)

	if ok and typeof(result) == "table" then
		local eligibleUserIds = {}
		for _, userId in result do
			eligibleUserIds[userId] = true
		end

		for _, player in toPlayers do
			resultByPlayer[player] = eligibleUserIds[player.UserId] == true
		end
	else
		for _, player in toPlayers do
			resultByPlayer[player] = false
		end
	end

	return resultByPlayer
end

function TextChatService:RegisterChannel(config: ChannelConfig): TextChannel
	assert(type(config) == "table", "Bad channel config")

	local channel = self:GetOrCreateChannel(config.Name)
	if config.DisplayName ~= nil then
		channel.DisplayName = config.DisplayName
	end
	if config.Metadata ~= nil then
		channel:SetAttribute("Metadata", config.Metadata)
	end
	if config.AutoJoin ~= nil then
		channel:SetAttribute("AutoJoin", config.AutoJoin)
	end

	return channel
end

function TextChatService:GetOrCreateChannel(name: string): TextChannel
	local channelName = TextChatSharedUtils.sanitizeChannelName(name)
	local textChannels = getTextChannelsFolder()
	local existing = textChannels:FindFirstChild(channelName)

	if existing then
		assert(existing:IsA("TextChannel"), `{channelName} must be a TextChannel`)
		return existing
	end

	local channel = Instance.new("TextChannel")
	channel.Name = channelName
	channel.Parent = textChannels
	self.ChannelAdded:Fire(channel)
	self:_fireClientEventAll(TextChatServiceConstants.EventNames.ChannelAdded, channelName)
	return channel
end

function TextChatService:AddUserToChannel(player: Player, channelName: string)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Bad player")

	local channel = self:GetOrCreateChannel(channelName)
	if channel:FindFirstChild(tostring(player.UserId)) then
		return
	end

	channel:AddUserAsync(player.UserId)
end

function TextChatService:RemoveUserFromChannel(player: Player, channelName: string)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Bad player")

	local channel = self:GetOrCreateChannel(channelName)
	local textSource = channel:FindFirstChild(tostring(player.UserId))
	if textSource then
		textSource:Destroy()
	end
end

function TextChatService:SendSystemMessage(channelName: string, message: string, metadata: string?)
	local channel = self:GetOrCreateChannel(channelName)
	local ok, err = pcall(function()
		channel:DisplaySystemMessage(message, metadata)
	end)

	local payload = {
		Text = message,
		Metadata = metadata,
		ChannelName = channel.Name,
	}

	if ok then
		self.SystemMessageReceived:Fire(payload)
		self:_fireClientEventAll(TextChatServiceConstants.EventNames.SystemMessageReceived, payload)
	else
		Log.Warn("Failed to display system message", {
			ChannelName = channel.Name,
			Error = tostring(err),
		})
	end
end

function TextChatService:RegisterTag(tagConfig: ChatTagConfig)
	assert(type(tagConfig) == "table", "Bad tag config")
	local tagName = TextChatSharedUtils.assertNonEmptyString(tagConfig.Name, "tagConfig.Name")

	self._registeredTags[tagName] = {
		Name = tagName,
		Text = tagConfig.Text,
		Color = tagConfig.Color,
		Priority = tagConfig.Priority,
	}

	self:_fireClientEventAll(TextChatServiceConstants.TagSnapshotEvent, self._registeredTags, self._playerTagsByUserId)
end

function TextChatService:SetPlayerTags(player: Player, tags: { string })
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Bad player")
	assert(type(tags) == "table", "Bad tags")

	local nextTags = table.clone(tags)
	table.sort(nextTags)
	self._playerTagsByUserId[player.UserId] = nextTags

	self.PlayerTagsChanged:Fire(player, table.clone(nextTags))
	self:_fireClientEventAll(TextChatServiceConstants.EventNames.PlayerTagsChanged, player.UserId, nextTags)
end

function TextChatService:GetPlayerTags(player: Player): { string }
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Bad player")
	return self:GetPlayerTagsByUserId(player.UserId)
end

function TextChatService:GetPlayerTagsByUserId(userId: number): { string }
	local tags = self._playerTagsByUserId[userId]
	return if tags ~= nil then table.clone(tags) else {}
end

function TextChatService:RegisterCommand(commandConfig: CommandConfig)
	assert(type(commandConfig) == "table", "Bad command config")
	local commandName = TextChatSharedUtils.assertNonEmptyString(commandConfig.Name, "commandConfig.Name")
	local primaryAlias = TextChatSharedUtils.assertNonEmptyString(commandConfig.PrimaryAlias, "commandConfig.PrimaryAlias")

	self:UnregisterCommand(commandName)

	local commandsFolder = getTextChatCommandsFolder()
	local command = Instance.new("TextChatCommand")
	command.Name = commandName
	command.PrimaryAlias = primaryAlias
	command.SecondaryAlias = if commandConfig.SecondaryAliases ~= nil then commandConfig.SecondaryAliases[1] or "" else ""
	command.Parent = commandsFolder

	local record: CommandRecord = {
		Config = commandConfig,
		Instance = command,
		Connections = {},
	}

	table.insert(record.Connections, command.Triggered:Connect(function(originTextSource: TextSource, unfilteredText: string)
		self:_handleCommandTriggered(record, originTextSource, unfilteredText)
	end))

	self._commands[commandName] = record
end

function TextChatService:UnregisterCommand(commandName: string)
	local record = self._commands[commandName]
	if record == nil then
		return
	end

	for _, connection in record.Connections do
		connection:Disconnect()
	end
	record.Instance:Destroy()
	self._commands[commandName] = nil
end

function TextChatService:_handleCommandTriggered(record: CommandRecord, originTextSource: TextSource, unfilteredText: string)
	local player = playerFromTextSource(originTextSource)
	if player == nil then
		return
	end

	local config = record.Config
	if config.Permission ~= nil then
		local allowed, reason = config.Permission(player)
		if not allowed then
			self:_fireClientEvent(player, TextChatServiceConstants.EventNames.MessageFailed, {
				Text = unfilteredText,
				UserId = player.UserId,
				Status = reason or "Command permission denied",
			})
			return
		end
	end

	local context: CommandContext = {
		Player = player,
		TextSource = originTextSource,
		RawText = unfilteredText,
		Arguments = TextChatSharedUtils.parseCommandArguments(config.PrimaryAlias, unfilteredText),
		CommandName = config.Name,
	}

	self.CommandExecuted:Fire(context)
	if config.ReplicateToClients == true then
		self:_fireClientEventAll(TextChatServiceConstants.EventNames.CommandExecuted, {
			UserId = player.UserId,
			RawText = unfilteredText,
			Arguments = context.Arguments,
			CommandName = context.CommandName,
		})
	end

	if config.Run ~= nil then
		task.spawn(config.Run, context)
	end
end

function TextChatService:Destroy()
	if self._requestRemote ~= nil then
		self._requestRemote.OnServerInvoke = nil
	end

	for commandName in self._commands do
		self:UnregisterCommand(commandName)
	end

	self._maid:DoCleaning()
end

return TextChatService
