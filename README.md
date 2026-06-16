# REAPER FX Map

**REAPER FX Map** is a dockable thumbnail-based FX browser for REAPER.

It provides a visual way to browse, search, filter, favorite, group, and insert plugins with thumbnail previews. It is designed as a separate dockable FX browser panel, not a modification of REAPER's native FX Browser.

## Features

* Dockable `FX Map` window
* Modern dark/gray interface
* Thumbnail-based plugin grid
* Keyword search across:

  * Plugin name
  * Internal identifier
  * Plugin type
  * Group
  * Vendor
* Sidebar filters:

  * Favorites
  * Plugin type
  * Group
  * Vendor
* Collapsible sidebar sections
* Persistent sidebar collapse state
* Independent scrolling for sidebar and plugin grid
* Draggable scrollbars
* Lazy thumbnail image loading
* Double-click a plugin card to add and open the plugin
* Right-click context menu:

  * Add FX
  * Capture Thumbnail
  * Toggle Favorite
  * Assign manual group
* Per-card `Shot` button for capturing plugin GUI thumbnails
* Persistent favorites
* Persistent manual group assignments
* Customizable automatic group rules
* Single-instance behavior with toolbar toggle state sync
* Restores previous dock state
* Remembers the last FX insert position for smoother repeated insertion

## Screenshot

Add your screenshot here:

```markdown
![REAPER FX Map Screenshot](docs/screenshot.png)
```

## Requirements

### Required

* REAPER
* ReaScript / Lua support

### Required for thumbnail capture

* `js_ReaScriptAPI`

The main FX Map browser can run without `js_ReaScriptAPI`, but the `Shot` / `Capture Thumbnail` feature requires it.

You can install `js_ReaScriptAPI` through ReaPack:

```text
ReaPack > Browse Packages > js_ReaScriptAPI
```

## Installation

1. Download or clone this repository.

2. Copy the Lua script into your REAPER scripts folder:

```text
REAPER resource path/Scripts/
```

You can open the REAPER resource folder from:

```text
Options > Show REAPER resource path in explorer/finder
```

3. In REAPER, open:

```text
Actions > Show action list
```

4. Click:

```text
New action > Load ReaScript
```

5. Select the FX Map Lua script.

6. Run the action.

## Toolbar Setup

FX Map works well as a toolbar button.

1. Right-click a REAPER toolbar.
2. Choose:

```text
Customize toolbar...
```

3. Click:

```text
Add...
```

4. Search for the FX Map script action.
5. Add it to the toolbar.
6. Rename the button to:

```text
FX Map
```

or simply:

```text
FX
```

The script supports single-instance behavior and toolbar toggle state sync. Clicking the toolbar button again will close the running FX Map instance.

## Docking

FX Map can be docked inside REAPER's docker.

For example, it can sit alongside:

```text
Toolbar 2 | Toolbar 3 | MIDI Editor | FX Map
```

The dock position is saved automatically and restored the next time the script runs.

## Usage

### Search

Use the search box at the top to search plugins by name, identifier, type, group, or vendor.

### Filter

Use the left sidebar to filter plugins by:

* Favorites
* Type
* Group
* Vendor

Only one sidebar filter category is active at a time. Use `Reset` to clear the current filter and search text.

### Add a plugin

Double-click a plugin card to:

1. Add the plugin to the selected track.
2. Open the plugin floating window.

If no track is selected, FX Map will create a new track.

### Capture a thumbnail

Hover over a plugin card and click:

```text
Shot
```

or right-click the card and choose:

```text
Capture Thumbnail
```

FX Map will:

1. Create a temporary track.
2. Load the plugin.
3. Open the plugin floating window.
4. Capture the plugin GUI.
5. Save the image as a PNG thumbnail.
6. Remove the temporary track.
7. Restore the previous track selection.

This feature requires `js_ReaScriptAPI`.

## Data Folder

FX Map stores its data here:

```text
REAPER resource path/FXMap/
```

Thumbnail images are stored here:

```text
REAPER resource path/FXMap/Thumbs/
```

Common data files:

```text
favorites.txt
manual_groups.txt
group_rules.txt
```

## Thumbnails

Each plugin thumbnail is saved as a PNG file using a sanitized version of the plugin identifier.

If no thumbnail exists, FX Map displays a placeholder card showing the plugin type and group.

## Favorites

Favorites are saved automatically to:

```text
REAPER resource path/FXMap/favorites.txt
```

You can toggle favorites by:

* Clicking the star icon on a hovered plugin card
* Right-clicking a card and choosing `Toggle Favorite`

## Groups

FX Map supports both automatic and manual grouping.

Automatic group rules are stored in:

```text
REAPER resource path/FXMap/group_rules.txt
```

Default group categories include:

* Instrument
* EQ
* Dynamics
* Reverb
* Delay
* Saturation
* Modulation
* Pitch
* Meter
* Utility
* Other

Example rule format:

```text
EQ|eq,equalizer,filter,pro-q,channel strip
Dynamics|compressor,comp,limiter,gate,expander
Reverb|reverb,room,hall,plate,space,verb
```

Manual group assignments are saved to:

```text
REAPER resource path/FXMap/manual_groups.txt
```

Manual groups take priority over automatic group rules.

## Vendor Detection

FX Map attempts to detect plugin vendors from the plugin name, usually from the trailing parenthesized part of the REAPER FX name.

Example:

```text
VST3: Pro-Q 3 (FabFilter)
```

Vendor:

```text
FabFilter
```

If no reliable vendor is detected, the plugin is placed under:

```text
Unknown
```

JS plugins are grouped under:

```text
JS
```

## Notes

FX Map does not replace or modify REAPER's native FX Browser.

It is a separate dockable ReaScript window that provides a more visual plugin browsing workflow.

Some plugins may not expose reliable vendor names. Some plugin windows may also fail to capture correctly depending on the plugin GUI framework, operating system, or window behavior.

## Roadmap

Possible future improvements:

* Batch thumbnail capture
* Manual vendor override file
* Custom tag system
* Drag-and-drop FX insertion
* More flexible card size settings
* Theme customization
* Import REAPER FX Browser folders
* ReaImGui version

## License

MIT License

You are free to use, modify, and distribute this project.
<img width="2560" height="1392" alt="image" src="https://github.com/user-attachments/assets/512135d6-c077-49da-a9de-3ed754a4981a" />
<img width="2250" height="1232" alt="image" src="https://github.com/user-attachments/assets/919fb68a-8693-46e9-b6b3-f5467a6ca30e" />
