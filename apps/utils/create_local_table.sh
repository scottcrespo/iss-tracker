#!/bin/bash
# module to create local dynamo-db table with the docker container
aws dynamodb create-table \
  --table-name iss-positions \
  --attribute-definitions \
      AttributeName=pk,AttributeType=S \
      AttributeName=timestamp,AttributeType=N \
  --key-schema \
      AttributeName=pk,KeyType=HASH \
      AttributeName=timestamp,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --endpoint-url http://localhost:8000