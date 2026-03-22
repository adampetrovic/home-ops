FROM python:3.12-slim

WORKDIR /app

# System deps for Pillow
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libjpeg62-turbo-dev libwebp-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# Python deps — torch from CPU-only index, rest from PyPI
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu --index-url https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir \
    Pillow==11.2.1 \
    imagehash==4.3.2 \
    numpy==2.2.4 \
    transformers==4.49.0

COPY dedup.py .

ENTRYPOINT ["python3", "dedup.py"]
