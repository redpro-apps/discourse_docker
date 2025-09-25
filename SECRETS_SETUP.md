# Discourse Dual Secrets Management Strategy

This setup implements a dual secrets management strategy that prioritizes AWS Secrets Manager in production environments while providing `.env` file fallback for development and disaster recovery scenarios.

## Overview

The system works as follows:
1. **AWS Secrets Manager** (Primary for production)
2. **`.env` file** (Fallback for development/local)
3. **Default values** (For non-critical settings)

## Quick Start

### For Development (Local .env)

1. **Copy the template:**
   ```bash
   cp .env.example .env
   ```

2. **Edit your secrets:**
   ```bash
   nano .env
   # Configure your actual values
   ```

3. **Validate setup:**
   ```bash
   ./scripts/validate-config.sh
   ```

4. **Test with launcher:**
   ```bash
   ./launcher bootstrap app
   ```

### For Production (AWS Secrets Manager)

1. **Configure AWS credentials:**
   ```bash
   aws configure
   # or use IAM roles, environment variables, etc.
   ```

2. **Create .env with your secrets:**
   ```bash
   cp .env.example .env
   nano .env  # Add real production values
   ```

3. **Push secrets to AWS:**
   ```bash
   ./scripts/setup-secrets.sh --create --from-env
   ```

4. **Remove local .env (optional but recommended):**
   ```bash
   rm .env  # Secrets now loaded from AWS
   ```

5. **Test the setup:**
   ```bash
   ./scripts/validate-config.sh
   ./launcher bootstrap app
   ```

## Scripts Reference

### `scripts/load_secrets.sh`
Core secrets loading logic with fallback strategy.

### `scripts/setup-secrets.sh`
Manage secrets in AWS Secrets Manager.

```bash
# Create secret in AWS from .env
./scripts/setup-secrets.sh --create --from-env

# Update existing secret
./scripts/setup-secrets.sh --update --from-env

# Preview what would be uploaded
./scripts/setup-secrets.sh --create --from-env --dry-run
```

### `scripts/sync-secrets.sh`
Synchronize secrets between .env and AWS.

```bash
# Push .env to AWS (with backup)
./scripts/sync-secrets.sh push --backup

# Pull AWS secrets to .env
./scripts/sync-secrets.sh pull --force

# Compare secrets between sources
./scripts/sync-secrets.sh compare

# Create backup of current secrets
./scripts/sync-secrets.sh backup
```

### `scripts/validate-config.sh`
Validate the entire setup.

```bash
# Run all validation checks
./scripts/validate-config.sh

# Verbose output
./scripts/validate-config.sh --verbose
```

## Environment Variables

### Required Variables
- `DISCOURSE_HOSTNAME` - Your domain name
- `DISCOURSE_DEVELOPER_EMAILS` - Admin emails
- `DISCOURSE_SMTP_ADDRESS` - SMTP server address
- `DISCOURSE_SMTP_USER_NAME` - SMTP username
- `DISCOURSE_SMTP_PASSWORD` - SMTP password

### Optional Variables
- `DISCOURSE_SMTP_PORT` (default: 587)
- `DISCOURSE_SMTP_ENABLE_START_TLS` (default: true)
- `LETSENCRYPT_ACCOUNT_EMAIL` - For SSL certificates
- `DISCOURSE_MAXMIND_LICENSE_KEY` - For IP geolocation
- `DISCOURSE_CDN_URL` - CDN configuration

### AWS Configuration
- `AWS_DEFAULT_REGION` (default: us-east-1)
- `AWS_SECRET_NAME` (default: discourse/production)

## File Structure

```
/var/discourse/
├── scripts/
│   ├── load_secrets.sh         # Core loading logic
│   ├── setup-secrets.sh        # AWS Secrets Manager setup
│   ├── sync-secrets.sh         # Sync between sources
│   └── validate-config.sh      # Validation script
├── .env                        # Local secrets (gitignored)
├── .env.example               # Template for secrets
├── .env.local.example         # Development template
├── containers/app.yml         # Modified to use env vars
├── launcher                   # Modified with secrets loading
└── SECRETS_SETUP.md          # This file
```

## How It Works

1. **Launcher Integration**: The `launcher` script calls `load_discourse_secrets()` before processing configurations.

2. **Fallback Strategy**: 
   - Try AWS Secrets Manager first
   - Fall back to `.env` file if AWS fails
   - Use default values from `app.yml` if both fail

3. **Environment Variable Substitution**: The `app.yml` file uses `${VAR_NAME:-default}` syntax for dynamic values.

## Security Best Practices

### File Permissions
```bash
chmod 600 .env                    # Restrict .env access
chmod 755 scripts/*.sh           # Make scripts executable
```

### AWS IAM Policy
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue",
                "secretsmanager:DescribeSecret"
            ],
            "Resource": "arn:aws:secretsmanager:*:*:secret:discourse/production-*"
        }
    ]
}
```

### Git Configuration
The `.gitignore` file has been updated to exclude:
- `.env`
- `.env.local`
- `.env.production`
- `.env.*.local`
- `secrets-backup-*.json`

## Troubleshooting

### Common Issues

1. **"Secrets loading script not found"**
   - Ensure scripts are executable: `chmod +x scripts/*.sh`

2. **"AWS credentials not configured"**
   - Run `aws configure` or set up IAM roles

3. **"Missing required secrets"**
   - Check `.env` file has all required variables
   - Validate with `./scripts/validate-config.sh`

4. **"Permission denied" errors**
   - Set proper file permissions: `chmod 600 .env`
   - Ensure scripts are executable

### Debug Mode
Add `DEBUG=1` to see detailed loading information:
```bash
DEBUG=1 ./launcher bootstrap app
```

## Migration from Hardcoded Values

If you have an existing `app.yml` with hardcoded values:

1. **Backup your current config:**
   ```bash
   cp containers/app.yml containers/app.yml.backup
   ```

2. **Extract secrets to .env:**
   ```bash
   # Create .env with your current values
   echo "DISCOURSE_HOSTNAME=your-domain.com" >> .env
   echo "DISCOURSE_DEVELOPER_EMAILS=admin@your-domain.com" >> .env
   # ... add other secrets
   ```

3. **The new app.yml already uses environment variables**, so your secrets will be loaded automatically.

## Support

For issues or questions:
1. Run `./scripts/validate-config.sh` to check your setup
2. Check the logs during launcher execution
3. Verify AWS credentials and permissions
4. Ensure all required environment variables are set

---

**Security Note**: Never commit `.env` files or expose secrets in logs or version control. This dual strategy provides both security and operational flexibility for your Discourse deployment.
