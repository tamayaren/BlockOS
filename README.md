# BlockOS

A macOS-inspired desktop operating system for **Advanced Computers** in
[CC: Tweaked](https://tweaked.cc). BlockOS gives you a menu bar, a dock, movable
windows with traffic-light buttons and full-screen mode, a Launchpad, a login
screen, and a set of bundled apps.

```
################
##%####%#####
%.%%#%%%%.%%
%%%:%%%'%%%%
%.%%%%:%%%%.%
%%%.%%%%%:%%%%.%
%:%%%'%%%%%%.%%%
```

## BlockOS Server Edition and BlockCloud (`server` branch)

This branch adds **BlockOS Server Edition** for Data Center computers and **BlockCloud**, a
networked services platform over rednet whose first service is **BlockDrive**, shared network
storage for BlockOS computers. Full guide: [docs/BLOCKCLOUD.md](docs/BLOCKCLOUD.md).

On a Data Center computer (Advanced Computer with a wireless, ender or wired modem; any
disk drives attached to it, also over wired modems, are pooled into its storage):

```
wget run https://raw.githubusercontent.com/tamayaren/BlockOS/server/server-install.lua
```

On each BlockOS desktop computer that should use the Data Center, get **BlockDrive**
from the App Store (Discover > Utilities), or run:

```
wget run https://raw.githubusercontent.com/tamayaren/BlockOS/server/blockdrive-install.lua
```

Then open **BlockDrive**, choose **Add Server** and **Connect**. Servers are public by default
(anyone in range may read and write, no pairing); a private server asks you to approve the
computer on its console with the code BlockDrive shows. The desktop edition below is unchanged and still
installs and updates from `main`.

## Install

On an **Advanced Computer** (or Advanced Turtle), run:

```
wget run https://raw.githubusercontent.com/tamayaren/BlockOS/main/install.lua
```

The installer opens an onboarding wizard: name the computer, create your
account, pick light or dark mode, an accent colour and a wallpaper, choose your
update settings, and BlockOS installs itself. Your old `startup.lua` is kept as
`startup.lua.bak`.

Running the installer again on a computer that already has BlockOS updates the
system files and keeps your data.

On a **turtle**, the installer offers the *Turtle Agent* instead: a small
program that lets the Turtles app on a BlockOS computer pair with and drive the
turtle over rednet (basic turtles get the agent automatically).

> HTTP must be enabled on the server (it is by default) for installing,
> updates, the App Store, Pastebin installs and bTunes.

## The desktop

| Area | What it does |
| --- | --- |
| Menu bar | Block logo menu (About, Settings, App Store, Force Quit, Lock, Log Out, Restart, Shut Down), the app's name, **Go** and **Window** menus, an update arrow when one is available, the clock, and a Show Desktop sliver in the top-right corner that hides every window (click it again to bring them back). Solid, clear (the wallpaper shows through) or blur (the wallpaper's colours smoothed into soft blocks) in **Settings → Appearance**. |
| Dock | Pinned apps, running apps (dot underneath) and a Messages unread badge. Right-click an icon to open, quit, keep it in the dock or add it to the desktop. Small (2 rows, the default) or large, solid or clear (no background, just the icons and running dots) in **Settings → Dock**. |
| Windows | Drag the title bar to move, drag the bottom-right corner to resize. Red closes, yellow minimizes, green goes full screen. |
| Full screen | Hides the dock and menu bar like macOS. Click the top-left corner, right-click or scroll up on the top row, or press Ctrl+Shift+Up to show the menu bar and the window buttons (close, minimize, exit full screen). |
| Launchpad | Every app in a searchable grid. Type to search, scroll for more pages. Right-click an app to open it full screen, keep it in the dock or add it to the desktop. |
| Desktop | Right-click for New Terminal, Finder, Change Wallpaper, Settings. Shortcuts to apps, files and folders line up down the left: click to select, double-click to open, right-click to open, edit, show in Finder, remove the shortcut or delete the file. |
| Lock screen | Date and a large clock over an animated screensaver, your name and a password field. The button in the bottom-right corner restarts or shuts down. Pick the screensaver colours in **Settings → Lock Screen** (your accent colour by default). |

### Animations

Windows open out of their dock icon and minimize back into it, Launchpad
zooms open, menus and right-click menus unroll, notifications slide in from the
right, the lock screen bleeds in over the desktop (and the desktop back in when
you unlock), and restarting shows a boot screen with the logo and a loading
bar. Turn animations off in **Settings → Dock** if your server is slow.

