# pangolin-bootstrap

![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Pangolin](https://img.shields.io/badge/Pangolin-Newt%20%2F%20Olm-2ea44f)

PowerShell installers for the [Pangolin](https://docs.pangolin.net) tunnel clients
**Newt** and **Olm** as native **Windows services** — on head office boxes, store
servers, or any Windows host that needs to join a Pangolin network. Three scripts:

- **`Setup-Pangolin.ps1`** — flexible interactive installer (Newt and/or Olm; endpoint
  and credentials supplied per run).
- **`Setup-Pangolin-TH.ps1`** — Olm-only variant with the **Thailand endpoint baked
  in**, for fleet rollouts where operators paste only an ID + secret. See
  [Fixed-endpoint installers](#fixed-endpoint-installers--th--id).
- **`Setup-Pangolin-ID.ps1`** — the full installer with the **Indonesia endpoint
  pre-filled** as the default (operators press Enter to accept). See
  [Fixed-endpoint installers](#fixed-endpoint-installers--th--id).

All three can **optionally install the Windows OpenSSH Server** for remote access —
you're prompted (default **No**), or pass `-InstallSsh y` / `-InstallSsh n` for
unattended runs.

> Bulk-creating the Olm clients (Integration API) is a separate, **private** admin tool
> — see the `pangolin-provisioning` repo. This repo is just the device-side installers.

It is **site-agnostic**: the Pangolin endpoint and all site/client IDs and secrets are
supplied per run, so the same script works for any environment. Binaries are pulled
fresh from the official GitHub releases each time, so you are never shipping or
committing executables.

Running the clients **as services** (not a manual `newt.exe` window or a scheduled
task) means the tunnel starts with Windows, survives logoff and reboot, and recovers
without anyone logged in.

---

## Newt vs Olm

Pangolin has two client agents; this script handles either or both.

| Client   | Role                                                       | Network mode                  | Needs a driver? |
| -------- | ---------------------------------------------------------- | ----------------------------- | --------------- |
| **Newt** | Site / network connector — exposes a site into Pangolin    | userspace WireGuard (netstack)| No              |
| **Olm**  | Client tunnel — connects this host *to* sites via Pangolin | real TUN adapter              | Yes — `wintun.dll` |

Install **Newt** on a box that should publish a site, **Olm** on a box that needs to
reach sites, or **both** on a box that does each.

## Prerequisites

- **Windows** (Server or client), `amd64` or `arm64` — architecture is auto-detected.
- **Windows PowerShell 5.1+** (the built-in `powershell.exe` is fine).
- **Elevated PowerShell** (Run as administrator) — required to register services.
- **Outbound HTTPS (443)** to:
  - `api.github.com` and `github.com` — Newt/Olm binaries (and the OpenSSH Server
    fallback, if Windows Update is blocked)
  - `www.wintun.net` — the Wintun driver (Olm only)
- **Optional — OpenSSH Server** (only if you opt in): installs via the native
  `Add-WindowsCapability` (needs Windows Update / Features-on-Demand), falling back to
  the [PowerShell/Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH) GitHub
  release. Opens inbound **TCP 22** and sets `sshd` to **Automatic**.
- **Pangolin credentials** for whatever you are installing:
  - Newt → **site ID + secret** (Pangolin → *Sites*)
  - Olm → **client ID + secret** (Pangolin → *Clients*)
  - the **endpoint** URL, e.g. `https://pangolin.example.com`

TLS 1.2 is forced at runtime, so it also works on older Windows Server builds.

## Quick start

Open **PowerShell as administrator** on the target server, then either:

### Bootstrap one-liner

```powershell
irm https://raw.githubusercontent.com/mjaylow/pangolin-bootstrap/main/Setup-Pangolin.ps1 | iex
```

> `irm | iex` runs in-process and **cannot self-elevate** — open the PowerShell window
> as administrator first, or it will exit at the admin check.

### Or clone / copy and run

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Setup-Pangolin.ps1
```

## What the run looks like

The script is fully interactive and walks through:

1. **Mode** — `1) Install / repair` or `2) Uninstall`.
2. **Component(s)** — `1) Newt only`, `2) Newt + Olm`, or `3) Olm only`.
3. **OpenSSH Server (optional)** — on install, asks whether to also install the Windows
   OpenSSH Server (default **No**). When accepted, it installs `sshd`, sets it to
   **Automatic**, starts it, and opens inbound TCP 22. Skip the prompt with
   `-InstallSsh y` / `-InstallSsh n`.
4. **Connection details** — the endpoint (uses the default if one is set, otherwise
   prompts), then the site/client ID + secret for each selected client.
5. **Download + install** — resolves the latest release, downloads the right binary
   (and Wintun for Olm), registers the service, starts it with your credentials, and
   forces the service to **Automatic** startup.
6. **Summary** — per client: running state, version, startup type, last status line.
7. **Optional ping test** — ping an internal host reachable over Pangolin to confirm
   the tunnel actually carries traffic (repeatable).

### Parameters

| Param         | Default            | Notes                                                                                  |
| ------------- | ------------------ | -------------------------------------------------------------------------------------- |
| `-Endpoint`   | *(empty → prompts)*| Pangolin endpoint. Empty by default, so the script asks each run. Pass to skip the prompt or override a baked-in default. |
| `-InstallDir` | `C:\_CDO\pangolin` | Where binaries, `wintun.dll`, and the services live.                                    |
| `-InstallSsh` | *(empty → prompts)*| Install the OpenSSH Server. `y`/`n` (or `yes`/`no`) skips the prompt for unattended runs; empty asks interactively (default **No**). |

```powershell
.\Setup-Pangolin.ps1 -Endpoint https://pangolin.example.com -InstallDir D:\pangolin -InstallSsh y
```

### Setting a default endpoint

To avoid typing the endpoint every run, edit the default near the top of
`Setup-Pangolin.ps1`:

```powershell
[string]$Endpoint = 'https://pangolin.example.com',
```

Leave it `''` to always prompt. A value passed with `-Endpoint` always wins.

## Fixed-endpoint installers — TH & ID

Two per-region variants ship with the Pangolin **endpoint pre-set**, for fleet rollouts
where operators shouldn't have to know or type the endpoint. Both still optionally
install the OpenSSH Server (prompt, or `-InstallSsh y`/`n`).

### `Setup-Pangolin-TH.ps1` — Thailand (Olm-only, no menus)

A trimmed, **Olm-only** variant with the Pangolin **endpoint hard-coded**. It prompts
only for the **client ID** and **secret** (or accepts `-Id` / `-Secret`), then downloads
Olm + Wintun and installs the service exactly like the main script.

```powershell
# operators: paste the id + secret for THIS device when prompted
irm https://raw.githubusercontent.com/mjaylow/pangolin-bootstrap/main/Setup-Pangolin-TH.ps1 | iex

