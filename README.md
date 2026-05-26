<p align="center">
  <img src="GITHUB-LOGO.png" alt="EISA Homelab" width="900">
</p>

# 🏠 EISA Homelab

> 🛡️ **The ultimate private, no-tracking homelab stack.**
> 💻 100% local-first  ·  🔇 zero telemetry  ·  🔐 your data on your machine.
>
> 👤 Created by **EISA**.

---

## ✨ What you get

**One wizard. ~25 containers. Zero cloud accounts. Five minutes from `git clone` to a running stack.**

| | Replaces | Apps in the stack |
| :-: | --- | --- |
| 🎬 | Netflix / Spotify / Google Photos | **Jellyfin** · **Navidrome** · **Immich** |
| 🍿 | Plex + Overseerr + a torrent box | **Seerr** request UI → **Sonarr** / **Radarr** / **Prowlarr** → **qBittorrent**, auto-wired to *1080p, English, ≤ 4 GB* |
| 🤖 | ChatGPT / Perplexity / research agents | **Open WebUI** · **Vane** · **Local Deep Research** - all running on local **Ollama** |
| 🔗 | Zapier / Make.com | **n8n** drag-and-drop automation, wired into everything else |
| 🧅 | a clean browser session | **Tor Browser** in a browser tab, one-click auto-login |
| 📂 | Dropbox / a file manager over the LAN | **Filebrowser** + **Omni Tools** + **Portainer** |
| 🌐 | port-forwarding pain | **Cloudflare tunnel** + **Authelia SSO** - opt-in; off by default |

Nothing phones home. Every LLM prompt stays on your hardware. No OpenAI / Anthropic / Google in the install path. SearXNG has tracking disabled. Every image is pinned to a numbered version - no `:latest`. Tunnel mode is opt-in (off by default) - local-only out of the box.

---

## 🚀 Quick start

**One launcher per platform.** Everything else is behind a menu.

```bat
:: Windows
git clone https://github.com/EISA-IO/EISA-HOMELAB.git
cd EISA-HOMELAB
WINDOWS-HOMELAB-MANAGER.BAT          :: or double-click it
```

```sh
# macOS
git clone https://github.com/EISA-IO/EISA-HOMELAB.git
cd EISA-HOMELAB
./MAC-HOMELAB-MANAGER.COMMAND        # or double-click in Finder
```

That opens this menu:

```
  EISA HOMELAB - Manager
   [1] First-Run Setup    (wizard - run once on a fresh clone)
   [2] Start Stack        (day-to-day, brings everything up)
   [3] Stop Stack         (compose down + cleanup)
   [4] LLM Manager        (pull / launch / delete Ollama models)
   [0] Exit
```

The first-run wizard:
- 🐳 Auto-installs **Docker Desktop** if it's missing (winget / MSI on Windows, brew / DMG on macOS) - one UAC / sudo prompt and it resumes.
- 🧱 Asks which stack:
  - **AI** - chat, search, research, agents
  - **MEDIA STREAMING** - Jellyfin, Navidrome, Immich
  - **MEDIA REQUEST** - Seerr + Sonarr + Radarr + Prowlarr + qBittorrent
  - **PRODUCTIVITY** - file tools, Omni Tools, Tor Browser
  - **ULTIMATE** - everything above
  - **CUSTOM** - pick individual services
  - Either way, you can then drop specific containers you don't want.
