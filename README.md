# TextChatService

A game-agnostic, server-first wrapper around Roblox `TextChatService` for NevermoreEngine projects.

The package keeps Roblox's native chat primitives underneath while adding a small service API for channel setup, chat eligibility, direct-message setup, tags, commands, and custom UI signals.

## Installation

```sh
npm install @hexium-softworks/textchatservice
```

## Server Usage

```lua
local textChatService = serviceBag:GetService(require("TextChatService"))

textChatService:RegisterChannel({
	Name = "Global",
	DisplayName = "Global",
	AutoJoin = true,
})

textChatService:RegisterTag({
	Name = "Developer",
	Text = "DEV",
	Color = Color3.fromRGB(90, 180, 255),
	Priority = 100,
})

textChatService:RegisterCommand({
	Name = "Wave",
	PrimaryAlias = "/wave",
	Run = function(context)
		textChatService:SendSystemMessage("Global", `{context.Player.DisplayName} waves.`)
	end,
})
```

## Client Usage

```lua
local textChatServiceClient = serviceBag:GetService(require("TextChatServiceClient"))

local canChat = textChatServiceClient:GetCanChat()
if canChat then
	textChatServiceClient:SendMessage("Global", "Hello world!")
end

textChatServiceClient.MessageReceived:Connect(function(message)
	print(message.ChannelName, message.UserId, message.Text)
end)
```

## API Overview

Server:

- `CanUserChatAsync(player)`
- `CanUsersChatAsync(fromPlayer, toPlayer)`
- `CanUsersDirectChatAsync(fromPlayer, toPlayers)`
- `RegisterChannel(config)`
- `GetOrCreateChannel(name)`
- `AddUserToChannel(player, channelName)`
- `RemoveUserFromChannel(player, channelName)`
- `SendSystemMessage(channelName, message, metadata?)`
- `RegisterTag(tagConfig)`
- `SetPlayerTags(player, tags)`
- `RegisterCommand(commandConfig)`
- `UnregisterCommand(commandName)`

Client:

- `GetChannels()`
- `GetChannel(name)`
- `SendMessage(channelName, text, metadata?)`
- `SendDirectMessage(toUserIds, text, metadata?)`
- `GetPlayerTags(userId)`
- `ObservePlayerTags(userId)`
- `GetCanChat()`
- `GetCanChatWith(userId)`

Signals:

- `MessageReceived`
- `MessageSent`
- `MessageFailed`
- `SystemMessageReceived`
- `ChannelAdded`
- `ChannelRemoved`
- `PlayerTagsChanged`
- `CommandExecuted`
- `ChatPermissionChanged`
