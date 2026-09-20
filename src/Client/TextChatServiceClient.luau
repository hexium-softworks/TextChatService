--!strict
--[=[
	Client helpers for custom UIs built on Roblox TextChatService.

	@class TextChatServiceClient
]=]

local RobloxTextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local require = require(script.Parent.loader).load(script)

local Maid = require("Maid")
local Signal = require("Signal")
local TextChatServiceConstants = require("TextChatServiceConstants")
local TextChatSharedUtils = require("TextChatSharedUtils")

type ChatTagConfig = TextChatServiceConstants.ChatTagConfig
type MessagePayload = TextChatServiceConstants.MessagePayload
type PermissionResult = TextChatServiceConstants.PermissionResult

local TextChatServiceClient = {}
TextChatServiceClient.ServiceName = "TextChatServiceClient"

local function createSignal<T...>()
	return Signal.new() :: Signal.Signal<T...>
end

local function waitForRemoteFolder(): Folder
	return ReplicatedStorage:WaitForChild(TextChatServiceConstants.RemoteFolderName) :: Folder
end

local function getTextChannelsFolder(): Folder?
	return RobloxTextChatService:FindFirstChild("TextChannels") :: Folder?
end

function TextChatServiceClient:Init(serviceBag)
	assert(not self._serviceBag, "Already initialized")
	self._serviceBag = assert(serviceBag, "No serviceBag")
	self._maid = Maid.new()

	self._registeredTags = {} :: { [string]: ChatTagConfig }
	self._playerTagsByUserId = {} :: { [number]: { string } }
	self._canChatCache = nil :: PermissionResult?
	self._canChatWithCache = {} :: { [number]: PermissionResult }

	self.MessageReceived = createSignal<MessagePayload>()
	self.MessageSent = createSignal<MessagePayload>()
	self.MessageFailed = createSignal<MessagePayload>()
	self.SystemMessageReceived = createSignal<MessagePayload>()
	self.ChannelAdded = createSignal<string>()
	self.ChannelRemoved = createSignal<string>()
	self.PlayerTagsChanged = createSignal<number, { string }>()
	self.CommandExecuted = createSignal<any>()
	self.ChatPermissionChanged = createSignal<number?, PermissionResult>()

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

function TextChatServiceClient:Start()
	self:_setupRemotes()
	self:_connectTextChatSignals()
	self:_syncInitialState()
end

function TextChatServiceClient:_setupRemotes()
	local folder = waitForRemoteFolder()
	self._requestRemote = folder:WaitForChild(TextChatServiceConstants.RequestRemoteName) :: RemoteFunction
	self._eventRemote = folder:WaitForChild(TextChatServiceConstants.EventRemoteName) :: RemoteEvent

	self._maid:GiveTask(self._eventRemote.OnClientEvent:Connect(function(eventName: string, ...)
		self:_handleServerEvent(eventName, ...)
	end))
end

function TextChatServiceClient:_connectTextChatSignals()
	self._maid:GiveTask(RobloxTextChatService.MessageReceived:Connect(function(message: TextChatMessage)
		local payload = self:_messageToPayload(message)
		self.MessageReceived:Fire(payload)
	end))

	self._maid:GiveTask(RobloxTextChatService.SendingMessage:Connect(function(message: TextChatMessage)
		local payload = self:_messageToPayload(message)
		self.MessageSent:Fire(payload)
	end))

	local onIncomingMessage = function(message: TextChatMessage): TextChatMessageProperties?
		return self:_decorateIncomingMessage(message)
	end
	RobloxTextChatService.OnIncomingMessage = onIncomingMessage

	self._maid:GiveTask(function()
		if RobloxTextChatService.OnIncomingMessage == onIncomingMessage then
			RobloxTextChatService.OnIncomingMessage = nil
		end
	end)
end

function TextChatServiceClient:_syncInitialState()
	local okTags, registeredTags = pcall(function()
		return self._requestRemote:InvokeServer(TextChatServiceConstants.Requests.GetRegisteredTags)
	end)
	if okTags and typeof(registeredTags) == "table" then
		self._registeredTags = registeredTags
	end

	local okPlayerTags, playerTags = pcall(function()
		return self._requestRemote:InvokeServer(TextChatServiceConstants.Requests.GetAllPlayerTags)
	end)
	if okPlayerTags and typeof(playerTags) == "table" then
		self._playerTagsByUserId = playerTags
	end
end

function TextChatServiceClient:_messageToPayload(message: TextChatMessage): MessagePayload
	return {
		Text = message.Text,
		Metadata = message.Metadata,
		ChannelName = if message.TextChannel ~= nil then message.TextChannel.Name else nil,
		UserId = if message.TextSource ~= nil then message.TextSource.UserId else nil,
		MessageId = message.MessageId,
		Status = tostring(message.Status),
	}
end

function TextChatServiceClient:_handleServerEvent(eventName: string, ...)
	local events = TextChatServiceConstants.EventNames

	if eventName == TextChatServiceConstants.TagSnapshotEvent then
		local registeredTags, playerTagsByUserId = ...
		if typeof(registeredTags) == "table" then
			self._registeredTags = registeredTags
		end
		if typeof(playerTagsByUserId) == "table" then
			self._playerTagsByUserId = playerTagsByUserId
		end
	elseif eventName == events.MessageReceived then
		self.MessageReceived:Fire(...)
	elseif eventName == events.MessageSent then
		self.MessageSent:Fire(...)
	elseif eventName == events.MessageFailed then
		self.MessageFailed:Fire(...)
	elseif eventName == events.SystemMessageReceived then
		self.SystemMessageReceived:Fire(...)
	elseif eventName == events.ChannelAdded then
		self.ChannelAdded:Fire(...)
	elseif eventName == events.ChannelRemoved then
		self.ChannelRemoved:Fire(...)
	elseif eventName == events.PlayerTagsChanged then
		local userId, tags = ...
		if type(userId) == "number" and typeof(tags) == "table" then
			self._playerTagsByUserId[userId] = tags
			self.PlayerTagsChanged:Fire(userId, table.clone(tags))
		end
	elseif eventName == events.CommandExecuted then
		self.CommandExecuted:Fire(...)
	elseif eventName == events.ChatPermissionChanged then
		self.ChatPermissionChanged:Fire(...)
	end
