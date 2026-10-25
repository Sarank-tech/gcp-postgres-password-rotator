FROM python:3.11-slim

# Unbuffered output so logs reach Cloud Logging immediately; no .pyc files.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Install dependencies first so this layer is cached across code changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY rotator.py .

# Run as an unprivileged user.
RUN useradd --system --uid 10001 rotator
USER rotator

ENTRYPOINT ["python", "rotator.py"]
