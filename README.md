<div align="center">
  <img src="./assets/images/Guardian_M.png" alt="Logo Guardian" width="400">
</div>

<p align="center">
  <img src="https://img.shields.io/badge/Go-1.25-blue" alt="Go">
  <img src="https://img.shields.io/badge/License-GPLv3-blue" alt="License">
  <a href="https://github.com/Mailuminati/Guardian/actions/workflows/go-tests.yml"><img src="https://github.com/Mailuminati/Guardian/actions/workflows/go-tests.yml/badge.svg" alt="Go Tests"></a>
</p>
<p align="center">
  <img src="https://img.shields.io/docker/pulls/mailuminati/guardian?style=flat-square&color=blue" alt="Docker Pulls">
  <img src="https://img.shields.io/docker/image-size/mailuminati/guardian/latest?style=flat-square" alt="Docker Image Size">
  <img src="https://img.shields.io/docker/v/mailuminati/guardian?sort=semver&style=flat-square" alt="Docker Image Version">
</p>

# Mailuminati Guardian

**Guardian** is a **high-performance, scalable spam/phishing detection and enforcement service** designed to run next to your MTA and filtering engine.

It analyzes incoming emails **ultra-fast** (structure fingerprinting + proximity detection), applies **immediate local learning** from operator/user reports, and only reaches out to the **Mailuminati Oracle** when needed for shared, collaborative intelligence.

