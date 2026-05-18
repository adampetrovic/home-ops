---
title: Profilarr v2 getting started
---

# Profilarr v2 getting started

Profilarr v2 is deployed as an internal-only media app at `profilarr.${SECRET_DOMAIN}`. It is protected by the shared Authelia ext-auth component and backed up with the standard VolSync component.

## Current Arr baseline

Snapshot from 2026-05-18:

- `radarr`: 1336 movies, mostly `HD-1080p`, zero custom formats, upgrades disabled.
- `radarr-4k`: 31 movies, `Ultra-HD`, zero custom formats, upgrades disabled.
- `sonarr`: 683 series, mostly `HD - 1080p/720p`, zero custom formats, upgrades enabled.
- `sonarr-4k`: 7 series, `Ultra-HD`, zero custom formats, upgrades disabled.
- Existing media has `customFormatScore = 0`, so there is no release-group, HDR/DV, source, audio, streaming-service, or bad-group scoring in use yet.
- `sonarr` has many cutoff-unmet episodes, so avoid broad upgrade automation until profile changes have been proven on a small set.

## Initial setup

1. Open `https://profilarr.${SECRET_DOMAIN}`.
2. Authentication is disabled inside Profilarr with `AUTH=off` because the HTTPRoute is protected by Authelia ext-auth. Do not expose this service without the reverse proxy auth layer.
3. Connect the Dictionarry database first. Add TRaSH PCD later only if you need a specific TRaSH/anime profile.
4. Add Arr instances with internal service URLs:
   - `http://radarr.media.svc.cluster.local`
   - `http://radarr-4k.media.svc.cluster.local`
   - `http://sonarr.media.svc.cluster.local`
   - `http://sonarr-4k.media.svc.cluster.local`
5. Read API keys from the existing Kubernetes secrets or 1Password items. Do not write API keys to Git.
6. Enable drift detection first. Do not enable scheduled upgrades during initial onboarding.

## Safe first profile mapping

Recommended starting point:

- `radarr` general movies: Dictionarry `1080p Balanced` or `1080p Quality`.
- `radarr` kids movies: Dictionarry `1080p Compact` or `1080p Balanced`.
- `radarr-4k`: Dictionarry `2160p Balanced` or `2160p Quality`; avoid `2160p Remux` unless the storage hit is intentional.
- `sonarr` general TV: Dictionarry `1080p Balanced`; use `1080p Efficient` if storage is the priority.
- `sonarr` kids TV: Dictionarry `1080p Compact` or `1080p Balanced`.
- `sonarr-4k`: Dictionarry `2160p Balanced` or `2160p Efficient`.
- Anime: leave current Sonarr handling in place initially. Consider TRaSH PCD anime later, once the standard profiles are stable.

## Rollout plan

1. Take/verify VolSync backups for all four Arrs and Profilarr.
2. Run Profilarr drift detection against all Arrs.
3. Use Profilarr's simulator/testing tools to inspect how proposed profiles score existing releases.
4. Sync one low-risk instance first, preferably `radarr-4k` or a small subset in `radarr`.
5. Review grabs for at least a few days before touching broad Sonarr profiles.
6. Add kids-specific profiles after the general profile behaviour looks good.
7. Only then consider upgrade automation.

## Upgrade automation guardrails

Start with manual or very narrow scheduled upgrades:

- Prefer `radarr` before `sonarr`; the Sonarr library has many more cutoff-unmet items.
- Filter to monitored items with existing files.
- Exclude `/kids` roots for the first run.
- Prioritise cutoff-unmet items over blanket library searches.
- Use cooldowns so the same item is not searched repeatedly.
- Keep 4K upgrade automation disabled until the 4K policy is settled.

## Delay profiles

Radarr and Radarr 4K currently use the upstream Dictionarry delay profile. Sonarr and Sonarr 4K use a Profilarr user-layer customisation on the Dictionarry `Sonarr` delay profile:

- Preferred protocol: `prefer_usenet`
- Usenet delay: `0` minutes
- Torrent delay: `30` minutes

This keeps new TV episodes fast on SABnzbd while leaving qBittorrent as a short-delay fallback. The customisation lives in Profilarr's database/PVC and is backed up by VolSync; drift remains clean because Profilarr's desired state includes the user-layer override.

## Naming and media management

Avoid mass renames during the initial rollout. Sonarr already includes custom-format tokens in naming; Radarr's main naming is simpler. Let Profilarr manage future naming/media-management drift, but review rename previews carefully before applying rename automation.
