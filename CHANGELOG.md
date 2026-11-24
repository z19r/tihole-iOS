# Changelog

All notable changes to tihole for iOS are documented in this file.

The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Combine all Pi-holes**: with two or more instances, the instance menu can
  merge every Pi-hole into one Dashboard and Query Log, for setups that run
  several Pi-holes for redundancy. Unreachable Pi-holes are named and the rest
  still show. Blocking on/off covers every Pi-hole in this mode, and the pill
  shows how many are blocking (for example `Partial 1/2`, or `On 1/2 ⚠` when
  one is unreachable). The Dashboard shows CPU, memory, temperature, load,
  gravity and diagnostics per Pi-hole in this mode. Adding the second
  instance asks whether to combine. Other changes still go to the active
  instance.

### Changed

- The dashboard refreshes history, sensors and messages every 30 seconds
  instead of every 3, which takes load off small Pi-holes. Pull to refresh
  still fetches everything.

### Fixed

- Changing an instance's password no longer loses the saved one if the
  Keychain refuses the update.

## [1.0.1] - 2026-11-19

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
- A demo Pi-hole with sample data, from the welcome screen, to try the
  app without a Pi-hole.
- Gloss, Deep Night, Light Luxury and Pi-hole Classic themes, plus Auto.

### Security

- New instances default to HTTPS, and the form warns about plain HTTP.
- Every TestFlight build carries a GitHub build provenance attestation.
