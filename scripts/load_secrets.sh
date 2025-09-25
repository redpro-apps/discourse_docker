#!/usr/bin/env bash
#
# Dual Secrets Loading Strategy
# 1. Try AWS Secrets Manager (production)
# 2. Fallback to .env file (development/local)
# 3. Validate required secrets exist
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DISCOURSE_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$DISCOURSE_DIR/.env"

# AWS Secrets Manager configuration
AWS_SECRET_NAME="discourse/production"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Required secrets list
REQUIRED_SECRETS=(
    "DISCOURSE_HOSTNAME"
    "DISCOURSE_DEVELOPER_EMAILS"
    "DISCOURSE_SMTP_ADDRESS"
    "DISCOURSE_SMTP_USER_NAME"
    "DISCOURSE_SMTP_PASSWORD"
)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to load secrets from AWS Secrets Manager
load_from_aws() {
    log_info "Attempting to load secrets from AWS Secrets Manager..."

    # Check if AWS CLI is available
    if ! command -v aws &> /dev/null; then
        log_warn "AWS CLI not found"
        return 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_warn "AWS credentials not configured or invalid"
        return 1
    fi

    # Try to retrieve the secret
    local secret_value
    if secret_value=$(aws secretsmanager get-secret-value \
        --secret-id "$AWS_SECRET_NAME" \
        --region "$AWS_REGION" \
        --query 'SecretString' \
        --output text 2>/dev/null); then

        log_info "Successfully retrieved secrets from AWS Secrets Manager"

        # Parse JSON and export environment variables
        echo "$secret_value" | jq -r 'to_entries|map("export \(.key)=\(.value|tostring)")|.[]' > /tmp/aws_secrets.env
        source /tmp/aws_secrets.env
        rm -f /tmp/aws_secrets.env

        return 0
    else
        log_warn "Failed to retrieve secret '$AWS_SECRET_NAME' from AWS Secrets Manager"
        return 1
    fi
}

# Function to load secrets from .env file
load_from_env_file() {
    log_info "Attempting to load secrets from .env file..."

    if [[ -f "$ENV_FILE" ]]; then
        log_info "Found .env file at $ENV_FILE"

        # Source the .env file
        set -a  # automatically export all variables
        source "$ENV_FILE"
        set +a

        log_info "Successfully loaded secrets from .env file"
        return 0
    else
        log_warn ".env file not found at $ENV_FILE"
        return 1
    fi
}

# Function to validate required secrets are set
validate_secrets() {
    log_info "Validating required secrets..."

    local missing_secrets=()

    for secret in "${REQUIRED_SECRETS[@]}"; do
        if [[ -z "${!secret}" ]]; then
            missing_secrets+=("$secret")
        fi
    done

    if [[ ${#missing_secrets[@]} -gt 0 ]]; then
        log_error "Missing required secrets:"
        for secret in "${missing_secrets[@]}"; do
            echo "  - $secret"
        done
        return 1
    fi

    log_info "All required secrets are present"
    return 0
}

# Function to export secrets to temporary file for docker
export_for_docker() {
    local temp_env_file="/tmp/discourse_secrets_$$.env"

    log_info "Exporting secrets for Docker container..."

    # Export all DISCOURSE_ variables
    env | grep "^DISCOURSE_" > "$temp_env_file"

    # Add other required variables
    echo "LETSENCRYPT_ACCOUNT_EMAIL=${LETSENCRYPT_ACCOUNT_EMAIL:-}" >> "$temp_env_file"

    echo "$temp_env_file"
}

# Main execution
main() {
    local source_used=""

    # Try AWS Secrets Manager first
    if load_from_aws; then
        source_used="AWS Secrets Manager"
    elif load_from_env_file; then
        source_used=".env file"
    else
        log_error "Failed to load secrets from any source"
        exit 1
    fi

    # Validate all required secrets are present
    if ! validate_secrets; then
        log_error "Secret validation failed"
        exit 1
    fi

    log_info "Secrets loaded successfully from: $source_used"

    # If called with --export flag, export to temporary file for docker
    if [[ "$1" == "--export" ]]; then
        export_for_docker
    fi
}

# Allow script to be sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
