--!strict

local require = require(script.Parent.loader).load(script)

local TextChatSharedUtils = require("TextChatSharedUtils")

return function()
	describe("normalizePermissionResult", function()
		it("normalizes allowed results", function()
			local result = TextChatSharedUtils.normalizePermissionResult(true)

			expect(result.Allowed).toBe(true)
			expect(result.Reason).toBeNil()
		end)

		it("normalizes denied results with reasons", function()
			local result = TextChatSharedUtils.normalizePermissionResult(false, "Blocked")

			expect(result.Allowed).toBe(false)
			expect(result.Reason).toBe("Blocked")
		end)
	end)

	describe("sanitizeChannelName", function()
		it("keeps safe channel characters", function()
			expect(TextChatSharedUtils.sanitizeChannelName("Global.Chat-1")).toBe("Global.Chat-1")
		end)

		it("replaces unsafe channel characters", function()
			expect(TextChatSharedUtils.sanitizeChannelName("Phone Chat #1")).toBe("Phone_Chat__1")
		end)
	end)

	describe("getDirectChannelName", function()
		it("creates a stable sorted channel name", function()
			expect(TextChatSharedUtils.getDirectChannelName({ 42, 7, 19 })).toBe("Direct_7_19_42")
		end)
	end)

	describe("resolveTags", function()
		it("resolves and sorts tags by priority then name", function()
			local tags = TextChatSharedUtils.resolveTags({ "Member", "Owner", "Admin" }, {
				Admin = {
					Name = "Admin",
					Text = "ADMIN",
					Priority = 50,
				},
				Member = {
					Name = "Member",
					Text = "MEMBER",
					Priority = 1,
				},
				Owner = {
					Name = "Owner",
					Text = "OWNER",
					Priority = 50,
				},
			})

			expect(tags[1].Name).toBe("Admin")
			expect(tags[2].Name).toBe("Owner")
			expect(tags[3].Name).toBe("Member")
			expect(TextChatSharedUtils.formatTagPrefix(tags)).toBe("[ADMIN] [OWNER] [MEMBER] ")
		end)

		it("ignores unregistered active tags", function()
			local tags = TextChatSharedUtils.resolveTags({ "Missing" }, {})

			expect(#tags).toBe(0)
			expect(TextChatSharedUtils.formatTagPrefix(tags)).toBe("")
		end)

		it("formats colored tags as rich text", function()
			local tags = TextChatSharedUtils.resolveTags({ "Developer" }, {
				Developer = {
					Name = "Developer",
					Text = "<DEV>",
					Color = Color3.fromRGB(90, 180, 255),
				},
			})

			expect(TextChatSharedUtils.formatTagPrefix(tags)).toBe(
				'<font color="#5AB4FF">[&lt;DEV&gt;]</font> '
			)
		end)
	end)

	describe("parseCommandArguments", function()
		it("splits command arguments by whitespace", function()
			local args = TextChatSharedUtils.parseCommandArguments("/give", "/give player sword 3")

			expect(args).toEqual({ "player", "sword", "3" })
		end)
	end)
end
