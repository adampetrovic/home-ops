#!/usr/bin/env python3
"""
Face Clustering Pipeline

1. Detect faces in all images using InsightFace (RetinaFace)
2. Extract 512-dim ArcFace embeddings
3. Cluster with DBSCAN (no predefined cluster count)
4. Output JSON with clusters mapped to file paths

Supports Intel iGPU via OpenVINO execution provider.
"""

import argparse
import json
import logging
import os
import pickle
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np
from insightface.app import FaceAnalysis
from sklearn.cluster import DBSCAN

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
FACE_DET_THRESHOLD = 0.5  # Minimum confidence for face detection
MIN_FACE_SIZE = 40  # Minimum face size in pixels


@dataclass
class FaceRecord:
    image_path: str
    face_idx: int  # Index within the image (for multi-face images)
    embedding: np.ndarray = None
    bbox: list = field(default_factory=list)  # [x1, y1, x2, y2]
    det_score: float = 0.0


# ── Image Discovery ──────────────────────────────────────────────────────────

def discover_images(root: str) -> list[str]:
    images = []
    for dirpath, _, filenames in os.walk(root):
        if "@eaDir" in dirpath:
            continue
        for fname in filenames:
            if Path(fname).suffix.lower() in IMAGE_EXTENSIONS:
                images.append(os.path.join(dirpath, fname))
    return sorted(images)


# ── Face Detection & Embedding ───────────────────────────────────────────────

def init_face_app(use_gpu: bool = False) -> FaceAnalysis:
    """Initialize InsightFace with detection + recognition."""
    providers = []
    if use_gpu:
        try:
            import onnxruntime
            available = onnxruntime.get_available_providers()
            log.info(f"Available ONNX providers: {available}")
            if "OpenVINOExecutionProvider" in available:
                providers.append("OpenVINOExecutionProvider")
                log.info("Using Intel iGPU via OpenVINO")
            elif "CUDAExecutionProvider" in available:
                providers.append("CUDAExecutionProvider")
                log.info("Using NVIDIA GPU via CUDA")
        except Exception as e:
            log.warning(f"GPU detection failed: {e}")

    providers.append("CPUExecutionProvider")

    app = FaceAnalysis(
        name="buffalo_l",  # RetinaFace + ArcFace (best quality)
        providers=providers,
    )
    app.prepare(ctx_id=0, det_size=(640, 640), det_thresh=FACE_DET_THRESHOLD)
    return app


def extract_faces(app: FaceAnalysis, image_path: str) -> list[FaceRecord]:
    """Detect faces and extract embeddings from a single image."""
    try:
        img = cv2.imread(image_path)
        if img is None:
            return []

        # Resize if too large (saves memory, detection still works well)
        h, w = img.shape[:2]
        max_dim = 1280
        if max(h, w) > max_dim:
            scale = max_dim / max(h, w)
            img = cv2.resize(img, (int(w * scale), int(h * scale)))

        faces = app.get(img)

        records = []
        for i, face in enumerate(faces):
            # Skip tiny faces
            bbox = face.bbox.astype(int).tolist()
            face_w = bbox[2] - bbox[0]
            face_h = bbox[3] - bbox[1]
            if face_w < MIN_FACE_SIZE or face_h < MIN_FACE_SIZE:
                continue

            if face.embedding is None:
                continue

            records.append(FaceRecord(
                image_path=image_path,
                face_idx=i,
                embedding=face.embedding,
                bbox=bbox,
                det_score=float(face.det_score),
            ))

        return records
    except Exception as e:
        log.debug(f"Error processing {image_path}: {e}")
        return []


