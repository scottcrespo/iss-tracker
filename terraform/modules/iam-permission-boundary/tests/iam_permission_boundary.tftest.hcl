# Tests for the iam-permission-boundary module
#
# Uses mock providers so no AWS credentials or real resources are needed.
# Run with: terraform test
#
# Covers:
#   - policy name is set correctly on the resource
#   - boundary_name output matches the input name
#   - tags are applied to the policy

mock_provider "aws" {}

# --- policy name ---

run "policy_name_is_set" {
  command = plan

  variables {
    name        = "iss-tracker-dev-boundary"
    policy_json = jsonencode({ Version = "2012-10-17", Statement = [] })
  }

  assert {
    condition     = aws_iam_policy.boundary.name == "iss-tracker-dev-boundary"
    error_message = "Expected policy name 'iss-tracker-dev-boundary', got '${aws_iam_policy.boundary.name}'"
  }
}

# --- boundary_name output ---

run "boundary_name_output_matches_input" {
  command = plan

  variables {
    name        = "iss-tracker-dev-boundary"
    policy_json = jsonencode({ Version = "2012-10-17", Statement = [] })
  }

  assert {
    condition     = output.boundary_name == "iss-tracker-dev-boundary"
    error_message = "Expected boundary_name output to match input name"
  }
}

# --- tags ---

run "tags_are_applied" {
  command = plan

  variables {
    name        = "iss-tracker-dev-boundary"
    policy_json = jsonencode({ Version = "2012-10-17", Statement = [] })
    tags        = { environment = "dev" }
  }

  assert {
    condition     = aws_iam_policy.boundary.tags["environment"] == "dev"
    error_message = "Expected environment tag to be 'dev'"
  }
}