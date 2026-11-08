# dmgbuild settings for the install window (Finder's window when the DMG is opened).
# Run through scripts/make-dmg.sh, which passes -D app=… -D background=… -D volicon=…
# Geometry is the macOS design's "Build spec": a 660 × 400 content area with the toolbar, sidebar,
# path bar and status bar hidden, 128 pt icons, 13 pt names, the app at (165, 186) and the
# Applications link at (495, 186).
import os

app = defines["app"]                 # path to the .app to ship
application = os.path.basename(app)  # e.g. LinkToMac.app

format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
# Finder shows the file name with the extension hidden — "LinkToMac". (CFBundleDisplayName and a
# localised InfoPlist.strings were tried: this Finder ignores both for the label.)
hide_extension = [application]

icon = defines.get("volicon")        # the disk's own icon: AppIcon.icns
background = defines["background"]   # background.tiff: 660 × 400 @1x + 1320 × 800 @2x in one file

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

# The window frame includes the 28 pt titlebar, so a 660 × 400 CONTENT area is a 660 × 428 window.
# (Finder's path bar and status bar are global View settings that a DMG can't switch off; with them
# on, the content area is shorter and only the footer is clipped.) Position is irrelevant: Finder
# cascades new windows.
window_rect = ((200, 120), (660, 428))

arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    application: (165, 186),
    "Applications": (495, 186),
}
