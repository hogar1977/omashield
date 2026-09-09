# OmaShield

Interactive, scanner-guarded AUR updates and installs for Omarchy.

Instead of blindly upgrading everything, OmaShield lists every pending repo
and AUR update preselected, lets you defer any of them, reviews the surviving
AUR set with **aur-scan** (static analysis) and **yay-guard** (heuristics +
AUR metadata), and only installs what you explicitly greenlight. Native yay
hooks guard every `yay` invocation as a second layer.

## Hard dependencies

OmaShield **stays OFF** until both of these are installed:

- `aur-scanner` (provides `aur-scan`)
- `yay-guard` (provides `aur_audit.py`)

Install them through the standard procedure (Main Menu > Install > Package,
or `yay -S aur-scanner yay-guard`), then switch OmaShield ON. The switch
re-checks on every attempt and tells you what is missing.

## Install

```bash
omarchy plugin add https://github.com/hogar1977/omashield.git --enable
```

The widget appears in the bar, OFF by default. Switching it ON for the first
time wires everything up (see below). No files outside this plugin directory
are touched before that — **switching ON is the explicit consent** for the
wiring described in "Files touched".

## What each control does

| Control | Behaviour |
|---|---|
| ON/OFF switch | Arms/disarms the guard. Refuses with a dialog while hard deps are missing. OFF keeps all files in place; flows bypass to stock behaviour. |
| Update | Opens a terminal: preselected repo+AUR picker → dependency-cascade defer → aur-scan + yay-guard review → greenlight → full omarchy update of the chosen set only. |
| Install AUR | Opens a terminal: fuzzy AUR picker → review of the picks → greenlight → install. |
| Audit AUR | Read-only audit of **all installed** AUR packages with both tools. Changes nothing. |
| Uninstall | Restores the stock menu, removes the yay hooks, the `omarchy-omashield` command and the state dir, then removes the plugin itself. `aur-scanner`/`yay-guard` stay installed (remove them via Main Menu > Remove > Package if wanted). |

Middle-click the bar icon re-reads status. Keys in the popup: `toggle`,
`u` update, `i` install, `a` audit, `esc` close.

## Files touched (all reversible via Uninstall)

| Path | What |
|---|---|
| `~/.local/bin/omarchy-omashield` | Symlink to this plugin's CLI (created on first ON). |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | `update.omarchy` / `install.aur` routed through OmaShield (stock values captured once for restore). |
| `~/.config/yay/init.lua` | Native guard hooks (pre-existing user file backed up as `init.lua.omashield-bak.*` first). |
| `~/.config/omashield/` | State (`enabled=1/0`), pending selections, review stamp, PATH-shadow symlinks. |

Nothing is installed system-wide; no sudo is used by the wiring itself.
Package installs (`yay -S aur-scanner yay-guard`, and the reviewed updates)
ask for sudo in the terminal like any stock omarchy flow.

## Disable vs uninstall

- **Disabling the widget** (plugin manager / `omarchy plugin disable`) keeps
  every file but bypasses the guard: Update/Install run the stock flows until
  the widget is re-enabled.
- **Uninstall button** removes everything above plus the plugin directory, as
  if it was never installed.

## Bypasses

- `OMASHIELD_OFF=1` (legacy `AUR_SHIELD_OFF=1`, yay-guard's `AUR_AUDIT_OFF=1`)
  disables the hooks and the guarded flows for a single command.

## Removal (manual, without the panel)

```bash
omarchy-omashield uninstall --yes
```

## License

MIT — see [LICENSE](LICENSE).
