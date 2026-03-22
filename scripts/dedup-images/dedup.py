#!/usr/bin/env python3
"""
Image Duplicate Detector — Two-Pass Pipeline

Pass 1: Perceptual hashing (dHash + pHash) for fast candidate grouping
Pass 2: CLIP embedding verification for accurate similarity scoring

Outputs a JSON file with groups of duplicate filenames.
"""

import argparse
import json
import logging
import os
import sys
import time
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional

import imagehash
import numpy as np
from PIL import Image, ImageFile

# Handle truncated images gracefully
ImageFile.LOAD_TRUNCATED_IMAGES = True
Image.MAX_IMAGE_PIXELS = None  # Some social media images are large

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

# ── Configuration ────────────────────────────────────────────────────────────

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tiff"}
HASH_SIZE = 16  # 16x16 = 256-bit hash (more precise than default 8x8)
BATCH_SIZE = 64  # CLIP inference batch size

# Mutable config — set from CLI args
config = {
    "hamming_threshold": 12,
    "clip_similarity_threshold": 0.93,
    "max_workers": 8,
}


# ── Data Types ───────────────────────────────────────────────────────────────

@dataclass
class ImageInfo:
    path: str
    size: int
    dhash: Optional[str] = None
    phash: Optional[str] = None
    error: Optional[str] = None


@dataclass
class DuplicateGroup:
    images: list = field(default_factory=list)
    similarity: float = 0.0
    method: str = "phash"  # phash, dhash, or clip


# ── Pass 1: Perceptual Hashing ───────────────────────────────────────────────

def compute_hashes(filepath: str) -> dict:
    """Compute dHash and pHash for a single image. Runs in worker process."""
    try:
        with Image.open(filepath) as img:
            img = img.convert("RGB")
            dhash = str(imagehash.dhash(img, hash_size=HASH_SIZE))
            phash = str(imagehash.phash(img, hash_size=HASH_SIZE))
            return {
                "path": filepath,
                "size": os.path.getsize(filepath),
                "dhash": dhash,
                "phash": phash,
                "error": None,
            }
    except Exception as e:
        return {
            "path": filepath,
            "size": os.path.getsize(filepath) if os.path.exists(filepath) else 0,
            "dhash": None,
            "phash": None,
            "error": str(e),
        }


def discover_images(root: str) -> list[str]:
    """Walk directory tree and collect all image file paths."""
    images = []
    for dirpath, _, filenames in os.walk(root):
        # Skip Synology metadata directories
        if "@eaDir" in dirpath:
            continue
        for fname in filenames:
            if Path(fname).suffix.lower() in IMAGE_EXTENSIONS:
                images.append(os.path.join(dirpath, fname))
    return sorted(images)


def hamming_distance(hash1: str, hash2: str) -> int:
    """Compute hamming distance between two hex hash strings."""
    h1 = imagehash.hex_to_hash(hash1)
    h2 = imagehash.hex_to_hash(hash2)
    return h1 - h2


def pass1_hash_images(image_paths: list[str], cache_path: Optional[str] = None) -> list[ImageInfo]:
    """Compute perceptual hashes for all images using parallel workers."""
    # Check for cached results
    if cache_path and os.path.exists(cache_path):
        log.info(f"Loading cached hashes from {cache_path}")
        with open(cache_path) as f:
            cached = json.load(f)
        # Validate cache covers all images
        cached_paths = {item["path"] for item in cached}
        if set(image_paths).issubset(cached_paths):
            log.info(f"Cache hit: {len(cached)} images")
            return [ImageInfo(**item) for item in cached if item["path"] in set(image_paths)]
        log.info(f"Cache stale: {len(cached)} cached, {len(image_paths)} needed")

    log.info(f"Hashing {len(image_paths)} images with {config["max_workers"]} workers...")
    results = []
    errors = 0
    start = time.time()

    with ProcessPoolExecutor(max_workers=config["max_workers"]) as executor:
        futures = {executor.submit(compute_hashes, p): p for p in image_paths}
        for i, future in enumerate(as_completed(futures), 1):
            result = future.result()
            info = ImageInfo(**result)
            results.append(info)
            if info.error:
                errors += 1
            if i % 5000 == 0 or i == len(image_paths):
                elapsed = time.time() - start
                rate = i / elapsed
                eta = (len(image_paths) - i) / rate if rate > 0 else 0
                log.info(f"  Hashed {i}/{len(image_paths)} ({rate:.0f}/s, ETA {eta:.0f}s, {errors} errors)")

    elapsed = time.time() - start
    log.info(f"Pass 1 complete: {len(results)} images in {elapsed:.1f}s ({len(results)/elapsed:.0f}/s), {errors} errors")

    # Cache results
    if cache_path:
        log.info(f"Saving hash cache to {cache_path}")
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        with open(cache_path, "w") as f:
            json.dump([asdict(r) for r in results], f)

    return results


