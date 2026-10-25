project_id        = "shriramblue"
region            = "europe-west1"
environment       = "dev"
sql_instance_name = "staging-database"

github_repository = "Sarank-tech/gcp-postgres-password-rotator"

user_secret_mappings = {
  "postgres"    = "postgres_pwd"
  "int_mdm_012" = "int_mdm_012_pwd"
  "int_mdm_013" = "int_mdm_013_pwd"
  "int_mdm_016" = "int_mdm_016_pwd"
}

vpc_network        = "default"
vpc_connector_cidr = "10.8.0.0/28"
