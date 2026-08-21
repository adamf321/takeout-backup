FROM python:3.12-slim

# rclone: install the official static binary rather than a distro package,
# so we're not stuck on whatever old version Debian ships.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip ca-certificates \
    && curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip \
    && unzip rclone-current-linux-amd64.zip \
    && cp rclone-*-linux-amd64/rclone /usr/local/bin/ \
    && chmod +x /usr/local/bin/rclone \
    && rm -rf rclone-*-linux-amd64* \
    && apt-get purge -y curl unzip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backup.py .

ENTRYPOINT ["python", "backup.py"]
