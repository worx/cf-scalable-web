---
name: Admin access policy — SSM-only ingress, ever
description: The non-negotiable rule that SSM is the only inbound path to any instance, and the SSH-via-SSM-proxy pattern that supports scp/sftp without opening port 22
type: project
created: 2026-05-19
---
# Admin access policy

## The rule

**SSM Session Manager is the only inbound path to any instance in this
project. Every environment. Always. No exceptions.**

This applies to deploy-host, the compute fleet (nginx, php-fpm), and any
future operator machines. No security group ever has port 22 (or any
inbound port other than the documented ALB targets) open from anywhere.

## Why this rule exists (and why "just for testing" isn't an exception)

If sandbox has port 22 open and production doesn't, sandbox is no longer
testing production's access model. Whatever convenience you gain from
SSH-in-sandbox-only, you lose by having a deployment topology that
diverges from prod in a way that *can* break things at promotion time.
The whole point of sandbox is to exercise the production failure modes,
including the ones that show up under "SSM is the only way in."

## SSH keys + scp without violating the rule

You can still run `scp` and `sftp` against instances using SSH-as-a-protocol
while SSM remains the only network ingress. The trick is `AWS-StartSSHSession`,
an SSM document that establishes a TCP forward to port 22 on the instance
*through* the existing SSM session — never crossing the security group.

The pieces:

1. **SG**: port 22 stays closed to all sources (no change).
2. **sshd**: running on the instance, listening on 127.0.0.1:22 or on
   all interfaces — doesn't matter, the SG blocks external traffic
   either way.
3. **authorized_keys**: contains the admin public key(s).
4. **Local `~/.ssh/config`**:
   ```
   Host i-* mi-*
     ProxyCommand sh -c "aws ssm start-session --target %h \
       --document-name AWS-StartSSHSession \
       --parameters 'portNumber=%p'"
   ```
5. **scp / sftp / rsync just work**:
   ```
   scp ./file.txt i-0d4b97b4f7735a360:/tmp/
   rsync -avz ./dir/ i-0d4b97b4f7735a360:/var/www/staging/
   ```

The auth handshake (key verification) happens over the SSM tunnel.
Anyone who tries to `ssh i-... -p 22` directly without SSM gets nothing
because the SG drops the packet.

## Where the admin public keys live (proposed)

SSM Parameter Store at `/worxco/admin/ssh-public-keys` (StringList,
newline-separated). Public keys aren't secret, but the *list of who
gets access* is sensitive — IAM policy on this path matters:

- Write: admin-only role
- Read: only the specific instance roles that install the keys
  (currently `cf-deploy-host`)

## Gating which instances install the keys

By **stack type**, not by parameter:

- `cf-deploy-host` (and any future "operator" boxes): UserData reads the
  SSM path and writes the keys to `~/.ssh/authorized_keys` for the
  ubuntu user.
- Compute templates (`cf-compute-nginx`, `cf-compute-php`): UserData
  does *not* reference the SSM path. No code path exists for keys to
  land on a compute box, by which I mean: there is no parameter to flip
  the wrong way.

Security by exclusion is more robust than security by parameter
defaults. Compute templates physically cannot install the keys because
the code that would do so doesn't exist in their UserData.

## What this is NOT

- This is NOT for terminal SSH sessions. Use SSM Session Manager for that
  (`aws ssm start-session --target i-...` or via the console).
- This is NOT for the compute fleet. Treating the fleet as SSM-only-for-
  everything is part of testing the production access model.
- This is NOT a "convenience flag" to be flipped per environment.
