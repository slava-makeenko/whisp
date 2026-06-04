tell application "Finder"
	tell disk "whisp"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 840, 548}
		set theViewOptions to the icon view options of container window
		set arrangement of theViewOptions to not arranged
		set icon size of theViewOptions to 128
		set text size of theViewOptions to 13
		set background picture of theViewOptions to file ".background:background.png"
		set position of item "whisp.app" of container window to {175, 200}
		set position of item "Applications" of container window to {465, 200}
		update without registering applications
		delay 1
		close
	end tell
	delay 1
	tell disk "whisp"
		open
		update without registering applications
		delay 2
		close
	end tell
end tell