#!/usr/bin/env bash
# Prints the sign-in settings for environment $1 and service account $2
# (sa-terraform or sa-terraform-plan), from .github/terraform-envs.json, as
# GITHUB_OUTPUT lines.
set -euo pipefail
file="$(dirname "$0")/../terraform-envs.json"
project="$(jq -r --arg e "$1" '.[$e].project_id // empty' "${file}")"
number="$(jq -r --arg e "$1" '.[$e].project_number // empty' "${file}")"
if [ -z "${project}" ] || ! [[ "${number}" =~ ^[0-9]+$ ]]; then
  echo "::error::$1 has no project_id and project_number in .github/terraform-envs.json" >&2
  exit 1
fi
echo "provider=projects/${number}/locations/global/workloadIdentityPools/github-actions-pool-$1/providers/github-provider-$1"
echo "service_account=$2@${project}.iam.gserviceaccount.com"
