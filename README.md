# TextChatService

A game-agnostic, server-first wrapper around Roblox `TextChatService` for NevermoreEngine projects.

The package keeps Roblox's native chat primitives underneath while adding a small service API for channel setup, chat eligibility, direct-message setup, tags, commands, and custom UI signals.

Networking is handled through Nevermore's `Remoting` package, so the service uses named remote methods and events instead of manually managing `RemoteFunction` and `RemoteEvent` instances.

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

textChatService:RegisterProximityChannel({
	Name = "Proximity",
	DisplayName = "Nearby",
	MaxDistance = 80,
	GetPlayerPosition = function(player)
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		return if rootPart and rootPart:IsA("BasePart") then rootPart.Position else nil
	end,
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

-- Optional: keep per-player chat eligibility snapshots updated for UI.
textChatService:StartChatEligibilityTracking()
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

local snapshot = textChatServiceClient:GetChatEligibilitySnapshot()
local targetResult = snapshot[targetUserId]
if targetResult ~= nil and not targetResult.Allowed then
	-- Decorate a nameplate or player list entry.
end
```

## Chat Eligibility Snapshots

Chat eligibility snapshots are an optional server-maintained cache of who the
local client can chat with. They are meant for UI, not authorization.

This is useful when a game wants to make chat availability visible without every
client repeatedly asking the server about every other player. Common uses:

- show an icon above players who cannot receive chat from you
- gray out a direct-message button in a player list
- show a short status in social menus, party menus, or trading screens
- avoid opening a direct-message UI that will immediately fail
- explain why a player appears in the server but is unavailable for chat

Snapshots are disabled by default. Enable them from the server when your game has
UI that benefits from this information:

```lua
local textChatService = serviceBag:GetService(require("TextChatService"))

textChatService:StartChatEligibilityTracking()
```

When tracking is enabled, the server builds one directional snapshot per player.
Each client only receives its own snapshot, keyed by the other players' user ids:

```lua
{
	[123456] = {
		Allowed = true,
		Reason = nil,
	},

	[987654] = {
		Allowed = false,
		Reason = "Users cannot chat",
	},
}
```

The snapshot is directional. If player A can chat with player B, that does not
mean player B necessarily has the same result for player A. Always read the
snapshot from the client that is making the UI decision.

### How Updates Work

`StartChatEligibilityTracking()` refreshes snapshots for the current server and
then updates them as players join. When a player leaves, their entry is removed
from the remaining clients' snapshots.

The server uses Roblox's bulk direct-chat eligibility check where possible, then
replicates only each player's own result map. This avoids sending a full server
matrix to every client and keeps memory bounded to active players.

If your game needs to refresh the cache after a known privacy-relevant moment,
call:

```lua
textChatService:RefreshChatEligibilitySnapshots()
```

You can stop tracking and clear client snapshots with:

```lua
textChatService:StopChatEligibilityTracking()
```

### Client UI Examples

For a player list, read the cached result and change the button state:

```lua
local allowed, reason = textChatServiceClient:GetCanChatWithCached(targetUserId)

if allowed == false then
	directMessageButton.Active = false
	directMessageButton.Text = "Unavailable"
	statusLabel.Text = reason or "Cannot chat"
elseif allowed == true then
	directMessageButton.Active = true
	directMessageButton.Text = "Message"
else
	-- No snapshot yet. You can show a neutral/loading state or call GetCanChatWith().
	directMessageButton.Active = false
	directMessageButton.Text = "Checking..."
end
```

For a nameplate or overhead indicator, observe one player:

```lua
local eligibility = textChatServiceClient:ObserveChatEligibility(targetUserId)

eligibility:Connect(function(result)
	if result == nil then
		chatUnavailableIcon.Visible = false
		return
	end

	chatUnavailableIcon.Visible = not result.Allowed
end)
```

For a custom social menu, read the whole snapshot once per render:

```lua
local snapshot = textChatServiceClient:GetChatEligibilitySnapshot()

for _, row in playerRows do
	local result = snapshot[row.UserId]
	row.CanChat = result == nil or result.Allowed
	row.DisabledReason = if result ~= nil then result.Reason else nil
end
```

### Important Notes

Snapshots are advisory. They are helpful for presenting clear UI, but they are
not the final permission check. `SendMessage`, `SendDirectMessage`, and the
server-side permission methods still perform authoritative checks before chat is
sent.

Use snapshots when many UI elements need the same answer repeatedly. If your game
only checks one player occasionally, `GetCanChatWith(userId)` is still simpler.

## Channels And Messages

Channels are Roblox `TextChannel` instances managed from the server. Use them for
public chat, team chat, trade chat, match chat, staff chat, or temporary activity
chat.

```lua
textChatService:RegisterChannel({
	Name = "Team",
	DisplayName = "Team",
	AutoJoin = false,
	Metadata = "team-chat",
})
```

`Name` is sanitized before the channel is created, so names are safe to use as
Roblox instances. `DisplayName`, `AutoJoin`, and `Metadata` are stored on the
channel for your UI or other systems to read.

Add and remove players from channels from the server:

```lua
textChatService:AddUserToChannel(player, "Team")
textChatService:RemoveUserFromChannel(player, "Team")
```

On the client, send through the wrapper so chat eligibility is checked before the
message is sent:

```lua
local ok, reason, message = textChatServiceClient:SendMessage("Team", "Regroup at base.")
if not ok then
	warn(reason)
end
```

`SendMessage` returns Roblox's `TextChatMessage` as the third result when
`TextChannel:SendAsync` succeeds. If your codebase prefers promises for yielding
flows, use the promise variant:

```lua
textChatServiceClient:PromiseSendMessage("Team", "Regroup at base.")
	:Then(function(message)
		print("sent", message.MessageId)
	end)
	:Catch(function(reason)
		warn(reason)
	end)
```

Server system messages are useful for match events, moderation notices, or
activity updates:

```lua
textChatService:SendSystemMessage("Global", "The round starts in 10 seconds.")
```

Game examples:

- lobby chat with a `Global` channel
- team-only callouts with `RedTeam` and `BlueTeam` channels
- trade plaza chat with a `Trading` channel
- raid, party, or dungeon chat created when an activity starts
- staff-only or moderator-only channels controlled by your own server logic

### Delivery Rules

Channels can define a server-side `ShouldDeliver` predicate. This uses Roblox's
`TextChannel.ShouldDeliverCallback` underneath, so it controls per-recipient
delivery without requiring custom filtering logic in each UI.

```lua
textChatService:RegisterChannel({
	Name = "Team",
	DisplayName = "Team",
	ShouldDeliver = function(context)
		if context.FromPlayer == nil or context.ToPlayer == nil then
			return false, "Missing player"
		end

		return getTeam(context.FromPlayer) == getTeam(context.ToPlayer), "Different team"
	end,
})
```

You can also change or clear delivery rules later:

```lua
textChatService:SetChannelDeliveryPredicate("Team", nil)
```

### Proximity Chat

For distance-based channels, use `RegisterProximityChannel`. The wrapper stays
game-agnostic by asking your game how to get each player's world position.

```lua
textChatService:RegisterProximityChannel({
	Name = "Proximity",
	DisplayName = "Nearby",
	MaxDistance = 80,
	GetPlayerPosition = function(player)
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		return if rootPart and rootPart:IsA("BasePart") then rootPart.Position else nil
	end,
})
```

Add your own `ShouldDeliver` predicate to stack extra rules, such as party-only
proximity or spectator exclusions.

## Direct Messages

Direct messages are set up through `SendDirectMessage(toUserIds, text,
metadata?)` on the client. The server validates that the recipients are in the
server and checks Roblox direct-chat eligibility before creating or joining the
direct channel.

```lua
local ok, reason = textChatServiceClient:SendDirectMessage({
	targetUserId,
}, "Want to party up?")

if not ok then
	warn(reason)
end
```

For group DMs, pass multiple user ids:

```lua
textChatServiceClient:SendDirectMessage({
	healerUserId,
	tankUserId,
}, "Queue is ready.")
```

This is useful for party invites, trading conversations, duel requests, support
flows, and social menus. Use chat eligibility snapshots to decide whether to show
or disable the button, but still let `SendDirectMessage` perform the final server
check.

Promise variants are available for UI flows that compose async steps:

```lua
textChatServiceClient:PromiseSendDirectMessage({ targetUserId }, "Want to party up?")
	:Catch(function(reason)
		showToast(reason)
	end)
```

## Chat Tags

Chat tags let the server attach stable labels to players, then the client
decorates incoming Roblox chat messages automatically. Tags are game-agnostic:
the package does not decide who is an admin, VIP, teammate, or event winner. Your
game decides that and calls `SetPlayerTags`.

First register the tag definitions:

```lua
textChatService:RegisterTag({
	Name = "Developer",
	Text = "DEV",
	Color = Color3.fromRGB(90, 180, 255),
	Priority = 100,
})

textChatService:RegisterTag({
	Name = "VIP",
	Text = "VIP",
	Color = Color3.fromRGB(255, 220, 90),
	Priority = 50,
})
```

Then assign tags per player:

```lua
local tags = {}

if isDeveloper(player) then
	table.insert(tags, "Developer")
end

if ownsVipPass(player) then
	table.insert(tags, "VIP")
end

textChatService:SetPlayerTags(player, tags)
```

The client receives the registered tag definitions and each player's active tag
list. Incoming messages are decorated with a prefix such as:

```text
[DEV] [VIP] PlayerName: hello
```

Tags are sorted by priority, then by name. Missing tag definitions are ignored,
which lets you safely remove or rename a tag definition without breaking every
player's tag list. If a tag has a `Color`, the prefix uses Roblox rich text so
the visible tag color matches the registered definition.

Client UIs can also read and observe player tags directly:

```lua
local tags = textChatServiceClient:GetPlayerTags(targetUserId)

local tagSignal = textChatServiceClient:ObservePlayerTags(targetUserId)
tagSignal:Connect(function(nextTags)
	print(targetUserId, nextTags)
end)
```

Good tag use cases:

- `Developer`, `Admin`, `Moderator`, or `Creator`
- `VIP`, `Premium`, `Founder`, or `Subscriber`
- seasonal roles like `Champion`, `Winner`, or `Event`
- team, faction, guild, or party labels
- temporary status tags like `Muted`, `Spectator`, or `InMatch`

Keep tags short. They appear inline with chat names, so compact labels like
`DEV`, `VIP`, or `MOD` usually read better than long phrases.

## Commands

Commands wrap Roblox `TextChatCommand` creation and route command execution back
to server code. Use them for chat-driven actions without mixing command parsing
throughout the game.

```lua
textChatService:RegisterCommand({
	Name = "Wave",
	PrimaryAlias = "/wave",
	Run = function(context)
		textChatService:SendSystemMessage("Global", `{context.Player.DisplayName} waves.`)
	end,
})
```

The command context includes the player, raw text, parsed arguments, and command
name:

```lua
textChatService:RegisterCommand({
	Name = "Roll",
	PrimaryAlias = "/roll",
	Run = function(context)
		local sides = tonumber(context.Arguments[1]) or 20
		local result = math.random(1, sides)

		textChatService:SendSystemMessage(
			"Global",
			`{context.Player.DisplayName} rolled {result}/{sides}.`
		)
	end,
})
```

Commands can have permission checks:

```lua
textChatService:RegisterCommand({
	Name = "Announce",
	PrimaryAlias = "/announce",
	Permission = function(player)
		if not isModerator(player) then
			return false, "Only moderators can announce"
		end

		return true, nil
	end,
	Run = function(context)
		textChatService:SendSystemMessage("Global", table.concat(context.Arguments, " "))
	end,
})
```

Set `ReplicateToClients = true` when custom client UI needs to know a command ran
through the `CommandExecuted` signal.

Command examples:

- `/wave`, `/me`, `/roll`, or other roleplay commands
- `/party invite PlayerName`
- `/trade PlayerName`
- `/report PlayerName reason`
- moderator tools like `/announce`, `/mute`, or `/kick`

## Signals And Custom UI

Both the server and client expose signals so a custom UI can react without
polling.

Message payloads include:

```lua
{
	Text = "Hello",
	Metadata = nil,
	ChannelName = "Global",
	UserId = 123456,
	MessageId = "...",
	Status = "...",
}
```

Client example:

```lua
textChatServiceClient.MessageReceived:Connect(function(message)
	if message.UserId ~= nil then
		addChatLine(message.ChannelName, message.UserId, message.Text)
	end
end)

textChatServiceClient.MessageFailed:Connect(function(message)
	showToast(message.Status or "Message failed")
end)

textChatServiceClient.ChannelAdded:Connect(function(channelName)
	addChannelTab(channelName)
end)
```

For game-specific presentation, add client-side decorators instead of replacing
`TextChatService.OnIncomingMessage` yourself:

```lua
local removeDecorator = textChatServiceClient:AddIncomingMessageDecorator(function(message, properties)
	if message.Metadata == "important" then
		properties = properties or Instance.new("TextChatMessageProperties")
		properties.PrefixText = "[!] " .. message.PrefixText
	end

	return properties
end)

-- Later, when this UI/controller is cleaned up:
removeDecorator()
```

Server example:

```lua
textChatService.MessageReceived:Connect(function(message)
	print("chat", message.ChannelName, message.UserId, message.Text)
end)

textChatService.ChatEligibilitySnapshotChanged:Connect(function(player, snapshot)
	print(player, snapshot)
end)
```

You can build:

- a fully custom chat window
- channel tabs and unread counts
- social menus with direct-message affordances
- nameplates that show tags or chat availability
- moderation dashboards that listen to messages and command usage

## Promises

The wrapper keeps simple tuple-returning methods for straightforward code, and
adds Nevermore `Promise` variants for flows that need composition or cancellation
through `Maid`.

Use tuple methods when handling one action inline:

```lua
local allowed, reason = textChatServiceClient:GetCanChatWith(targetUserId)
```

Use promise methods when chaining UI work or combining multiple async checks:

```lua
textChatServiceClient:PromiseCanChatWith(targetUserId)
	:Then(function()
		return textChatServiceClient:PromiseSendDirectMessage({ targetUserId }, "Hello!")
	end)
	:Catch(function(reason)
		showToast(reason)
	end)
```

## API Overview

Server:

- `CanUserChatAsync(player)`
- `CanUsersChatAsync(fromPlayer, toPlayer)`
- `CanUsersDirectChatAsync(fromPlayer, toPlayers)`
- `StartChatEligibilityTracking(config?)`
- `StopChatEligibilityTracking()`
- `RefreshChatEligibilitySnapshots()`
- `GetChatEligibilitySnapshot(player)`
- `PromiseCanUserChat(player)`
- `PromiseCanUsersChat(fromPlayer, toPlayer)`
- `PromiseCanUsersDirectChat(fromPlayer, toPlayers)`
- `RegisterChannel(config)`
- `RegisterProximityChannel(config)`
- `SetChannelDeliveryPredicate(channelName, shouldDeliver?)`
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
- `PromiseSendMessage(channelName, text, metadata?)`
- `SendDirectMessage(toUserIds, text, metadata?)`
- `PromiseSendDirectMessage(toUserIds, text, metadata?)`
- `GetPlayerTags(userId)`
- `ObservePlayerTags(userId)`
- `AddIncomingMessageDecorator(decorator)`
- `GetCanChat()`
- `PromiseCanChat()`
- `GetCanChatWith(userId)`
- `PromiseCanChatWith(userId)`
- `GetCanChatWithCached(userId)`
- `GetChatEligibilitySnapshot()`
- `ObserveChatEligibility(userId)`

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
- `ChatEligibilitySnapshotChanged`

Chat eligibility snapshots are advisory UI state. Keep using `SendMessage`,
`SendDirectMessage`, and the server-side permission methods as the authoritative
checks before messages are sent.