def extract_all_faces(
    app: FaceAnalysis,
    image_paths: list[str],
    cache_path: str | None = None,
) -> list[FaceRecord]:
    """Extract faces from all images with caching."""

    # Check cache
    if cache_path and os.path.exists(cache_path):
        log.info(f"Loading cached embeddings from {cache_path}")
        with open(cache_path, "rb") as f:
            cached = pickle.load(f)
        cached_paths = {r.image_path for r in cached}
        if set(image_paths).issubset(cached_paths):
            log.info(f"Cache hit: {len(cached)} face records")
            return [r for r in cached if r.image_path in set(image_paths)]
        log.info(f"Cache stale, re-extracting")

    log.info(f"Extracting faces from {len(image_paths)} images...")
    all_records = []
    no_face_count = 0
    multi_face_count = 0
    errors = 0
    start = time.time()

    for i, path in enumerate(image_paths, 1):
        records = extract_faces(app, path)
        if not records:
            no_face_count += 1
        elif len(records) > 1:
            multi_face_count += 1
        all_records.extend(records)

        if i % 1000 == 0 or i == len(image_paths):
            elapsed = time.time() - start
            rate = i / elapsed
            eta = (len(image_paths) - i) / rate if rate > 0 else 0
            log.info(
                f"  {i}/{len(image_paths)} images ({rate:.1f}/s, ETA {eta:.0f}s) — "
                f"{len(all_records)} faces, {no_face_count} no-face, "
                f"{multi_face_count} multi-face"
            )

    elapsed = time.time() - start
    log.info(
        f"Face extraction complete: {len(all_records)} faces from "
        f"{len(image_paths)} images in {elapsed:.0f}s "
        f"({len(image_paths)/elapsed:.1f} img/s)"
    )
    log.info(f"  No face detected: {no_face_count}")
    log.info(f"  Multiple faces: {multi_face_count}")

    # Save cache
    if cache_path:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        with open(cache_path, "wb") as f:
            pickle.dump(all_records, f)
        log.info(f"Cached {len(all_records)} face records to {cache_path}")

    return all_records


# ── Clustering ───────────────────────────────────────────────────────────────

def cluster_faces(
    records: list[FaceRecord],
    eps: float = 0.6,
    min_samples: int = 2,
) -> dict[int, list[FaceRecord]]:
    """Cluster face embeddings using DBSCAN on cosine distance."""
    if not records:
        return {}

    log.info(f"Clustering {len(records)} face embeddings (eps={eps}, min_samples={min_samples})...")
    start = time.time()

    # Normalize embeddings for cosine distance
    embeddings = np.array([r.embedding for r in records])
    norms = np.linalg.norm(embeddings, axis=1, keepdims=True)
    norms[norms == 0] = 1
    embeddings_norm = embeddings / norms

    # DBSCAN with cosine metric (precompute distance matrix for speed)
    # Cosine distance = 1 - cosine_similarity
    log.info("  Computing distance matrix...")
    dist_matrix = 1 - np.dot(embeddings_norm, embeddings_norm.T)
    np.fill_diagonal(dist_matrix, 0)  # Ensure self-distance is 0
    dist_matrix = np.clip(dist_matrix, 0, 2)  # Numerical stability

    log.info("  Running DBSCAN...")
    clustering = DBSCAN(
        eps=eps,
        min_samples=min_samples,
        metric="precomputed",
        n_jobs=-1,
    ).fit(dist_matrix)

    labels = clustering.labels_
    n_clusters = len(set(labels) - {-1})
    n_noise = (labels == -1).sum()

    elapsed = time.time() - start
    log.info(f"Clustering complete in {elapsed:.1f}s")
    log.info(f"  {n_clusters} clusters, {n_noise} unclustered faces")

    # Group by cluster
    clusters = defaultdict(list)
    for record, label in zip(records, labels):
        if label >= 0:  # Skip noise (-1)
            clusters[label].append(record)

    # Sort clusters by size (largest first)
    sorted_clusters = dict(
        sorted(clusters.items(), key=lambda x: len(x[1]), reverse=True)
    )

    # Log top clusters
    for i, (label, members) in enumerate(list(sorted_clusters.items())[:20]):
        unique_images = len(set(r.image_path for r in members))
        log.info(f"  Cluster {i+1}: {len(members)} faces across {unique_images} images")

    return sorted_clusters


