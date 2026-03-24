#!/usr/bin/env python3
"""
Face inference sidecar — HTTP API for extracting face embeddings.

Uses InsightFace buffalo_l model to detect faces and extract 512-dim ArcFace embeddings.
Designed to run as a k8s sidecar alongside Stash, sharing the /media volume.

Endpoints:
  POST /extract   — extract face embeddings from an image
  GET  /health    — health check
"""

import json
import gc
import os
import sys
import time
import traceback
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

import cv2
import numpy as np
from insightface.app import FaceAnalysis

MODEL_NAME = os.environ.get("MODEL_NAME", "buffalo_l")
MODEL_DIR = os.environ.get("MODEL_DIR", "/models")
LISTEN_PORT = int(os.environ.get("PORT", "8000"))
DET_SIZE = int(os.environ.get("DET_SIZE", "640"))

# Global model instance
face_app = None


def init_model():
    global face_app
    print(f"Loading InsightFace model: {MODEL_NAME}", flush=True)
    start = time.time()
    face_app = FaceAnalysis(
        name=MODEL_NAME,
        root=MODEL_DIR,
        providers=["CPUExecutionProvider"],
    )
    face_app.prepare(ctx_id=0, det_size=(DET_SIZE, DET_SIZE))
    elapsed = time.time() - start
    print(f"Model loaded in {elapsed:.1f}s", flush=True)


MAX_IMAGE_DIM = int(os.environ.get("MAX_IMAGE_DIM", "4096"))
MAX_FACES = int(os.environ.get("MAX_FACES", "10"))


def extract_faces(image_path):
    """Extract face embeddings from an image file."""
    img = cv2.imread(image_path)
    if img is None:
        return None, f"Failed to read image: {image_path}"

    # Resize oversized images to avoid OOM
    h, w = img.shape[:2]
    if max(h, w) > MAX_IMAGE_DIM:
        scale = MAX_IMAGE_DIM / max(h, w)
        img = cv2.resize(img, (int(w * scale), int(h * scale)))

    faces = face_app.get(img)
    results = []
    for i, face in enumerate(faces):
        if i >= MAX_FACES:
            break
        result = {
            "embedding": face.embedding.tolist(),
            "det_score": float(face.det_score),
        }
        bbox = face.bbox.astype(int).tolist()
        result["bbox"] = {
            "x": bbox[0],
            "y": bbox[1],
            "w": bbox[2] - bbox[0],
            "h": bbox[3] - bbox[1],
        }
        results.append(result)

    # Free image memory immediately
    del img
    gc.collect()

    return results, None


class RequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "model": MODEL_NAME})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/extract":
            self.handle_extract()
        else:
            self.send_json(404, {"error": "not found"})

    def handle_extract(self):
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)

            image_path = data.get("image_path", "")
            if not image_path:
                self.send_json(400, {"error": "image_path is required"})
                return

            if not os.path.isfile(image_path):
                self.send_json(404, {"error": f"file not found: {image_path}"})
                return

            faces, err = extract_faces(image_path)
            if err:
                self.send_json(500, {"error": err})
                return

            self.send_json(200, {"faces": faces, "count": len(faces)})

        except Exception as e:
            traceback.print_exc()
            self.send_json(500, {"error": str(e)})

    def send_json(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Quieter logging
        if "/health" not in str(args):
            print(f"{self.client_address[0]} - {format % args}", flush=True)


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def main():
    init_model()
    server = ThreadedHTTPServer(("0.0.0.0", LISTEN_PORT), RequestHandler)
    print(f"Face inference sidecar listening on :{LISTEN_PORT} (threaded)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
