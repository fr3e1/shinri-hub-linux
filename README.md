# Shinri Trial Hub on Linux

> [!NOTE]
> **This is a temporary workaround.** An official Shinri Hub for Linux and macOS is being developed.
> Until it's out, this script lets you use the Windows hub on Linux. When the official hub releases,
> [uninstall this workaround](#uninstall) with one command and switch to the official one.

A one-command installer for the [Shinri Trial](https://shinri-trial.com) Hub on Linux.
It runs the Windows hub through Steam's Proton, inside Garry's Mod's own Proton
prefix, and works around the issues that otherwise stop it from launching the game.

## Quick install

Paste this into a terminal:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fr3e1/shinri-hub-linux/main/shinri-hub-setup.sh)"
```

No `curl`? Use `wget` instead:

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/fr3e1/shinri-hub-linux/main/shinri-hub-setup.sh)"
```

Then open **Shinri Hub** from your app menu (or run `~/.local/bin/shinri-hub`).

Works on **Debian / Ubuntu / Mint / Pop!_OS**, **Fedora / Nobara**, **Arch / CachyOS / EndeavourOS / Manjaro**
and openSUSE. Immutable systems (Bazzite, Silverblue, SteamOS) work if 7-Zip is already available.

## Uninstall

When the official Linux hub is released (or whenever you want to remove this), paste this into a terminal:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fr3e1/shinri-hub-linux/main/shinri-hub-setup.sh)" _ --uninstall
```

Or, if it's still installed, simply run:

```bash
~/.local/bin/shinri-hub --uninstall
```

It shows what it will remove and asks before deleting anything. It removes everything the workaround added:

- the hub and its compatibility shim inside Garry's Mod's Proton prefix, and the registry tweaks it made there,
- the launcher, app-menu entry, icon, `st://` link handler, config, cache and downloaded installer,
- the hub's settings and logs, and the hub's copy of Garry's Mod (`steamapps/common/Shinri Trial Host`).

Steam, Garry's Mod and its Proton prefix are left alone. Add `--keep-data` to keep the hub's settings, logs and
game copy, or `--yes` to skip the question. If the hub is open it's closed first.

Afterwards, if you only forced Proton for Garry's Mod for this, you can switch it back in Steam
(Garry's Mod → **Properties** → **Compatibility**).

## Before you install

1. **Steam** is installed (your distro's package, Valve's `.deb`, or Ubuntu's Snap) and you're logged in.
2. **Garry's Mod** is installed and set to run with Proton:
   in Steam, right-click Garry's Mod → **Properties** → **Compatibility** → tick
   **Force the use of a specific Steam Play compatibility tool** and pick a Proton version.
3. **Launch Garry's Mod once** from Steam and quit it. This creates the Proton prefix the hub is installed into.

The installer also needs **7-Zip**, `python3` and `curl` (or `wget`). If one is missing it
detects your distro and offers to install it for you (it asks before using `sudo`):

| Distro | 7-Zip package it installs |
| --- | --- |
| Debian / Ubuntu / Mint | `7zip` (falls back to `p7zip-full`) |
| Fedora / Nobara | `7zip` (falls back to `p7zip p7zip-plugins`) |
| Arch / CachyOS / Manjaro | `7zip` (falls back to `p7zip`) |
| openSUSE | `7zip` (falls back to `p7zip-full`) |

If anything else is missing, the installer tells you what and how to fix it.
Set `SHINRI_ASSUME_YES=1` (or pass `--yes`) to install missing packages without asking.

## What it does

- Downloads the latest hub installer from the official update server and verifies its SHA-512 checksum.
- Unpacks it into Garry's Mod's Proton prefix (`steamapps/compatdata/4000`), where Proton gives it
  a Windows `steam.exe` connected to your Linux Steam, so it can find Steam and GMod.
- Adds a small compatibility shim (`C:\Program Files\Shinri Hub Linux` in that prefix):
  - a stand-in `steamwebhelper.exe` and the `ActiveUser` registry value the hub checks for before launching,
  - a `tasklist` wrapper, because Wine's `tasklist` output isn't readable by the hub
    (without it, Play fails with `STEAM_NOT_RUNNING`),
  - turns off window-manager title bars for Wine windows in that prefix, which fixes mouse clicks
    landing below the pointer on KDE/Wayland.
- Creates a launcher (`~/.local/bin/shinri-hub`), an app-menu entry with icon, and registers `st://` links.
- The launcher runs Proton inside Steam's own container runtime (Steam Linux Runtime), the same way Steam
  launches games, so it doesn't depend on your distro's libraries. Set `SHINRI_NO_RUNTIME=1` to run Proton directly.
- The hub starts with GPU acceleration off (its window doesn't need it, and it crashes on some GPUs/VMs under Wine).
  Set `SHINRI_HUB_GPU=1` to turn it back on. The game itself is not affected.
- Checks for hub updates every time you start it (the hub's built-in updater can't install under Wine).

Everything goes into your home folder; `sudo` is only used if you agree to install a missing package.

## Commands

If you'd rather download the script first:

```bash
curl -fsSLO https://raw.githubusercontent.com/fr3e1/shinri-hub-linux/main/shinri-hub-setup.sh
chmod +x shinri-hub-setup.sh
./shinri-hub-setup.sh --check
```

| Command | What it does |
| --- | --- |
| `./shinri-hub-setup.sh` | Download the latest hub and install it |
| `./shinri-hub-setup.sh --installer FILE` | Install from a `Shinri Hub Setup *.exe` you already have |
| `./shinri-hub-setup.sh --update` | Reinstall only if a newer hub version exists |
| `./shinri-hub-setup.sh --check` | Only run the checks, change nothing |
| `./shinri-hub-setup.sh --stop` | Close the hub and anything left running in GMod's prefix |
| `./shinri-hub-setup.sh --uninstall` | Remove everything the workaround added (asks first) |
| `./shinri-hub-setup.sh --uninstall --keep-data` | Same, but keep hub settings, logs and its GMod copy |

Once installed, `~/.local/bin/shinri-hub` accepts `--update`, `--check`, `--stop` and `--uninstall` too.
Set `SHINRI_WM_DECORATIONS=1` when installing to keep window-manager title bars on Wine windows.

## Good to know

- **Steam must be running and logged in** when you use the hub. The launcher starts it if it isn't.
- **While the hub is open, Steam shows Garry's Mod as running**, so you can't also start plain GMod
  from Steam. Quit the hub (including from its tray icon) first. If it's stuck, run:

  ```bash
  ~/.local/bin/shinri-hub --stop
  ```
- The hub copies GMod into `steamapps/common/Shinri Trial Host` for its own client.
- Logs: `~/.cache/shinri-hub/launch.log`, plus the hub's own logs in
  `steamapps/compatdata/4000/pfx/drive_c/users/steamuser/AppData/Roaming/Shinri Trial/logs/` in your Steam library.
- Flatpak Steam is only partly supported and untested.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| "Garry's Mod is installed as the Linux build" | Force Proton for GMod (step 2 above), let Steam update it, launch it once. |
| "GMod's Proton prefix does not exist yet" | Launch Garry's Mod once from Steam and quit it. |
| Play does nothing / "Steam not running" | Make sure Steam is open and logged in, then quit the hub fully and reopen it. |
| "Shinri Hub is running" when reinstalling | Run `~/.local/bin/shinri-hub --stop`, then try again. |
| Hub stopped working after a Proton update | Rerun the installer; the launcher also re-detects Proton automatically. |

This is an unofficial community script and isn't affiliated with Shinri Trial.
