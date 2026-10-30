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
> updates, the App Store, Pastebin installs and MusicStream.

## The desktop

| Area | What it does |
| --- | --- |
| Menu bar | Block logo menu (About, Settings, App Store, Force Quit, Lock, Log Out, Restart, Shut Down), the app's name, **Go** and **Window** menus, an update arrow when one is available, and the clock. |
| Dock | Pinned apps, running apps (dot underneath) and a Messages unread badge. Right-click an icon to open, quit, or keep it in the dock. |
| Windows | Drag the title bar to move, drag the bottom-right corner to resize. Red closes, yellow minimizes, green goes full screen. |
| Full screen | Hides the dock and menu bar like macOS. Scroll up on the top row, or press Ctrl+Shift+Up, to reveal the menu bar. |
| Launchpad | Every app in a searchable grid. Type to search, scroll for more pages. |
| Desktop | Right-click for New Terminal, Finder, Change Wallpaper, Settings. |

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
| Ctrl+Shift+L | Lock |

## Bundled apps

| App | Description |
| --- | --- |
| **Finder** | File manager with a sidebar (favourites, Applications, disks), list view, context menus, copy/cut/paste, rename, Get Info and Open in Terminal. |
| **Terminal** | A CraftOS shell in a window. Includes `bpm` (package manager) and `open`. |
| **Editor** | Code editor with Lua syntax highlighting, selection, undo/redo, find/replace, go to line, and Run (F5). |
| **App Store** | Browse catalogs, install apps from Pastebin or any URL, and manage installed apps. |
| **Messages** | Encrypted chat rooms and direct messages between BlockOS computers over rednet (needs a modem). |
| **MusicStream** | Stream DFPWM audio from URLs to a speaker, with a library, shuffle, repeat and a visualizer. Also plays `.dfpwm` files. |
| **Settings** | General, Appearance (theme, accent, wallpaper), Dock, Users & Login, Notifications, Network, Login Items, Software Update. |
| **Clock** | Large clock (real or Minecraft time), alarms, stopwatch and timer. |
| **Reminders** | Lists, smart lists (Today, Scheduled, All, Completed) and due times like `in 10m`, `14:30` or `tomorrow 9:00`. |
| **Turtles** | Pair with turtles running the agent; view inventory, fuel and position, drive them, and run programs remotely. |
| **DiskCopy** | Duplicate, back up, restore, erase and label floppy disks, or make a BlockOS installer disk. |
| **Devices** | Inspect this computer and every attached peripheral; toggle redstone outputs. |
| **Recorder** | Record the screen to `.rec` files, play them back, and export a standalone player. |

## Installing apps

* **App Store → Pastebin**: enter a Pastebin code, a name and an icon; the
  program is stored as its own app in Applications and shows up in Launchpad.
  Choose whether it opens in a window or full screen.
* **App Store → Discover**: apps from catalogs. The default catalog is
  [`store/catalog.cfg`](store/catalog.cfg); add more under *Sources*.
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

## Development

```
startup.lua            boots BlockOS
blockos/boot.lua       global BlockOS API, panic screen
blockos/sys/           desktop (window manager), login, setup wizard, app runner
blockos/lib/           ui toolkit, graphics, themes, config, users, apps, updater, chat, sha256, ...
blockos/apps/<id>/     bundled apps (app.cfg + main.lua)
blockos/turtle/        turtle agent
blockos/bin/           command-line tools on the shell path
src/installer.lua      installer template
store/                 App Store catalog and packages
tools/build.py         builds install.lua and manifest.cfg
```

After changing files, bump `blockos/version.txt` and run:

```
python tools/build.py
```

Commit the regenerated `install.lua` and `manifest.cfg`; computers pick up the
new version on their next update check.

## Credits

Inspired by [Opus OS](https://github.com/kepler155c/opus) and its
[apps](https://github.com/kepler155c/opus-apps), [Minux](https://minux.cc), and
macOS. Built on the [CC: Tweaked](https://tweaked.cc) API.