Guardian is built for anyone operating email infrastructure, from large providers to small and community-run servers, who wants fast decisions with minimal overhead.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Prerequisites & Requirements](#prerequisites--requirements)
- [Installation Options](#installation-options)
- [Configuration](#configuration)
- [How Guardian Works](#how-guardian-works)
- [Architecture & Ecosystem](#architecture--ecosystem)
- [API Reference](#api-reference)
- [License](#license)

---

## Quick Start

Install Guardian with a single command:

```sh
/bin/bash -c "$(curl -fsSL https://guardian.mailuminati.com/install.sh)"
```

The installer will:
- Detect your system configuration
- Install Guardian and dependencies
- Integrate with your existing email filtering system (Rspamd, SpamAssassin, etc.)
- Start the service automatically

**Custom installation options:**
```sh
/bin/bash -c "$(curl -fsSL https://guardian.mailuminati.com/install.sh)" -- --redis-host 192.168.1.50 --redis-port 6380
```
(note the double dashes `--` before the options)

For detailed prerequisites and configuration options, see below.

---

---

## Prerequisites & Requirements

### Mandatory

- Linux server
- `redis` server for local caching and learning (can be on the same host or remote)
- POSIX compatible shell (`/bin/sh` or `/bin/bash`)
- `curl`
- `tar`
- `sudo` (unless installing as root)

### Optional but Recommended

- `systemd` for service management
- An anti-spam engine capable of calling HTTP APIs  
  Examples: Rspamd, SpamAssassin, custom filters
- An IMAP server supporting Sieve  
  Examples: Dovecot, Cyrus, or equivalent

### What Guardian Does NOT Require

- IMAP credentials
- Access to raw mailbox content
- Heavy runtime dependencies

---

## Installation Options

You can customize the installation by passing arguments to the installer.

**See all available options:**
```sh
/bin/bash -c "$(curl -fsSL https://guardian.mailuminati.com/install.sh)" -- --help
```

**Common options:**

- **Redis Configuration:**  
  If your Redis instance is not on localhost (or `redis` for Docker):
  ```sh
  --redis-host 192.168.1.50 --redis-port 6380
  ```

- **Filter Integration:**  
  Skip all filter integration prompts:
  ```sh
  --no-filter-integration
  ```
  Disable a specific integration even if installed:
  ```sh
  --no-rspamd
  --no-spamassassin
  ```

- **Force Re-installation:**  
  Force the re-installation of the Guardian engine even if the version matches:
  ```sh
  --force-reinstall
  ```

---

## Configuration

Guardian can be configured via environment variables or a configuration file, depending on your installation method.

**For Source installations:**  
The configuration file is located at `/etc/mailuminati-guardian/guardian.conf`.  
You can edit this file to change settings. To apply changes without restarting the service (hot-reload), run:
```bash
sudo systemctl reload mailuminati-guardian
```

**For Docker installations:**  
Configuration is primarily managed via environment variables in `docker-compose.yaml`.

### Available Configuration Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `REDIS_HOST` | Hostname or IP of the Redis server | `localhost` (Source) / `redis` (Docker) |
| `REDIS_PORT` | Port of the Redis server | `6379` |
| `GUARDIAN_BIND_ADDR` | The network interface IP to bind to.<br>Use `127.0.0.1` for localhost only, or `0.0.0.0` for all interfaces. | `127.0.0.1` |
| `MI_ENABLE_IMAGE_ANALYSIS` | Set to `1` to enable the analysis of external images for low-text emails. | `0` (Disabled) |
| `FORCE_REINSTALL` | Set to `1` to force re-installation of the Guardian engine. | `0` |
| `SPAM_WEIGHT` | Weight applied to hashes reported as spam. | `1` |
| `HAM_WEIGHT` | Weight applied to hashes reported as ham (false positive). | `2` |
| `SPAM_THRESHOLD` | Minimum score required for a message to be considered spam locally.<br>By default (`1`), a single spam report (with weight 1) is enough to block similar messages.<br>Increase this value (e.g., to `2`) to require multiple reports before blocking. | `1` |
| `LOCAL_RETENTION_DAYS` | Retention period (in days) for local learning entries. | `15` |
| `LOG_LEVEL` | Logging verbosity leval (`DEBUG`, `INFO`, `WARN`, `ERROR`). | `INFO` |
| `LOG_FORMAT` | Format of logs (`JSON` for tools/ELK, `TEXT` for human reading). | `JSON` |

The weight and threshold variables work together to give you full control over the local learning mechanism:

* **Detection Logic:** A message is considered spam if its calculated score is greater than or equal to `SPAM_THRESHOLD`.
* **Spam Reports:** Reporting a message as spam adds `SPAM_WEIGHT` to its score.
* **Ham Reports:** Reporting a message as legit (ham) subtracts `HAM_WEIGHT` from its score.

**Example Scenarios:**

*   **Default (Aggressive):** `SPAM_WEIGHT=1`, `SPAM_THRESHOLD=1`.
    *   1 Spam Report = Score 1. Since `1 >= 1`, it is blocked immediately.
*   **Cautious:** `SPAM_WEIGHT=1`, `SPAM_THRESHOLD=2`.
    *   1 Spam Report = Score 1. Not blocked (`1 < 2`).
    *   2 Spam Reports = Score 2. Blocked (`2 >= 2`).
    *   1 Spam Report + 1 Ham Report = Score 0. Not blocked (`0 < 2`).
---

---

## How Guardian Works

Guardian combines local intelligence with shared threat detection to provide fast, accurate spam filtering.

### Core Concepts

**Local Intelligence:**
- Instant analysis and learning from operator-specific threats
- Immediate impact after user/operator reports
- Works even when disconnected from the Oracle
- Zero-latency decisions for most messages

**Shared Intelligence (via Oracle):**
- Cross-operator correlation of spam campaigns
- Shared threat clusters from independent reports
- Protection against large-scale, fast-moving threats
- Early detection of previously unseen campaigns

By querying the Oracle only when meaningful proximity is detected, Guardian benefits from collective intelligence without sacrificing performance or privacy.

### Analysis Pipeline

#### 1. Local Analysis

For each incoming email, Guardian:
- Normalizes textual and HTML content
- Extracts meaningful attachments
- Computes one or more TLSH structural fingerprints

This process is fast, deterministic, and does not rely on external calls.

**Image Analysis (Optional):**  
When enabled via `MI_ENABLE_IMAGE_ANALYSIS=1`, Guardian can fetch and analyze external images for emails containing very little text. This is beneficial for detecting "image-only" spam where the message content is hidden in a remote picture to bypass text-based filters.

> **⚠️ Performance & Privacy Warning:**
> - **Latency**: Guardian must download images from external servers. If the remote server is slow or under load, this will increase scan time.
> - **Tracking**: Downloading external images may trigger "read receipts" (tracking pixels) on the sender's side.

#### 2. Local Proximity Detection

Each fingerprint is split into overlapping bands using LSH (Locality-Sensitive Hashing) techniques.

Guardian checks:
- Its local learning database
- A locally cached subset of Oracle band data

If sufficient proximity is detected, Guardian may:
- Classify the message locally
- Flag it as a partial or suspicious match
- Escalate to the Oracle for confirmation

#### 3. Oracle Confirmation (When Needed)

Only when proximity thresholds are met, Guardian contacts the Oracle to:
- Compute exact distances against known threat clusters
- Compare fingerprints against cluster medoids built from confirmed reports
- Receive a final verdict

This design ensures that **only a small fraction of messages** require remote confirmation.

#### 4. Learning and Feedback

Guardian supports learning through reports such as:
- User complaints (via IMAP/Sieve integration)
- Operator validation
- Abuse desk signals

Confirmed reports immediately reinforce local detection and can be shared with the Oracle, contributing to global Mailuminati intelligence.

### Architecture Diagram

<pre>
Incoming Email
      |
      v
+---------------------+
|  Mailuminati        |
|  Guardian (Local)   |
+---------------------+
   |           |
   |           +--------------------+
   |                                |
   v                                v
Local Analysis                  Local Learning
(TLSH + LSH)                (Immediate Effect)
   |
   |  No proximity
   |----------------------------->  ALLOW / LOCAL DECISION
   |
   |  Proximity detected
   v
+---------------------+
|   Mailuminati       |
|   Oracle (Remote)   |
+---------------------+
        |
        v
Shared Intelligence
(Clusters, Medoids,
Community Reports)
        |
        v
   Verdict Returned
        |
        v
Local Enforcement
(Spam / Allow / Flag)
</pre>

### Design Goals

- **Very low latency** — Most decisions made locally without network calls
- **Immediate learning** — Reports take effect instantly
- **Minimal resources** — Low CPU and memory footprint
- **Privacy-preserving** — No raw email content sharing
- **Resilient** — Works even when Oracle is unavailable
- **Scalable** — Suitable for high-volume and small operators alike

---

## Architecture & Ecosystem

### Role in the Mailuminati Ecosystem

Guardian is responsible for:
- Local spam/phishing analysis of incoming emails
- Structural fingerprinting using TLSH
- Fast proximity detection via locality-sensitive hashing (LSH)
- Immediate application of local learning
- Remote confirmation through the Mailuminati Oracle
- Enforcing final decisions (allow, spam, proximity match)

It acts as the **first line of defense**, minimizing latency and resource usage while remaining connected to a broader community-driven detection network.

### Deployment Model

Guardian typically runs as:
- A local HTTP service on port `12421`
- A bridge between your MTA and the Mailuminati ecosystem
- A containerized service alongside Redis

Your email filtering engine (Rspamd, SpamAssassin, etc.) calls Guardian's `/analyze` endpoint for each incoming email, then acts on the verdict.

### Relationship to Other Components

- **Guardian** performs local detection, learning, and enforcement
- **Oracle** provides shared intelligence and collaborative confirmation

Guardian can operate independently. Its effectiveness increases when connected to the Oracle, where local signals become part of a collective defense.

---

---

## API Reference

Guardian exposes a simple HTTP API on port `12421`.

> **⚠️ Security Warning**
>
> Guardian provides **no authentication** on its API. It is strongly recommended to:
> - **NOT expose** port `12421` to the Internet
> - **Block external access** with a firewall
> - Allow only `localhost` or your internal network

### Base URL

```
http://<guardian-host>:12421
```

### Endpoints

#### GET /status

Health and version information endpoint.

**Example:**
```bash
curl -sS http://localhost:12421/status | jq
```

**Response:**
```json
{
  "node_id": "6c0a5e16-2b32-4f86-9b3d-2b2e3df5c7d8",
  "current_seq": 0,
  "version": "0.3.2"
}
```

---

#### POST /analyze

Analyzes an email provided as raw RFC822/MIME bytes. Maximum request size: **15 MB**.

**Request:**
```bash
curl -sS -X POST \
  -H 'Content-Type: message/rfc822' \
  --data-binary @message.eml \
  http://localhost:12421/analyze | jq
```

**Response:**
```json
{
  "action": "allow",
  "proximity_match": false,
  "hashes": [
    "T1A9B0E0F2D3C4B5A6..."
  ]
}
```

**Response Fields:**
- `action`: `allow` | `spam`
- `label` (optional): e.g., `local_spam`, `oracle_spam`
- `proximity_match`: boolean indicating if similar spam was detected
- `distance` (optional): TLSH distance to nearest threat (lower = more similar)
- `hashes` (optional): array of computed TLSH signatures

**Notes:**
- If the email lacks a `Message-ID` header, Guardian will still analyze it, but `/report` won't be able to reference it later.
- The `hashes` field contains the computed TLSH fingerprints for the message.

---

#### POST /report

Reports a previously scanned email to improve Guardian's learning.

Guardian will:
1. Apply **local learning** immediately (spam or ham correction)
2. Forward the report to the Oracle for shared intelligence

**Request:**
```bash
curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message-id":"<your-message-id@example>","report_type":"spam"}' \
  http://localhost:12421/report
```

**Request Body:**
```json
{
  "message-id": "<your-message-id@example>",
  "report_type": "spam"
}
```

**Report Types:**
- `spam`: Reports a missed spam (false negative)
- `ham`: Reports a false positive (legitimate email incorrectly flagged)

**Notes:**
- Guardian must have previously scanned this email (identified by `Message-ID`)
- Returns `404 Not Found` if no scan data exists for this Message-ID
- Response is proxied from the Oracle when reachable

---

#### GET /metrics

Exposes internal metrics in **Prometheus** format for monitoring.

**Example:**
```bash
curl -sS http://localhost:12421/metrics
```

**Available Metrics:**
- `mailuminati_guardian_scanned_total`: Total emails scanned
- `mailuminati_guardian_local_match_total`: Emails detected using local intelligence
- `mailuminati_guardian_oracle_match_total`: Emails matched via Oracle
- `mailuminati_guardian_cache_hits_total`: Cache hit efficiency

---

## License

This client is open-source software licensed under the GNU GPLv3.

Copyright © 2025 Simon Bressier.

Please note: This license applies strictly to the client-side code contained in this repository.

See the [LICENSE](LICENSE) file for details.
