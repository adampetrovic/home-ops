#!/usr/bin/env python3
"""
Stash Image Merge — Merge duplicate images, keeping highest resolution.

Reads duplicates.json from the dedup job, resolves Stash image IDs,
skips groups already merged by Stash (same ID), and merges the rest
by unioning metadata onto the highest-res image and deleting the rest.
"""

import argparse
import json
import logging
import os
import sys
import time
import urllib.request
import urllib.error

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


class StashAPI:
    def __init__(self, url: str, api_key: str):
        self.url = url.rstrip("/") + "/graphql"
        self.api_key = api_key
        self.request_count = 0

    def query(self, graphql: str, variables: dict = None) -> dict:
        body = {"query": graphql}
        if variables:
            body["variables"] = variables
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            self.url,
            data=data,
            headers={
                "Content-Type": "application/json",
                "ApiKey": self.api_key,
            },
        )
        self.request_count += 1
        try:
            resp = urllib.request.urlopen(req, timeout=30)
            result = json.loads(resp.read())
            if "errors" in result:
                log.error(f"GraphQL errors: {result['errors']}")
            return result.get("data", {})
        except urllib.error.HTTPError as e:
            log.error(f"HTTP {e.code}: {e.read().decode()}")
            return {}
        except Exception as e:
            log.error(f"Request failed: {e}")
            return {}

    def find_image_by_path(self, path: str) -> dict | None:
        """Find a Stash image by file path. Returns full image data."""
        escaped = path.replace('"', '\\"')
        data = self.query(f'''{{
            findImages(
                image_filter: {{ path: {{ value: "{escaped}", modifier: EQUALS }} }}
                filter: {{ per_page: 1 }}
            ) {{
                images {{
                    id
                    title
                    rating100
                    organized
                    urls
                    date
                    details
                    photographer
                    visual_files {{
                        ... on ImageFile {{
                            id
                            path
                            width
                            height
                            size
                        }}
                    }}
                    tags {{ id name }}
                    performers {{ id name }}
                    galleries {{ id title }}
                    studio {{ id name }}
                }}
            }}
        }}''')
        images = data.get("findImages", {}).get("images", [])
        return images[0] if images else None

    def update_image(self, image_id: str, updates: dict) -> bool:
        """Update an image's metadata."""
        # Build the input fields
        fields = [f'id: "{image_id}"']
        if "tag_ids" in updates:
            ids = ", ".join(f'"{i}"' for i in updates["tag_ids"])
            fields.append(f"tag_ids: [{ids}]")
        if "performer_ids" in updates:
            ids = ", ".join(f'"{i}"' for i in updates["performer_ids"])
            fields.append(f"performer_ids: [{ids}]")
        if "gallery_ids" in updates:
            ids = ", ".join(f'"{i}"' for i in updates["gallery_ids"])
            fields.append(f"gallery_ids: [{ids}]")
        if "urls" in updates:
            urls = ", ".join(f'"{u}"' for u in updates["urls"])
            fields.append(f"urls: [{urls}]")
        if "title" in updates and updates["title"]:
            escaped = updates["title"].replace('"', '\\"')
            fields.append(f'title: "{escaped}"')
        if "rating100" in updates and updates["rating100"]:
            fields.append(f'rating100: {updates["rating100"]}')
        if "details" in updates and updates["details"]:
            escaped = updates["details"].replace('"', '\\"').replace("\n", "\\n")
            fields.append(f'details: "{escaped}"')
        if "studio_id" in updates and updates["studio_id"]:
            fields.append(f'studio_id: "{updates["studio_id"]}"')

        input_str = ", ".join(fields)
        data = self.query(f'''mutation {{
            imageUpdate(input: {{ {input_str} }}) {{
                id
            }}
        }}''')
        return bool(data.get("imageUpdate"))

    def destroy_images(self, image_ids: list[str], delete_file: bool = True) -> bool:
        """Delete images and optionally their files."""
        ids = ", ".join(f'"{i}"' for i in image_ids)
        data = self.query(f'''mutation {{
            imagesDestroy(input: {{
                ids: [{ids}]
                delete_file: {str(delete_file).lower()}
                delete_generated: true
            }})
        }}''')
        return data.get("imagesDestroy") is not None


def resolve_group_images(api: StashAPI, group: dict) -> list[dict]:
    """Resolve all images in a group to Stash image data."""
    stash_images = {}  # stash_id -> image data (deduplicated)
    for img in group["images"]:
        stash_img = api.find_image_by_path(img["full_path"])
        if stash_img and stash_img["id"] not in stash_images:
            stash_images[stash_img["id"]] = stash_img
    return list(stash_images.values())


def pick_primary(images: list[dict]) -> tuple[dict, list[dict]]:
    """Pick the highest resolution image as primary. Returns (primary, rest)."""
    def resolution(img):
        max_res = 0
        for vf in img.get("visual_files", []):
            w = vf.get("width", 0) or 0
            h = vf.get("height", 0) or 0
            res = w * h
            if res > max_res:
                max_res = res
        return max_res

    sorted_imgs = sorted(images, key=resolution, reverse=True)
    return sorted_imgs[0], sorted_imgs[1:]