# ── Output ───────────────────────────────────────────────────────────────────

def write_output(
    clusters: dict[int, list[FaceRecord]],
    output_path: str,
    media_root: str,
):
    """Write clustering results as JSON."""
    output = {
        "metadata": {
            "total_clusters": len(clusters),
            "total_faces": sum(len(members) for members in clusters.values()),
            "total_images": len(set(
                r.image_path
                for members in clusters.values()
                for r in members
            )),
            "media_root": media_root,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        },
        "clusters": [],
    }

    for i, (label, members) in enumerate(clusters.items(), 1):
        # Group faces by image
        images = defaultdict(list)
        for r in members:
            rel_path = os.path.relpath(r.image_path, media_root)
            images[r.image_path].append({
                "face_idx": r.face_idx,
                "bbox": r.bbox,
                "det_score": round(r.det_score, 3),
            })

        image_list = []
        for path, faces in images.items():
            rel = os.path.relpath(path, media_root)
            image_list.append({
                "path": rel,
                "full_path": path,
                "faces": faces,
            })

        # Compute average intra-cluster similarity
        embeddings = np.array([r.embedding for r in members])
        norms = np.linalg.norm(embeddings, axis=1, keepdims=True)
        norms[norms == 0] = 1
        embeddings_norm = embeddings / norms
        sim_matrix = np.dot(embeddings_norm, embeddings_norm.T)
        n = len(members)
        if n > 1:
            avg_sim = float((sim_matrix.sum() - n) / (n * (n - 1)))
        else:
            avg_sim = 1.0

        output["clusters"].append({
            "id": i,
            "face_count": len(members),
            "image_count": len(images),
            "avg_similarity": round(avg_sim, 4),
            "images": image_list,
        })

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    log.info(f"Results written to {output_path}")
    log.info(f"  {len(clusters)} clusters across {output['metadata']['total_images']} images")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Face clustering pipeline")
    parser.add_argument("--media-dir", required=True, help="Root image directory")
    parser.add_argument("--output", default="/output/face-clusters.json", help="Output JSON")
    parser.add_argument("--cache-dir", default="/output/cache", help="Cache directory")
    parser.add_argument("--eps", type=float, default=0.6,
                        help="DBSCAN eps (cosine distance threshold, lower=stricter)")
    parser.add_argument("--min-samples", type=int, default=2,
                        help="DBSCAN min_samples (min faces to form a cluster)")
    parser.add_argument("--gpu", action="store_true", help="Use GPU via OpenVINO")
    parser.add_argument("--extract-only", action="store_true", help="Only extract faces, don't cluster")
    parser.add_argument("--limit", type=int, default=0, help="Limit number of images to process (0=all)")
    args = parser.parse_args()

    # Discover images
    log.info(f"Scanning {args.media_dir}...")
    image_paths = discover_images(args.media_dir)
    log.info(f"Found {len(image_paths)} images")

    if not image_paths:
        log.warning("No images found")
        sys.exit(0)

    if args.limit > 0:
        image_paths = image_paths[:args.limit]
        log.info(f"Limited to {len(image_paths)} images")

    # Initialize face analysis
    app = init_face_app(use_gpu=args.gpu)

    # Extract faces
    cache_path = os.path.join(args.cache_dir, "face_embeddings.pkl") if args.cache_dir else None
    records = extract_all_faces(app, image_paths, cache_path=cache_path)

    if not records:
        log.warning("No faces detected!")
        sys.exit(0)

    if args.extract_only:
        log.info("Extract-only mode — done")
        sys.exit(0)

    # Cluster
    clusters = cluster_faces(records, eps=args.eps, min_samples=args.min_samples)

    # Write output
    write_output(clusters, args.output, args.media_dir)


if __name__ == "__main__":
    main()
