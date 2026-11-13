project_id        = "ingka-dp-sap-dev"
region            = "europe-west1"
environment       = "dev"
sql_instance_name = "staging-database"

github_repository = "ingka-group-digital/mdm-postgrespwd-rotator"

user_secret_mappings = {
  "postgres"    = "postgres_pwd"
  "int_mdm_012" = "int_mdm_012_pwd"
  "int_mdm_013" = "int_mdm_013_pwd"
  "int_mdm_016" = "int_mdm_016_pwd"
}

vpc_network        = "ingka-dp-vpc-1"
vpc_connector_cidr = "10.3.0.0/28"

# Dev hosts the only image registry; these environments run images from it.
image_reader_projects = {
  "ingka-dp-sap-test" = "1051284681247"
}
