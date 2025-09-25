#!/usr/bin/env bash
#
# Secrets Synchronization Script
# Sync secrets between .env file and AWS Secrets Manager
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DISCOURSE_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$DISCOURSE_DIR/.env"
BACKUP_DIR="$DISCOURSE_DIR/secrets-backup"

# AWS Configuration
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
    echo "Usage: $0 [OPTIONS] ACTION"
    echo ""
    echo "Actions:"
    echo "  push        Push secrets from .env to AWS Secrets Manager"
    echo "  pull        Pull secrets from AWS Secrets Manager to .env"
    echo "  backup      Create backup of current secrets"
    echo "  compare     Compare secrets between .env and AWS"
    echo ""
    echo "Options:"
    echo "  --dry-run   Show what would be done without executing"
    echo "  --force     Skip confirmation prompts"
    echo "  --backup    Create backup before making changes"
    echo "  --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 push --backup       # Push .env to AWS with backup"
    echo "  $0 pull --dry-run      # Preview pulling from AWS"
    echo "  $0 compare             # Compare current secrets"
}

check_prerequisites() {
    local missing_tools=()

    # Check required tools
    for tool in aws jq; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

create_backup() {
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup .env file if it exists
    if [[ -f "$ENV_FILE" ]]; then
        cp "$ENV_FILE" "$BACKUP_DIR/.env.backup.$backup_timestamp"
        log_info "Created .env backup: .env.backup.$backup_timestamp"
    fi
    
    # Backup AWS secrets if they exist
    if aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" --region "$AWS_REGION" &> /dev/null; then
        local secret_value=$(aws secretsmanager get-secret-value \
            --secret-id "$AWS_SECRET_NAME" \
            --region "$AWS_REGION" \
            --query 'SecretString' \
            --output text 2>/dev/null)
        
        if [[ -n "$secret_value" ]]; then
            echo "$secret_value" > "$BACKUP_DIR/aws-secrets.backup.$backup_timestamp.json"
            log_info "Created AWS secrets backup: aws-secrets.backup.$backup_timestamp.json"
        fi
    fi
}

load_env_secrets() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env file not found at $ENV_FILE"
        return 1
    fi

    local env_secrets="{}"
    
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        
        # Remove quotes from value if present
        value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
        
        # Add to JSON object
        env_secrets=$(echo "$env_secrets" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
        
    done < <(grep -E '^[A-Z_]+=.*' "$ENV_FILE")

    echo "$env_secrets"
}

load_aws_secrets() {
    if ! aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" --region "$AWS_REGION" &> /dev/null; then
        log_warn "AWS secret '$AWS_SECRET_NAME' does not exist"
        echo "{}"
        return
    fi

    local secret_value=$(aws secretsmanager get-secret-value \
        --secret-id "$AWS_SECRET_NAME" \
        --region "$AWS_REGION" \
        --query 'SecretString' \
        --output text 2>/dev/null)

    if [[ -n "$secret_value" ]]; then
        echo "$secret_value"
    else
        echo "{}"
    fi
}

push_secrets() {
    local dry_run="$1"
    
    log_info "Pushing secrets from .env to AWS Secrets Manager..."
    
    local env_secrets
    env_secrets=$(load_env_secrets)
    
    if [[ "$env_secrets" == "{}" ]]; then
        log_error "No secrets found in .env file"
        return 1
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        log_debug "DRY RUN: Would push the following secrets to AWS:"
        echo "$env_secrets" | jq .
        return
    fi
    
    # Check if secret exists
    if aws secretsmanager describe-secret --secret-id "$AWS_SECRET_NAME" --region "$AWS_REGION" &> /dev/null; then
        # Update existing secret
        aws secretsmanager update-secret \
            --secret-id "$AWS_SECRET_NAME" \
            --secret-string "$env_secrets" \
            --region "$AWS_REGION" > /dev/null
        log_info "Updated existing AWS secret"
    else
        # Create new secret
        aws secretsmanager create-secret \
            --name "$AWS_SECRET_NAME" \
            --description "Discourse production secrets (synced from .env)" \
            --secret-string "$env_secrets" \
            --region "$AWS_REGION" > /dev/null
        log_info "Created new AWS secret"
    fi
}

pull_secrets() {
    local dry_run="$1"
    local force="$2"
    
    log_info "Pulling secrets from AWS Secrets Manager to .env..."
    
    local aws_secrets
    aws_secrets=$(load_aws_secrets)
    
    if [[ "$aws_secrets" == "{}" ]]; then
        log_error "No secrets found in AWS Secrets Manager"
        return 1
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        log_debug "DRY RUN: Would create .env file with the following secrets:"
        echo "$aws_secrets" | jq -r 'to_entries[] | "\(.key)=\(.value)"' | head -10
        return
    fi
    
    # Check if .env already exists
    if [[ -f "$ENV_FILE" && "$force" != "true" ]]; then
        log_warn ".env file already exists. Use --force to overwrite."
        return 1
    fi
    
    # Create .env file
    echo "$aws_secrets" | jq -r 'to_entries[] | "\(.key)=\(.value)"' > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    
    log_info "Created .env file with secrets from AWS"
}

compare_secrets() {
    log_info "Comparing secrets between .env and AWS Secrets Manager..."
    
    local env_secrets aws_secrets
    
    if [[ -f "$ENV_FILE" ]]; then
        env_secrets=$(load_env_secrets)
        log_debug "Found $(echo "$env_secrets" | jq 'keys | length') secrets in .env file"
    else
        env_secrets="{}"
        log_warn ".env file not found"
    fi
    
    aws_secrets=$(load_aws_secrets)
    if [[ "$aws_secrets" != "{}" ]]; then
        log_debug "Found $(echo "$aws_secrets" | jq 'keys | length') secrets in AWS"
    else
        log_warn "No secrets found in AWS Secrets Manager"
    fi
    
    # Find differences
    local env_only aws_only different
    
    env_only=$(echo "$env_secrets $aws_secrets" | jq -s '.[0] - .[1] | keys[]' 2>/dev/null | tr -d '"' || true)
    aws_only=$(echo "$aws_secrets $env_secrets" | jq -s '.[0] - .[1] | keys[]' 2>/dev/null | tr -d '"' || true)
    
    echo ""
    echo "=== Comparison Results ==="
    
    if [[ -n "$env_only" ]]; then
        echo "Secrets only in .env:"
        echo "$env_only" | sed 's/^/  - /'
    fi
    
    if [[ -n "$aws_only" ]]; then
        echo "Secrets only in AWS:"
        echo "$aws_only" | sed 's/^/  - /'
    fi
    
    if [[ -z "$env_only" && -z "$aws_only" ]]; then
        log_info "Secrets are in sync between .env and AWS"
    fi
}

main() {
    local action=""
    local dry_run=false
    local force=false
    local backup=false

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            push|pull|backup|compare)
                action="$1"
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --force)
                force=true
                shift
                ;;
            --backup)
                backup=true
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

    if [[ -z "$action" ]]; then
        log_error "Must specify an action"
        usage
        exit 1
    fi

    check_prerequisites

    # Create backup if requested
    if [[ "$backup" == true ]]; then
        create_backup
    fi

    # Perform the requested action
    case $action in
        push)
            push_secrets "$dry_run"
            ;;
        pull)
            pull_secrets "$dry_run" "$force"
            ;;
        backup)
            create_backup
            ;;
        compare)
            compare_secrets
            ;;
    esac

    if [[ "$dry_run" != true ]]; then
        log_info "Operation '$action' completed successfully"
    fi
}

main "$@"
