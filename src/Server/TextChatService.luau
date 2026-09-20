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
local Promise = require("Promise")
local Remoting = require("Remoting")
local Signal = require("Signal")
local TextChatServiceConstants = require("TextChatServiceConstants")
local TextChatSharedUtils = require("TextChatSharedUtils")

type ChannelConfig = TextChatServiceConstants.ChannelConfig
type ChannelDeliveryContext = TextChatServiceConstants.ChannelDeliveryContext
type ChatTagConfig = TextChatServiceConstants.ChatTagConfig
type ChatEligibilitySnapshot = TextChatServiceConstants.ChatEligibilitySnapshot
type ChatEligibilityTrackingConfig = TextChatServiceConstants.ChatEligibilityTrackingConfig
type CommandConfig = TextChatServiceConstants.CommandConfig
type CommandContext = TextChatServiceConstants.CommandContext
type MessagePayload = TextChatServiceConstants.MessagePayload
type PermissionResult = TextChatServiceConstants.PermissionResult
type ProximityChannelConfig = TextChatServiceConstants.ProximityChannelConfig

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
	self._channelDeliveryPredicates = {} :: { [string]: (ChannelDeliveryContext) -> (boolean, string?) }
	self._chatEligibilityByViewerUserId = {} :: { [number]: ChatEligibilitySnapshot }
	self._chatEligibilityTrackingMaid = nil
	self._chatEligibilityTrackingConfig = nil :: ChatEligibilityTrackingConfig?
	self._remoting = Remoting.Server.new(ReplicatedStorage, TextChatServiceConstants.RemotingName)

	self.MessageReceived = createSignal<MessagePayload>()
	self.MessageSent = createSignal<MessagePayload>()
	self.MessageFailed = createSignal<MessagePayload>()
	self.SystemMessageReceived = createSignal<MessagePayload>()
	self.ChannelAdded = createSignal<TextChannel>()
	self.ChannelRemoved = createSignal<string>()
	self.PlayerTagsChanged = createSignal<Player, { string }>()
	self.CommandExecuted = createSignal<CommandContext>()
	self.ChatPermissionChanged = createSignal<Player, PermissionResult>()
	self.ChatEligibilitySnapshotChanged = createSignal<Player, ChatEligibilitySnapshot>()

	self._maid:GiveTask(self.MessageReceived)
	self._maid:GiveTask(self.MessageSent)
	self._maid:GiveTask(self.MessageFailed)
	self._maid:GiveTask(self.SystemMessageReceived)
	self._maid:GiveTask(self.ChannelAdded)
	self._maid:GiveTask(self.ChannelRemoved)
	self._maid:GiveTask(self.PlayerTagsChanged)
	self._maid:GiveTask(self.CommandExecuted)
	self._maid:GiveTask(self.ChatPermissionChanged)
	self._maid:GiveTask(self.ChatEligibilitySnapshotChanged)
	self._maid:GiveTask(self._remoting)
end

function TextChatService:Start()
	self:_setupRemoting()
	self:_connectTextChatSignals()

	self._maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self._playerTagsByUserId[player.UserId] = nil
		self:_removePlayerFromChatEligibilitySnapshot(player)
		self:_fireClientEventAll(TextChatServiceConstants.EventNames.PlayerTagsChanged, player.UserId, {})
	end))
end

function TextChatService:_setupRemoting()
	local requests = TextChatServiceConstants.Requests
	local events = TextChatServiceConstants.EventNames

	for _, eventName in events do
		self._remoting:DeclareEvent(eventName)
	end
	self._remoting:DeclareEvent(TextChatServiceConstants.TagSnapshotEvent)

	self._maid:GiveTask(self._remoting:Bind(requests.GetCanChat, function(player)
		return self:CanUserChatAsync(player)
	end))

	self._maid:GiveTask(self._remoting:Bind(requests.GetCanChatWith, function(player, targetUserId)
		return self:_canChatWithUserIdAsync(player, targetUserId)
	end))

	self._maid:GiveTask(self._remoting:Bind(requests.GetChatEligibilitySnapshot, function(player)
		return self:GetChatEligibilitySnapshot(player)
	end))

	self._maid:GiveTask(self._remoting:Bind(requests.SendMessage, function(player, channelName)
		return self:_prepareClientMessageAsync(player, channelName)
	end))

	self._maid:GiveTask(self._remoting:Bind(requests.SendDirectMessage, function(player, toUserIds)
		return self:_prepareDirectMessageAsync(player, toUserIds)
	end))

	self._maid:GiveTask(self._remoting:Bind(requests.GetPlayerTags, function(_player, userId)
		return self:GetPlayerTagsByUserId(userId)
	end))

	self._maid:GiveTask(self._remoting:Bind(requests.GetAllPlayerTags, function(_player)
		return table.clone(self._playerTagsByUserId)
	end))

	self._maid:GiveTask(self._remoting:Bind(requests.GetRegisteredTags, function(_player)
		return table.clone(self._registeredTags)
	end))
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
	self._remoting:FireAllClients(eventName, ...)