### Keyboard shortcuts

| Keys | Action |
| --- | --- |
| Ctrl+Shift+Space | Launchpad |
| Ctrl+Shift+T | New Terminal |
| Ctrl+Shift+Tab | Next window |
| Ctrl+Shift+F | Toggle full screen |
| Ctrl+Shift+M | Minimize |
| Ctrl+Shift+W / Q | Close window / quit app |
| Ctrl+Shift+Up | Reveal menu bar in full screen |
| Ctrl+Shift+D | Show Desktop |
| Ctrl+Shift+L | Lock |

## Bundled apps

| App | Description |
| --- | --- |
| **Finder** | File manager with a sidebar (favourites, Applications, disks), list view, context menus, copy/cut/paste, rename, Get Info and Open in Terminal. Right-click any file, folder or app and choose **Add to Desktop** for a desktop shortcut. |
| **Terminal** | A CraftOS shell in a window. Includes `bpm` (package manager) and `open`. |
| **Editor** | Code editor with Lua syntax highlighting, selection, undo/redo, find/replace, go to line, and Run (F5). **File > Add to Desktop** puts the open script on the desktop. |
| **App Store** | Browse catalogs, install apps from Pastebin or any URL, and manage installed apps. |
| **Messages** | Encrypted chat rooms and direct messages between BlockOS computers over rednet (needs a modem). |
| **Notes** | Quick notes with word wrap, bullet lists and autosave, stored in `/home/Notes`. Opens `.txt` files from Finder. |
| **Brocreate** | Paint pictures with solid colours and text characters: pen, line, box (outline or filled), fill, text, colour picker and eraser, with undo/redo. Left and right click paint with two colours; switch the ink between **Solid** and **Char** (any of the 256 characters). Saves `.bimg` (or colour-only `.nfp`) to `/home/Pictures`. Use **File > Set as Wallpaper**, or right-click a picture in Finder and choose **Set as Wallpaper**. |
| **Print** | Print text files on an attached printer, with a page preview, page titles, copies, and ink and paper levels. Right-click a `.txt` file in Finder and choose **Print**, or use Print in Notes. |
| **Network** | Finds nearby BlockOS computers over a wireless or ender modem and, with a GPS cluster in range, shows them on a map with distance and direction. Turn off *Let other computers find this one* (also in **Settings → Network**) to stay hidden. |
| **bTunes** | Music player for speakers: search YouTube or paste a YouTube video or playlist link, play DFPWM links and `.dfpwm` files, and keep a library with shuffle and repeat. The **Visual** tab shows a live spectrum in sync with the speaker: **Bars** with falling peaks, **Mirror**, or a **Wave** oscilloscope (click it to switch). |
| **Settings** | General, Storage (a usage bar split into System, Apps, Home, Data and Other, and every app by size, with Uninstall), Appearance (theme, accent, menu bar style, wallpaper incl. dark ones and a solid colour, white and black included), Dock (size, style, animations), Lock Screen, Users & Login, Notifications, Network, Login Items, Software Update. |
| **Calculator** | A four-function calculator with keyboard support. |
| **Clock** | Large clock (real or Minecraft time), alarms, stopwatch and timer. |
| **Reminders** | Lists, smart lists (Today, Scheduled, All, Completed) and due times like `in 10m`, `14:30` or `tomorrow 9:00`. |
| **Turtles** | Pair with turtles running the agent; view inventory, fuel and position, drive them, and run programs remotely. The **Scripts** tab keeps Lua scripts in `/home/Turtles` (tunnel, stairs and floor examples included): write them in Editor, then run them on the selected turtle with arguments. |
| **DiskCopy** | Duplicate, back up, restore, erase and label floppy disks, or make a BlockOS installer disk. |
| **Devices** | Inspect this computer and every attached peripheral; toggle redstone outputs. |
| **Recorder** | Record the screen to `.rec` files, play them back, and export a standalone player. |

### YouTube in bTunes

YouTube audio is converted to DFPWM by the community server that Minux and the
iPod program use (`ipod-2to6magyna-uc.a.run.app`). BlockOS has no affiliation
with it, and it can be slow or offline at times. To use another server with the
same API, go to **bTunes → Add → Server**.

## Installing apps

* **App Store → Pastebin**: enter a Pastebin code, a name and an icon; the
  program is stored as its own app in Applications and shows up in Launchpad.
  Choose whether it opens in a window or full screen.
