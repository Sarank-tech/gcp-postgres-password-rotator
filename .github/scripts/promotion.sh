# Promotion settings shared by the workflows. Source it from bash.
#
# To switch on stage or prod: add it to PROMOTION_ENVS below and to the
# "environment" choices in promote.yaml, create its GitHub Environment, and
# apply its Terraform.

# Environments that can be promoted to, in order.
PROMOTION_ENVS="test stage"

# The environment a build must come from before reaching $1.
previous_env() {
  case "$1" in
    test) echo dev ;;
    stage) echo test ;;
    prod) echo stage ;;
    *) return 1 ;;
  esac
}

is_enabled() {
  [[ " ${PROMOTION_ENVS} " == *" $1 "* ]]
}

job_name() {
  echo "postgres-password-rotator-$1"
}

# Prints every tag of image $1 as "<tag> <digest>" lines. Uses tags list,
# which only reads tags ("images describe" also reads vulnerability data and
# needs Container Analysis permissions the deployer doesn't have).
all_tags() {
  gcloud artifacts docker tags list "$1" --format=json \
    | jq -r '.[] | "\(.tag | split("/") | last) \(.version | split("/") | last)"'
}

# Prints the tags on image digest $2 (sha256:...) in image $1, one per line.
image_tags() {
  all_tags "$1" | awk -v d="$2" '$2 == d { print $1 }'
}

# Prints the digest (sha256:...) that tag $2 points at in image $1, if any.
tag_digest() {
  all_tags "$1" | awk -v t="$2" '$1 == t { print $2 }'
}

# Fails unless deploy/<env>.json at $1 is a valid promotion record.
check_record() {
  local file="$1" repo="$2"
  jq -e --arg repo "${repo}/rotator@" '
    (.build | type == "number") and
    (.commit | test("^[0-9a-f]{40}$")) and
    (.image | startswith($repo)) and
    (.image | test("@sha256:[0-9a-f]{64}$"))
  ' "${file}" > /dev/null || {
    echo "::error::${file} is not a valid promotion record (build, commit, image from ${repo}/rotator)"
    return 1
  }
}

# Succeeds if deploy/$1.json named image $2 at some point in the history of
# ref $3, i.e. env $1 ran that image before (a rollback target).
ran_before() {
  local rev
  for rev in $(git log --format=%H "$3" -- "deploy/$1.json"); do
    if [ "$(git show "${rev}:deploy/$1.json" 2> /dev/null | jq -r .image)" = "$2" ]; then
      return 0
    fi
  done
  return 1
}

# Prints the record env $1 had for build $2 in the history of ref $3.
earlier_record() {
  local rev record
  for rev in $(git log --format=%H "$3" -- "deploy/$1.json"); do
    record="$(git show "${rev}:deploy/$1.json" 2> /dev/null)" || continue
    if [ "$(jq -r .build <<< "${record}")" = "$2" ]; then
      echo "${record}"
      return 0
    fi
  done
  return 1
}
