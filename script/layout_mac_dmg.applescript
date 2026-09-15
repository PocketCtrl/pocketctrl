-- SPDX-License-Identifier: MPL-2.0
on run argv
    set mountPath to item 1 of argv
    set installerFolder to POSIX file mountPath as alias
    tell application "Finder"
        open installerFolder
        set installerWindow to container window of installerFolder
        set current view of installerWindow to icon view
        set toolbar visible of installerWindow to false
        set statusbar visible of installerWindow to false
        set bounds of installerWindow to {200, 200, 840, 560}
        set viewOptions to icon view options of installerWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 14
        set background color of viewOptions to {65535, 65535, 65535}
        set position of item "PocketCtrl.app" of installerFolder to {170, 150}
        set position of item "Applications" of installerFolder to {470, 150}
        update installerFolder without registering applications
        close installerWindow
        open installerFolder
        delay 2
        close container window of installerFolder
    end tell
end run
