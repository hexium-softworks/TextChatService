--!strict
--[=[
	Pure helpers for channel names, permission results, tags, and command args.

	@class TextChatSharedUtils
]=]

local TextChatSharedUtils = {}

export type PermissionResult = {
	Allowed: boolean,
	Reason: string?,
}

export type ChatTagDefinition = {
	Name: string,
	Text: string?,
	Color: Color3?,
	Priority: number?,
}

export type ResolvedChatTag = {
	Name: string,
	Text: string,
	Color: Color3?,
	Priority: number,
}

local CHANNEL_NAME_PATTERN = "[^%w_%-%.]"

local function escapeRichText(value: string): string
	value = string.gsub(value, "&", "&amp;")
	value = string.gsub(value, "<", "&lt;")
	value = string.gsub(value, ">", "&gt;")
	value = string.gsub(value, "\"", "&quot;")
	value = string.gsub(value, "'", "&apos;")
	return value
end

local function colorToHex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.clamp(math.round(color.R * 255), 0, 255),
		math.clamp(math.round(color.G * 255), 0, 255),
		math.clamp(math.round(color.B * 255), 0, 255)
	)
end

function TextChatSharedUtils.normalizePermissionResult(allowed: boolean?, reason: string?): PermissionResult
	return {
		Allowed = allowed == true,
		Reason = if reason ~= nil and reason ~= "" then reason else nil,
	}
end

function TextChatSharedUtils.assertNonEmptyString(value: any, name: string): string
	assert(type(value) == "string" and value ~= "", `{name} must be a non-empty string`)
	return value
end

function TextChatSharedUtils.sanitizeChannelName(name: string): string
	TextChatSharedUtils.assertNonEmptyString(name, "name")

	local sanitized = string.gsub(name, CHANNEL_NAME_PATTERN, "_")
	assert(sanitized ~= "", "Channel name cannot be empty")
	return sanitized
end

function TextChatSharedUtils.getDirectChannelName(userIds: { number }): string
	assert(#userIds >= 2, "Direct channel needs at least two users")

	local sortedUserIds = table.clone(userIds)
	table.sort(sortedUserIds, function(left, right)
		return left < right
	end)

	local parts = table.create(#sortedUserIds)
	for index, userId in sortedUserIds do
		parts[index] = tostring(userId)
	end

	return "Direct_" .. table.concat(parts, "_")
end

function TextChatSharedUtils.resolveTags(activeTags: { string }, definitions: { [string]: ChatTagDefinition }): { ResolvedChatTag }
	local resolved = {}

	for _, tagName in activeTags do
		local definition = definitions[tagName]
		if definition ~= nil then
			table.insert(resolved, {
				Name = definition.Name,
				Text = definition.Text or definition.Name,
				Color = definition.Color,
				Priority = definition.Priority or 0,
			})
		end
	end

	table.sort(resolved, function(left, right)
		if left.Priority == right.Priority then
			return left.Name < right.Name
		end

		return left.Priority > right.Priority
	end)

	return resolved
end

function TextChatSharedUtils.formatTagPrefix(tags: { ResolvedChatTag }): string
	if #tags == 0 then
		return ""
	end

	local parts = table.create(#tags)
	for index, tag in tags do
		local text = `[{escapeRichText(tag.Text)}]`
		if tag.Color ~= nil then
			parts[index] = `<font color="{colorToHex(tag.Color)}">{text}</font>`
		else
			parts[index] = text
		end
	end

	return table.concat(parts, " ") .. " "
end

function TextChatSharedUtils.parseCommandArguments(alias: string, text: string): { string }
	local body = string.sub(text, #alias + 1)
	local args = {}

	for token in string.gmatch(body, "%S+") do
		table.insert(args, token)
	end

	return args
end

return TextChatSharedUtils
