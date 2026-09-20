--!strict
--[=[
    Constants and shared types for the TextChatService wrapper.
    @class TextChatServiceConstants
]=]

local require = require(script.Parent.loader).load(script)

local Table = require("Table")

export type PermissionResult = {
	Allowed: boolean,
	Reason: string?,
}

export type ChatEligibilitySnapshot = { [number]: PermissionResult }

export type ChatEligibilityTrackingConfig = {
	RefreshOnPlayerAdded: boolean?,
}

export type ChannelDeliveryContext = {
	Channel: TextChannel,
	Message: TextChatMessage,
	FromPlayer: Player?,
	FromTextSource: TextSource?,
	ToPlayer: Player?,
	ToTextSource: TextSource,
}

export type ChannelConfig = {
	Name: string,
	DisplayName: string?,
	AutoJoin: boolean?,
	Metadata: string?,
	ShouldDeliver: ((ChannelDeliveryContext) -> (boolean, string?))?,
}

export type ProximityChannelConfig = ChannelConfig & {
	MaxDistance: number,
	GetPlayerPosition: (Player) -> Vector3?,
}

export type DirectMessageConfig = {
	ToUserIds: { number },
	Text: string,
	Metadata: string?,
}

export type ChatTagConfig = {
	Name: string,
	Text: string?,
	Color: Color3?,
	Priority: number?,
}

export type CommandContext = {
	Player: Player,
	TextSource: TextSource?,
	RawText: string,
	Arguments: { string },
	CommandName: string,
}

export type CommandConfig = {
	Name: string,
	PrimaryAlias: string,
	SecondaryAliases: { string }?,
	Permission: ((Player) -> (boolean, string?))?,
	Run: ((CommandContext) -> ())?,
	ReplicateToClients: boolean?,
}

export type MessagePayload = {
	Text: string,
	Metadata: string?,
	ChannelName: string?,
	UserId: number?,
	MessageId: string?,
	Status: string?,
}

export type TextChatServiceConstants = {
	RemotingName: string,
	TagSnapshotEvent: string,
	EventNames: {
		MessageReceived: string,
		MessageSent: string,
		MessageFailed: string,
		SystemMessageReceived: string,
		ChannelAdded: string,
		ChannelRemoved: string,
		PlayerTagsChanged: string,
		CommandExecuted: string,
		ChatPermissionChanged: string,
		ChatEligibilitySnapshot: string,
	},
	Requests: {
		GetCanChat: string,
		GetCanChatWith: string,
		GetChatEligibilitySnapshot: string,
		SendMessage: string,
		SendDirectMessage: string,
		GetPlayerTags: string,
		GetAllPlayerTags: string,
		GetRegisteredTags: string,
	},
}

local constants = {
	RemotingName = "NevermoreTextChatService",
	TagSnapshotEvent = "TagSnapshot",

	EventNames = Table.readonly({
		MessageReceived = "MessageReceived",
		MessageSent = "MessageSent",
		MessageFailed = "MessageFailed",
		SystemMessageReceived = "SystemMessageReceived",
		ChannelAdded = "ChannelAdded",
		ChannelRemoved = "ChannelRemoved",
		PlayerTagsChanged = "PlayerTagsChanged",
		CommandExecuted = "CommandExecuted",
		ChatPermissionChanged = "ChatPermissionChanged",
		ChatEligibilitySnapshot = "ChatEligibilitySnapshot",
	}),

	Requests = Table.readonly({
		GetCanChat = "GetCanChat",
		GetCanChatWith = "GetCanChatWith",
		GetChatEligibilitySnapshot = "GetChatEligibilitySnapshot",
		SendMessage = "SendMessage",
		SendDirectMessage = "SendDirectMessage",
		GetPlayerTags = "GetPlayerTags",
		GetAllPlayerTags = "GetAllPlayerTags",
		GetRegisteredTags = "GetRegisteredTags",
	}),
} :: TextChatServiceConstants

return Table.readonly(constants)
