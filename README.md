# Sticker Converter Pro

A powerful, stateless Node.js + FFmpeg Docker application to automatically compress and decode raw `.gif` and `.png` assets into strict format specifications for WhatsApp, WeChat, Telegram, Signal, and LINE. Features a beautiful drag-and-drop web UI with real-time SSE logs.

---

## 🚀 Option 1: Local Deployment (Mac/Linux/Windows)

You can easily run this application locally for development or personal usage natively.

### Prerequisites
- Docker & Docker Compose installed.

### Steps
1. Clone this repository or download the files.
2. Open a terminal and navigate to the folder.
3. Make sure the local build flag is enabled in your `docker-compose.yml` (`build: .`).
4. Run the compose command to build and launch the container:
   ```bash
   docker-compose up -d --build
   ```
5. Open your browser and navigate to: **[http://localhost:8080](http://localhost:8080)**
6. Drag and drop your `.zip` archive to test the conversion.

---

## 🐳 Option 2: Synology NAS Portainer Deployment

Deploy this converter permanently on your Synology NAS using Portainer.

### 1. Preparing the Docker Image
Portainer acts as an orchestration tool and prefers deploying pre-built images. To install it natively without a registry:
1. Enable SSH on your Synology (`Control Panel` -> `Terminal & SNMP` -> `Enable SSH`).
2. SSH into your NAS, navigate to where you dropped these files, and manually build the image natively so Portainer can see it:
   ```bash
   sudo docker build -t yourname/sticker_converter:latest .
   ```
   *(Alternatively, build it on your desktop and push it to DockerHub, then pull the image tag directly in the Portainer UI).*

### 2. Deploy the Stack
1. Open **Portainer** on your NAS.
2. Go to **Stacks** -> **Add stack**.
3. Name it `sticker-converter`.
4. Choose **Web editor** and paste the contents of `docker-compose.yml`.
   - **Important:** If you built the image manually or are pulling from DockerHub, comment out `build: .` and uncomment `image: yourname/sticker_converter:latest`.
5. Click **Deploy the stack**.
6. Access it locally via `http://YOUR_NAS_IP:8080`.

*(Note: There is no need to map static volume folders like `input_gifs` or `output_stickers`. The new web-interface architecture processes everything statelessly in memory within `/tmp`, avoiding junk files filling up your NAS drives!)*

---

## 🔒 Securing Your NAS with Cloudflare Zero Trust

Exposing your NAS directly to the internet is dangerous. Instead of port forwarding your router, use **Cloudflare Tunnels (Zero Trust)** to securely access the sticker interface via a custom domain.

### 1. Set Up Your Domain & Cloudflare
1. Purchase a custom domain (e.g., `my-stickers.com`) and add it to your Cloudflare dashboard.
2. Go into your Cloudflare Dashboard -> **Zero Trust** -> **Access** -> **Tunnels**.

### 2. Create the Tunnel
1. Click **Create a tunnel** (Select Cloudflared). Name it (e.g., `Synology-Stickers`).
2. Choose **Docker** as your environment. Cloudflare will give you an installation string containing a secure token.

### 3. Install Cloudflared in Portainer
1. Go back to Synology Portainer -> **Stacks** -> **Add stack**.
2. Name it `cloudflare-tunnel`.
3. Paste the following configuration, injecting your unique token:
   ```yaml
   version: "3.8"
   services:
     cloudflared:
       image: cloudflare/cloudflared:latest
       container_name: cloudflared
       restart: unless-stopped
       command: tunnel run
       environment:
         - TUNNEL_TOKEN=YOUR_CLOUDFLARE_TOKEN_HERE
   ```
4. Click **Deploy the stack**.

### 4. Route the Custom Domain
1. Back in the Cloudflare Zero Trust dashboard, proceed to the **Public Hostname** routing step for your new tunnel.
2. Set the Subdomain (e.g., `app`) and select your Domain (`my-stickers.com`).
3. Set the **Service Type** to `HTTP` and the **URL** to your Synology NAS local IP address with the port mapped to the converter (e.g., `192.168.1.50:8080`).
4. Save the tunnel.

Boom! You can now visit `https://app.my-stickers.com` securely from anywhere in the world. No router ports opened, explicitly secured by Cloudflare SSL.

---

## 🛠️ Modifying the Scripts

If you want to alter the frame scaling limits or platform sizing geometries:
- Edit the arithmetic variables (`HALF_FPS`, `CONFIGS` arrays) directly inside `process_stickers.sh`.
- Rebuild the Docker container (`docker-compose up --build`) to inject the updated payload into the Node.js runner.