- 🌐 Asks hosting mode: **local-only** (default) or **Cloudflare tunnel** - walks you through getting a tunnel token if you choose tunnel.
- 📁 Asks where your media lives in plain English (Movies, TV Shows, Music, Downloads, Photos).
- 🔑 Generates every secret + Authelia argon2 hash silently.
- 🛠️ If the **Request Stack** is in, auto-wires Seerr ↔ Sonarr ↔ Radarr ↔ Prowlarr ↔ qBittorrent, locks profiles to **1080p / English / ≤ 4 GB**, pre-loads working indexers, and makes qBittorrent **stop seeding the instant a download completes**.
- 🧠 If AI is in the stack, auto-installs two starter LLMs (see [The LLMs](#-the-recommended-llms) below).
- 🖱️ On the last screen offers to drop a **desktop shortcut** that opens Docker + brings the stack up + opens Heimdall in your browser - one click from a cold boot to a working stack.

After that, day-to-day is `[2] Start Stack` / `[3] Stop Stack`, or double-click the desktop shortcut. Stopping never touches your media folders or the docker named volumes - Ollama models, Open WebUI history, Jellyfin cache, qBittorrent state, etc. all survive.

---

## 🎯 What each app does (plain English)

### 🏗️ CORE - always on, you usually don't think about them

- 🏠 **Heimdall** - your homepage. Tiles for every other app, so you don't remember port numbers.
- 🚦 **Caddy** - the traffic cop. Routes requests to the right app. You never click on it.
- 🔐 **Authelia** - the login page (tunnel mode). 2FA + group permissions.
- 🎛️ **Portainer** - a Docker web GUI for when you want to look at logs or restart something.

### 🤖 AI - local LLMs, private search, agents, automation

- 🧠 **Ollama** - the engine running AI language models on your own hardware. Everything below talks to it.
- 💬 **Open WebUI** - a ChatGPT-style chat window. The main app you'll open.
- 🔍 **SearXNG** - a private metasearch engine. Google / Bing / DuckDuckGo results without the tracking.
- 📚 **Local Deep Research** - give it a topic, get a structured report. Like a researcher that works overnight.
- ❓ **Vane** - a Perplexity-style answer engine. One-shot questions with sources.
- 🔗 **n8n** - drag-and-drop automation. *"When an email arrives → save the attachment → ask the AI to summarise it → text me the result."*
- 🧭 **Qdrant** - vector database under the hood for AI memory / RAG. You won't open it manually, n8n + research agents talk to it.

### 🎬 MEDIA STREAMING STACK - your own Netflix / Spotify / Google Photos

- 🎥 **Jellyfin** - Netflix for your movies and TV. Reads from the folder you set, streams to TV / phone / browser. Pinned to **10.10.7** (10.11.x has a known startup bug).
- 🎵 **Navidrome** - Spotify for your music. Same idea. Beautiful mobile apps available.
- 📸 **Immich** - Google Photos replacement. Phone auto-backup, face / object recognition, search by what's *in* the photo.

### 🍿 MEDIA REQUEST STACK - request a movie/show, it downloads itself

Pick a title in Seerr → Sonarr/Radarr find it → Prowlarr searches indexers → qBittorrent pulls it → it lands in your Jellyfin library. Fully auto-wired by the wizard with sane defaults you can change in each app's UI.

- 📺 **Seerr** - the request UI. Looks like Netflix, but the "Watch" button is "Request". Signs in via your Jellyfin account.
- 📡 **Sonarr** - the TV brain. Monitors shows, grabs new episodes, renames + moves files into your TV folder.
- 🎞️ **Radarr** - same idea for movies.
- 🛰️ **Prowlarr** - one place to manage torrent indexers; Sonarr + Radarr ask it where to look.
- ⚡ **qBittorrent** - the downloader. Configured to **stop seeding the instant a download finishes** (no background bandwidth use, no ratio babysitting).

Default quality profile: **HD-1080p, English-only, reject any release > 4 GB**. Custom Formats enforce the size + language caps automatically.

### 🛠️ PRODUCTIVITY - utilities

- 📂 **Filebrowser** - web file explorer for the folders you exposed. Upload / rename / move from any browser.
- 🧰 **Omni Tools** - local versions of every "online tool" site (resize, convert, QR, base64, …) - nothing leaves your machine.
- 🧅 **Tor Browser** - full Tor Browser in a browser tab. One click from Heimdall.

### 🌐 ONLINE-ONLY - only in tunnel mode

- ☁️ **Cloudflared** - connects your stack to Cloudflare so people can reach `chat.yourdomain.com`, `movie.yourdomain.com`, etc. without you opening router ports.

---

## 🗺️ Service URLs (local mode)

After the wizard finishes, every app is reachable at a clean `*.localhost` URL - no port numbers, no hosts-file edits. Caddy on port 80 proxies each subdomain to the right container. (`*.localhost` is hard-resolved to `127.0.0.1` by every modern browser and OS - RFC 6761.)

| Service | URL | Service | URL |
| --- | --- | --- | --- |
| Heimdall (start page) | <http://hub.localhost> | Open WebUI (chat) | <http://chat.localhost> |
| Jellyfin (movies/TV) | <http://movie.localhost> | SearXNG (search) | <http://search.localhost> |
| Navidrome (music) | <http://music.localhost> | Local Deep Research | <http://research.localhost> |
| Immich (photos) | <http://photos.localhost> | Vane (AI search) | <http://smartsearch.localhost> |
| Filebrowser | <http://file.localhost> | n8n (workflows) | <http://n8n.localhost> |
| Omni Tools | <http://tool.localhost> | Qdrant (vectors) | <http://qdrant.localhost> |
| Tor Browser | <http://tor.localhost/> | Portainer | <http://portainer.localhost> |
| Seerr (requests) | <http://request.localhost> | Sonarr (TV) | <http://sonarr.localhost> |
| Radarr (movies) | <http://radarr.localhost> | Prowlarr (indexers) | <http://prowlarr.localhost> |
| qBittorrent | <http://torrent.localhost> | Ollama API | <http://localhost:11434> |

In tunnel mode everything also gets a subdomain on your own domain (`chat.example.com`, `movie.example.com`, …) gated by Authelia SSO.

---

## 🔑 Default credentials

The wizard pre-configures **`admin` / `admin`** everywhere it can, and tells you exactly what to type at any first-visit signup screen so it stays consistent. **Change these the moment you expose anything beyond your LAN.**

| Service | Username | Password | Notes |
| --- | --- | --- | --- |
| Jellyfin | `admin` | `admin` | wizard creates the admin via the API |
| Seerr | - | - | signs in with your Jellyfin `admin / admin` |
| qBittorrent | `admin` | `adminadmin` | v5 requires ≥ 6 chars |
| Authelia | `admin` | `admin` | tunnel-mode SSO gate (argon2-hashed) |
| Portainer | `admin` | `admin` | first-visit signup |
| Filebrowser | `admin` | `admin` | first-visit default |
| Immich | `admin@local.host` | `admin` | admin signup form |
| Navidrome | `admin` | `admin` | first-visit prompt |
| Open WebUI | `admin` | `admin` | first-visit signup |
| n8n | `admin@local.host` | `admin` | owner signup |
| Sonarr / Radarr / Prowlarr / Heimdall | - | - | no login required on LAN |

---

## 🧠 The recommended LLMs

The wizard auto-installs two starter models so you're not staring at an empty chat box. Two heavier "monsters" sit in `recommended_models.txt` for when you have the hardware - pull them from `[4] LLM Manager` in the launcher.

### 📦 Starters (auto-installed, ~5 GB each, runs on almost any GPU/CPU)

- **🌟 `huihui_ai/gemma-4-abliterated:e4b-q4_K`** - General-purpose, uncensored.
  Google's Gemma 4 (4B) with the refusal layer surgically removed (no retraining, just no more "I can't help with that"). Daily-driver for chat / writing / Q&A.
- **👨‍💻 `carstenuhlig/omnicoder-2-9b:q4_k_m`** - Agentic + coding.
  9B fine-tune built for code generation and tool-use. Use for anything code-shaped or when you want the model to plan + execute multi-step work. Pairs cleanly with n8n's AI nodes.

### 💪 Monsters (manual pull, ~16-24 GB VRAM)

- **🦣 `iaprofesseur/SuperGemma4-26b-uncensored-Q4`** - 26B uncensored Gemma 4. Same family as the small starter, much bigger brain. For long-form writing / sustained reasoning.
- **🐲 `fredrezones55/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4`** - 35B Qwen MoE, aggressive uncensored finetune. **MoE** = 35B total params, only ~3B *active* per token - runs at the speed of a small model with the reasoning of a huge one. The closest you'll get to a frontier model on your own GPU.

> **Glossary** - *VRAM*: your GPU's memory budget. *Quantization* (`q4_K`, `Q4_K_M`): how the weights are compressed; smaller = faster, slight quality cost. *Abliterated*: refusal removed via weight surgery; the model isn't retrained or dumbed down. *MoE*: many "experts" inside; only a couple activate per token, so total params >> active params.

---

## ⚙️ Notes

- **Linux containers run on Apple Silicon** - every image is multi-arch (`linux/arm64`). Docker on Mac can't pass Metal through to containers, so the wizard offers a "**Native Ollama**" mode that points Open WebUI / LDR / Vane at the host's Metal-accelerated `brew install ollama`.
- **GPU acceleration is pluggable** - the wizard detects NVIDIA / AMD / CPU and layers the right compose override on top. Same detection drives Immich's NVENC / VAAPI transcoding + ML acceleration.
- **All images pinned** - no `:latest` anywhere in `docker-compose.yml`; upgrades are explicit. Bumping a version is a one-line change you can roll back from.
- **Re-configure later** - open the launcher → `[1] First-Run Setup` again. Existing data survives; the wizard is fully idempotent (it drift-detects, e.g., a stale qBittorrent port in Sonarr's download client and corrects it).
- **Manual stop** - `cd files && docker compose down`. The launcher's `[3]` does this + a by-`container_name` fallback so containers from older installs are also caught.

---

## 🌐 Remote Ollama API (Bearer-token gated)

Tunnel-mode publishes the in-stack Ollama at **`https://ollama.${DOMAIN}`** (e.g. `https://ollama.eisa.io`), gated by a Bearer token. Use this for cloud apps (Cloud Run, Vercel, etc.) that need your homelab GPU without bouncing through Open WebUI.

**Token requirement applies only to remote traffic.** Local access bypasses the gate:
- `http://localhost:11434` (host-loopback port mapping)
- `http://ollama.localhost` (Caddy vhost — *.localhost resolves to 127.0.0.1 per RFC 6761)
- `http://ollama:11434` (intra-docker network, e.g. Open WebUI, n8n)

Only `https://ollama.${DOMAIN}` (arriving via Cloudflare Tunnel) hits the auth sidecar.

**How it's protected**
- Cloudflare Tunnel terminates TLS — no router ports opened.
- Caddy forwards every public request to the `ollama-auth` sidecar (`files/ollama-auth/server.js`, runs read-only / no-new-privileges / cap-drop ALL).
- The sidecar SHA-256-hashes the supplied Bearer token and constant-time-compares it against the allow-list.
- The host port `11434` is bound to `127.0.0.1` — Ollama itself is never on a LAN/WAN interface.

**Issuing a token — two paths, pick whichever fits**

**A. Drop it in `.env`** (lowest friction, plaintext at rest, one restart):

```env
# files/.env
OLLAMA_TOKEN_EXECUTIVE_BRIEF=<your-long-random-string>
OLLAMA_TOKEN_DARKO_HOMELAB=<another-long-random-string>
OLLAMA_TOKEN_EISA_HOMELAB=<another-long-random-string>
# or a bare comma-separated list with no labels:
OLLAMA_TOKENS=tok1,tok2
```

```pwsh
docker compose restart ollama-auth
```

The `OLLAMA_TOKEN_<LABEL>` suffix becomes the token's log label. Plaintext sits in `.env` (already a private host file); the sidecar hashes them in memory at startup and never logs the value.

**B. Use the issuer CLI** (hashed at rest, hot-reload, audit-friendly):

```pwsh
pwsh files/scripts/ollama-token.ps1 issue executive-brief-prod
#   -> prints the plaintext ONCE - save it then. Hashes are persisted.
#   -> takes effect within ~5s (the sidecar reloads on mtime).
```

```pwsh
pwsh files/scripts/ollama-token.ps1 list
pwsh files/scripts/ollama-token.ps1 revoke <id-or-label>
pwsh files/scripts/ollama-token.ps1 rotate executive-brief-prod
pwsh files/scripts/ollama-token.ps1 issue  executive-brief-prod -Expires 2026-12-31
```

**Smoke test**

```sh
curl -H "Authorization: Bearer <token>" https://ollama.eisa.io/api/tags
```

A wrong / missing token returns `401 unauthorized`. A good one passes through to Ollama's normal JSON API.

---

## 🔒 Security

- Real `.env`, `users_database.yml`, and rendered configs (`Caddyfile`, `configuration.yml`, `settings.yml`) are gitignored - they contain tokens, secrets, encryption keys, and password hashes. Never commit them.
- In tunnel mode every protected route requires a valid Authelia session (group `admins` by default). Only `auth.${DOMAIN}` and `c.${DOMAIN}` bypass.
- The `admin` / `admin` defaults are **only safe on a trusted LAN**. Before turning on Cloudflare tunnel mode, log into Jellyfin, Seerr, Immich, etc. and rotate them. The Authelia password should be the first to change.
- qBittorrent's WebUI subnet whitelist is wide-open (`0.0.0.0/0, ::/0`) so the in-container Sonarr/Radarr can talk to it; this is fine on a LAN, *not* fine if you port-forward qBittorrent directly. In tunnel mode it sits behind Authelia.

---

## 🙏 Credits

Built on the shoulders of [Jellyfin](https://jellyfin.org), [Navidrome](https://www.navidrome.org), [Immich](https://github.com/immich-app/immich), [Filebrowser](https://github.com/filebrowser/filebrowser), [Ollama](https://ollama.com), [Open WebUI](https://github.com/open-webui/open-webui), [SearXNG](https://github.com/searxng/searxng), [Local Deep Research](https://github.com/LearningCircuit/local-deep-research), [Vane](https://github.com/itzcrazykns1337/Vane), [Qdrant](https://qdrant.tech), [n8n](https://n8n.io), [Seerr](https://github.com/seerr-team/seerr), [Sonarr](https://sonarr.tv), [Radarr](https://radarr.video), [Prowlarr](https://prowlarr.com), [qBittorrent](https://www.qbittorrent.org), [Caddy](https://caddyserver.com), [Authelia](https://www.authelia.com), [Cloudflared](https://github.com/cloudflare/cloudflared), [Portainer](https://www.portainer.io), [Heimdall](https://heimdall.site), and [KasmVNC Tor Browser](https://hub.docker.com/r/kasmweb/tor-browser).
