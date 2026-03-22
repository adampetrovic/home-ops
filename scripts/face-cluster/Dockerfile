FROM python:3.12-slim

WORKDIR /app

# System deps for OpenCV, InsightFace build
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 libgomp1 \
        build-essential python3-dev && \
    rm -rf /var/lib/apt/lists/*

# Install Cython first (insightface build dep), then the rest
RUN pip install --no-cache-dir Cython numpy==2.2.4 && \
    pip install --no-cache-dir \
    opencv-python-headless==4.11.0.86 \
    insightface==0.7.3 \
    scikit-learn==1.7.0 \
    onnxruntime==1.22.0

COPY cluster.py .

ENTRYPOINT ["python3", "cluster.py"]
