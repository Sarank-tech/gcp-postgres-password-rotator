project_id        = "ingka-dp-sap-dev"
region            = "europe-west1"
environment       = "dev"
sql_instance_name = "staging-database"

github_repository = "ingka-group-digital/mdm-postgrespwd-rotator"

# PR preview deploys go to dev only.
github_allow_pull_requests = true

user_secret_mappings = {
  "postgres"    = "postgres_pwd"
  "int_mdm_012" = "int_mdm_012_pwd"
  "int_mdm_013" = "int_mdm_013_pwd"
  "int_mdm_016" = "int_mdm_016_pwd"
}

# The password each rotation replaces is kept here for ops (current and
# previous version only).
user_old_secret_mappings = {
  "postgres"    = "postgres_oldpwd"
  "int_mdm_012" = "int_mdm_012_oldpwd"
  "int_mdm_013" = "int_mdm_013_oldpwd"
  "int_mdm_016" = "int_mdm_016_oldpwd"
}

vpc_network        = "ingka-dp-vpc-1"
vpc_connector_cidr = "10.3.0.0/28"

# Dev hosts the only image registry; these environments run images from it.
image_reader_projects = {
  "ingka-dp-sap-test"  = "1051284681247"
  "ingka-dp-sap-stage" = "47183561456"
}

# Scheduled rotation is off for now: run the job by hand. Set false to rotate
# on the schedule (default 00:00 UTC on 1 Jan/Apr/Jul/Oct).
schedule_paused = true
