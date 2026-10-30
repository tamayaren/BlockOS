# BlockCloud, BlockDrive and BlockOS Server Edition

BlockCloud turns CC: Tweaked computers in your Data Center into network services for the
other BlockOS computers in the world. This first release has two parts:

* **BlockOS Server Edition**, a lightweight BlockOS for Data Center computers. It boots
  straight into the BlockCloud services and a small admin console. Finder is its only
  graphical app.
* **BlockDrive**, the first BlockCloud service: shared network storage that BlockOS desktop
  computers browse, upload to, download from and edit over rednet.

Everything runs inside CC: Tweaked with its own rednet and modem APIs. There are no web
servers, databases, Java services or extra mods.

```
  Office (BlockOS desktop)                     Data Center (Server Edition)
 +---------------------------+   rednet    +----------------------------------+
 | BlockDrive app / bdrive   |  <------->  | BlockCloud runtime               |
 | Finder > BlockDrive       |  modems     |   Core: discovery, pairing, auth |
 | cloud/client, transfer    |             |   BlockDrive: /blockcloud/storage|
 +---------------------------+             |   Software Update                |
                                           | Console + Finder (admin only)    |
                                           +----------------------------------+
```

## Contents

1. [Hardware](#hardware)
2. [Installing Server Edition](#installing-server-edition)
3. [The server console](#the-server-console)
4. [Connecting BlockOS computers](#connecting-blockos-computers)
5. [Using BlockDrive](#using-blockdrive)
6. [Settings reference](#settings-reference)
7. [Updates](#updates)
8. [Reliability on Aternos](#reliability-on-aternos)
9. [Security model and Rednet's limits](#security-model-and-rednets-limits)
10. [Troubleshooting](#troubleshooting)
11. [For developers: protocol and adding services](#for-developers)
12. [What has been tested](#what-has-been-tested)

## Hardware

| Part | What to use |
| --- | --- |
| Server | An **Advanced Computer** for the console. A basic computer also works: it runs the services with a text status screen and a shell (headless mode). |
| Modem on the server | A **wireless modem** reaches about 64 blocks (more at high altitude). An **ender modem** reaches everywhere, including other dimensions, and is the easiest choice for a Data Center that serves the whole base. Wired modems and networking cable work too, for computers on the same cable network. |
| Modem on clients | Any modem that can reach the server's modem. BlockOS Messages and Network use the same modems; BlockCloud uses its own rednet protocol names, so nothing interferes. |
| Storage | The server's own disk (about **1 MB** by default in CC: Tweaked) plus **every disk drive attached to it**, directly or over **wired modems and networking cable** (100 drives on one server work). The disks are [pooled](#disk-drives-and-the-storage-pool) with the main storage, so each floppy adds about 125 KB to the same shares. To give the computer itself more room, raise `computer_space_limit` in the CC: Tweaked server config (on Aternos: *Files > config > computercraft-server.toml*) and restart the Minecraft server. |
| HTTP | Needed only for installing and updating (enabled by default in CC: Tweaked). BlockDrive itself never uses HTTP. |

Keep the Data Center in chunks that stay loaded while people play (see
[Reliability on Aternos](#reliability-on-aternos)).

### Disk drives and the storage pool

Attach as many disk drives as you like, next to the server or on a wired modem network
(connect each drive's wired modem with networking cable to a wired modem on the server and
right-click the modems so they turn red). Put a floppy in each. Server Edition finds them by
itself, also when drives or floppies are added or removed while it runs.

Each disk is used in one of three ways (console **Settings > Disks**, or `bcloud disk`):

| Mode | What clients see |
| --- | --- |
| **Pool** (default) | The disk adds its space to the main storage. Shares are the top-level folders of the whole pool, so `Shared` spans every pooled disk: 100 floppies add about 12 MB to one share. |
| **Own share** | The disk is a separate share named after its label, or `Disk <ID>` (rename it in Settings > Disks). |
| **Unused** | BlockDrive leaves the disk alone. |

How the pool works:

* Each file is stored whole on one disk: next to the other files in its folder if that disk has
  room, otherwise on the disk with the most free space. **A single file can be at most as big
  as the free space on one disk** (about 120 KB on a floppy); a bigger upload is refused with
  *No single disk has room for a file this size*. Clients see the pool's total free space.
* Folders can be spread over several disks; listing, renaming, copying and deleting them treats
  them as one folder.
* Everything BlockDrive stores on a disk is inside a `blockcloud` folder on it. Other files on
  the disk are never shown or changed.
* Disks are recognised by their floppy ID, so they keep their mode and name when they move to
  another drive or the `diskN` mount names change after a restart.
* Removing a pooled disk hides the files on it until it is put back (uploads to it are
  stopped). Changing a disk that already holds files from Pool to another mode, or back, makes
  its files show up somewhere else; the console and `bcloud` warn you first.
* The main storage folder may itself be on a floppy (choose a disk during setup); that disk is
  then the first part of the pool.

Server Edition also turns off CraftOS's *boot from disk* (`shell.allow_disk_startup`), so a
floppy with a `startup` file in one of the drives can never stop the server from booting.

## Installing Server Edition

Server Edition lives on the `server` branch with its own installer, manifest and update
channel. It never downloads anything from `main`.

On the Data Center computer, run:

```
wget run https://raw.githubusercontent.com/tamayaren/BlockOS/server/server-install.lua
```

The installer first looks at what is already on the computer and tells you what it will do:

| Found | What happens |
| --- | --- |
| Nothing, or a non-BlockOS `startup.lua` | Fresh install. The old `startup.lua` is kept as `startup.lua.bak`. |
| BlockOS **Server Edition** | Update. Stored files, paired clients, settings and logs are kept. Server files that a release no longer ships are removed. |
| BlockOS **desktop** | It explains that Server Edition **replaces** the desktop (a computer runs one edition; there is no side-by-side install) and asks first. Desktop system files and apps are removed. `/home`, users and settings in `/blockos/data`, and apps you installed in `/blockos/userapps` are kept. To go back, run the desktop installer from `main`; your data is still there. |

Then the setup assistant asks for:

1. **Hostname** (letters, digits, `-`, `_`; also used as the computer label) and **display
   name**. Clients see the display name, for example *BlockDrive > Data Center > Shared*.
2. **Storage location**: `/blockcloud/storage` by default, or a folder on an attached disk
   drive. It cannot be the computer's root, `/rom` or `/blockos`.
3. **Administrator password** for the console (optional). The services run whether or not
   anyone logs in; the password only protects the console.
4. **Updates**: check automatically, and install in the background.

The computer restarts into Server Edition. Basic computers get the same questions as plain
text prompts.

### Unattended installs

To set up a rack of identical servers without answering questions:

```
wget https://raw.githubusercontent.com/tamayaren/BlockOS/server/server-install.lua server-install
server-install --yes --hostname rack1 --name "Data Center" --storage /blockcloud/storage --password secret
```

`--yes` also accepts replacing a desktop install, so use it with care.

### What is installed

```
startup.lua                 boots Server Edition (or the desktop, where that is installed)
blockos/server/             the server: boot, runtime, services, console, setup, bcloud
blockos/lib/cloud/          BlockCloud protocol, auth and path libraries
blockos/lib/                ui, gfx, theme, config, sha256, updater, logo, apps
blockos/apps/finder/        Finder, the only graphical app
blockos/data/cloud/         runtime data: server.dat, clients.dat, logs/ (never touched by updates)
/blockcloud/storage/        BlockDrive files (or the location you chose)
```

Not installed: the desktop window manager, dock, Launchpad, login screen, animations,
App Store, Messages, bTunes, Brocreate, Calculator, Clock, Reminders, Notes, Editor and the
other desktop apps.

## The server console

```
 * BlockOS Server                datacenter  17:39
 Overview  Clients  Pairing 1    Logs    Settings

 datacenter  *  Data Center
 BlockOS Server 1.0.0  *  Computer #1  *  up 2h 13m

 Network   * top wireless
 Services  * BlockCloud Core  1 modem
           * BlockDrive       1699 KB free
           * Software Update  Up to date (1.0.0)

 Storage   [#######-------------]        1.2 MB free
           /blockcloud/storage  *  12 files, 340 KB

 Clients   3 paired, 1 active recently
 Requests  42 handled, 0 rejected, 0 errors

  > Finder  >_ Shell  Lock
```

* **Overview**: hostname, computer ID, uptime, modems, the health of each service (green
  running, orange needs attention, red failed), storage use and client activity. It refreshes
  every 15 seconds and when something changes.
* **Clients**: paired computers, their access and when they were last seen. Change a client
  between read-only and read/write, rename it, or remove it (it must pair again).
* **Pairing**: computers waiting to pair. Choose **Approve...**, type the code the client
  shows, then pick read-only or read/write. Toggle whether new requests are accepted at all.
* **Logs**: the most recent log lines. The full log is `/blockos/data/cloud/logs/server.log`
  (rotated at 32 KB to `server.old.log`).
* **Settings**: see the [reference](#settings-reference).
* **Finder** opens the storage folder; use it to create shares (top-level folders), tidy up
  files or read logs. It runs full screen under a title bar: **x** closes it, **< Console**
  returns to the console while Finder stays open. Files open in the CraftOS editor.
* **Shell** opens a CraftOS shell for setup and recovery. `exit` closes it.

With a password set, the console starts locked and locks again after the idle time in
Settings (10 minutes by default). Locked, it still shows whether the services are healthy.

### bcloud

The same administration works from the shell:

```
bcloud status                    services, storage, clients
bcloud pending                   computers waiting to pair
bcloud approve 1 K7QM2X9D read   approve request 1 with its code (read or write)
bcloud deny 1
bcloud clients
bcloud perm 2 write              change client 2's access
bcloud remove 2                  unpair client 2
bcloud restart blockdrive        restart a service
bcloud disks                     disk drives, their mode and free space, and the pool's total
bcloud disk 3 share              disk 3 gets its own share (or: pool, off)
bcloud disk 3 name Archive       rename disk 3
bcloud set diskmode pool         how new disks are used; bcloud set disks off ignores all
bcloud logs 30
bcloud update install            check for and install an update
bcloud set hostname rack1        also: name, storage, quota, pairing on|off, encrypt on|off
bcloud password
```

### Recovery

* Press **S** on the boot screen for a recovery shell. The services still run there; `bcloud`
  works as usual.
* If the console itself keeps crashing, Server Edition shows a fallback screen (press **R** to
  try again). The services are unaffected.
* If the whole runtime fails, a blue panic screen offers a restart or a shell and **restarts by
  itself after 30 seconds**, so an unattended server comes back on its own.

## Connecting BlockOS computers

### Install BlockDrive on a desktop computer

The simplest way: open the **App Store** on a BlockOS desktop computer, find **BlockDrive**
under Discover (Utilities) and choose **Get**. The App Store keeps it up to date. The App Store
installs a single file, so BlockDrive sets up the BlockCloud client library
(`/blockos/lib/cloud`) and the `bdrive` command the first time it opens.

Or, from the terminal, on each BlockOS desktop computer that should use the Data Center:

```
wget run https://raw.githubusercontent.com/tamayaren/BlockOS/server/blockdrive-install.lua
```

This adds the BlockDrive app (pinned to the Dock), the BlockCloud client library
(`/blockos/lib/cloud`) and the `bdrive` command, and changes nothing else. Desktop updates
from `main` keep it. Run it again to update, or use **BlockDrive > menu > Check for Updates**.

### Pair

1. Open **BlockDrive** and choose **Add Server**. Servers in modem range are listed.
2. Pick the Data Center and give this computer a name. BlockDrive shows an
   **8-character code** such as `K7QM-2X9D`.
3. On the server console, open **Pairing**, approve the request and type that code
   (or `bcloud approve <n> <code>`), choosing read-only or read/write.
4. BlockDrive connects within a few seconds. The pairing is remembered on both computers
   across restarts.

The code is only ever shown on the client's screen and typed on the server; it never goes over
the network. A wrong code is refused. Pending requests expire after 10 minutes, and a server
restart clears them (start again).

## Using BlockDrive

The app's sidebar shows **BlockDrive**, each paired server (green dot online, red offline)
and, for the open server, its shares, so the path reads *BlockDrive > Data Center > Shared*.

* **Browse**: double-click folders; Backspace or the up arrow goes up; F5 refreshes.
* **Open**: text files (`.txt`, `.md`, `.lua`, `.cfg`, `.json`, `.log`, `.csv`, files without an
  extension; up to 64 KB) open in the built-in editor. **Ctrl+S** saves back to the server.
  Read-only clients can view but not change them. Other files offer to download.
* **Right-click a file**: Open, Download..., Rename..., Duplicate, Move To..., Copy To...,
  Get Info, Delete. **Right-click empty space**: New Folder, New Text File, Upload File,
  Refresh, Server Info. The toolbar's down arrow uploads and **+** makes a folder.
* **Transfers** run in the background with progress in the status bar, so the window keeps
  working. Errors appear in red with a plain explanation, for example *The server is not
  reachable. Check that it is on and in modem range.*
* **Finder**: when BlockDrive is installed, Finder's sidebar lists paired servers under
  BlockDrive, and right-clicking a file offers **Upload to BlockDrive...**. *(This Finder
  integration is part of the Finder on this branch; on computers running the desktop from
  `main`, use the BlockDrive app until the integration is merged.)*

Shares are the top-level folders of the storage location. Clients cannot create, rename or
delete shares; the administrator does that in Finder on the server.

### bdrive

```
bdrive discover                  servers in range
bdrive pair datacenter           pair (shows the code to give the administrator)
bdrive servers                   paired servers and whether they answer
bdrive info
bdrive ls Shared
bdrive put notes.txt Shared/     upload
bdrive get Shared/notes.txt      download to the current folder
bdrive cat Shared/notes.txt
bdrive mkdir Shared/docs
bdrive mv Shared/notes.txt Shared/docs/notes.txt
bdrive cp, rm
bdrive forget datacenter
```

With several servers paired, prefix paths with the hostname: `datacenter:Shared/notes.txt`.

### For BlockOS app developers

Apps can use the client library directly. Remote paths are kept apart from CC's `fs` API on
purpose: nothing overrides `fs` or pretends a remote path is local.

```lua
local Client = BlockOS.Require("cloud/client")
local Drive = BlockOS.Require("cloud/drive")

local Server = Client.List()[1]                       -- a paired server
local Listing, Err = Drive.List(Server, "Shared")     -- Err = { Code, Message }
local Text = Drive.ReadText(Server, "Shared/todo.txt")
Drive.WriteText(Server, "Shared/todo.txt", Text .. "- buy redstone\n")
```

Calls block the calling coroutine. GUI apps should run them with `cloud/tasks` (see
`blockos/apps/blockdrive/main.lua`).

## Settings reference

Server settings are stored in `/blockos/data/cloud/server.dat` and edited in **Settings**:

| Section | Setting | Default | Notes |
| --- | --- | --- | --- |
| General | Hostname | `datacenter` | Announced on the network; also the computer label. |
| General | Name | `Data Center` | Shown in BlockDrive. |
| Storage | Location | `/blockcloud/storage` | Changing it restarts BlockDrive. Existing files are **not** moved. |
| Storage | Quota MB | 0 (none) | Total size clients may store. |
| Storage | Max file KB | 0 (none) | Largest single file. |
| Disks | Use disk drives | on | Off ignores every disk drive. |
| Disks | New disks | Pool | How a newly attached disk is used: Pool, Own share or Unused. |
| Disks | Pool / Own Share / Unused / Rename | | Per disk; settings follow the floppy's ID. |
| Security | Accept pairing requests | on | Turn off once everyone is paired. |
| Security | Encrypt file transfers | on | ChaCha20 encryption of request and response bodies. Turning it off saves CPU. |
| Security | Lock after | 10 min | Idle time before the console locks (needs a password). |
| Security | Password | none | Console password. |
| Updates | Check automatically / Install in the background / Restart when no one is transferring | on / on / on | |
| Updates | Every (h) | 6 | Hours between checks. |
| Updates | Channel | `.../BlockOS/server/` | Where `server-manifest.cfg` is fetched from. |
| Services | Restart, Enable/Disable | | BlockCloud Core and Software Update are always on. |
| Appearance | Mode, Accent | light, blue | The usual BlockOS look. |

## Updates

* **Server Edition** follows the `server` branch: it fetches `server-manifest.cfg` every 6
  hours (and on demand), downloads every file to a staging folder, swaps them in, then
  restarts 10 to 30 seconds later, once no transfer is running. `/blockos/data` (settings,
  clients, logs) and the storage location are never touched.
* Every manifest names its edition (`desktop`, `server` or `blockdrive`). The updater refuses
  a manifest for another edition, so a misconfigured channel can never install the desktop on
  a server, or the server on a desktop.
* **BlockDrive clients** update from `blockdrive-manifest.cfg` (menu > Check for Updates, or
  re-run the installer). The desktop itself keeps updating from `main` as before.

## Reliability on Aternos

Aternos stops the Minecraft server when nobody is online, and chunks unload when players move
away. BlockCloud is built for that:

* **Nothing waits for a person.** Services start at boot before the console; no login is
  needed. A server that was on starts again when its chunk loads or the Minecraft server
  starts.
* **Everything that matters is on disk**: settings, paired clients, stored files. Pending
  pairing requests and half-finished transfers are memory only and are simply dropped.
* **Uploads are all-or-nothing.** Data goes to a staging file in a hidden folder; the real file
  is replaced only after every chunk arrived and the whole-file checksum matches. Staging files
  left by a shutdown are deleted at the next boot. An interrupted upload never damages the
  existing file.
* **Clients never hang.** A request is retried twice with growing waits and gives up after
  about 7.5 seconds with *The server is not reachable...*. Transfers retry each chunk and
  restart once if the server restarted mid-transfer.
* **Reconnection is automatic.** A booting server broadcasts one announcement; open BlockDrive
  windows reconnect when they hear it. While a server is offline BlockDrive checks it once
  every 20 seconds, and not at all while it is online.
* **Low load.** No periodic broadcasts. The console redraws on changes and every 15 seconds,
  not every frame. Usage statistics are recalculated at most every few seconds after changes.

Keep the Data Center chunks loaded while people play, for example by building it in the spawn
chunks or near where players spend time. CC: Tweaked computers do not run in unloaded chunks.

## Security model and Rednet's limits

BlockCloud is designed for a private in-game network among friends. Know what it does and
does not protect:

**What it does**

* A computer is trusted only after the administrator approves it with the one-time code shown
  on that computer. Hostnames, labels, usernames and claimed computer IDs are never trusted on
  their own.
* Pairing derives a 256-bit key from the code and random nonces from both sides. The code is
  never transmitted.
* Every request and response between paired computers carries an HMAC-SHA256 signature over
  its headers and body. Forged, altered or wrongly keyed requests are refused, and clients
  reject unsigned or forged answers (apart from the error saying the pairing is no longer valid).
* Requests carry a timestamp and an ID: requests older than two minutes are refused, and a
  repeated request ID gets the original answer instead of running twice.
* With encryption on, request and response bodies (file names and contents) are encrypted with
  ChaCha20.
* Read-only clients cannot change anything. Every path is validated and resolved inside the
  storage location; `..`, absolute paths, the staging folder and odd characters are refused, so
  clients cannot reach other files on the server.

**What it does not do**

* **Rednet is not private.** Any computer with a modem in range can see every message. Message
  headers (which operation, which client ID, sizes) are always visible; with encryption off,
  file contents are too.
* **Rednet is not authenticated.** Sender IDs can be faked with raw modem messages. BlockCloud
  relies on its signatures, not sender IDs, but someone could still disrupt traffic, for
  example by flooding or by faking "not paired" errors (denial of service).
* **The pairing code is short** (8 characters, about 40 bits). Someone who records the pairing
  messages could try to guess the code offline; this is impractical inside CC but not for a
  determined attacker with tools outside the game. Pair while no one untrusted is listening,
  and turn pairing off when you are done.
* **Keys are stored in plain files** (`/blockos/data/cloud/*.dat`). Anyone who can open the
  computer's files (in-game, or the Minecraft server's files) can read them. Lock up the Data
  Center and the client computers.
* Randomness comes from what CC offers (clock, IDs, Java hash codes, a persisted pool). It is
  far better than `math.random` alone, but not a cryptographic random source.
* There are no user accounts on the server; access is per computer.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| BlockDrive finds no servers | Is the server on and does the console show a modem under Network? Is the client in range (wireless about 64 blocks; use an ender modem for distance)? Are both modems open (Settings > Network on the desktop)? |
| *The server is not reachable* | The server is off, its chunk is unloaded, or it is out of range. BlockDrive reconnects by itself when it comes back. |
| *This computer is not paired* | The client was removed on the server, or the server's data was reset. Choose Forget Server in BlockDrive and pair again. |
| *The message could not be verified* | Keys no longer match (for example, data restored from a backup on one side). Forget the server and pair again. |
| The code is refused | Type it exactly as shown (dash and case do not matter). Each request has its own code; if the client started again, use the new one. |
| Pairing requests do not appear | *Accept pairing requests* must be on (Pairing tab or Settings > Security). |
| *There is not enough storage space* | The pool or the quota is full. Add disk drives (Settings > Disks shows each disk's free space), raise `computer_space_limit` in the CC: Tweaked config, or raise the quota in Settings > Storage. |
| *No single disk has room for a file this size* | Files are not split across disks, so a file must fit on one disk (about 120 KB on a floppy). Use the server's own storage for big files, or raise `computer_space_limit`. |
| A disk drive is not used | Does it hold a floppy (music discs are ignored)? Is the drive's wired modem switched on (red) and cabled to the server's wired modem? Check **Settings > Disks** and `bcloud disks`. |
| Files disappeared after removing a disk | They are still on the floppy; put it back (in any drive) and they reappear. |
| *That file is too large* | Settings > Storage > Max file KB. |
| *You do not have permission* | The client is read-only; change it under Clients. |
| Updates fail | HTTP must be enabled in CC: Tweaked. Settings > Updates shows the last error; the channel must end with `/server/`. |
| The console is locked and the password is lost | Reboot, press **S** for the recovery shell, and run `bcloud password`. |
| Something else | Read the Logs tab or `/blockos/data/cloud/logs/server.log`, and `bcloud status`. |

## For developers

### Layout

```
blockos/lib/cloud/          shared by server and clients
  codec.lua                 canonical serialisation (signable, parsed without load()), Adler-32
  path.lua                  remote path validation and resolution inside a root
  auth.lua                  random IDs, pairing codes, key derivation, HMAC, ChaCha20
  protocol.lua              protocol names, envelopes, error codes, modem helpers
  client.lua                discovery, pairing, signed calls with retries
  transfer.lua drive.lua    chunked transfers and the BlockDrive API
  tasks.lua                 background tasks for GUI apps
  finder.lua                Finder integration layer
blockos/server/
  boot.lua init.lua         boot and the runtime event loop
  rpc.lua                   request dispatcher (auth, de-duplication, worker coroutines)
  service_manager.lua       service registry, restarts, health
  clients.lua config.lua log.lua
  services/core.lua         discovery, pairing, hello
  services/blockdrive.lua   file storage
  services/updater.lua      Software Update
  ui/host.lua ui/console.lua setup.lua bin/bcloud.lua
blockos/apps/blockdrive/    the desktop client app
blockos/bin/bdrive.lua      the client command
```

### Protocol

All BlockCloud traffic uses rednet with namespaced protocol names, so it never mixes with
BlockOS Messages (`blockos_chat`), Network (`blockos_presence`) or Turtles (`blockos_turtle`):

* `blockcloud/discover`: a client broadcasts `{ BC = 1, K = "discover" }`; each server answers
  `{ BC = 1, K = "announce", Node = { NodeID, Hostname, Name, Version, Edition, Encrypt,
  Pairing, Services = { { Name, Title, Version } } } }`. Servers also broadcast one announcement
  when they boot, and register with `rednet.host("blockcloud/discover", hostname)`.
* `blockcloud/svc/<service>`: requests and responses. Every message is
  `{ BC, K = "req" | "res" | "push", ID, Svc, Op, Cl, T, N, E, B, S }`: request ID, service,
  operation, client ID, epoch-ms time, nonce, encrypted flag, body (canonical encoding of the
  arguments, or of `{ Ok = true, R = result }` / `{ Ok = false, Code, Msg }`), and signature.

Core operations: `ping`, `pair_request`, `pair_status` (public); `hello`, `unpair` (paired).
BlockDrive operations: `info`, `list`, `stat`, `download_begin/chunk/end` (read);
`mkdir`, `delete`, `move`, `copy`, `upload_begin/chunk/commit/abort` (write). Files move in
8 KB chunks; each upload chunk is acknowledged with the next expected index, so a lost
acknowledgement just makes the client resend and the server re-acknowledge.

`info` also returns `Volumes` (each share's kind, free space, largest storable file and number
of disks), `PooledDisks` and `Largest`; clients that ignore them keep working.

Error codes and their messages are listed in `protocol.lua` (`Protocol.Errors`).

### Adding a service

A storage node, job worker or anything else is one file in `blockos/server/services/` plus
its name in `Manager.Order` in `service_manager.lua`:

```lua
local Service = { Name = "jobs", Title = "Job Queue", Version = "1.0" }

function Service.Init(Ctx)
	Ctx.Rpc.Register("jobs", {
		submit = { Access = "write", Handler = function(Req, Args)
			-- Req.Client is the verified client; raise errors with Ctx.Rpc.Fail("invalid").
			return { Queued = true }
		end }
	})
end

function Service.Run(Ctx) -- optional background loop, restarted if it crashes
	while (true) do os.pullEvent() end
end

function Service.Health() return "ok", "idle" end
return Service
```

The service is announced in discovery, shown in the console with its health, restartable,
and its operations get pairing, signatures, permissions and de-duplication for free. Clients
call it with `Client.Call(Server, "jobs", "submit", Args)`. Long handlers should call
`Ctx.Rpc.Yield()` now and then.

### Building and testing

After changing files, bump the edition's version (`blockos/server/version.txt`,
`blockos/apps/blockdrive/version.txt`, or `blockos/version.txt` for the desktop) and run:

```
python tools/build.py
```

The tests boot real CC: Tweaked 26.2 computers headlessly (see `tests/run.py`):

```
sh tests/harness/fetch.sh     # once: CC: Tweaked core, Cobalt and Java 25 (not committed)
python3 tests/run.py          # all scenarios, or name some: unit vertical network ...
```

## What has been tested

Automated, on CC: Tweaked **26.2 core 1.120.2** (the same Lua VM, bios, ROM, filesystem and
rednet that computers run in-game) with a simulated wireless network, using the actual files
each installer ships:

* Unit tests of the codec, path validation, keys, signatures and ChaCha20 (RFC 7539 vector).
* Disk pooling with simulated disk drives and a simulated wired modem that the real CC
  `peripheral` and `disk` APIs talk to (as in-game, drives appear as `drive_0`, `drive_1`, ...):
  files spread over floppies, folders spanning disks renamed, copied and deleted, an overwrite
  that moves to another disk, a disk on its own share, ejecting and reinserting a pooled disk,
  and a rack of **100 drives** on one wired modem (4 MB stored over 40 floppies; info about
  0.2 s and listing about 0.15 s on this machine).
* The milestone's vertical slice on separate computers: discovery, pairing with a code (and a
  wrong code), upload, remote read, edit and save, folders, rename, copy, move, delete,
  download, path traversal attempts, forged and replayed requests, an interrupted upload,
  size limits, a server restart with the file still there, and a read-only second client.
* 10% modem message loss, and the server powered off mid-session and back on.
* The Server Edition console and Finder, and the first-boot setup wizard, through real mouse
  events on an Advanced Computer screen.
* BlockDrive inside the real BlockOS desktop, driven by mouse and keyboard events: pairing,
  upload through the file picker, editing and saving with Ctrl+S.
* Software Update from a local channel (install, self-restart, data kept) and refusal of a
  desktop manifest.
* Installers: fresh unattended install, replacing a desktop (user data kept), updating a
  server (identity and files kept), and the BlockDrive client installer.

**Not tested in a Minecraft world.** These need checking in-game: real wireless, ender and
wired modem ranges; real disk drives and wired modem cabling; chunk unloading and Aternos shutdowns (simulated here by powering the
computer off); the Minecraft server's CPU budget with many clients; HTTP to GitHub from
Aternos; disk drives as the storage location; and screen sizes other than the standard
51x19 computer terminal.
