<div align="center">
  <img src="./assets/images/Guardian_M.png" alt="Logo Guardian" width="400">
</div>

# Mailuminati Guardian

**Guardian** is the local detection and enforcement component of the Mailuminati ecosystem.

It operates close to mail transfer agents and filtering engines, providing
ultra fast analysis of incoming emails, immediate local learning, and controlled
interaction with the Mailuminati Oracle for shared and collaborative intelligence.

Guardian is designed for anyone operating email services, from large providers
to small and community run infrastructures.

---

## Role in the Mailuminati Ecosystem

Guardian is responsible for:

- Local analysis of incoming emails
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

## Relationship to Other Components

- **Custos** defines the global architecture and protocols
- **Guardian** performs local detection, learning, and enforcement
- **Oracle** provides shared intelligence and collaborative confirmation

Guardian can operate independently.
Its effectiveness increases when connected to the Oracle,
where local signals become part of a collective defense.

---

## License

This project is released under the MIT License.  
See the [LICENSE](LICENSE) file for details.
