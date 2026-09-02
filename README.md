# 󰐃 PinRoutes for Omarchy

An [Omarchy](https://omarchy.org) shell plugin that keeps your static routes pinned. Routes get lost after sleep, VPN reconnects, or network changes — PinRoutes watches for that and puts them back.

This is the Linux/Omarchy port of the [PinRoutes macOS menu bar app](https://github.com/Positronico/pinroutes).

![PinRoutes panel](preview.png)

## Features

- **Bar widget** — a pin icon in the Omarchy bar; it turns urgent when a route goes missing
- **Route management** — add, edit, enable/disable routes with CIDR network + gateway from the panel
- **Event-driven monitoring** — watches netlink (`ip monitor route`), so lost routes are caught within a second of a VPN reconnect or resume, plus a periodic fallback check (15s–10min)
- **Gateway-aware standby** — a route whose gateway is not on-link (wifi still reassociating after sleep, a foreign network, a VPN tunnel that's down) goes into *standby* instead of erroring: no apply attempts, no alerts, calm bar icon. The moment the gateway's subnet comes back, netlink wakes the plugin and the route is re-applied
- **Auto-reapply** — optionally puts missing routes back automatically and silently
- **Notifications** — desktop notification when routes go missing (or when a silent re-apply fails), with a 10-second grace so transient route churn (DHCP renews, reconnects) never pages you
- **Root helper with route approval** — one authenticated prompt installs a root-owned helper and approves your exact routes into a root-owned allowlist; after that, approved routes re-apply silently (`NOPASSWD` sudoers entry scoped to the helper, which refuses anything outside the allowlist). Changing routes later takes one re-approval prompt. Without the helper, user-initiated applies go through `pkexec` and Omarchy's themed auth dialog.

## Install

```bash
omarchy plugin add https://github.com/Positronico/pinroutes-omarchy.git --enable
```

That clones the plugin, validates it, and asks where on the bar to place it. To move it later:

```bash
omarchy bar move pinroutes --section right
```

Manual install: clone the repo to `~/.config/omarchy/plugins/pinroutes`, run `omarchy-shell shell rescanPlugins`, then `omarchy plugin enable pinroutes`.

## Usage

1. Click the 󰐃 icon in the bar, hit **+**, enter a name, CIDR network (e.g. `10.255.0.0/16`), and gateway (e.g. `10.0.0.1`).
2. Enabled routes are verified continuously; re-apply manually with the refresh button (or right-click the bar icon), or turn on **Auto-reapply**.
3. **Install helper** (recommended) — in the HELPER section of the panel. One password prompt installs the helper *and approves your current routes*; after that, approved routes re-apply silently, which is what makes background auto-reapply possible. When you later add or edit a route, the panel offers **Approve route changes** (one prompt) to extend silent re-apply to it.

Bar icon: left-click opens the panel, right-click re-applies missing routes, middle-click re-verifies. In the panel: `j`/`k` move, `Enter` re-applies the selected route, `a` re-applies all, `n` adds a route, `r` refreshes, `Esc` closes.

### Route states

| State | Meaning | Behavior |
|-------|---------|----------|
| pinned | Route present with the right gateway | — |
| missing | Gateway reachable but route absent | Auto-reapply fixes it silently; otherwise a notification after a 10s grace |
| standby | Gateway not on-link on the current network | No apply attempts, no alerts; retried automatically when the gateway's subnet returns |
| disabled | Rule turned off | Ignored |

Standby mirrors the kernel's own nexthop rule: `ip route replace X via GW` only succeeds when `GW` is inside a directly-connected subnet, so PinRoutes checks that (from the route table it already reads) before acting. This is what keeps the plugin quiet when you resume from sleep before wifi is back, roam to a network where your routes don't apply, or drop a VPN tunnel whose far side hosts the gateway.

## Security

Changing routes requires root, so this plugin has a deliberately small, policy-bound privileged surface. Full disclosure for reviewers and the appropriately suspicious:

- **`helper/pinroutes-helper`** — a bash script whose entire command surface is `ip route replace <cidr> via <gateway>` and `ip route del <cidr>`, capped at 128 operations per invocation. Two validation layers:
  1. *Syntax*: every argument must be a well-formed IPv4 CIDR / address (strict regex, checked before `ip` runs).
  2. *Policy*: whenever the root-owned allowlist `/etc/pinroutes/routes.allow` exists — and always when running under sudo — each operation must exactly match an approved `<network> <gateway>` pair. The passwordless path **fails closed**: under sudo with no allowlist, everything is refused. This is what stops an arbitrary same-user process from using the NOPASSWD entry to hijack the default route (`0.0.0.0/0`, or the `/1`-pair equivalent) or any other unapproved route.
- **Root never executes a file from the plugin checkout.** The plugin dir is user-writable, so a privileged executable read from it could be swapped between authentication and root opening it (a TOCTOU root-code-execution path). Instead the two scripts are read into the shell's memory once at load, and privileged runs pass that captured text as an **argv constant to the fixed system interpreter**: `pkexec /bin/bash -c "<script text>" …`. `/bin/bash` is trusted and immutable; the script text is data, not a path root resolves.
- **"Install helper" / "Approve route changes"** runs the installer this way with `--approve <pairs...>`. On first run it installs *itself* root-owned to `/usr/local/bin/pinroutes-approve` (recovering its own text from `$BASH_EXECUTION_STRING`), and every later approval executes that fixed, root-owned component directly. The installer derives the invoking user from **`PKEXEC_UID`/`SUDO_UID`** (never argv or ambient env), re-validates and caps route pairs (100), embeds the route helper (root never copies a second mutable file), and writes:
  - `/usr/local/bin/pinroutes-helper` and `/usr/local/bin/pinroutes-approve` (root:root 0755)
  - `/etc/pinroutes/routes.allow` (root:root 0644) — exactly the approved pairs
  - `/etc/sudoers.d/pinroutes` (root:root 0440, `visudo -cf`-validated): a pinned `secure_path` for the helper plus `<you> ALL=(root) NOPASSWD: /usr/local/bin/pinroutes-helper`

  Adding or editing a route later requires one re-approval prompt; until then the new route is applied only through per-operation `pkexec` and is marked "not yet approved" in the panel.
- **Trusted interpreter and PATH.** Both scripts use `#!/bin/bash` (absolute, not `/usr/bin/env`), and the installed helper's sudoers entry pins `secure_path`, so the NOPASSWD path never depends on the caller's `PATH` or ambient sudo policy.
- **Without the helper installed**, user-initiated applies run the in-repo helper text through the same `pkexec /bin/bash -c` handoff (one themed auth prompt per operation — each invocation individually authenticated, so syntax-only validation applies). The background monitor *never* invokes pkexec — if it can't fix a route silently, it only notifies.
- **State I/O** (`stateio.py`) opens the config's parent directory once (`O_DIRECTORY|O_NOFOLLOW`), validates it (directory, self-owned, not group/other-writable), and anchors every subsequent open/rename/unlink to that held fd so no path component is re-resolved between check and use. The file must be a regular, self-owned, single-link file (`O_NOFOLLOW|O_NONBLOCK`); writes are atomic (`O_EXCL` temp + `fsync` + rename within the held fd) and an over-limit payload is a hard error, never a silent truncation.
- **Nothing else**: no network access, no downloads, no bundled binaries, no services. The plugin only ever executes `ip`, `notify-send`, `python3 stateio.py`, `/bin/bash -c <own script text>`, and the helper via `sudo -n`. Route counts (100), name lengths (100), helper operations (128), route-table output (producer-side `head` cap), and monitor restarts (exponential backoff) are all bounded, and every short-lived process has a watchdog deadline.

Uninstall the helper from the panel, or manually:

```bash
sudo /usr/local/bin/pinroutes-approve --uninstall
```

## Dependencies

Nothing beyond a stock Omarchy install: `iproute2`, `bash`, `python3`, `sudo`, `polkit`, `libnotify` (`notify-send`).

## Configuration

Routes and settings are stored in `~/.config/pinroutes/pinroutes.json`.

| Setting | Default | Description |
|---------|---------|-------------|
| Monitoring | On | Netlink watch + periodic verification |
| Check interval | 60s | Periodic fallback verify interval |
| Auto-reapply | On | Silently re-apply missing routes (needs the helper) |
| Notify when missing | On | Desktop notification via `notify-send` |

## Scripting (IPC)

```bash
omarchy-shell pinroutes status    # e.g. "3 routes pinned"
omarchy-shell pinroutes apply     # re-apply missing routes
omarchy-shell pinroutes refresh   # re-verify now
omarchy-shell pinroutes toggle    # open/close the panel
```

## Project structure

```
manifest.json        # Omarchy plugin manifest (bar-widget)
Panel.qml            # Bar icon + popup panel UI (instantiated per monitor)
Service.qml          # Singleton: route state, verification, apply, netlink monitor
qmldir               # Registers Service as a QML singleton
Model.js             # Pure helpers: CIDR validation, route-table matching
stateio.py           # Atomic, symlink-safe config file I/O
helper/
  pinroutes-helper           # Root helper: validated ip-route ops only
  pinroutes-helper-install   # Installs helper + scoped sudoers entry (pkexec)
```

Developing: the shell hot-reloads files saved under `~/.config/omarchy/plugins/`. If you keep the source elsewhere and symlink the plugin directory, saves aren't watched across the symlink — run `omarchy-shell shell rescanPlugins` after editing.

## License

[MIT](LICENSE)
