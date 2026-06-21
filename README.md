# pangolin-bootstrap

Interactive bootstrap for the [Pangolin](https://docs.pangolin.net) tunnel clients
**Newt** (site/network connector) and **Olm** (client-to-Newt tunnel) on Windows
head office and store servers. Site-agnostic — the Pangolin endpoint and all
site/client IDs and secrets are supplied per run, so the same script serves any
environment.

One script, run elevated on the target box. It:

1. Asks what to install — **Newt only / Newt + Olm / Olm only**
2. Prompts for the endpoint and the relevant site/client IDs + secrets
3. Downloads the **latest** Windows binaries from GitHub releases into `C:\_CDO\pangolin`
4. Registers and starts each client as a **native Windows service** (`install` → `start` → set **Automatic** startup → `status`). The fosrl installer registers services as *Manual*, so the script forces `NewtWireguardService` / `OlmWireguardService` to **Automatic** start.
5. Prints a summary
6. Optionally runs a 3-count ping test against an internal host/service reachable over Pangolin

Running as a service means the tunnel starts with Windows, survives logoff/reboot, and
recovers without a logged-in session or scheduled task.

## Run it

The script first asks for a **mode** — *Install / repair* or *Uninstall* — then which
component(s) to act on (**Newt only / Newt + Olm / Olm only**).

Elevated PowerShell (Run as administrator) on the target server.

### Bootstrap one-liner

```powershell
irm https://raw.githubusercontent.com/<you>/pangolin-bootstrap/main/Setup-Pangolin.ps1 | iex
```

> `irm | iex` runs in-process, so it can't self-elevate — start the PowerShell window
> as administrator first.

### Or clone / copy and run

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Setup-Pangolin.ps1
```

### Parameters

| Param         | Default              | Notes                                                                 |
|---------------|----------------------|-----------------------------------------------------------------------|
| `-Endpoint`   | *(set in script)*    | Pangolin endpoint for the target environment. If empty, the script prompts. Pass to override. |
| `-InstallDir` | `C:\_CDO\pangolin`   | Where binaries + services live.                                       |

```powershell
.\Setup-Pangolin.ps1 -Endpoint https://pangolin.example.com
```

## Set the default endpoint

Edit the `$Endpoint` default near the top of `Setup-Pangolin.ps1`:

```powershell
[string]$Endpoint = 'https://pangolin.example.com',
```

Leave it blank to always be prompted. Provide a value via `-Endpoint` at runtime to override.

## What gets installed

| Client | Repo                                            | Asset                       | Service via      |
|--------|-------------------------------------------------|-----------------------------|------------------|
| Newt   | [fosrl/newt](https://github.com/fosrl/newt)     | `newt_windows_<arch>.exe`   | `newt install`   |
| Olm    | [fosrl/olm](https://github.com/fosrl/olm)       | `olm_windows_<arch>.exe`    | `olm install`    |

Version is resolved per-run from each repo's GitHub `releases/latest`. Architecture
(`amd64`/`arm64`) is detected automatically.

### Olm needs Wintun

Newt is userspace WireGuard (netstack) and needs no driver. **Olm** creates a real TUN
adapter, so it requires `wintun.dll` next to `olm.exe` — this is the only thing fosrl's
`olm_windows_installer.exe` adds over the raw binary. The script downloads the signed
[Wintun](https://www.wintun.net) `0.14.1` DLL into `C:\_CDO\pangolin` (SHA-256 verified)
when installing Olm. Without it Olm logs: `Failed to create TUN device: Error loading
wintun.dll`.

## Uninstall

Choose **Uninstall** at the mode prompt, then pick Newt only / Newt + Olm / Olm only.
For each selected client it stops and removes the Windows service (via the client's own
`uninstall`, with an `sc.exe delete` fallback by service name). It then asks whether to
**also delete** the binaries and saved config (`C:\_CDO\pangolin\<client>.exe`,
`wintun.dll` for Olm, and `C:\ProgramData\<client>\`) — answer `N` to leave files in
place and only remove the services. A final `yes` confirmation is required before anything
is changed.

## Re-running / switching from the old manual or scheduled-task setup

Safe to re-run. On each client it stops any existing instance (releases the binary
lock), re-registers the service, and starts it with the credentials you supply, so a
box still on the old `newt.exe --id ... --endpoint ...` manual/scheduled-task approach
is migrated cleanly to a managed service.

## Security note

Secrets are typed into the console. After verifying the migration, **regenerate the
site/client secrets in Pangolin**.

## Verify

After it finishes, confirm each site/client shows **Online** in the Pangolin dashboard.
On the server you can re-check any time with:

```powershell
cd C:\_CDO\pangolin
.\newt.exe status   # and/or
.\olm.exe status
```
