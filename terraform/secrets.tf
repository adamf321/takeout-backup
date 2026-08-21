# This creates an EMPTY secret container. Terraform intentionally does not
# set the value here — putting OAuth secrets in .tf files or state is a bad
# habit even with a private state file. Populate it after apply with:
#
#   aws secretsmanager put-secret-value \
#     --secret-id takeout-backup/google-oauth \
#     --secret-string file://google-oauth.json
#
# See README.md for how to generate google-oauth.json (one-time, interactive
# OAuth flow using rclone on your own machine).

resource "aws_secretsmanager_secret" "google_oauth" {
  name        = "${var.project_name}/google-oauth"
  description = "Google Drive OAuth client_id, client_secret, and refresh_token for the Takeout backup task"

  tags = {
    Project = var.project_name
  }
}

output "google_oauth_secret_arn" {
  value = aws_secretsmanager_secret.google_oauth.arn
}
