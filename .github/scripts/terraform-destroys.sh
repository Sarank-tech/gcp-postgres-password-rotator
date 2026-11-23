#!/usr/bin/env bash
# Prints the addresses of resources the plan in $1 (terraform show -json)
# destroys or replaces, one per line. IAM member bindings are left out:
# replacing one is routine (it changes whenever its member does) and loses
# nothing.
set -euo pipefail
jq -r '
  .resource_changes[]?
  | select(.change.actions | index("delete"))
  | select(.type | endswith("_iam_member") | not)
  | .address
' "$1"
