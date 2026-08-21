# Google Takeout → S3 Backup

Fully automated pipeline: Google Takeout delivers to Drive on its own
2-month recurring schedule → EventBridge Scheduler fires an ECS Fargate
task → the task syncs Drive to S3 with rclone, verifies checksums, and
clears the Drive folder to reclaim space. No Lambda involved.

## Architecture

```
EventBridge Scheduler (cron)
        │
        ▼
   ECS RunTask (Fargate, public subnet, no NAT)
        │
        ▼
   backup.py container
     ├─ reads Google OAuth creds from Secrets Manager
     ├─ rclone copy   Drive:Takeout → S3
     ├─ rclone check  (verify checksums)
     ├─ rclone purge  Drive:Takeout   (only if check passed)
     └─ SNS notify (success or failure)
```

S3 objects land under `takeout/YYYY-MM/` and transition to Glacier Deep
Archive after 30 days (configurable).

## Prerequisites

- Terraform >= 1.5
- AWS CLI, configured with credentials that can create IAM/ECS/S3/etc.
- Docker, to build and push the container image
- `rclone` installed **on your own machine** (just for the one-time Google
  OAuth step below — not related to the container)

## 1. One-time: authorize Google Drive access

This step can't be scripted safely — it's an interactive OAuth consent
flow that has to happen in a browser, once, on your machine.

1. In Google Cloud Console, create (or reuse) a project, enable the
   **Google Drive API**, and create an **OAuth 2.0 Client ID** (type:
   Desktop app). Set the OAuth consent screen to **"In production"**, not
   "Testing" — testing-mode refresh tokens expire after 7 days, which
   would silently break the scheduled runs.
2. On your own machine, run:
   ```bash
   rclone authorize "drive" "<your-client-id>" "<your-client-secret>"
   ```
   This opens a browser, you sign in and grant access, and rclone prints a
   JSON token blob to the terminal.
3. Build `google-oauth.json` from the three values you now have:
   ```json
   {
     "client_id": "your-client-id.apps.googleusercontent.com",
     "client_secret": "your-client-secret",
     "refresh_token": "the refresh_token field from the printed JSON"
   }
   ```
   Keep this file out of version control (already covered by `.gitignore`).

## 2. Deploy the infrastructure

```bash
cd terraform
terraform init
terraform apply \
  -var="backup_bucket_name=adam-fenton-google-takeout-backup" \
  -var="alert_email=adam.fenton@gmail.com"
```

Review the plan before confirming — in particular check `schedule_expression`
matches roughly a week after whatever date your Takeout export actually
lands, and adjust `aws_region` if `eu-west-2` isn't where you want this.

Confirm the SNS subscription email that lands in your inbox — alerts won't
deliver until you click confirm.

## 3. Push the container image

```bash
cd ../container
aws ecr get-login-password --region eu-west-2 | \
  docker login --username AWS --password-stdin 377721963729.dkr.ecr.eu-west-2.amazonaws.com/takeout-backup-runner

docker build --platform linux/amd64 -t takeout-backup-runner .
docker tag takeout-backup-runner:latest 377721963729.dkr.ecr.eu-west-2.amazonaws.com/takeout-backup-runner:latest
docker push 377721963729.dkr.ecr.eu-west-2.amazonaws.com/takeout-backup-runner
```

(`<ecr_repository_url>` is in the `terraform apply` output.)

## 4. Populate the secret

```bash
aws secretsmanager put-secret-value \
  --secret-id takeout-backup/google-oauth \
  --secret-string file://google-oauth.json \
  --region eu-west-2
```

## 5. Set up the Takeout export itself

In `takeout.google.com`, configure the export as covered earlier:
services selected, delivery to **Add to Drive**, frequency **every 2
months for 1 year**, file type **.zip**, size **50GB**. Make sure the
Drive destination folder is named `Takeout` (rclone's default target) or
update the `DRIVE_FOLDER` environment variable in `ecs.tf` to match.

Put a calendar reminder ~11 months out — Takeout's recurring schedule
stops after a year and needs resubmitting.

## 6. Test it manually before trusting the schedule

```bash
aws ecs run-task \
  --cluster $(terraform -chdir=terraform output -raw ecr_repository_url | cut -d/ -f1) \
  --task-definition takeout-backup-runner \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<subnet-id>],securityGroups=[<sg-id>],assignPublicIp=ENABLED}"
```

Or simpler: trigger it from the AWS Console → ECS → Clusters →
`takeout-backup-cluster` → Tasks → Run new task, using the task definition
Terraform created. Watch progress in CloudWatch Logs at
`/ecs/takeout-backup`.

## Notes / things to revisit later

- **Cost**: this is very cheap to run — Fargate only bills while the task
  is running (a few times a year), S3 storage is mostly in Deep Archive,
  and there's no NAT Gateway. Rough estimate: a few dollars a year unless
  your Google data is very large.
- **Retries**: EventBridge Scheduler retries once on a failed `RunTask`
  call, but that only covers the task failing to *start* — if the script
  runs and fails partway (e.g. rclone check fails), it exits non-zero,
  alerts you via SNS, and leaves the Drive source untouched for you to
  investigate. It does not auto-retry the actual sync.
- **Google API quotas**: rclone's Drive OAuth here uses your own client
  ID, so you're not sharing rclone's default rate limits with everyone
  else using rclone — should be comfortable for a backup this infrequent.
