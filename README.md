<div align="center">
  <img src="./assets/images/Guardian_M.png" alt="Logo Guardian" width="400">
</div>

<p align="center">
  <img src="https://img.shields.io/badge/Go-1.25-blue" alt="Go">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License">
  <a href="https://github.com/Mailuminati/Guardian/actions/workflows/go-tests.yml"><img src="https://github.com/Mailuminati/Guardian/actions/workflows/go-tests.yml/badge.svg" alt="Go Tests"></a>
</p>


# Mailuminati Guardian

**Guardian** is a **high-performance, scalable spam/phishing detection and enforcement service** designed to run next to your MTA and filtering engine.

It analyzes incoming emails **ultra-fast** (structure fingerprinting + proximity detection), applies **immediate local learning** from operator/user reports, and only reaches out to the **Mailuminati Oracle** when needed for shared, collaborative intelligence.

Guardian is built for anyone operating email infrastructure, from large providers to small and community-run servers, who wants fast decisions with minimal overhead.

---

## Table of Contents

- [Role in the Mailuminati Ecosystem](#role-in-the-mailuminati-ecosystem)
- [Local Intelligence vs Shared Intelligence](#local-intelligence-vs-shared-intelligence)
  - [Local Intelligence](#local-intelligence)
  - [Shared Intelligence via the Oracle](#shared-intelligence-via-the-oracle)
- [How It Works](#how-it-works)
  - [1. Local Analysis](#1-local-analysis)
  - [2. Local Proximity Detection](#2-local-proximity-detection)
  - [3. Oracle Confirmation (When Needed)](#3-oracle-confirmation-when-needed)
  - [4. Learning and Feedback](#4-learning-and-feedback)
- [Design Goals](#design-goals)
- [Prerequisites](#prerequisites)
  - [Mandatory](#mandatory)
  - [Optional but Recommended](#optional-but-recommended)
- [Installation Options](#installation-options)
- [Installation](#installation)
  - [Method 1: Install from GitHub Archive (Recommended)](#method-1-install-from-github-archive-recommended)
  - [Method 2: Install using Git, developer friendly](#method-2-install-using-git-developer-friendly)
- [Deployment Model](#deployment-model)
- [API Endpoints](#api-endpoints)
- [Relationship to Other Components](#relationship-to-other-components)
- [License](#license)

---

## Role in the Mailuminati Ecosystem

Guardian is responsible for:

- Local spam/phishing analysis of incoming emails
- Structural fingerprinting using TLSH
- Fast proximity detection via locality sensitive hashing (LSH)
- Immediate application of local learning
- Remote confirmation through the Mailuminati Oracle
- Enforcing final decisions (allow, spam, proximity match)

It acts as the **first line of defense**, minimizing latency and resource usage,
while remaining connected to a broader community driven detection network.

---

## Local Intelligence vs Shared Intelligence

Guardian is built around a clear separation of concerns.

### Local Intelligence

Local analysis and learning allow Guardian to:

- Apply new detections immediately after a report
- Adapt instantly to operator specific threats and campaigns
- Remain effective even when disconnected from the Oracle
- Keep latency close to zero for the majority of messages

This ensures that confirmed spam or phishing reports have an **instant impact**
on subsequent mail flows for the same operator.

### Shared Intelligence via the Oracle

The Mailuminati Oracle provides the indispensable collaborative dimension:

- Cross operator correlation of campaigns
- Shared clusters built from independent reports
- Protection against large scale or fast moving threats
- Early detection of campaigns unseen locally

By querying the Oracle only when meaningful proximity is detected,
Guardian benefits from collective intelligence without sacrificing performance
or privacy.

---

## How It Works

### 1. Local Analysis

For each incoming email, Guardian:

- Normalizes textual and HTML content
- Extracts meaningful attachments
- Computes one or more TLSH structural fingerprints

This process is fast, deterministic, and does not rely on external calls.

### 2. Local Proximity Detection

Each fingerprint is split into overlapping bands using LSH techniques.

Guardian checks:
- Its local learning database
- A locally cached subset of Oracle band data

If sufficient proximity is detected, Guardian may:
- Classify the message locally
- Flag it as a partial or suspicious match
- Escalate to the Oracle for confirmation

### 3. Oracle Confirmation (When Needed)

Only when proximity thresholds are met, Guardian contacts the Oracle to:

- Compute exact distances against known threat clusters
- Compare fingerprints against cluster medoids built from confirmed reports
- Receive a final verdict

This design ensures that **only a small fraction of messages** require remote
confirmation.

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


### 4. Learning and Feedback

Guardian supports learning through reports such as:

- User complaints
- Operator validation
- Abuse desk signals

Confirmed reports immediately reinforce local detection.
They can also be shared with the Oracle, contributing to the global
Mailuminati intelligence and benefiting other Guardian users.

---

## Design Goals

- Very low latency
- Immediate impact of local learning
- Minimal CPU and memory usage
- Privacy preserving by design
- No raw email content sharing
- Resilience to Oracle unavailability
- Suitable for high volume and low volume operators alike

---

## Prerequisites

### Mandatory

- Linux server  
- POSIX compatible shell (`/bin/sh` or `/bin/bash`)  
- `curl`  
- `tar`  
- `sudo` (unless installing as root)  

### Optional but Recommended

- `systemd` for service management  
- `redis` for local cache and learning  
- An anti spam engine capable of calling HTTP APIs  
  Examples: Rspamd, SpamAssassin, custom filters  
- An IMAP server supporting Sieve  
  Examples: Dovecot, Cyrus, or equivalent  

Guardian does **not** require:

- Git (unless using the developer installation method)  
- IMAP credentials  
- Access to raw mailbox content  
- Heavy runtime dependencies  

### Installation Options

You can customize the installation by passing arguments to the installer.

To see all available options:

```sh
./install.sh --help
```

Common options:

- **Redis Configuration**:
  If your Redis instance is not on localhost (or `mi-redis` for Docker), specify it:
  ```sh
  ./install.sh --redis-host 192.168.1.50 --redis-port 6380
  ```

- **Filter Integration**:
  Skip all filter integration prompts:
  ```sh
  ./install.sh --no-filter-integration
  ```
  Disable a specific integration even if installed:
  ```sh
  ./install.sh --no-rspamd
  ./install.sh --no-spamassassin
  ```

---

## Installation

Two installation methods are officially supported.

### Method 1: Install from GitHub Archive (Recommended)

This method does not require Git and is suitable for production environments.

```sh
curl -fsSL https://github.com/Mailuminati/Guardian/archive/refs/heads/main.tar.gz \
| tar xz
cd Guardian-main
./install.sh
```

### Method 2: Install using Git, developer friendly

This method is recommended if you plan to contribute or track changes easily.

```sh
git clone https://github.com/Mailuminati/Guardian.git
cd Guardian
./install.sh
```

## Deployment Model

Guardian typically runs as:

- A local HTTP service
- A bridge between the MTA and the Mailuminati ecosystem
- A containerized service alongside Redis

It exposes endpoints such as:
- `/analyze`
- `/report`
- `/status`

---

## API Endpoints

Base URL: `http://<guardian-host>:1133`

> **Warning (Security)**
>
> Guardian listens on port **1133** and the API provides **no authentication**.
> It is therefore strongly recommended to **not expose** `:1133` to the Internet and to **block external access** with a firewall (allow only `localhost` or your internal network) to prevent fraudulent use.

### GET /status

Health/info endpoint used by the installer post-start check.

```bash
curl -sS http://localhost:1133/status | jq
```

Example response:

```json
{
  "node_id": "6c0a5e16-2b32-4f86-9b3d-2b2e3df5c7d8",
  "current_seq": 0,
  "version": "0.3.2"
}
```

### POST /analyze

Analyzes an email provided as raw RFC822/MIME bytes (the full message). Maximum request size is 15 MB.

Notes:
- If the email has no `Message-ID` header, Guardian will still analyze it, but `/report` will not be able to find its scan data later.
- The response includes the computed TLSH signatures under `hashes`.

```bash
curl -sS -X POST \
  -H 'Content-Type: message/rfc822' \
  --data-binary @message.eml \
  http://localhost:1133/analyze | jq
```

Example response:

```json
{
  "action": "allow",
  "proximity_match": false,
  "hashes": [
    "T1A9B0E0F2D3C4B5A6..."
  ]
}
```

Possible fields:
- `action`: `allow` | `spam`
- `label` (optional): e.g. `local_spam`
- `proximity_match`: boolean
- `distance` (optional): integer (TLSH distance when applicable)
- `hashes` (optional): array of TLSH signatures computed for body/attachments

### POST /report

Reports a previously scanned email by `Message-ID` (as seen in the original email headers). Guardian will:
- Apply **local learning** immediately when `report_type` is `spam`
- Forward the report to the Oracle

Request body:

```json
{
  "message-id": "<your-message-id@example>",
  "report_type": "spam"
}
```

```bash
curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message-id":"<your-message-id@example>","report_type":"spam"}' \
  http://localhost:1133/report
```

Notes:
- If Guardian has no stored scan data for this `Message-ID`, it returns `404 No scan data found`.
- The response body/status code are proxied from the Oracle when reachable.

### Configuration (env vars)

Guardian’s API behavior depends on these environment variables:

- `REDIS_HOST` (default: `localhost`)
- `REDIS_PORT` (default: `6379`)

---

## Relationship to Other Components

- **Guardian** performs local detection, learning, and enforcement
- **Oracle** provides shared intelligence and collaborative confirmation

Guardian can operate independently.
Its effectiveness increases when connected to the Oracle,
where local signals become part of a collective defense.

---

## License

This client is open-source software licensed under the GNU GPLv3.

Copyright © 2025 Simon Bressier.

Please note: This license applies strictly to the client-side code contained in this repository.

See the [LICENSE](LICENSE) file for details.