def pass1_find_candidates(images: list[ImageInfo], threshold: int = config["hamming_threshold"]) -> list[list[str]]:
    """Group images by similar perceptual hashes using Union-Find."""
    log.info(f"Finding candidate groups (hamming threshold={threshold})...")

    # Filter out errored images
    valid = [img for img in images if img.phash and img.dhash]
    log.info(f"  {len(valid)} valid images (skipped {len(images) - len(valid)} errors)")

    # Build hash buckets for fast lookup (bucket by hash prefix)
    # Use pHash as primary, dHash as secondary confirmation
    parent = {}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    for img in valid:
        parent[img.path] = img.path

    # Compare using hash buckets to avoid O(n²)
    # Group by coarse hash (first 4 hex chars of phash = top 16 bits)
    phash_buckets = defaultdict(list)
    BUCKET_PREFIX_LEN = 8  # First 8 hex chars = 32 bits, generous bucketing
    for img in valid:
        prefix = img.phash[:BUCKET_PREFIX_LEN]
        phash_buckets[prefix].append(img)

    # Also check neighboring buckets by flipping bits in prefix
    comparisons = 0
    matches = 0

    for prefix, bucket in phash_buckets.items():
        # Compare all within the same bucket
        for i in range(len(bucket)):
            for j in range(i + 1, len(bucket)):
                comparisons += 1
                a, b = bucket[i], bucket[j]
                dist = hamming_distance(a.phash, b.phash)
                if dist <= threshold:
                    # Verify with dHash too
                    ddist = hamming_distance(a.dhash, b.dhash)
                    if ddist <= threshold * 1.5:  # dHash is slightly looser
                        union(a.path, b.path)
                        matches += 1

    # For images not caught by bucketing, do a second pass with dHash buckets
    dhash_buckets = defaultdict(list)
    for img in valid:
        prefix = img.dhash[:BUCKET_PREFIX_LEN]
        dhash_buckets[prefix].append(img)

    for prefix, bucket in dhash_buckets.items():
        for i in range(len(bucket)):
            for j in range(i + 1, len(bucket)):
                a, b = bucket[i], bucket[j]
                if find(a.path) == find(b.path):
                    continue  # Already grouped
                comparisons += 1
                dist = hamming_distance(a.dhash, b.dhash)
                if dist <= threshold:
                    pdist = hamming_distance(a.phash, b.phash)
                    if pdist <= threshold * 1.5:
                        union(a.path, b.path)
                        matches += 1

    # Extract groups
    groups = defaultdict(list)
    for img in valid:
        groups[find(img.path)].append(img.path)

    # Only keep groups with 2+ images
    candidate_groups = [paths for paths in groups.values() if len(paths) >= 2]
    total_dupes = sum(len(g) for g in candidate_groups)

    log.info(f"  {comparisons} comparisons, {matches} matches")
    log.info(f"  Found {len(candidate_groups)} candidate groups ({total_dupes} images)")

    return candidate_groups


# ── Pass 2: CLIP Embedding Verification ──────────────────────────────────────

def pass2_verify_with_clip(
    candidate_groups: list[list[str]],
    similarity_threshold: float = config["clip_similarity_threshold"],
) -> list[DuplicateGroup]:
    """Verify candidate groups using CLIP embeddings."""
    # Count total images to process
    total_images = sum(len(g) for g in candidate_groups)
    log.info(f"Pass 2: Verifying {len(candidate_groups)} groups ({total_images} images) with CLIP...")

    if total_images == 0:
        return []

    import torch
    from transformers import CLIPProcessor, CLIPModel

    device = "cpu"
    log.info(f"  Loading CLIP model (ViT-B/32) on {device}...")
    model = CLIPModel.from_pretrained("openai/clip-vit-base-patch32")
    processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")
    model.to(device)
    model.eval()

    verified_groups = []
    start = time.time()

    for gi, group_paths in enumerate(candidate_groups, 1):
        if gi % 100 == 0:
            elapsed = time.time() - start
            log.info(f"  Verified {gi}/{len(candidate_groups)} groups ({elapsed:.0f}s)")

        # Load and embed all images in this group
        embeddings = {}
        for path in group_paths:
            try:
                img = Image.open(path).convert("RGB")
                inputs = processor(images=img, return_tensors="pt").to(device)
                with torch.no_grad():
                    emb = model.get_image_features(**inputs)
                    emb = emb / emb.norm(dim=-1, keepdim=True)
                embeddings[path] = emb.cpu().numpy().flatten()
            except Exception as e:
                log.debug(f"  CLIP error for {path}: {e}")
                continue

        if len(embeddings) < 2:
            continue

        # Re-cluster within group using cosine similarity
        paths = list(embeddings.keys())
        emb_matrix = np.stack([embeddings[p] for p in paths])
        sim_matrix = emb_matrix @ emb_matrix.T

        # Union-Find within this group
        parent = {i: i for i in range(len(paths))}

        def find(x):
            while parent[x] != x:
                parent[x] = parent[parent[x]]
                x = parent[x]
            return x

        def union(a, b):
            ra, rb = find(a), find(b)
            if ra != rb:
                parent[ra] = rb

        for i in range(len(paths)):
            for j in range(i + 1, len(paths)):
                if sim_matrix[i, j] >= similarity_threshold:
                    union(i, j)

        # Extract verified sub-groups
        sub_groups = defaultdict(list)
        for i in range(len(paths)):
            sub_groups[find(i)].append(i)

        for indices in sub_groups.values():
            if len(indices) >= 2:
                group_paths_verified = [paths[i] for i in indices]
                # Compute average pairwise similarity
                sims = []
                for ii in range(len(indices)):
                    for jj in range(ii + 1, len(indices)):
                        sims.append(float(sim_matrix[indices[ii], indices[jj]]))
                avg_sim = sum(sims) / len(sims) if sims else 0
                verified_groups.append(DuplicateGroup(
                    images=group_paths_verified,
                    similarity=round(avg_sim, 4),
                    method="clip",
                ))

    elapsed = time.time() - start
    total_verified = sum(len(g.images) for g in verified_groups)
    log.info(f"Pass 2 complete: {len(verified_groups)} verified groups ({total_verified} images) in {elapsed:.1f}s")

    return verified_groups


