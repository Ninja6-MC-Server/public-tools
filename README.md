# Ninja6 Minecraft Server - Public Player Tools

Connectivity and troubleshooting tools for **Ninja6 Minecraft Server** players.

---

## How to connect

### Java Edition (PC)
* **Server Address:** `tissues-convertible.tun.ply.gg`
* Type the name exactly like this. You do not need a port.
* **Do not use a numeric IP address.** The tunnel decides where to send you by the
  name you typed, so a connection made to the raw IP (IPv4 or IPv6) is reset and
  fails with errors like `Connection reset` or `Connection socket exception`.
* If you must enter a port, both `tissues-convertible.tun.ply.gg:25565` and
  `tissues-convertible.tun.ply.gg:64766` work. Leaving the port out is simplest.

### Bedrock Edition (Mobile / Windows / Consoles)
* **Server Address:** `la64zuc5.free.tryportwarp.cc`
* **Port:** `11899`
* **Supported versions:** 1.26.50 to 1.26.60
* Do not use the Java address on Bedrock.
* Keep IPv6 turned on. If your network has working IPv6, Bedrock uses a direct
  IPv6 route, which is the best one. Without IPv6 it uses a relay route on its own.

---

## Network diagnostics

If you cannot join, or get errors like `Connection reset`, `Connection socket
exception`, `Failed to log in` or `Error Code: Creaking`, run the check below. It only
reads information and opens test connections; it does not change anything on your
device.

### Windows (PowerShell)
Open **PowerShell** (press `Win + X`, then choose Terminal or PowerShell), paste this
command, and press **Enter**:
```powershell
irm https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.ps1 | iex
```

### Linux / macOS / Android (Termux)
Open a terminal and run:
```bash
curl -sSL https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.sh | bash
```

### What it checks
* Internet access over IPv4.
* IPv6 (information only; nothing to fix if it fails).
* Windows only: firewall rules that block Minecraft, and the Microsoft / Xbox Live
  sign-in servers.
* **Java:** a real Minecraft server list ping to `tissues-convertible.tun.ply.gg`,
  sent the same way the game does. If this passes, the server is online and your
  network can reach it.
* **DNS:** whether your device can find both server names. If your own DNS server
  cannot find them but public DNS can, your internet provider, router or a filter
  is blocking the name, and the tool tells you how to switch to a public DNS server.
  In that case it also tests the Java server through the public address, so you
  know whether fixing DNS is all you need.
* **Java:** a real Minecraft server list ping to `tissues-convertible.tun.ply.gg`,
  sent the same way the game does. If this passes, the server is online and your
  network can reach it.
* **Bedrock:** a TCP connection to `la64zuc5.free.tryportwarp.cc` port `11899`.
  Game traffic (UDP) is set up separately when you join, so this check shows the
  join address is up but cannot prove the whole join path.
* **Saved servers:** reads your saved server lists (official launcher, Prism,
  Modrinth, CurseForge, ATLauncher and GDLauncher on Windows; the official launcher
  and Prism on Linux and macOS; Windows Bedrock) and points out any entry that still
  uses an old address, such as the numeric IP. It never edits them.

### Asking for help
At the end the tool prints a **result line** that starts with `N6DIAG`. On Windows it
is also copied to your clipboard. Paste that one line in Discord when you ask for help.
