# CoreDNS: fanout multi-upstream DNS with cache, serve-stale, and prefetch (Windows & Linux)

## What this setup gives you

- Creates a DNS resolver on the loopback address (**127.0.0.153** on Linux, **127.0.0.1** on Windows).
- Forwards DNS queries to a list of DNS servers in parallel (**fanout**) and returns the first reply from the fastest server.
- Stores prior query results in a local cache and reuses them when the same DNS query is requested.
- Keeps records in the cache even after their expiry so the client is always served with a response.
- Automatically detects frequently requested queries and prefetches them in the background to keep them fresh in the cache.
- Changes the system DNS resolver to the local DNS provided by CoreDNS.

---

## Linux (root)

**Changes in brief**

- Downloads and installs **`coredns`** to **`/usr/local/bin`**.
- Creates **`/etc/coredns`** with **`resolvers`** and **`Corefile`**.
- Adds the **`coredns`** system user and **`coredns.service`** systemd unit.
- Enables and starts **`coredns.service`**.
- Points **`/etc/resolv.conf`** at **`127.0.0.153`** and applies **`chattr +i`**.
- **Uninstall:** removes **`coredns.service`**, **`/usr/local/bin/coredns`**, **`/etc/coredns`**, user **`coredns`**; Rewrites **`nameserver`** lines in **`/etc/resolv.conf`** to **`217.218.127.127`** and **`217.218.155.155`**

**Run as root**:

**Install / upgrade / re-apply config**

```bash
curl -fsSL 'https://raw.githubusercontent.com/aleskxyz/coredns/refs/heads/release/installer/linux.sh' | sudo bash
```

**Uninstall**

```bash
curl -fsSL 'https://raw.githubusercontent.com/aleskxyz/coredns/refs/heads/release/installer/linux.sh' | sudo bash -s -- --uninstall
```

---

## Windows (Administrator PowerShell)

**Changes in brief**

- Downloads and installs **`coredns.exe`** under **`C:\Program Files\CoreDNS\`**.
- Writes **`resolvers`** and **`Corefile`** under **`C:\ProgramData\coredns\`**.
- Registers a **CoreDNS** Windows service and starts it.
- Points **active adapters** at loopback DNS (**IPv4 `127.0.0.1`**, **IPv6 `::1`**).
- **`-Uninstall`:** removes the service, install/data dirs, temp download artifacts; sets **IPv4** DNS to **`217.218.127.127`** and **`217.218.155.155`**.

**Run as Administrator** in PowerShell:

**Install / upgrade / re-apply config**

```powershell
$u = 'https://raw.githubusercontent.com/aleskxyz/coredns/refs/heads/release/installer/windows.ps1';
$p = Join-Path $env:TEMP 'install_coredns_windows.ps1';
Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing;
powershell.exe -ExecutionPolicy Bypass -File $p;
```

**Uninstall**

```powershell
$u = 'https://raw.githubusercontent.com/aleskxyz/coredns/refs/heads/release/installer/windows.ps1';
$p = Join-Path $env:TEMP 'install_coredns_windows.ps1';
Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing;
powershell.exe -ExecutionPolicy Bypass -File $p -Uninstall;
```

---
