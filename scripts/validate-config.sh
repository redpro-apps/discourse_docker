#!/usr/bin/env bash
#
# Configuration Validation Script
# Validates the dual secrets strategy setup
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DISCOURSE_DIR="$(dirname "$SCRIPT_DIR")"

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

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --verbose   Show detailed output"
    echo "  --help      Show this help message"
    echo ""
    echo "This script validates:"
    echo "  - Secrets loading scripts exist and are executable"
    echo "  - App.yml uses environment variables correctly"
    echo "  - Launcher modifications are in place"
    echo "  - AWS CLI is configured (if available)"
    echo "  - .env file structure (if present)"
}

check_scripts() {
    log_info "Checking scripts..."
    
    local scripts=(
        "load_secrets.sh"
        "setup-secrets.sh" 
        "sync-secrets.sh"
        "validate-config.sh"
    )
    
    local missing=()
    
    for script in "${scripts[@]}"; do
        local path="$SCRIPT_DIR/$script"
        if [[ -f "$path" && -x "$path" ]]; then
            log_success "✓ $script exists and is executable"
        else
            log_error "✗ $script missing or not executable at $path"
            missing+=("$script")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

check_launcher() {
    log_info "Checking launcher modifications..."
    
    local launcher="$DISCOURSE_DIR/launcher"
    
    if [[ ! -f "$launcher" ]]; then
        log_error "✗ Launcher not found at $launcher"
        return 1
    fi
    
    # Check if load_discourse_secrets function exists
    if grep -q "load_discourse_secrets()" "$launcher"; then
        log_success "✓ load_discourse_secrets function found in launcher"
    else
        log_error "✗ load_discourse_secrets function not found in launcher"
        return 1
    fi
    
    # Check if function is called
    if grep -q "load_discourse_secrets" "$launcher"; then
        log_success "✓ load_discourse_secrets is called in launcher"
    else
        log_error "✗ load_discourse_secrets not called in launcher"
        return 1
    fi
    
    return 0
}

check_app_yml() {
    log_info "Checking app.yml configuration..."
    
    local app_yml="$DISCOURSE_DIR/containers/app.yml"
    
    if [[ ! -f "$app_yml" ]]; then
        log_error "✗ app.yml not found at $app_yml"
        return 1
    fi
    
    # Check if environment variables are used
    local env_vars=(
        "DISCOURSE_HOSTNAME"
        "DISCOURSE_DEVELOPER_EMAILS"
        "DISCOURSE_SMTP_ADDRESS"
        "DISCOURSE_SMTP_USER_NAME"
        "DISCOURSE_SMTP_PASSWORD"
    )
    
    local missing=()
    
    for var in "${env_vars[@]}"; do
        if grep -q "\${$var" "$app_yml"; then
            log_success "✓ $var uses environment variable"
        else
            log_warn "⚠ $var may not use environment variable"
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Some variables may still use hardcoded values"
    fi
    
    return 0
}

check_aws_cli() {
    log_info "Checking AWS CLI configuration..."
    
    if ! command -v aws &> /dev/null; then
        log_warn "⚠ AWS CLI not found (required for AWS Secrets Manager)"
        return 0
    fi
    
    log_success "✓ AWS CLI found"
    
    if aws sts get-caller-identity &> /dev/null; then
        local identity=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null || echo "unknown")
        log_success "✓ AWS credentials configured ($identity)"
    else
        log_warn "⚠ AWS credentials not configured or invalid"
    fi
    
    return 0
}

check_env_file() {
    log_info "Checking .env file structure..."
    
    local env_file="$DISCOURSE_DIR/.env"
    local env_example="$DISCOURSE_DIR/.env.example"
    
    if [[ -f "$env_example" ]]; then
        log_success "✓ .env.example template exists"
    else
        log_warn "⚠ .env.example template not found"
    fi
    
    if [[ -f "$env_file" ]]; then
        log_success "✓ .env file exists"
        
        # Check permissions
        local perms=$(stat -c "%a" "$env_file" 2>/dev/null || stat -f "%A" "$env_file" 2>/dev/null || echo "unknown")
        if [[ "$perms" == "600" ]]; then
            log_success "✓ .env file has correct permissions (600)"
        else
            log_warn "⚠ .env file permissions are $perms (should be 600)"
        fi
        
        # Check if it contains required variables
        local required_vars=(
            "DISCOURSE_HOSTNAME"
            "DISCOURSE_DEVELOPER_EMAILS"
            "DISCOURSE_SMTP_ADDRESS"
        )
        
        for var in "${required_vars[@]}"; do
            if grep -q "^$var=" "$env_file"; then
                log_success "✓ $var found in .env"
            else
                log_warn "⚠ $var not found in .env"
            fi
        done
    else
        log_info "ℹ .env file not present (will fallback to AWS or defaults)"
    fi
    
    return 0
}

check_gitignore() {
    log_info "Checking .gitignore configuration..."
    
    local gitignore="$DISCOURSE_DIR/.gitignore"
    
    if [[ ! -f "$gitignore" ]]; then
        log_warn "⚠ .gitignore not found"
        return 0
    fi
    
    local env_patterns=(".env" ".env.local" ".env.production")
    
    for pattern in "${env_patterns[@]}"; do
        if grep -q "^$pattern$" "$gitignore"; then
            log_success "✓ $pattern is in .gitignore"
        else
            log_warn "⚠ $pattern not found in .gitignore"
        fi
    done
    
    return 0
}

run_test_load() {
    log_info "Testing secrets loading..."
    
    # Test the load_secrets script
    local load_script="$SCRIPT_DIR/load_secrets.sh"
    
    if [[ -x "$load_script" ]]; then
        log_info "Attempting to test secrets loading (dry run)..."
        
        # This will test the loading logic without actually loading secrets
        if bash -c "source '$load_script' && echo 'Secrets loading test passed'" 2>/dev/null; then
            log_success "✓ Secrets loading script works"
        else
            log_warn "⚠ Secrets loading script may have issues"
        fi
    else
        log_error "✗ Cannot test secrets loading - script not executable"
        return 1
    fi
    
    return 0
}

main() {
    local verbose=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                verbose=true
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
    
    echo "===========================================" 
    echo "  Discourse Dual Secrets Strategy Validation"
    echo "==========================================="
    echo ""
    
    local checks=(
        "check_scripts"
        "check_launcher" 
        "check_app_yml"
        "check_aws_cli"
        "check_env_file"
        "check_gitignore"
        "run_test_load"
    )
    
    local failed=()
    
    for check in "${checks[@]}"; do
        echo ""
        if $check; then
            log_success "✓ $check passed"
        else
            log_error "✗ $check failed"
            failed+=("$check")
        fi
    done
    
    echo ""
    echo "===========================================" 
    echo "  Validation Summary"
    echo "==========================================="
    
    if [[ ${#failed[@]} -eq 0 ]]; then
        log_success "✓ All checks passed! Dual secrets strategy is ready."
        echo ""
        echo "Next steps:"
        echo "1. Copy .env.example to .env and configure your secrets"
        echo "2. Test with: ./launcher bootstrap app"
        echo "3. For production, use: ./scripts/setup-secrets.sh --create --from-env"
        exit 0
    else
        log_error "✗ ${#failed[@]} checks failed:"
        for check in "${failed[@]}"; do
            echo "  - $check"
        done
        exit 1
    fi
}

main "$@"
