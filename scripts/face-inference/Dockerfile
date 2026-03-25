FROM python:3.14-slim

# Install OpenCV dependencies + build tools for insightface Cython extension
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 libglib2.0-0 libsm6 libxrender1 libxext6 \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN pip install --no-cache-dir \
    insightface==0.7.3 \
    onnxruntime==1.18.1 \
    opencv-python-headless==4.10.0.84 \
    numpy==1.26.4

# Pre-download the buffalo_l model
RUN python3 -c "from insightface.app import FaceAnalysis; FaceAnalysis(name='buffalo_l', root='/models', providers=['CPUExecutionProvider']).prepare(ctx_id=0, det_size=(640,640)); print('Model downloaded')"

WORKDIR /app
COPY server.py .

ENV PORT=8000
EXPOSE 8000

CMD ["python3", "server.py"]
