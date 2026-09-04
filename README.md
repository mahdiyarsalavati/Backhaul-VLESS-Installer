# Backhaul VLESS Installer

A guided, paginated installer that relays an existing (or freshly built)
**VLESS** proxy through **[Backhaul](https://github.com/Musixal/Backhaul)**:

```
[ VLESS client ] --> [ Iran relay, public ] == Backhaul tunnel ==> [ Foreign server ]
                                                                        |
                                                                   VLESS inbound
                                                                  (127.0.0.1 only)
```

The foreign server runs a VLESS inbound bound to `127.0.0.1` — either one you
already run (e.g. via 3x-ui/x-ui), or a fresh Xray-core VLESS+REALITY
inbound the script sets up for you. The Iran server runs Backhaul and
exposes the only public port, forwarding it through the tunnel to the
foreign server's local VLESS port. The script builds the final VLESS URL
for you: paste your inbound's share link once, and it does the rest — you
never hand-edit a VLESS URL.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mahdiyarsalavati/Backhaul-VLESS-Installer/main/backhaul-universal.sh)
```

Run it as root on both servers.

## Setup order

The menu is numbered in the order you need to run it:

1. **Foreign server — option 1**: choose either
   - **I already have an inbound** (e.g. from 3x-ui/x-ui) — nothing is
     installed or touched; you paste its VLESS share link (any type —
     REALITY, TLS, plain `security=none`, whatever it already uses) and
     the script parses out what it needs, or
   - **Build a new one** — installs Xray-core and sets up VLESS+REALITY
     from scratch.

   Either way it prints a compact "bundle" string (your VLESS credentials,
   base64-encoded).
2. **Iran server — option 2**: installs Backhaul, asks you to paste the
   bundle from step 1, lets you choose the tunnel transport (raw TCP, or
   WebSocket fronted by Cloudflare with your own domain), and prints the
   final, ready-to-import **VLESS URL** plus the address/token you need for
   step 3.
3. **Foreign server — option 3**: installs the Backhaul client using the
   address/transport/token from step 2.
4. Import the VLESS URL from step 2 into your client app.

Menu option 7 (**Help**) shows this same order inside the script, along with
the reasoning for it.

## What's tuned automatically

- BBR congestion control, tuned socket buffers, larger backlog/queues, and
  raised file-descriptor limits, applied on every install (also available
  standalone via menu option 4).
- `TCP_NODELAY`, a plain (mux-free) transport, and disabled stats/sniffer
  endpoints to keep CPU overhead low.
- Connection-pool size (step 3) is the one deliberate manual choice: larger
  pools raise throughput and resilience at the cost of idle CPU/RAM, so the
  script asks and explains the trade-off instead of guessing.
- Every port prompt (tunnel port, public port, local Xray port) offers
  **Auto** (finds the best free port for you) or **Manual** (validates the
  port is free, and — for Cloudflare-proxied WebSocket — that it's one of
  Cloudflare's officially proxied ports: 443, 2053, 2083, 2087, 2096, 8443
  for HTTPS, or 80, 8080, 8880, 2052, 2082, 2086, 2095 for HTTP).

## WebSocket / Cloudflare mode

If you choose WebSocket for the Backhaul tunnel, the script asks for a
domain and whether it will be **Proxied** (orange cloud) or **DNS only**
(grey cloud) in Cloudflare, then prints the exact DNS record to add. Plain
WS pairs with Cloudflare's "Flexible" SSL mode (no certificate needed); WSS
pairs with "Full" mode and uses a self-signed certificate generated on the
Iran server.

Original project: [Musixal/Backhaul](https://github.com/Musixal/Backhaul) ·
[XTLS/Xray-core](https://github.com/XTLS/Xray-core)
