on open location theURL
	set tid to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "/"
	set parts to text items of theURL
	-- parts: {"claude-focus:", "", "focus" or "activate", "<id>"}
	set action to item 3 of parts
	set AppleScript's text item delimiters to tid

	if action is "activate" then
		-- Just bring Warp to front (already on the right tab)
		tell application "Warp" to activate
	else
		-- "focus" action: search for specific tab via Navigation Palette
		set focusId to item 4 of parts
		set targetFile to "/tmp/claude-focus-" & focusId & ".txt"
		set searchTerm to ""
		try
			set searchTerm to do shell script "cat " & quoted form of targetFile & " && rm -f " & quoted form of targetFile
		end try

		tell application "Warp" to activate
		delay 0.3

		if searchTerm is not "" then
			tell application "System Events"
				tell process "stable"
					click menu item "Navigation Palette" of menu "View" of menu bar 1
					delay 0.3
					keystroke searchTerm
					delay 0.3
					key code 36
				end tell
			end tell
		end if
	end if
end open location