end

function TextChatService:_fireClientEvent(player: Player, eventName: string, ...)
	self._remoting:FireClient(eventName, player, ...)
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

function TextChatService:PromiseCanUserChat(player: Player)
	return Promise.spawn(function(resolve, reject)
		local allowed, reason = self:CanUserChatAsync(player)
		if allowed then
			resolve(true)
		else
			reject(reason or "User cannot chat")
		end
	end)
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

function TextChatService:PromiseCanUsersChat(fromPlayer: Player, toPlayer: Player)
	return Promise.spawn(function(resolve, reject)
		local allowed, reason = self:CanUsersChatAsync(fromPlayer, toPlayer)
		if allowed then
			resolve(true)
		else
			reject(reason or "Users cannot chat")
		end
	end)
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

function TextChatService:PromiseCanUsersDirectChat(fromPlayer: Player, toPlayers: { Player })
	return Promise.spawn(function(resolve)
		resolve(self:CanUsersDirectChatAsync(fromPlayer, toPlayers))
	end)
end

function TextChatService:StartChatEligibilityTracking(config: ChatEligibilityTrackingConfig?)
	if self._chatEligibilityTrackingMaid ~= nil then
		self:StopChatEligibilityTracking()
	end

	local trackingMaid = Maid.new()
	self._chatEligibilityTrackingMaid = trackingMaid
	self._chatEligibilityTrackingConfig = config or {}

	trackingMaid:GiveTask(Players.PlayerAdded:Connect(function(player)
		local trackingConfig = self._chatEligibilityTrackingConfig
		if trackingConfig ~= nil and trackingConfig.RefreshOnPlayerAdded == false then
			return
		end

		task.spawn(function()
			self:_refreshChatEligibilityForPlayer(player)
			for _, otherPlayer in Players:GetPlayers() do
				if otherPlayer ~= player then
					self:_refreshChatEligibilityForPlayer(otherPlayer)
				end
			end
		end)
	end))

	task.spawn(function()
		self:RefreshChatEligibilitySnapshots()
	end)
end

function TextChatService:StopChatEligibilityTracking()
	if self._chatEligibilityTrackingMaid ~= nil then
		self._chatEligibilityTrackingMaid:DoCleaning()
		self._chatEligibilityTrackingMaid = nil
	end

	self._chatEligibilityTrackingConfig = nil
	self._chatEligibilityByViewerUserId = {}

	for _, player in Players:GetPlayers() do
		self.ChatEligibilitySnapshotChanged:Fire(player, {})
		self:_fireClientEvent(player, TextChatServiceConstants.EventNames.ChatEligibilitySnapshot, {})
	end
end

function TextChatService:RefreshChatEligibilitySnapshots()
	for _, player in Players:GetPlayers() do
		self:_refreshChatEligibilityForPlayer(player)
	end
end

function TextChatService:GetChatEligibilitySnapshot(player: Player): ChatEligibilitySnapshot
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Bad player")

	local snapshot = self._chatEligibilityByViewerUserId[player.UserId]
	if snapshot == nil then
		return {}
	end

	return self:_cloneChatEligibilitySnapshot(snapshot)
end

function TextChatService:_refreshChatEligibilityForPlayer(viewer: Player)
	if self._chatEligibilityTrackingMaid == nil then
		return
	end

	if viewer.Parent ~= Players then
		return
	end

	local targets = {}
	for _, target in Players:GetPlayers() do
		if target ~= viewer then
			table.insert(targets, target)
		end
	end

	local directResults = {}
	if #targets > 0 then
		directResults = self:CanUsersDirectChatAsync(viewer, targets)
	end
	local snapshot = {}
	for _, target in targets do
		local allowed = directResults[target] == true
		snapshot[target.UserId] = TextChatSharedUtils.normalizePermissionResult(
			allowed,
			if allowed then nil else "Users cannot chat"
		)
	end

	if viewer.Parent ~= Players or self._chatEligibilityTrackingMaid == nil then
		return
	end

	self._chatEligibilityByViewerUserId[viewer.UserId] = snapshot
	local clonedSnapshot = self:_cloneChatEligibilitySnapshot(snapshot)
	self.ChatEligibilitySnapshotChanged:Fire(viewer, clonedSnapshot)
	self:_fireClientEvent(viewer, TextChatServiceConstants.EventNames.ChatEligibilitySnapshot, clonedSnapshot)