end

function TextChatServiceClient:_decorateIncomingMessage(message: TextChatMessage): TextChatMessageProperties?
	if message.TextSource == nil then
		return nil
	end

	local tags = self._playerTagsByUserId[message.TextSource.UserId]
	if tags == nil or #tags == 0 then
		return nil
	end

	local resolvedTags = TextChatSharedUtils.resolveTags(tags, self._registeredTags)
	local prefix = TextChatSharedUtils.formatTagPrefix(resolvedTags)
	if prefix == "" then
		return nil
	end

	local properties = Instance.new("TextChatMessageProperties")
	properties.PrefixText = prefix .. message.PrefixText
	return properties
end

function TextChatServiceClient:GetChannels(): { TextChannel }
	local textChannels = getTextChannelsFolder()
	if textChannels == nil then
		return {}
	end

	local channels = {}
	for _, child in textChannels:GetChildren() do
		if child:IsA("TextChannel") then
			table.insert(channels, child)
		end
	end

	return channels
end

function TextChatServiceClient:GetChannel(name: string): TextChannel?
	local textChannels = getTextChannelsFolder()
	if textChannels == nil then
		return nil
	end

	local channel = textChannels:FindFirstChild(TextChatSharedUtils.sanitizeChannelName(name))
	if channel and channel:IsA("TextChannel") then
		return channel
	end

	return nil
end

function TextChatServiceClient:SendMessage(channelName: string, text: string, metadata: string?): (boolean, string?)
	assert(type(text) == "string", "Bad text")

	local allowed, result = self:_invokeServer(TextChatServiceConstants.Requests.SendMessage, channelName)
	if not allowed then
		self.MessageFailed:Fire({
			Text = text,
			Metadata = metadata,
			ChannelName = channelName,
			Status = result,
		})
		return false, result
	end

	local channel = self:GetChannel(result :: string)
	if channel == nil then
		return false, "Channel was not created"
	end

	local ok, err = pcall(function()
		channel:SendAsync(text, metadata)
	end)

	if not ok then
		self.MessageFailed:Fire({
			Text = text,
			Metadata = metadata,
			ChannelName = channel.Name,
			Status = tostring(err),
		})
		return false, tostring(err)
	end

	return true, nil
end

function TextChatServiceClient:SendDirectMessage(toUserIds: { number }, text: string, metadata: string?): (boolean, string?)
	assert(type(text) == "string", "Bad text")

	local allowed, result = self:_invokeServer(TextChatServiceConstants.Requests.SendDirectMessage, toUserIds)
	if not allowed then
		self.MessageFailed:Fire({
			Text = text,
			Metadata = metadata,
			Status = result,
		})
		return false, result
	end

	return self:SendMessage(result :: string, text, metadata)
end

function TextChatServiceClient:GetPlayerTags(userId: number): { string }
	local tags = self._playerTagsByUserId[userId]
	if tags ~= nil then
		return table.clone(tags)
	end

	local ok, result = pcall(function()
		return self._requestRemote:InvokeServer(TextChatServiceConstants.Requests.GetPlayerTags, userId)
	end)
	if ok and typeof(result) == "table" then
		self._playerTagsByUserId[userId] = result
		return table.clone(result)
	end

	return {}
end

function TextChatServiceClient:ObservePlayerTags(userId: number)
	local signal = createSignal<{ string }>()
	signal:Fire(self:GetPlayerTags(userId))

	local connection = self.PlayerTagsChanged:Connect(function(changedUserId, tags)
		if changedUserId == userId then
			signal:Fire(tags)
		end
	end)

	local destroy = signal.Destroy
	function signal:Destroy()
		connection:Disconnect()
		destroy(self)
	end

	return signal
end

function TextChatServiceClient:GetCanChat(): (boolean, string?)
	if self._canChatCache ~= nil then
		return self._canChatCache.Allowed, self._canChatCache.Reason
	end

	local allowed, reason = self:_invokeServer(TextChatServiceConstants.Requests.GetCanChat)
	local result = TextChatSharedUtils.normalizePermissionResult(allowed, reason)
	self._canChatCache = result
	self.ChatPermissionChanged:Fire(nil, result)
	return result.Allowed, result.Reason
end

function TextChatServiceClient:GetCanChatWith(userId: number): (boolean, string?)
	local cached = self._canChatWithCache[userId]
	if cached ~= nil then
		return cached.Allowed, cached.Reason
	end

	local allowed, reason = self:_invokeServer(TextChatServiceConstants.Requests.GetCanChatWith, userId)
	local result = TextChatSharedUtils.normalizePermissionResult(allowed, reason)
	self._canChatWithCache[userId] = result
	self.ChatPermissionChanged:Fire(userId, result)
	return result.Allowed, result.Reason
end

function TextChatServiceClient:_invokeServer(requestName: string, ...): (boolean, string?)
	local ok, result, reason = pcall(function(...)
		return self._requestRemote:InvokeServer(requestName, ...)
	end, ...)

	if not ok then
		return false, tostring(result)
	end

	return result == true, if result == true then reason else tostring(reason or result)
end

function TextChatServiceClient:Destroy()
	self._maid:DoCleaning()
end

return TextChatServiceClient
