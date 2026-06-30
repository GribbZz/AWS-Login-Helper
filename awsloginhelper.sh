#!/bin/bash

set -euo pipefail

AWS_DIR="$HOME/.aws"
CRED_FILE="$AWS_DIR/credentials"
CONFIG_FILE="$AWS_DIR/config"

mkdir -p "$AWS_DIR"
touch "$CRED_FILE"
touch "$CONFIG_FILE"

# Cleanup function to remove all profiles except 'default' from credentials file
cleanup_profiles() {
  TMP_FILE=$(mktemp)

  if [[ ! -f "$CRED_FILE" ]]; then
    echo "Credentials file does not exist: $CRED_FILE"
    return
  fi

  echo "Cleaning non-default profiles from $CRED_FILE..."

  awk '
    BEGIN { keep = 1 }
    /^\[default\]/ { keep = 1 }
    /^\[.*\]/ {
      if ($0 ~ /^\[default\]/) {
        keep = 1
      } else {
        keep = 0
      }
    }
    {
      if (keep) print
    }
  ' "$CRED_FILE" > "$TMP_FILE"

  mv "$TMP_FILE" "$CRED_FILE"

  echo "Cleanup complete: All profiles except 'default' removed."
}

# Option 1: Standard AWS login without MFA
standard_aws_login() {
  read -p "Enter name for the AWS CLI profile (leave blank to use 'default'): " TARGET_PROFILE
  TARGET_PROFILE=${TARGET_PROFILE:-default}

  read -p "Enter AWS Access Key ID: " AWS_ACCESS_KEY_ID
  read -s -p "Enter AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
  echo ""
  read -p "Enter default region (leave blank to skip): " REGION
  read -p "Enter output format (leave blank to skip, e.g., json): " OUTPUT_FORMAT

  if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
    echo "AWS Access Key ID and AWS Secret Access Key are required."
    exit 1
  fi

  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID" --profile "$TARGET_PROFILE"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$TARGET_PROFILE"

  if [[ -n "$REGION" ]]; then
    aws configure set region "$REGION" --profile "$TARGET_PROFILE"
  fi

  if [[ -n "$OUTPUT_FORMAT" ]]; then
    aws configure set output "$OUTPUT_FORMAT" --profile "$TARGET_PROFILE"
  fi

  echo -e "\nStandard AWS credentials saved under profile: [$TARGET_PROFILE]"
  echo "   To use it: aws sts get-caller-identity --profile $TARGET_PROFILE"
}

# Option 2: Standard AWS login with MFA
standard_login_with_mfa() {
  read -p "Enter source AWS CLI profile containing your long-lived IAM user keys (leave blank to use 'default'): " SOURCE_PROFILE
  SOURCE_PROFILE=${SOURCE_PROFILE:-default}

  read -p "Enter MFA ARN (e.g., arn:aws:iam::123456789012:mfa/your.mfa.name): " MFA_ARN

  read -p "Enter duration in seconds (leave blank to use 43200): " DURATION
  DURATION=${DURATION:-43200}

  read -p "Enter name for the profile to store MFA session credentials (e.g., mfa-session): " TARGET_PROFILE

  read -p "Enter MFA token code: " TOKEN_CODE

  if [[ -z "$MFA_ARN" || -z "$TOKEN_CODE" || -z "$TARGET_PROFILE" ]]; then
    echo "MFA ARN, MFA token code, and target profile are required."
    exit 1
  fi

  CREDS=$(aws sts get-session-token \
    --profile "$SOURCE_PROFILE" \
    --serial-number "$MFA_ARN" \
    --token-code "$TOKEN_CODE" \
    --duration-seconds "$DURATION")

  AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' <<< "$CREDS")
  AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' <<< "$CREDS")
  AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' <<< "$CREDS")
  EXPIRATION=$(jq -r '.Credentials.Expiration' <<< "$CREDS")

  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID" --profile "$TARGET_PROFILE"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$TARGET_PROFILE"
  aws configure set aws_session_token "$AWS_SESSION_TOKEN" --profile "$TARGET_PROFILE"

  echo -e "\nStandard AWS MFA session credentials saved under profile: [$TARGET_PROFILE]"
  echo "   Expiration: $EXPIRATION"
  echo "   To use it: aws sts get-caller-identity --profile $TARGET_PROFILE"
}