* **App Store → Discover**: apps from catalogs. The default catalog is
  [`store/catalog.cfg`](store/catalog.cfg) (games such as Snake, Breakout and
  SameGame, BlockDrive for Data Center storage, and more); add more under
  *Sources*. BlockDrive connects to computers running BlockOS Server Edition;
  see the [`server` branch](https://github.com/tamayaren/BlockOS/tree/server)
  and its [BlockCloud guide](https://github.com/tamayaren/BlockOS/blob/server/docs/BLOCKCLOUD.md).
* **Terminal**: `bpm pastebin <code> [name]`, `bpm url <url> [name]`,
  `bpm search`, `bpm get <id>`, `bpm list`, `bpm remove <id>`.

Installed apps live in `/blockos/userapps/<id>/` with a `main.lua` and an
`app.cfg`:

```lua
{
	Name = "My App",
	Description = "Does a thing.",
	Mode = "window", -- or "fullscreen"
	Width = 40,
	Height = 14,
	Icon = { Lines = { "\2:)", "app" }, Fg = "white", Bg = "purple" }
}
```

Apps run in their own shell, so ordinary CraftOS programs work unchanged.
Apps written for BlockOS can use the global `BlockOS` API, for example
`BlockOS.Require("ui")` for the widget toolkit, `BlockOS.Notify(Title, Text)`,
`BlockOS.SetFullscreen(true)` and `BlockOS.Open(Path)`.

### Catalog format

```lua
{
	Name = "My Catalog",
	Apps = {
		{
			ID = "myapp",
			Name = "My App",
			Description = "Does a thing.",
			Category = "Utilities",
			Version = "1.0.0",
			Icon = { Lines = { "abc", "def" }, Fg = "white", Bg = "blue" },
			Source = { Type = "url", Url = "packages/myapp.lua" } -- or { Type = "pastebin", Code = "abcd1234" }
		}
	}
}
```

Relative URLs are resolved against the catalog's own URL.

## Updates

BlockOS checks [`manifest.cfg`](manifest.cfg) on this repository every couple
of hours (and shortly after login). When a newer version is listed, an arrow
appears in the menu bar; open it, or go to **Settings → Software Update**. You
can also turn on background installs. Updates never touch `/blockos/data`
(settings, users, messages) or `/blockos/userapps`.

### Recovery

If BlockOS won't start or the screen is unusable, hold **Ctrl+T** while the
boot screen is showing, then press **S** for the recovery shell. From there you
can run `/blockos/bin/bpm update` to update, or the install command above to
reinstall, and then `reboot`. Your data is kept.

## Development

```
startup.lua            boots BlockOS (Server Edition when installed, otherwise the desktop)
blockos/boot.lua       global BlockOS API, panic screen
blockos/sys/           desktop (window manager), login, setup wizard, app runner
blockos/lib/           ui toolkit, graphics, themes, config, users, apps, updater, chat, sha256, ...
blockos/apps/<id>/     bundled apps (app.cfg + main.lua)
blockos/turtle/        turtle agent
blockos/bin/           command-line tools on the shell path
src/installer.lua      installer template
store/                 App Store catalog and packages
blockos/server/        BlockOS Server Edition: BlockCloud runtime, services, console
blockos/lib/cloud/     BlockCloud protocol and client libraries
blockos/apps/blockdrive/  BlockDrive client app
src/*installer.lua     installer templates for each edition
tools/build.py         builds each edition's installer and manifest
tests/                 BlockCloud tests on headless CC: Tweaked computers
```

After changing files, bump the edition's version (`blockos/version.txt` for the
desktop, `blockos/server/version.txt` for Server Edition,
`blockos/apps/blockdrive/version.txt` for the BlockDrive client) and run:

```
python tools/build.py
```

Commit the regenerated installers and manifests (`install.lua`/`manifest.cfg`,
`server-install.lua`/`server-manifest.cfg`, `blockdrive-install.lua`/
`blockdrive-manifest.cfg`); computers pick up the new version on their next
update check. Each manifest names its edition, and the updater refuses a
manifest for a different edition. The build stops if any Lua file has more
than 200 locals in scope at once (counting those of enclosing functions), since
CC: Tweaked refuses to load it.

## Credits

Inspired by [Opus OS](https://github.com/kepler155c/opus) and its
[apps](https://github.com/kepler155c/opus-apps), [Minux](https://minux.cc), and
macOS. Built on the [CC: Tweaked](https://tweaked.cc) API.