# ── Output ───────────────────────────────────────────────────────────────────

def write_output(groups: list[DuplicateGroup], output_path: str, media_root: str):
    """Write results as JSON, sorted by group size."""
    # Sort by group size (largest first)
    groups.sort(key=lambda g: len(g.images), reverse=True)

    output = {
        "metadata": {
            "total_groups": len(groups),
            "total_duplicate_images": sum(len(g.images) for g in groups),
            "media_root": media_root,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "settings": {
                "hash_size": HASH_SIZE,
                "hamming_threshold": config["hamming_threshold"],
                "clip_similarity_threshold": config["clip_similarity_threshold"],
            },
        },
        "groups": [],
    }

    for i, group in enumerate(groups, 1):
        images = []
        for path in group.images:
            rel = os.path.relpath(path, media_root) if media_root else path
            try:
                size = os.path.getsize(path)
            except OSError:
                size = 0
            images.append({"path": rel, "full_path": path, "size_bytes": size})

        output["groups"].append({
            "id": i,
            "count": len(group.images),
            "similarity": group.similarity,
            "method": group.method,
            "images": images,
        })

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    log.info(f"Results written to {output_path}")
    log.info(f"  {len(groups)} groups, {sum(len(g.images) for g in groups)} duplicate images")

    # Print summary of top groups
    log.info("\nTop 20 largest duplicate groups:")
    for group in output["groups"][:20]:
        paths = [img["path"] for img in group["images"]]
        log.info(f"  Group {group['id']}: {group['count']} images (sim={group['similarity']:.3f})")
        for p in paths[:5]:
            log.info(f"    - {p}")
        if len(paths) > 5:
            log.info(f"    ... and {len(paths) - 5} more")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Detect duplicate images using perceptual hashing + CLIP")
    parser.add_argument("--media-dir", required=True, help="Root directory of images")
    parser.add_argument("--output", default="/output/duplicates.json", help="Output JSON path")
    parser.add_argument("--cache-dir", default="/output/cache", help="Directory for hash cache")
    parser.add_argument("--hamming-threshold", type=int, default=config["hamming_threshold"])
    parser.add_argument("--clip-threshold", type=float, default=config["clip_similarity_threshold"])
    parser.add_argument("--workers", type=int, default=config["max_workers"])
    parser.add_argument("--skip-clip", action="store_true", help="Skip CLIP verification pass")
    parser.add_argument("--hash-only", action="store_true", help="Only compute hashes, don't find groups")
    args = parser.parse_args()

    config["hamming_threshold"] = args.hamming_threshold
    config["clip_similarity_threshold"] = args.clip_threshold
    config["max_workers"] = args.workers

    # Discover images
    log.info(f"Scanning {args.media_dir} for images...")
    image_paths = discover_images(args.media_dir)
    log.info(f"Found {len(image_paths)} images")

    if not image_paths:
        log.warning("No images found!")
        sys.exit(0)

    # Pass 1: Perceptual hashing
    cache_path = os.path.join(args.cache_dir, "hashes.json") if args.cache_dir else None
    images = pass1_hash_images(image_paths, cache_path=cache_path)

    if args.hash_only:
        log.info("Hash-only mode — stopping after hashing")
        sys.exit(0)

    # Find candidate groups
    candidate_groups = pass1_find_candidates(images, threshold=config["hamming_threshold"])

    if not candidate_groups:
        log.info("No duplicates found!")
        write_output([], args.output, args.media_dir)
        sys.exit(0)

    # Pass 2: CLIP verification
    if args.skip_clip:
        log.info("Skipping CLIP verification (--skip-clip)")
        # Convert candidates directly to output groups
        verified = []
        for group_paths in candidate_groups:
            verified.append(DuplicateGroup(images=group_paths, similarity=1.0, method="phash"))
        write_output(verified, args.output, args.media_dir)
    else:
        verified = pass2_verify_with_clip(candidate_groups, args.clip_threshold)
        write_output(verified, args.output, args.media_dir)


if __name__ == "__main__":
    main()
