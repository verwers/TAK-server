# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this deployment template, **please
do not open a public GitHub issue**. Instead, report it privately via GitHub's
[private security advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
feature on this repository.

Please include:

- A description of the issue and its impact
- Steps to reproduce (proof of concept if possible)
- Affected version / commit
- Any suggested mitigation

You can expect an initial response within a reasonable time frame. Fixes for
confirmed issues will be coordinated before public disclosure.

## Scope

This repository contains **only deployment tooling** (Docker Compose, shell
scripts, PowerShell helpers, certificate-generation glue). Vulnerabilities in
TAK Server itself should be reported to its upstream maintainers via
<https://tak.gov/>. Vulnerabilities in PostgreSQL/PostGIS should be reported
upstream.

In scope for this repo:

- Insecure defaults in the provided configuration
- Credential or key leakage caused by the scripts
- Container escape, privilege escalation, or insecure file permissions
  introduced by the Dockerfile or entrypoint scripts
- Shell-injection or command-injection in the helper scripts

## Default Credentials

The example configuration uses the well-known ATAK default password
`atakatak`. This is documented as a convenience for local testing only.
**Always change `POSTGRES_PASSWORD` and `TAK_CERT_PASSWORD` in `.env` before
exposing the server to any untrusted network.**

## Generated Secrets

The scripts generate a root CA, server certificate, and per-user client
certificates under `data/certs/`. These files contain **private keys** and
must be treated as secrets:

- `data/certs/` is excluded by `.gitignore` — do not force-add its contents
- Do not share `.p12` keystores or `.dp.zip` Data Packages over untrusted
  channels; they contain client private keys
- Rotate the CA and re-issue certs if you suspect compromise

## Compliance

TAK Server is U.S. government software subject to potential export-control
restrictions (EAR/ITAR). Users of this template are responsible for their own
compliance with applicable laws and the terms of use at <https://tak.gov/>.
