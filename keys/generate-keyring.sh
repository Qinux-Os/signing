#!/usr/bin/env bash
#
# Generate or reuse the Qinux master signing key, and derive the pacman
# keyring files the signing package ships.
#
# This is run once, by whoever holds the signing key, on a machine that is not
# the build machine and not a machine that gets reinstalled. Everything else in
# the release process depends on it existing and being backed up.
#
# Usage:
#   ./generate-keyring.sh [KEYID]
#
#   KEYID   the key identity, as "Name <email>".
#           Defaults to the distribution identity below.
#
# Output, written next to this script:
#
#   qinux.gpg        public keyring, consumed by `pacman-key --populate qinux`
#   qinux-trusted    ownertrust, this key fully trusted (':4:')
#   qinux-revoked    revocation list, initially empty
#
# And, which must NOT be committed:
#
#   gnupg/           the private key. Losing it means nobody can sign a
#                    release again, and there is no recovery short of rotating
#                    every key in every user's keyring.

set -o errexit
set -o nounset
set -o pipefail

readonly KEYID="${1:-Qinux Packaging <packaging@qinux-os.org>}"

startdir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export GNUPGHOME="$startdir/gnupg"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v gpg >/dev/null 2>&1 || die "gpg is not installed"

# Validate before splitting. A KEYID with no angle brackets would make the
# parameter expansions below produce two copies of the input rather than an
# error, and the generated key would silently have the wrong name.
if [[ "$KEYID" != *'<'* || "$KEYID" != *'>'* ]]; then
    die "KEYID must look like 'Name <email>', got: $KEYID"
fi
# Both are computed in one expansion each. Re-declaring a variable readonly
# after it is already readonly is an error in bash, so the angle bracket cannot
# be stripped in a second step.
readonly NAME_REAL="${KEYID%% <*}"
readonly NAME_EMAIL="${KEYID#*<}"
NAME_EMAIL="${NAME_EMAIL%%>*}"
readonly NAME_EMAIL

mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

# --- The master key -------------------------------------------------------
#
# RSA 4096, no expiry. No expiry is deliberate and it is a risk: an expiry
# means that on the day it passes, no user can install anything until they
# update a keyring nobody is updating any more. The key is protected by being
# offline and backed up, not by a date.

if ! gpg --batch --list-keys "$KEYID" >/dev/null 2>&1; then
    log "generating master key: $KEYID"

    if [[ -e "$GNUPGHOME/trustdb.gpg" ]]; then
        die "a keyring already exists but the key '$KEYID' is not in it; refusing to overwrite"
    fi

    gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${NAME_REAL}
Name-Email: ${NAME_EMAIL}
Expire-Date: 0
%commit
EOF
else
    log "reusing existing master key: $KEYID"
fi

fpr="$(gpg --batch --with-colons --list-keys "$KEYID" \
        | awk -F: '/^fpr:/ {print $10; exit}')"
[[ -n "$fpr" ]] || die "could not read the fingerprint of '$KEYID'"

log "fingerprint: $fpr"

# --- Derived files --------------------------------------------------------
#
# Written with --yes so re-running overwrites rather than failing on an
# existing file, which is what makes this script re-runnable.

log "exporting public keyring"
gpg --batch --yes --output "$startdir/qinux.gpg" --export "$KEYID"

# Ownertrust fully trusts our own master key. ':4:' is "ultimate" in the
# gpg trust model. This is only correct because the key is ours: the file must
# never contain trust for anyone else's key.
log "writing ownertrust"
printf '%s:4:\n' "$fpr" > "$startdir/qinux-trusted"

# An empty revocation list is what makes `pacman-key --populate qinux` succeed
# on a machine with nothing revoked.
log "writing revocation list"
: > "$startdir/qinux-revoked"

# --- Guard ----------------------------------------------------------------

if grep -q . "$startdir/.gitignore" 2>/dev/null \
   && ! grep -qx 'gnupg/' "$startdir/.gitignore"; then
    log "NOTE: gnupg/ is not in .gitignore; add it before committing anything here"
fi

log ""
log "Wrote qinux.gpg, qinux-trusted and qinux-revoked in $startdir"
log ""
log "BACK UP $GNUPGHOME NOW. Losing it means no further release can be signed."
log "It must never be committed, and never copied onto a build machine."