# Option 3: Assume role without MFA
assume_role_login() {
  read -p "Enter source AWS CLI profile (leave blank to use 'default'): " SOURCE_PROFILE
  SOURCE_PROFILE=${SOURCE_PROFILE:-default}

  read -p "Enter ROLE ARN (e.g., arn:aws:iam::123456789012:role/MyRole): " ROLE_ARN
  read -p "Enter role session name (leave blank to use 'session'): " SESSION_NAME
  SESSION_NAME=${SESSION_NAME:-session}

  read -p "Enter duration in seconds (leave blank to use 3600): " DURATION
  DURATION=${DURATION:-3600}

  read -p "Enter name for the profile to store credentials (e.g., assumed-role): " TARGET_PROFILE

  if [[ -z "$ROLE_ARN" || -z "$TARGET_PROFILE" ]]; then
    echo "ROLE ARN and target profile are required."
    exit 1
  fi

  CREDS=$(aws sts assume-role \
    --profile "$SOURCE_PROFILE" \
    --role-arn "$ROLE_ARN" \
    --role-session-name "$SESSION_NAME" \
    --duration-seconds "$DURATION")

  AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' <<< "$CREDS")
  AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' <<< "$CREDS")
  AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' <<< "$CREDS")
  EXPIRATION=$(jq -r '.Credentials.Expiration' <<< "$CREDS")

  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID" --profile "$TARGET_PROFILE"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$TARGET_PROFILE"
  aws configure set aws_session_token "$AWS_SESSION_TOKEN" --profile "$TARGET_PROFILE"

  echo -e "\nAssume role credentials saved under profile: [$TARGET_PROFILE]"
  echo "   Expiration: $EXPIRATION"
  echo "   To use it: aws sts get-caller-identity --profile $TARGET_PROFILE"
}

# Option 4: Assume role with MFA
assume_role_with_mfa() {
  read -p "Enter source AWS CLI profile (leave blank to use 'default'): " SOURCE_PROFILE
  SOURCE_PROFILE=${SOURCE_PROFILE:-default}

  read -p "Enter ROLE ARN (e.g., arn:aws:iam::123456789012:role/MyRole): " ROLE_ARN
  read -p "Enter MFA ARN (e.g., arn:aws:iam::123456789012:mfa/your.mfa.name): " MFA_ARN

  read -p "Enter role session name (leave blank to use 'session'): " SESSION_NAME
  SESSION_NAME=${SESSION_NAME:-session}

  read -p "Enter duration in seconds (leave blank to use 3600): " DURATION
  DURATION=${DURATION:-3600}

  read -p "Enter name for the profile to store credentials (e.g., assumed-role-mfa): " TARGET_PROFILE

  read -p "Enter MFA token code: " TOKEN_CODE

  if [[ -z "$ROLE_ARN" || -z "$MFA_ARN" || -z "$TOKEN_CODE" || -z "$TARGET_PROFILE" ]]; then
    echo "ROLE ARN, MFA ARN, MFA token code, and target profile are required."
    exit 1
  fi

  CREDS=$(aws sts assume-role \
    --profile "$SOURCE_PROFILE" \
    --role-arn "$ROLE_ARN" \
    --role-session-name "$SESSION_NAME" \
    --duration-seconds "$DURATION" \
    --serial-number "$MFA_ARN" \
    --token-code "$TOKEN_CODE")

  AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' <<< "$CREDS")
  AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' <<< "$CREDS")
  AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' <<< "$CREDS")
  EXPIRATION=$(jq -r '.Credentials.Expiration' <<< "$CREDS")

  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID" --profile "$TARGET_PROFILE"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$TARGET_PROFILE"
  aws configure set aws_session_token "$AWS_SESSION_TOKEN" --profile "$TARGET_PROFILE"

  echo -e "\nAssume role with MFA credentials saved under profile: [$TARGET_PROFILE]"
  echo "   Expiration: $EXPIRATION"
  echo "   To use it: aws sts get-caller-identity --profile $TARGET_PROFILE"
}

# Optional cleanup
read -p "Do you want to clean up non-default profiles from ~/.aws/credentials? (y/N): " CLEANUP_CHOICE
CLEANUP_CHOICE=${CLEANUP_CHOICE:-N}

if [[ "$CLEANUP_CHOICE" == "y" || "$CLEANUP_CHOICE" == "Y" ]]; then
  cleanup_profiles
fi

echo ""
echo "Select an option:"
echo "1) Standard AWS login"
echo "2) Standard AWS login with MFA"
echo "3) Assume role login"
echo "4) Assume role with MFA"
echo ""

read -p "Enter choice [1-4]: " OPTION

case "$OPTION" in
  1)
    standard_aws_login
    ;;
  2)
    standard_login_with_mfa
    ;;
  3)
    assume_role_login
    ;;
  4)
    assume_role_with_mfa
    ;;
  *)
    echo "Invalid option selected."
    exit 1
    ;;
esac