def merge_metadata(primary: dict, others: list[dict]) -> dict:
    """Union metadata from all images onto the primary."""
    # Collect existing primary metadata
    tag_ids = {t["id"] for t in primary.get("tags", [])}
    performer_ids = {p["id"] for p in primary.get("performers", [])}
    gallery_ids = {g["id"] for g in primary.get("galleries", [])}
    urls = set(primary.get("urls", []) or [])
    title = primary.get("title", "")
    rating = primary.get("rating100")
    details = primary.get("details", "")
    studio_id = primary.get("studio", {}).get("id") if primary.get("studio") else None

    # Union from others
    for img in others:
        for t in img.get("tags", []):
            tag_ids.add(t["id"])
        for p in img.get("performers", []):
            performer_ids.add(p["id"])
        for g in img.get("galleries", []):
            gallery_ids.add(g["id"])
        for u in (img.get("urls", []) or []):
            urls.add(u)
        # Take title if primary has none
        if not title and img.get("title"):
            title = img["title"]
        # Take highest rating
        if img.get("rating100") and (not rating or img["rating100"] > rating):
            rating = img["rating100"]
        # Append details
        if img.get("details") and img["details"] not in (details or ""):
            details = f"{details}\n{img['details']}" if details else img["details"]
        # Take studio if primary has none
        if not studio_id and img.get("studio"):
            studio_id = img["studio"]["id"]

    updates = {
        "tag_ids": list(tag_ids),
        "performer_ids": list(performer_ids),
        "gallery_ids": list(gallery_ids),
        "urls": list(urls),
    }
    if title:
        updates["title"] = title
    if rating:
        updates["rating100"] = rating
    if details:
        updates["details"] = details.strip()
    if studio_id:
        updates["studio_id"] = studio_id

    return updates


def main():
    parser = argparse.ArgumentParser(description="Merge duplicate images in Stash")
    parser.add_argument("--duplicates", required=True, help="Path to duplicates.json")
    parser.add_argument("--stash-url", required=True, help="Stash API URL")
    parser.add_argument("--api-key", required=True, help="Stash API key")
    parser.add_argument("--dry-run", action="store_true", help="Don't actually merge/delete")
    parser.add_argument("--limit", type=int, default=0, help="Limit number of groups to process (0=all)")
    parser.add_argument("--output", default="/output/merge-report.json", help="Output report path")
    args = parser.parse_args()

    api = StashAPI(args.stash_url, args.api_key)

    with open(args.duplicates) as f:
        data = json.load(f)

    groups = data["groups"]
    limit = args.limit if args.limit > 0 else len(groups)
    log.info(f"Processing {min(limit, len(groups))} of {len(groups)} duplicate groups")
    if args.dry_run:
        log.info("DRY RUN — no changes will be made")

    stats = {
        "total_groups": len(groups),
        "processed": 0,
        "skipped_same_id": 0,
        "skipped_single": 0,
        "merged": 0,
        "deleted_images": 0,
        "errors": 0,
        "dry_run": args.dry_run,
    }
    report = []
    start = time.time()

    for gi, group in enumerate(groups[:limit], 1):
        if gi % 100 == 0:
            elapsed = time.time() - start
            log.info(
                f"  Progress: {gi}/{limit} groups "
                f"(merged={stats['merged']}, skipped={stats['skipped_same_id']}, "
                f"errors={stats['errors']}, {elapsed:.0f}s, "
                f"{api.request_count} API calls)"
            )

        stats["processed"] += 1

        # Resolve all images to Stash IDs
        stash_images = resolve_group_images(api, group)

        if len(stash_images) <= 1:
            # All paths resolve to the same Stash image (already merged by MD5)
            stats["skipped_same_id"] += 1
            continue

        # Pick highest resolution as primary
        primary, others = pick_primary(stash_images)

        # Compute merged metadata
        updates = merge_metadata(primary, others)

        # Get resolution info for report
        def get_res(img):
            for vf in img.get("visual_files", []):
                return f"{vf.get('width', '?')}x{vf.get('height', '?')}"
            return "?"

        entry = {
            "group_id": group["id"],
            "similarity": group["similarity"],
            "primary": {"id": primary["id"], "resolution": get_res(primary)},
            "deleted": [{"id": o["id"], "resolution": get_res(o)} for o in others],
            "metadata_merged": {
                "tags": len(updates.get("tag_ids", [])),
                "performers": len(updates.get("performer_ids", [])),
                "galleries": len(updates.get("gallery_ids", [])),
                "urls": len(updates.get("urls", [])),
            },
        }

        if not args.dry_run:
            # Update primary with merged metadata
            if not api.update_image(primary["id"], updates):
                log.error(f"  Failed to update image {primary['id']} in group {group['id']}")
                stats["errors"] += 1
                entry["error"] = "update_failed"
                report.append(entry)
                continue

            # Delete the others
            delete_ids = [o["id"] for o in others]
            if not api.destroy_images(delete_ids, delete_file=True):
                log.error(f"  Failed to delete images {delete_ids} in group {group['id']}")
                stats["errors"] += 1
                entry["error"] = "delete_failed"
                report.append(entry)
                continue

            stats["deleted_images"] += len(others)

        stats["merged"] += 1
        report.append(entry)

    elapsed = time.time() - start
    stats["elapsed_seconds"] = round(elapsed, 1)
    stats["api_requests"] = api.request_count

    log.info(f"\nComplete in {elapsed:.0f}s ({api.request_count} API calls)")
    log.info(f"  Processed: {stats['processed']}")
    log.info(f"  Skipped (same Stash ID): {stats['skipped_same_id']}")
    log.info(f"  Merged: {stats['merged']}")
    log.info(f"  Deleted images: {stats['deleted_images']}")
    log.info(f"  Errors: {stats['errors']}")

    # Write report
    output = {"stats": stats, "merges": report}
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(output, f, indent=2)
    log.info(f"Report written to {args.output}")


if __name__ == "__main__":
    main()
