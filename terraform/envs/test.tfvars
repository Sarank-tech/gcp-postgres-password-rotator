project_id        = "ingka-dp-sap-test"
region            = "europe-west1"
environment       = "test"
sql_instance_name = "staging-database"

github_repository = "ingka-group-digital/mdm-postgrespwd-rotator"

user_secret_mappings = {
  "postgres"    = "postgres_pwd"
  "int_mdm_012" = "int_mdm_012_pwd"
  "int_mdm_013" = "int_mdm_013_pwd"
  "int_mdm_016" = "int_mdm_016_pwd"
}

vpc_network = "ingka-dp-vpc-1"
# TODO: confirm this /28 is unused in ingka-dp-sap-test before the first apply.
vpc_connector_cidr = "10.8.0.0/28"