# unattended (deployment tool): credentials + skip the SSH prompt
.\Setup-Pangolin-TH.ps1 -Id <olmId> -Secret <olmSecret> -InstallSsh n
```

Endpoint: `https://th-pangolin.prod.hthai-azure.gillcapitalinternal.com` (set near the
top of the script).

### `Setup-Pangolin-ID.ps1` — Indonesia (full installer, endpoint pre-filled)

A copy of the main `Setup-Pangolin.ps1` (same Newt/Olm menus, same flow) with the
**Indonesia endpoint pre-filled as the default** — operators just press Enter at the
endpoint prompt, or pass `-Endpoint` to override.

```powershell
irm https://raw.githubusercontent.com/mjaylow/pangolin-bootstrap/main/Setup-Pangolin-ID.ps1 | iex
```

Endpoint: `https://id-pangolin.prod.hthai-azure.gillcapitalinternal.com` (the `$Endpoint`
default near the top of the script).

Per-device credentials for both are issued by whoever administers Pangolin.

| Item                  | Location                                                       |
| --------------------- | ------------------------------------------------------------- |
| Newt binary           | `C:\_CDO\pangolin\newt.exe`                                    |
| Olm binary            | `C:\_CDO\pangolin\olm.exe`                                     |
| Wintun driver (Olm)   | `C:\_CDO\pangolin\wintun.dll`                                  |
| Newt service          | `NewtWireguardService` (Automatic)                            |
| Olm service           | `OlmWireguardService` (Automatic)                             |
| Service config + logs | `C:\ProgramData\newt\` and `C:\ProgramData\olm\`              |

| Client | Source repo                                       | Asset                     |
| ------ | ------------------------------------------------- | ------------------------- |
| Newt   | [fosrl/newt](https://github.com/fosrl/newt)       | `newt_windows_<arch>.exe` |
| Olm    | [fosrl/olm](https://github.com/fosrl/olm)         | `olm_windows_<arch>.exe`  |

Versions are resolved per run from each repo's `releases/latest`.

> The fosrl installer registers services as **Manual** start. This script forces them
> to **Automatic** so the tunnel comes up on boot without a logged-in session.

### Why Olm needs Wintun

Olm creates a real TUN adapter, so it needs `wintun.dll` beside `olm.exe` — this is the
only thing fosrl's `olm_windows_installer.exe` adds over the raw binary. The script
downloads the signed [Wintun](https://www.wintun.net) `0.14.1` DLL (**SHA-256
verified**) when installing Olm. Without it, Olm logs:
`Failed to create TUN device: Error loading wintun.dll`. Newt is userspace and needs
nothing.

## Verify

After it finishes, confirm each site/client shows **Online** in the Pangolin
dashboard. On the server you can re-check any time:

```powershell
cd C:\_CDO\pangolin
.\newt.exe status   # and / or
.\olm.exe status
```

## Re-running and migration

Safe to re-run. On each client it stops any running instance (releasing the binary
lock), re-registers the service, and starts it with the credentials you supply — so a
box still on the old manual `newt.exe --id ... --endpoint ...` or a scheduled task is
migrated cleanly to a managed service.

## Uninstall

Choose **Uninstall** at the mode prompt, then Newt only / Newt + Olm / Olm only. For
each selected client it stops and removes the Windows service (the client's own
`uninstall`, with an `sc.exe delete` fallback by service name). It then asks whether to
**also delete** the binaries and saved config (`*.exe`, `wintun.dll` for Olm, and
`C:\ProgramData\<client>\`) — answer **N** to leave files in place and only remove the
services. A final `yes` confirmation is required before anything changes.

## Troubleshooting

| Symptom                                                       | Fix                                                                                       |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `must run in an ELEVATED PowerShell`                          | Relaunch PowerShell as administrator.                                                     |
| Download / TLS errors on old Windows Server                   | TLS 1.2 is forced automatically; confirm outbound 443 to GitHub (and wintun.net for Olm).|
| Olm: `Error loading wintun.dll`                               | `wintun.dll` is missing next to `olm.exe`; re-run and install Olm so it is fetched.       |
| Service does not start after reboot                           | Check `services.msc` for `NewtWireguardService` / `OlmWireguardService` set to Automatic. |
| Status does not clearly show *running*                        | Recheck ID/secret/endpoint, confirm **Online** in Pangolin, review `C:\ProgramData\<client>` logs. |
| Ping test fails with a "lack of resources" style error        | The script already uses `ping.exe` (not `Test-Connection`) to avoid this WMI issue.       |
| OpenSSH: `Add-WindowsCapability` fails (Windows Update blocked)| Expected on locked-down boxes — the script auto-falls back to the Win32-OpenSSH GitHub release. Confirm outbound 443 to GitHub. |
| Can't reach the box over SSH after install                    | Confirm `sshd` is **Running**/Automatic in `services.msc` and that inbound **TCP 22** is allowed by any upstream/network firewall. |

## Security

Secrets are typed into the console at runtime and passed to the client on `start`.
After verifying a migration, **regenerate the affected site/client secrets in
Pangolin**. Binaries are never committed (see `.gitignore`).
