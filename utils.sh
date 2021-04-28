##############################################################
# Utilities
#
# Required tools
# - helm v3+
# - jq 1.6+
# - kubectl 1.16+
#
# Tested version
#   EKS v1.19
#
# Usage:
#   createRole $1 $2 $3 $4 $5
#     - $1: CLUSTER_NAME (required)
#     - $2: NAMESPACE (required)
#     - $3: SERVICE_ACCOUNT (required)
#     - $4: ROLE_NAME (required)
#     - $5: IAM_POLICY_ARN (required)
##############################################################
#!/bin/bash

## Create IAM Role based on OIDC
function createRole {
  FILE_NAME=$(uuidgen).json
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
  OIDC_PROVIDER=$(aws eks describe-cluster --name "$1" --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")

  read -r -d '' TRUST_RELATIONSHIP <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "${OIDC_PROVIDER}:sub": "system:serviceaccount:$2:$3",
            "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
          }
        }
      }
    ]
  }
EOF
  echo "${TRUST_RELATIONSHIP}" > /tmp/$FILE_NAME

  ## Create a Role
  ROLE_ARN=$(aws iam get-role --role-name "$4" 2>/dev/null | jq -r '.Role.Arn' 2>/dev/null)
  if [ -z "$ROLE_ARN" ]; then

    ROLE_ARN=$(aws iam create-role --role-name "$4" --assume-role-policy-document file:///tmp/"$FILE_NAME" | jq -r '.Role.Arn')

    while true;
    do
        role=$(aws iam get-role --role-name "$4" 2> /dev/null)
        if [ -n "$role" ]; then
            aws iam attach-role-policy --role-name "$4" --policy-arn="$5"
            break;
        fi
        sleep 1
    done
  fi

  echo $ROLE_ARN
}

# Convert array to string
function arrayToString {
  STR=""
  for N in "$@"
    do STR=$STR$N
  done
  echo $STR
}