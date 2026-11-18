# Changelog

All notable changes to tihole for iOS are documented in this file.

The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0] - 2026-11-18

### Added

- Dashboard with live totals, health gauges, queries over time, query
  types, upstreams, and top domains, blocked domains and clients.
- Blocking pill in every tab: on/off, a live countdown, and timed disable.
- Live query log with a domain filter and swipe to allow or block.
- Domains, adlists with a streamed gravity update, groups, clients and
  local DNS records.
- System info, diagnosis messages, network devices, DNS log, and restart
  DNS, flush logs and flush network.
- The full FTL configuration tree, searchable and editable.
- Any number of Pi-holes, with passwords in the Keychain.
- Gloss, Deep Night, Light Luxury and Pi-hole Classic themes, plus Auto.

### Security

- New instances default to HTTPS, and the form warns about plain HTTP.
- Every TestFlight build carries a GitHub build provenance attestation.
