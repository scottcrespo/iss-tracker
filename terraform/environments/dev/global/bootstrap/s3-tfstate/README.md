# S3-TFstate

Bootstrap provisions s3 remote state bucket for terraform. 

Once the bucket is created, use `terraform init -migrate-state` to migrate local state
to S3. 
