import boto3
import os

from dotenv import load_dotenv

load_dotenv()

dynamodb = boto3.resource("dynamodb")

dynamo_table = dynamodb.Table(os.environ['DYNAMODB_TABLE'])

