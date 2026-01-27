# GitHub Repository Setup

## Create GitHub Repository

### Option 1: Using GitHub CLI (gh)

```bash
# Install gh if not already installed (macOS)
brew install gh

# Authenticate with GitHub
gh auth login

# Create repository
gh repo create worxco/cf-scalable-web \
  --public \
  --description "Scalable AWS infrastructure for Drupal/WordPress hosting using CloudFormation" \
  --source=. \
  --remote=origin \
  --push

# Verify
gh repo view
```

### Option 2: Using GitHub Web UI

1. **Go to GitHub:** https://github.com/new

2. **Repository Details:**
   - **Owner:** worxco (or your organization)
   - **Repository name:** `cf-scalable-web`
   - **Description:** Scalable AWS infrastructure for Drupal/WordPress hosting using CloudFormation
   - **Visibility:** Public (or Private if preferred)
   - **DO NOT** initialize with README, .gitignore, or license (we already have these)

3. **Create repository** (click button)

4. **Connect local repo to GitHub:**
   ```bash
   git remote add origin https://github.com/worxco/cf-scalable-web.git
   # or if using SSH:
   git remote add origin git@github.com:worxco/cf-scalable-web.git

   # Verify remote
   git remote -v

   # Push code
   git push -u origin main
   ```

5. **Verify on GitHub:**
   - Visit https://github.com/worxco/cf-scalable-web
   - Check that README.md displays correctly
   - Check that all files are present

## Repository Settings (Recommended)

### Branch Protection

```bash
# Enable branch protection for main (via gh cli)
gh api repos/worxco/cf-scalable-web/branches/main/protection \
  --method PUT \
  --field required_status_checks='{"strict":true,"contexts":[]}' \
  --field enforce_admins=true \
  --field required_pull_request_reviews='{"required_approving_review_count":1}' \
  --field restrictions=null
```

Or via GitHub UI:
1. Go to Settings → Branches
2. Add rule for `main` branch
3. Enable:
   - ✅ Require a pull request before merging
   - ✅ Require status checks to pass before merging
   - ✅ Require branches to be up to date before merging
   - ✅ Include administrators

### Topics (GitHub Tags)

```bash
gh repo edit --add-topic cloudformation
gh repo edit --add-topic aws
gh repo edit --add-topic drupal
gh repo edit --add-topic wordpress
gh repo edit --add-topic infrastructure-as-code
gh repo edit --add-topic terraform
gh repo edit --add-topic scalable
gh repo edit --add-topic devops
```

Or via GitHub UI:
1. Go to repository main page
2. Click gear icon next to "About"
3. Add topics: `cloudformation`, `aws`, `drupal`, `wordpress`, `infrastructure-as-code`, `scalable`, `devops`

### Issues & Projects

Enable GitHub Issues for bug tracking and feature requests:
1. Settings → Features
2. ✅ Issues

Optional: Create GitHub Project for roadmap tracking

### GitHub Actions (Future)

Create `.github/workflows/validate.yml` for CI/CD:

```yaml
name: Validate CloudFormation Templates

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install cfn-lint
        run: pip install cfn-lint

      - name: Validate templates
        run: make validate

      - name: Run tests
        run: make test
```

## Post-Push Checklist

- [ ] Repository created on GitHub
- [ ] Code pushed successfully
- [ ] README.md displays correctly
- [ ] All files present (19 files)
- [ ] Topics added
- [ ] Branch protection enabled (optional, recommended for teams)
- [ ] Issues enabled
- [ ] Add collaborators (if team project)
- [ ] Update repository URL in `.claude/settings.json` if different from default

## Clone URL for Others

Once published, others can clone with:

```bash
# HTTPS
git clone https://github.com/worxco/cf-scalable-web.git

# SSH
git clone git@github.com:worxco/cf-scalable-web.git
```

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
