# Terraform steps shared by the workflows. Source it from bash, then call the
# functions from inside the terraform/ directory to work on.

TF_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read-only init for environment $1. An environment without state yet is
# initialised with an empty local state instead: creating the remote state
# takes a lock the read-only identity can't write, and the plan is the same.
tf_init_readonly() {
  local bucket prefix listing
  bucket="$(sed -n 's/^bucket *= *"\(.*\)"/\1/p' "envs/$1.backend.hcl")"
  prefix="$(sed -n 's/^prefix *= *"\(.*\)"/\1/p' "envs/$1.backend.hcl")"
  if ! listing="$(gcloud storage ls "gs://${bucket}/**" 2>&1)"; then
    grep -q "matched no objects" <<< "${listing}" \
      || { echo "Can't read gs://${bucket}: ${listing}"; return 1; }
    listing=""
  fi
  if grep -qx "gs://${bucket}/${prefix}/default.tfstate" <<< "${listing}"; then
    terraform init -input=false -no-color -reconfigure "-backend-config=envs/$1.backend.hcl"
  else
    echo "No Terraform state for $1 yet: planning it as a new environment."
    printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
    terraform init -input=false -no-color
  fi
}

# Read-only plan of environment $1 (sa-terraform-plan). Writes plan.txt (the
# plan, or the error) and, if it worked, plan.json. Fails if it didn't.
tf_plan_readonly() {
  if ! tf_init_readonly "$1" > init.log 2>&1; then
    cp init.log plan.txt
    return 1
  fi
  if ! terraform plan -input=false -lock=false -no-color \
       "-var-file=envs/$1.tfvars" -out=tfplan > plan.log 2>&1; then
    cat init.log plan.log > plan.txt
    return 1
  fi
  terraform show -no-color tfplan > plan.txt
  terraform show -json tfplan > plan.json
}

# Prints the markdown for plan.txt/plan.json of environment $1: $2 is "ok" or
# not, $3 the heading, $4 a note under it. Starts with a marker so the
# comment can be found and updated.
tf_plan_markdown() {
  local summary destroys
  if [ "$2" = "ok" ]; then
    summary="$(grep -E '^(Plan:|No changes\.)' plan.txt | head -1)" || true
    destroys="$(bash "${TF_SCRIPTS}/terraform-destroys.sh" plan.json)"
  else
    summary="❌ Plan failed"
    destroys=""
  fi
  echo "<!-- terraform-plan:$1 -->"
  echo "### $3"
  echo ""
  echo "**${summary:-See the plan}** ($4)"
  if [ -n "${destroys}" ]; then
    echo ""
    echo "⚠️ **Destroys or replaces:**"
    sed 's/^/- `/; s/$/`/' <<< "${destroys}"
    echo ""
    echo "Applying stops on these; see CICD.md (allow destroy)."
  fi
  echo ""
  echo "<details><summary>Show plan</summary>"
  echo ""
  echo '```'
  head -c 60000 plan.txt
  if [ "$(wc -c < plan.txt)" -gt 60000 ]; then
    echo ""
    echo "... cut off; the full plan is in the run log."
  fi
  echo '```'
  echo "</details>"
}

# Posts markdown file $3 on PR $1, replacing an earlier comment for
# environment $2. Needs GH_TOKEN.
tf_post_comment() {
  local id
  id="$(gh api "repos/${GITHUB_REPOSITORY}/issues/$1/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"<!-- terraform-plan:$2 -->\")) | .id" | head -1)" || true
  if [ -n "${id}" ]; then
    gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${id}" -F body=@"$3" > /dev/null
  else
    gh api "repos/${GITHUB_REPOSITORY}/issues/$1/comments" -F body=@"$3" > /dev/null
  fi
}

# Plans and applies environment $1 (sa-terraform). Stops before applying if
# the plan destroys or replaces anything but IAM bindings, unless $2 is
# "true".
tf_apply() {
  local destroys
  terraform init -input=false -no-color -reconfigure "-backend-config=envs/$1.backend.hcl"
  terraform plan -input=false -no-color "-var-file=envs/$1.tfvars" -out=tfplan
  terraform show -json tfplan > plan.json
  {
    echo "### Terraform $1"
    echo '```'
    terraform show -no-color tfplan | grep -E '^(Plan:|No changes\.)' || true
    echo '```'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

  destroys="$(bash "${TF_SCRIPTS}/terraform-destroys.sh" plan.json)"
  if [ -n "${destroys}" ] && [ "$2" != "true" ]; then
    echo "::error::The plan for $1 destroys or replaces resources; nothing was applied:"
    echo "${destroys}"
    echo "If that's intended, run the Terraform workflow for $1 with 'Allow a plan that destroys or replaces resources'."
    {
      echo "**Stopped: destroys or replaces**"
      sed 's/^/- `/; s/$/`/' <<< "${destroys}"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    return 1
  fi
  terraform apply -input=false -no-color tfplan
}
