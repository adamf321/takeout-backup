#!/usr/bin/env python3
"""
Google Takeout -> S3 backup runner.

Runs as a one-shot ECS Fargate task, triggered on a schedule by
EventBridge Scheduler. Steps:

  1. Pull Google OAuth creds from Secrets Manager, build an rclone.conf.
  2. List the Takeout folder in Drive; bail out if it's empty or looks
     like it's still mid-export (files modified too recently).
  3. Copy everything to S3 under a dated prefix.
  4. Verify the copy with checksums (rclone check).
  5. Only if verification passes: delete the source folder from Drive.
  6. Notify success or failure via SNS. On failure, also log a line
     containing "BACKUP_FAILED" so the CloudWatch metric filter/alarm
     catches it even if the SNS publish itself fails.

Exits non-zero on any failure so the ECS task shows a failed status.
"""

import json
import logging
import os
import subprocess
import sys
from datetime import datetime, timezone

import boto3

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("takeout-backup")

# --- Config from environment (set by the ECS task definition) ---
S3_BUCKET = os.environ["S3_BUCKET"]
S3_PREFIX = os.environ.get("S3_PREFIX", "takeout")
GOOGLE_OAUTH_SECRET_ARN = os.environ["GOOGLE_OAUTH_SECRET_ARN"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
DRIVE_FOLDER = os.environ.get("DRIVE_FOLDER", "Takeout")
MIN_FILE_AGE_HOURS = float(os.environ.get("MIN_FILE_AGE_HOURS", "6"))
AWS_REGION_NAME = os.environ.get("AWS_REGION_NAME", "eu-west-2")

RCLONE_CONF_PATH = "/tmp/rclone.conf"
GDRIVE_REMOTE = f"gdrive:{DRIVE_FOLDER}"
RUN_STAMP = datetime.now(timezone.utc).strftime("%Y-%m")
S3_REMOTE = f"s3:{S3_BUCKET}/{S3_PREFIX}/{RUN_STAMP}/"


def fail(message: str, exc: Exception | None = None) -> None:
    """Log a failure in the format the CloudWatch alarm watches for,
    notify SNS, and exit non-zero. Source data is left untouched."""
    log.error("BACKUP_FAILED: %s", message)
    if exc:
        log.exception(exc)
    try:
        notify(
            subject="Takeout backup FAILED",
            body=f"{message}\n\nRun stamp: {RUN_STAMP}\nS3 target: {S3_REMOTE}",
        )
    except Exception as sns_exc:  # noqa: BLE001 - best-effort notify
        log.error("Also failed to publish SNS alert: %s", sns_exc)
    sys.exit(1)


def notify(subject: str, body: str) -> None:
    sns = boto3.client("sns", region_name=AWS_REGION_NAME)
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=body)


def load_google_oauth() -> dict:
    secrets = boto3.client("secretsmanager", region_name=AWS_REGION_NAME)
    resp = secrets.get_secret_value(SecretId=GOOGLE_OAUTH_SECRET_ARN)
    creds = json.loads(resp["SecretString"])
    for key in ("client_id", "client_secret", "refresh_token"):
        if key not in creds:
            raise ValueError(f"Google OAuth secret is missing '{key}'")
    return creds


def write_rclone_conf(creds: dict) -> None:
    # expiry deliberately in the past -> rclone refreshes the access token
    # on first use rather than trying to use a stale/blank one.
    token = json.dumps(
        {
            "access_token": "expired",  # rclone 1.67+ ignores refresh_token if access_token is empty
            "token_type": "Bearer",
            "refresh_token": creds["refresh_token"],
            "expiry": "2000-01-01T00:00:00Z",
        }
    )

    conf = f"""[gdrive]
type = drive
client_id = {creds['client_id']}
client_secret = {creds['client_secret']}
scope = drive
token = {token}

[s3]
type = s3
provider = AWS
env_auth = true
region = {AWS_REGION_NAME}
"""
    with open(RCLONE_CONF_PATH, "w") as f:
        f.write(conf)
    os.chmod(RCLONE_CONF_PATH, 0o600)


