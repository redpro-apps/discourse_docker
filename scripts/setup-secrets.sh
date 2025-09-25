#!/usr/bin/env bash
#
# AWS Secrets Manager Setup Script
# Creates or updates secrets in AWS Secrets Manager from .env file
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DISCOURSE_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$DISCOURSE_DIR/.env"

# AWS Secrets Manager configuration
AWS_SECRET_NAME="discourse/production"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --create        Create new secret in AWS Secrets Manager"
    echo "  --update        Update existing secret in AWS Secrets Manager"
    echo "  --from-env      Use local .env file as source"
    echo "  --dry-run       Show what would be done without executing"
    echo "  --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --create --from-env    # Create secret from .env file"
    echo "  $0 --update --from-env    # Update existing secret from .env file"
    echo "  $0 --dry-run --from-env   # Preview what would be uploaded"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is required but not installed"
        exit 1
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        log_info "Please run 'aws configure' or set AWS environment variables"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

load_env_file() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env file not found at $ENV_FILE"
        log_info "Please create a .env file with your secrets"
        exit 1
    fi

    log_info "Loading secrets from $ENV_FILE"

    # Create JSON object from .env file
    local json_secrets="{}"
    
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        
        # Remove quotes from value if present
        value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
        
        # Add to JSON object
        json_secrets=$(echo "$json_secrets" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
        
    done < <(grep -E '^[A-Z_]+=.*' "$ENV_FILE")

    echo "$json_secrets"
}

create_secret() {
    local secrets_json="$1"
    local dry_run="$2"

    log_info "Creating new secret '$AWS_SECRET_NAME' in AWS Secrets Manager..."

    if [[ "$dry_run" == "true" ]]; then
        log_debug "DRY RUN: Would create secret with the following data:"
        echo "$secrets_json" | jq .
        return
    fi

    # Check if secret already exists
    if aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" --region "$AWS_REGION" &> /dev/null; then
        log_error "Secret '$AWS_SECRET_NAME' already exists. Use --update to modify it."
        exit 1
    fi

    # Create the secret
    aws secretsmanager create-secret \
        --name "$AWS_SECRET_NAME" \
        --description "Discourse production secrets" \
        --secret-string "$secrets_json" \
        --region "$AWS_REGION" > /dev/null

    log_info "Secret '$AWS_SECRET_NAME' created successfully"
}

update_secret() {
    local secrets_json="$1"
    local dry_run="$2"

    log_info "Updating secret '$AWS_SECRET_NAME' in AWS Secrets Manager..."

    if [[ "$dry_run" == "true" ]]; then
        log_debug "DRY RUN: Would update secret with the following data:"
        echo "$secrets_json" | jq .
        return
    fi

    # Check if secret exists
    if ! aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" --region "$AWS_REGION" &> /dev/null; then
        log_error "Secret '$AWS_SECRET_NAME' does not exist. Use --create to create it."
        exit 1
    fi

    # Update the secret
    aws secretsmanager update-secret \
        --secret-id "$AWS_SECRET_NAME" \
        --secret-string "$secrets_json" \
        --region "$AWS_REGION" > /dev/null

    log_info "Secret '$AWS_SECRET_NAME' updated successfully"
}

main() {
    local action=""
    local from_env=false
    local dry_run=false

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --create)
                action="create"
                shift
                ;;
            --update)
                action="update"
                shift
                ;;
            --from-env)
                from_env=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Validate arguments
    if [[ -z "$action" ]]; then
        log_error "Must specify --create or --update"
        usage
        exit 1
    fi

    if [[ "$from_env" != true ]]; then
        log_error "Must specify --from-env"
        usage
        exit 1
    fi

    check_prerequisites

    # Load secrets from .env file
    local secrets_json
    secrets_json=$(load_env_file)

    # Perform the requested action
    case $action in
        create)
            create_secret "$secrets_json" "$dry_run"
            ;;
        update)
            update_secret "$secrets_json" "$dry_run"
            ;;
    esac

    if [[ "$dry_run" != true ]]; then
        log_info "Operation completed successfully"
        log_info "You can now use the dual secrets loading strategy"
    fi
}

main "$@"