end

function TextChatService:_removePlayerFromChatEligibilitySnapshot(player: Player)
	self._chatEligibilityByViewerUserId[player.UserId] = nil

	for viewerUserId, snapshot in self._chatEligibilityByViewerUserId do
		snapshot[player.UserId] = nil

		local viewer = Players:GetPlayerByUserId(viewerUserId)
		if viewer ~= nil then
			local clonedSnapshot = self:_cloneChatEligibilitySnapshot(snapshot)
			self.ChatEligibilitySnapshotChanged:Fire(viewer, clonedSnapshot)
			self:_fireClientEvent(viewer, TextChatServiceConstants.EventNames.ChatEligibilitySnapshot, clonedSnapshot)
		end
	end
end

function TextChatService:_cloneChatEligibilitySnapshot(snapshot: ChatEligibilitySnapshot): ChatEligibilitySnapshot
	local clone = {}
	for userId, result in snapshot do
		clone[userId] = {
			Allowed = result.Allowed,
			Reason = result.Reason,
		}
	end

	return clone
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
	if config.ShouldDeliver ~= nil then
		self:SetChannelDeliveryPredicate(channel.Name, config.ShouldDeliver)
	end

	return channel
end

function TextChatService:SetChannelDeliveryPredicate(
	channelName: string,
	shouldDeliver: ((ChannelDeliveryContext) -> (boolean, string?))?
)
	local channel = self:GetOrCreateChannel(channelName)

	if shouldDeliver == nil then
		self._channelDeliveryPredicates[channel.Name] = nil
		channel.ShouldDeliverCallback = nil
		return
	end

	self._channelDeliveryPredicates[channel.Name] = shouldDeliver
	channel.ShouldDeliverCallback = function(message: TextChatMessage, toTextSource: TextSource): boolean
		local predicate = self._channelDeliveryPredicates[channel.Name]
		if predicate == nil then
			return true
		end

		local ok, allowedOrReason, reason = pcall(predicate, {
			Channel = channel,
			Message = message,
			FromPlayer = playerFromTextSource(message.TextSource),
			FromTextSource = message.TextSource,
			ToPlayer = playerFromTextSource(toTextSource),
			ToTextSource = toTextSource,
		})

		if not ok then
			Log.Warn("Channel delivery predicate failed", {
				ChannelName = channel.Name,
				Error = tostring(allowedOrReason),
			})
			return false
		end

		if allowedOrReason ~= true and reason ~= nil then
			Log.Debug("Channel delivery predicate denied message", {
				ChannelName = channel.Name,
				Reason = reason,
			})
		end

		return allowedOrReason == true
	end
end

function TextChatService:RegisterProximityChannel(config: ProximityChannelConfig): TextChannel
	assert(type(config) == "table", "Bad proximity channel config")
	assert(type(config.MaxDistance) == "number" and config.MaxDistance > 0, "MaxDistance must be a positive number")
	assert(type(config.GetPlayerPosition) == "function", "GetPlayerPosition must be a function")

	local channel = self:RegisterChannel({
		Name = config.Name,
		DisplayName = config.DisplayName,
		AutoJoin = config.AutoJoin,
		Metadata = config.Metadata,
	})

	self:SetChannelDeliveryPredicate(channel.Name, function(context: ChannelDeliveryContext)
		if config.ShouldDeliver ~= nil then
			local allowed, reason = config.ShouldDeliver(context)
			if not allowed then
				return false, reason
			end
		end

		if context.FromPlayer == nil or context.ToPlayer == nil then
			return false, "Missing player"
		end

		local fromPosition = config.GetPlayerPosition(context.FromPlayer)
		local toPosition = config.GetPlayerPosition(context.ToPlayer)
		if fromPosition == nil or toPosition == nil then
			return false, "Missing position"
		end

		local isInRange = (fromPosition - toPosition).Magnitude <= config.MaxDistance
		return isInRange, if isInRange then nil else "Outside proximity"
	end)

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
	for commandName in self._commands do
		self:UnregisterCommand(commandName)
	end

	self._maid:DoCleaning()
end

return TextChatService