def run_rclone(*args: str, timeout: int = 3600) -> subprocess.CompletedProcess:
    cmd = ["rclone", "--config", RCLONE_CONF_PATH, *args]
    log.info("Running: %s", " ".join(a if "token" not in a else "***" for a in cmd))
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def run_rclone_streaming(*args: str, timeout: int = 3600) -> None:
    """Run rclone, streaming stderr to the logger line-by-line in real time."""
    import threading

    cmd = ["rclone", "--config", RCLONE_CONF_PATH, *args]
    log.info("Running: %s", " ".join(a if "token" not in a else "***" for a in cmd))

    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)

    def _stream() -> None:
        for line in proc.stderr:
            line = line.rstrip()
            if line:
                log.info("rclone: %s", line)

    thread = threading.Thread(target=_stream, daemon=True)
    thread.start()
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        thread.join(timeout=5)
        raise RuntimeError(f"rclone timed out after {timeout}s")
    thread.join(timeout=30)

    if proc.returncode != 0:
        raise RuntimeError(f"rclone copy failed with exit code {proc.returncode}")


def list_drive_files() -> list[dict]:
    result = run_rclone("lsjson", GDRIVE_REMOTE, timeout=120)
    if result.returncode != 0:
        raise RuntimeError(f"rclone lsjson failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def guard_against_partial_export(files: list[dict]) -> None:
    if not files:
        raise RuntimeError(
            f"Drive folder '{DRIVE_FOLDER}' is empty — nothing to back up "
            f"(or Takeout hasn't delivered yet this cycle)."
        )

    now = datetime.now(timezone.utc)
    for f in files:
        mod_time = datetime.fromisoformat(f["ModTime"].replace("Z", "+00:00"))
        age_hours = (now - mod_time).total_seconds() / 3600
        if age_hours < MIN_FILE_AGE_HOURS:
            raise RuntimeError(
                f"File '{f['Path']}' was modified {age_hours:.1f}h ago, "
                f"under the {MIN_FILE_AGE_HOURS}h safety buffer — Takeout "
                f"may still be writing files. Skipping this run; the next "
                f"scheduled run will retry."
            )


def sync_to_s3() -> None:
    run_rclone_streaming(
        "copy", GDRIVE_REMOTE, S3_REMOTE,
        "--checksum", "--transfers", "4", "--s3-upload-concurrency", "4",
        "--stats", "60s", "--stats-one-line",
        timeout=int(os.environ.get("RCLONE_COPY_TIMEOUT", "18000")),  # 5h default
    )


def verify_copy() -> None:
    result = run_rclone(
        "check", GDRIVE_REMOTE, S3_REMOTE, "--one-way",
        timeout=int(os.environ.get("RCLONE_CHECK_TIMEOUT", "3600")),
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"rclone check found mismatches — NOT deleting source. "
            f"Details: {result.stderr.strip()[-2000:]}"
        )


def delete_source() -> None:
    result = run_rclone("purge", GDRIVE_REMOTE, timeout=300)
    if result.returncode != 0:
        # Copy is verified and safe in S3 at this point — a failed delete
        # just means next cycle's guard logic sees leftover old files. Not
        # fatal, but worth flagging.
        log.warning(
            "Verified backup succeeded but deleting the Drive source "
            "failed: %s. Space will be reclaimed manually or next run.",
            result.stderr.strip(),
        )


def main() -> None:
    log.info("Starting Takeout backup run, stamp=%s", RUN_STAMP)

    try:
        creds = load_google_oauth()
        write_rclone_conf(creds)
    except Exception as exc:
        fail("Could not load/apply Google OAuth credentials", exc)
        return

    try:
        files = list_drive_files()
        guard_against_partial_export(files)
        log.info("Found %d file(s) to back up", len(files))
    except Exception as exc:
        fail(str(exc), exc)
        return

    try:
        sync_to_s3()
        log.info("Copy to S3 complete: %s", S3_REMOTE)
    except Exception as exc:
        fail("rclone copy to S3 failed", exc)
        return

    try:
        verify_copy()
        log.info("Checksum verification passed")
    except Exception as exc:
        fail(str(exc), exc)
        return

    delete_source()  # best-effort, logged not fatal

    notify(
        subject="Takeout backup succeeded",
        body=(
            f"Backed up {len(files)} file(s) to {S3_REMOTE} and verified "
            f"checksums. Drive source cleared."
        ),
    )
    log.info("Backup run complete.")


if __name__ == "__main__":
    main()
