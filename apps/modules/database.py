import os
import boto3

table_name = os.environ["DYNAMODB_TABLE"]

dynamodb = boto3.resource("dynamodb", endpoint_url=os.getenv("DYNAMODB_ENDPOINT_URL") )

table = dynamodb.Table(os.environ['DYNAMODB_TABLE'])

