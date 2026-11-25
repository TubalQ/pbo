# shellcheck shell=bash
# lib/perms.sh: the permission rule table and the engine that checks or applies
# it (0.6 M6, ADR 0009 "Permissions"). doctor runs it with --check, `pbo
# doctor --fix` with --fix, every backup with --fix --only CACHE_DIR:dir
# (_cache_dir_protect in lib/common.sh), install.sh through `pbo doctor --fix
# --perms-only`.
#
# Rule format (_perm_rules), one per line:
#   NAME|KIND|OWNER|GROUP|MODE|ACL|CLASS|WHY
# NAME   where the path comes from: a config key (CACHE_DIR), KEY/<sub> for a
#        path below its value (PVE_SPOOL_DIR/dump), KEY/.. for the directory
#        its value is in (METRICS_FILE/..), config and config/.. for the local
#        config file and its directory, config-shared for the cluster-shared
#        one. `--only NAME` (or NAME:KIND) selects rules.
# KIND   dir, file, files (the regular files directly in the directory; the
#        symlinks there are left alone), parents (each directory above the
#        path), keys (a config file: which keys it sets)
# OWNER  root, a user name or -; a trailing ? means reported, never changed
# GROUP  a group name or -
# MODE   0700 exact; 0600/0400 any of these (a fix sets the first); <0750 no
#        bit outside these (a fix clears the others); - any
# ACL    ct-roots: an entry u:<uid>:--x for the mapped root of every
#        unprivileged CT on this node (_ct_root_uid); - none
# CLASS  fix (doctor --fix changes it), ask (only with --fix-parents), check
#        (reported only)
# WHY    shown with a finding
#
# Nothing here names a path: every path is a config value (or its default in
# lib/config_schema.sh). A rule only applies to a path that exists; M6 creates
# nothing.

# _perm_rules [role]: the table for host or janitor (default: PBO_ROLE).
_perm_rules() {
    local role="${1:-${PBO_ROLE:-host}}"
    if [[ "$role" == janitor ]]; then
        # The janitor runs as JANITOR_USER: it owns its own directories, and
        # reads the config through the group named like it. That is the group
        # install.sh gives the config and pbo-janitor.service runs as (Group=);
        # the user's primary group can be one other daemons share (adduser
        # --system makes it nogroup), which would hand them the config.
        local ju="${JANITOR_USER:-restic}" jg
        jg="$ju"
        printf '%s\n' \
            "CACHE_DIR|dir|$ju|-|<0750|-|fix|the janitor's cache, written as $ju" \
            "LOG_DIR|dir|$ju|-|0755|-|fix|the janitor writes its logs as $ju" \
            "LOG_FILE|file|$ju|-|0600|-|fix|repo paths, guest names and errors" \
            "AUDIT_FILE|file|$ju|-|0600|-|fix|who did what" \
            "AUDIT_JSON|file|$ju|-|0600|-|fix|who did what" \
            "STATE_DIR|dir|$ju|-|0755|-|fix|the janitor keeps its state as $ju" \
            "LOCK_DIR|dir|$ju|-|0700|-|fix|a user who can write here can pre-create or hold the janitor's locks" \
            "RESTIC_CACHE_DIR|dir|$ju|-|0700|-|fix|restic's metadata cache (snapshot paths, tags, file names)" \
            "config/..|dir|root|$jg|0750|-|fix|root writes the config, $ju only reads it" \
            "config|file|root|$jg|0640|-|fix|root writes the config, $ju only reads it" \
            "RESTIC_PASSWORD_FILE|file|$ju|-|0400/0600|-|fix|the DR key: whoever reads it can decrypt every backup" \
            "RESTIC_ENV_FILE|file|$ju|-|0400/0600|-|fix|the backend credentials restic gets (S3, B2, Azure, GCS, rclone)" \
            "NTFY_CREDS_FILE|file|$ju|-|<0640|-|fix|the ntfy credentials (group-readable is allowed: other tools may share the file)"
        return 0
    fi
    printf '%s\n' \
        "CACHE_DIR|dir|root|-|<0750|ct-roots|fix|plaintext vzdump archives lie here while a backup runs; an unprivileged CT's vzdump runs tar as its mapped root, which passes through an ACL entry" \
        "CACHE_DIR|parents|-|-|-|ct-roots|ask|vzdump of an unprivileged CT runs tar as its mapped root, which must pass every directory above CACHE_DIR" \
        "RESTIC_CACHE_REPO|dir|-|-|<0770|-|fix|the cache repo: other users must not read it (restic creates it 0700)" \
        "PVE_SPOOL_DIR|dir|root|-|0755|-|fix|PVE backup jobs write here; an unprivileged CT's vzdump passes it as the CT's mapped root" \
        "PVE_SPOOL_DIR/dump|dir|root|-|0755|-|fix|PVE backup jobs write here; an unprivileged CT's vzdump passes it as the CT's mapped root" \
        "PVE_STAGING_DIR|dir|root|-|0700|-|fix|archives staged for a restore from the PVE GUI, in plaintext" \
        "PVE_STAGING_DIR|files|root|-|0600|-|fix|an archive staged for a restore from the PVE GUI, in plaintext" \
        "LOCK_DIR|dir|root|-|0700|-|fix|a user who can write here can pre-create or hold pbo's locks" \
        "LOG_DIR|dir|root|-|0755|-|fix|pbo and logrotate write here; the logs themselves are 0600" \
        "LOG_FILE|file|root|-|0600|-|fix|repo paths, guest names and errors" \
        "AUDIT_FILE|file|root|-|0600|-|fix|who did what" \
        "AUDIT_JSON|file|root|-|0600|-|fix|who did what" \
        "STATE_DIR|dir|root|-|0755|-|fix|the PVE storage plugin reads the catalogue below it" \
        "STATE_DIR/runs|dir|root|-|0750|-|fix|job logs and results" \
        "PBO_CATALOG/..|dir|root|-|0755|-|fix|the PVE storage plugin reads the catalogue" \
        "PBO_CATALOG|file|root|-|0644|-|fix|the PVE storage plugin reads the catalogue" \
        "RESTIC_CACHE_DIR|dir|root|-|0700|-|fix|restic's metadata cache (snapshot paths, tags, file names)" \
        "config/..|dir|root|-|0700|-|fix|the config directory also holds the DR key and credentials" \
        "config|file|root|-|0600|-|fix|its exec keys name programs root runs, and it can hold ntfy credentials" \
        "config-shared|keys|-|-|-|-|check|pmxcfs copies the cluster-shared config to every node" \
        "RESTIC_PASSWORD_FILE|file|root?|-|0600/0400|-|fix|the DR key: whoever reads it can decrypt every backup" \
        "RESTIC_REST_PASSWORD_FILE|file|root?|-|0600/0400|-|fix|the rest-server password" \
        "RESTIC_ENV_FILE|file|root?|-|0600/0400|-|fix|the backend credentials restic gets (S3, B2, Azure, GCS, rclone)" \
        "NTFY_CREDS_FILE|file|root?|-|<0640|-|fix|the ntfy credentials (group-readable is allowed: other tools may share the file)" \
        "PVE_CATALOG_MOUNT_DIR/..|dir|root|-|<0700|-|check|the cache repo is mounted below it with allow_other: only root may enter"
    [[ "${METRICS_ENABLED:-true}" != true ]] \
        || printf '%s\n' "METRICS_FILE/..|dir|root|-|-|-|check|pbo writes the metrics textfile there as root and refuses a directory root does not own"
}

# Directories the system shares. A rule never checks or changes one (a config
# could point LOCK_DIR at /var/lock, or the config at /etc/pbo.conf); a
# world-writable one is named. A sticky directory counts too (/tmp-like).
readonly PERM_SYSTEM_DIRS=' / /bin /boot /dev /etc /etc/pve /home /lib /lib64 /media /mnt /opt /proc /root /run /run/lock /sbin /srv /sys /tmp /usr /usr/local /var /var/cache /var/lib /var/lock /var/log /var/run /var/tmp '

# Findings: PERM_FINDINGS ("<level>\t<name:kind>\t<path>\t<message>", level ok,
# warn or fail); changes: PERM_CHANGES ("<name>\t<path>\t<what>\t<from>\t<to>\t
# <applied 1|0>", what = mode, owner, group or acl); fixes that failed:
# PERM_FIX_ERRORS (messages).
_perm_find() { PERM_FINDINGS+=("$1"$'\t'"$_PERM_RULE"$'\t'"$2"$'\t'"$3"); }

_perm_dirname_r() { _PERM_D="${1%/*}"; [[ -n "$_PERM_D" ]] || _PERM_D=/; }

# _perm_path_r NAME: the rule's path into _PERM_P (empty: the rule does not apply).
_perm_path_r() {
    local n="$1" base sub="" v cfs="${PBO_PVE_CFS_DIR:-/etc/pve}"
    _PERM_P=""
    cfs="${cfs%/}"
    case "$n" in
        config|config/..)
            # the local file (PBO_CONFIG_LOCAL, set by load_config even when the
            # file does not exist); pmxcfs has its own modes
            v="${PBO_CONFIG_LOCAL:-}"
            if [[ -z "$v" ]]; then
                v="${PBO_CONFIG_LOADED:-}"
                [[ -n "$v" && "$v" != "${PBO_CONFIG_SHARED_LOADED:-}" ]] || v="${PBO_CONFIG:-/etc/pbo/config}"
            fi
            # pmxcfs keeps its own fixed modes (0640 root:www-data): a config on
            # it, even an explicit PBO_CONFIG, is checked by config-shared only
            [[ "$v" == "$cfs"/* ]] && return 0
            [[ -e "$v" || -L "$v" ]] || return 0
            if [[ "$n" == config/.. ]]; then _perm_dirname_r "$v"; v="$_PERM_D"; fi
            _PERM_P="$v"; return 0 ;;
        config-shared)
            # an explicit PBO_CONFIG on pmxcfs is a shared file as well
            _PERM_P="${PBO_CONFIG_SHARED_LOADED:-}"
            [[ -n "$_PERM_P" || "${PBO_CONFIG_LOADED:-}" != "$cfs"/* ]] || _PERM_P="$PBO_CONFIG_LOADED"
            return 0 ;;
    esac
    base="${n%%/*}"; [[ "$n" == */* ]] && sub="${n#*/}"
    [[ "$base" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 0
    v="${!base:-}"
    [[ -n "$v" ]] || return 0
    if [[ "$v" != /* ]]; then
        _perm_find warn "$v" "$base=$v is not an absolute path: its permissions are not checked"; return 0
    fi
    while [[ "$v" == */ && "$v" != / ]]; do v="${v%/}"; done
    case "$sub" in
        "") ;;
        ..) _perm_dirname_r "$v"; v="$_PERM_D" ;;
        *)  v="${v%/}/$sub" ;;
    esac
    # a janitor started as root (the fix pass before the re-exec) has root's
    # LOCK_DIR default; the janitor itself uses STATE_DIR/lock (lib/common.sh)
    if [[ "$n" == LOCK_DIR && "${PBO_ROLE:-host}" == janitor && "$EUID" == 0 ]] && declare -F _cs_default_r >/dev/null; then
        _cs_default_r LOCK_DIR
        if [[ "$v" == "$_CS_R" ]]; then v="${STATE_DIR%/}/lock"; fi
    fi
    _PERM_P="$v"
}

# --- modes, owners ---------------------------------------------------------------
# _perm_mode_ok <mode (stat %a)> <spec>
_perm_mode_ok() {
    local m=$((8#$1)) s="$2" a
    case "$s" in
        -)  return 0 ;;
        \<*) (( (m & ~8#${s#<}) == 0 )); return ;;
    esac
    local IFS=/
    for a in $s; do (( m == 8#$a )) && return 0; done
    return 1
}
# _perm_mode_target_r <mode> <spec>: what a fix sets, into _PERM_M (4 digits)
_perm_mode_target_r() {
    local m=$((8#$1)) s="$2"
    case "$s" in
        \<*) printf -v _PERM_M '%04o' $(( m & 8#${s#<} )) ;;
        *)   _PERM_M="${s%%/*}" ;;
    esac
}
_perm_mode_desc() {
    case "$1" in
        \<*) printf 'at most %s' "${1#<}" ;;
        */*) printf '%s' "${1//\// or }" ;;
        *)   printf '%s' "$1" ;;
    esac
}
_perm_hint() {
    case "$1" in
        fix) printf ' (pbo doctor --fix)' ;;
        ask) printf ' (pbo doctor --fix --fix-parents)' ;;
    esac
}

# _perm_uid_r <user> / _perm_gid_r <group>: the number into _PERM_N; non-zero
# when there is no such user/group. Cached per run.
_perm_uid_r() {
    _PERM_N=""
    case "$1" in root) _PERM_N=0; return 0 ;; esac
    [[ "$1" =~ ^[0-9]+$ ]] && { _PERM_N="$1"; return 0; }
    if [[ -z "${_PERM_IDS[u:$1]+x}" ]]; then _PERM_IDS[u:$1]="$(id -u -- "$1" 2>/dev/null)" || _PERM_IDS[u:$1]=""; fi
    _PERM_N="${_PERM_IDS[u:$1]}"; [[ -n "$_PERM_N" ]]
}
_perm_gid_r() {
    _PERM_N=""
    case "$1" in root) _PERM_N=0; return 0 ;; esac
    [[ "$1" =~ ^[0-9]+$ ]] && { _PERM_N="$1"; return 0; }
    if [[ -z "${_PERM_IDS[g:$1]+x}" ]]; then
        _PERM_IDS[g:$1]="$(getent group "$1" 2>/dev/null | cut -d: -f3)" || _PERM_IDS[g:$1]=""
    fi
    _PERM_N="${_PERM_IDS[g:$1]}"; [[ -n "$_PERM_N" ]]
}
_perm_uname() { id -nu -- "$1" 2>/dev/null || printf 'uid %s' "$1"; }
_perm_gname() { getent group "$1" 2>/dev/null | cut -d: -f1 | grep . || printf 'gid %s' "$1"; }

# Owners are only checked as root, or on a janitor (which runs as JANITOR_USER
# and checks root's and its own files): a host pbo run by a plain user is a
# test or a dev setup, where every file belongs to that user.
_perm_owner_checked() { (( EUID == 0 )) || [[ "${PBO_ROLE:-host}" == janitor ]]; }

# --- the only place that changes anything ------------------------------------------
# A path is opened once without following a symlink (O_NOFOLLOW), its type and
# link count are checked on the open file, /proc/self/fd says it is still the
# path that was checked, and the change goes to that file descriptor (fchmod,
# fchown, setfacl on /proc/self/fd/N). So a symlink or a rename slipped in
# between check and change (on a janitor root fixes files in JANITOR_USER's
# directories) changes nothing else. perl-base is part of every Debian/PVE.
# shellcheck disable=SC2016  # perl code, not shell
readonly _PERM_PL='use strict; use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK F_SETFD);
my ($path, $kind, $op, @a) = @ARGV;
sub fail { print STDERR @_; exit 1 }
sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or fail($!{ELOOP} ? "it is a symlink" : "open: $!");
my @st = stat($fh) or fail("stat: $!");
if ($kind eq "dir") { -d _ or fail("not a directory") }
else { -f _ or fail("not a regular file"); $st[3] == 1 or fail("it has $st[3] hard links") }
my $fd = "/proc/self/fd/" . fileno($fh);
my $real = readlink($fd);
defined $real && $real eq $path or fail("it moved (now " . ($real // "?") . ")");
if ($op eq "chmod") { chmod(oct($a[0]), $fh) or fail("chmod: $!") }
elsif ($op eq "chown") { chown($a[0], $a[1], $fh) or fail("chown: $!") }
elsif ($op eq "acl") { fcntl($fh, F_SETFD, 0) or fail("fcntl: $!"); exec("setfacl", "-m", $a[0], $fd) or fail("setfacl: $!") }
else { fail("unknown operation $op") }'

# _perm_fdop <path> <dir|file> chmod <octal> | chown <uid> <gid> | acl <spec>
# → 0, or 1 with the reason in _PERM_ERR.
_perm_fdop() {
    local p="$1" k="$2" real
    shift 2
    _PERM_ERR=""
    command -v perl >/dev/null 2>&1 || { _PERM_ERR="perl is needed to change it safely"; return 1; }
    _perm_dirname_r "$p"
    real="$(readlink -e -- "$_PERM_D" 2>/dev/null)" || { _PERM_ERR="cannot resolve $_PERM_D"; return 1; }
    real="${real%/}/${p##*/}"
    _PERM_ERR="$(perl -e "$_PERM_PL" -- "$real" "$k" "$@" 2>&1)" && return 0
    [[ -n "$_PERM_ERR" ]] || _PERM_ERR="failed"
    return 1
}

# _perm_set <path> <kind> <what> <from> <to> <op args...>: one change (a dry run
# records it only).
_perm_set() {
    local p="$1" k="$2" what="$3" from="$4" to="$5"
    shift 5
    local rec="${_PERM_RULE%%:*}"$'\t'"$p"$'\t'"$what"$'\t'"$from"$'\t'"$to"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then PERM_CHANGES+=("$rec"$'\t'0); return 0; fi
    if _perm_fdop "$p" "$k" "$@"; then PERM_CHANGES+=("$rec"$'\t'1); return 0; fi
    PERM_FIX_ERRORS+=("could not change the $what of $p (${_PERM_RULE%%:*}) from $from to $to: $_PERM_ERR")
    return 1
}

# --- unprivileged CTs ------------------------------------------------------------
# _perm_ct_uids: _PERM_CT[<host uid>]="<vmid> ..." for the mapped root of every
# unprivileged CT on this node, plus PERM_EXTRA_VMIDS (a CT whose backup is about
# to run). Once per _perm_apply.
_perm_ct_uids() {
    [[ "${_PERM_CT_DONE:-0}" == 1 ]] && return 0
    _PERM_CT_DONE=1; _PERM_CT=()
    local v u vids=("${PERM_EXTRA_VMIDS[@]+"${PERM_EXTRA_VMIDS[@]}"}")
    while IFS= read -r v; do [[ -n "$v" ]] && vids+=("$v"); done \
        < <(find "${PBO_PVE_LXC_DIR:-/etc/pve/lxc}/" -maxdepth 1 -name '[0-9]*.conf' -printf '%f\n' 2>/dev/null | sed 's/\.conf$//')
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        u="$(_ct_root_uid "$v")" || continue
        _PERM_CT[$u]="${_PERM_CT[$u]:+${_PERM_CT[$u]} }$v"
    done < <(printf '%s\n' "${vids[@]+"${vids[@]}"}" | sort -nu)
}

# --- rule kinds ------------------------------------------------------------------
# _perm_entry <name> <dir|file> <path> <owner> <group> <mode> <acl> <class> <why>
_perm_entry() {
    local n="$1" k="$2" p="$3" ow="$4" gr="$5" ms="$6" acl="$7" cls="$8" why="$9"
    if [[ "$n" == config/.. ]]; then
        local own="${PBO_PERMS_CONFIG_DIR:-/etc/pbo}"
        own="${own%/}"
        if [[ "$p" != "$own" ]]; then
            # not pbo's own directory (PBO_CONFIG=/usr/local/etc/pbo.conf):
            # other software keeps files there, so it is never changed and need
            # not be 0700; only what lets someone replace the config is named
            gr=- ms='<0755' cls=check
            why="the config in it names programs root runs (exec keys): whoever can write the directory can replace the config"
        fi
    fi
    local fix=0 hint; [[ "$_PERM_MODE" == fix && "$cls" == fix ]] && fix=1
    hint="$(_perm_hint "$cls")"
    if [[ "$k" == dir ]] && { [[ "$PERM_SYSTEM_DIRS" == *" $p "* ]] || [[ -d "$p" && -k "$p" ]]; }; then
        # not pbo's to change; only say so when anyone can write it (followed
        # if it is a symlink: /var/lock is one, to /run/lock)
        local sm; sm="$(stat -L -c %a -- "$p" 2>/dev/null)" || return 0
        if (( 8#$sm & 8#002 )); then
            if [[ "$n" == LOCK_DIR ]]; then
                local def=""; declare -F _cs_default_r >/dev/null && { _cs_default_r LOCK_DIR; def="$_CS_R"; }
                _perm_find warn "$p" "LOCK_DIR $p is world-writable: a local user can block pbo's locks (remove LOCK_DIR from the config to use ${def:-the default})"
            else
                _perm_find warn "$p" "$n $p is a shared world-writable directory: pbo does not change it; point $n at a directory of its own"
            fi
        fi
        return 0
    fi
    # -r follows a symlink: a dangling link is as missing as no file at all,
    # and every backup fails without the key
    if [[ "$n" == RESTIC_PASSWORD_FILE && ! -r "$p" ]]; then
        if (( PERM_KEY_MISSING_OK )) && [[ ! -e "$p" && ! -L "$p" ]]; then
            _perm_find warn "$p" "DR key $p not created yet ('pbo setup' creates it)"
        else
            _perm_find fail "$p" "DR key $p missing or unreadable"
        fi
        return 0
    fi
    if [[ ! -e "$p" && ! -L "$p" ]]; then return 0; fi
    if [[ -L "$p" ]]; then
        _perm_find warn "$p" "$p ($n) is a symlink: pbo never changes permissions through one; point $n at the real path"
        if [[ "$n" == RESTIC_PASSWORD_FILE ]]; then
            # read through the link, never changed through it: a key others can
            # read is still named as such
            local tm; tm="$(stat -L -c %a -- "$p" 2>/dev/null)" || tm=0
            if (( 8#$tm & 8#077 )); then
                _perm_find warn "$p" "DR key $p -> target is $tm, should be ${ms%%/*}: whoever reads it can decrypt every backup"
            fi
        fi
        return 0
    fi
    if [[ "$k" == dir && ! -d "$p" ]]; then _perm_find warn "$p" "$p ($n) is not a directory: not checked"; return 0; fi
    if [[ "$k" == file && ! -f "$p" ]]; then _perm_find warn "$p" "$p ($n) is not a regular file: not checked"; return 0; fi
    local st u g m h
    st="$(stat -c '%u %g %a %h' -- "$p" 2>/dev/null)" || { _perm_find warn "$p" "$p ($n): cannot stat it"; return 0; }
    read -r u g m h <<<"$st"
    local bad=0 want
    # owner and group
    if [[ "$ow" != - ]] && _perm_owner_checked; then
        local wo="${ow%\?}"
        if ! _perm_uid_r "$wo"; then
            [[ -n "${_PERM_SAID[nouser:$wo]:-}" ]] || _perm_find warn "$p" "user $wo does not exist: the owners of pbo's files on this $([[ "${PBO_ROLE:-host}" == janitor ]] && echo janitor || echo host) are not checked (JANITOR_USER?)"
            _PERM_SAID[nouser:$wo]=1
        elif [[ "$u" != "$_PERM_N" ]]; then
            want="$_PERM_N"
            if (( fix && EUID == 0 )) && [[ "$ow" != *\? ]] && _perm_set "$p" "$k" owner "$(_perm_uname "$u")" "$wo" chown "$want" -1; then
                u="$want"
            else
                _perm_find warn "$p" "$p ($n) is owned by $(_perm_uname "$u"), should be $wo: $why$([[ "$ow" == *\? ]] || printf '%s' "$hint")"; bad=1
            fi
        fi
    fi
    if [[ "$gr" != - ]] && _perm_owner_checked; then
        if ! _perm_gid_r "$gr"; then
            _perm_find warn "$p" "$p ($n): group $gr does not exist, the group is not checked"; bad=1
        elif [[ "$g" != "$_PERM_N" ]]; then
            want="$_PERM_N"
            if (( fix && EUID == 0 )) && _perm_set "$p" "$k" group "$(_perm_gname "$g")" "$gr" chown -1 "$want"; then
                g="$want"
            else
                _perm_find warn "$p" "$p ($n) has group $(_perm_gname "$g"), should be $gr: $why$hint"; bad=1
            fi
        fi
    fi
    # ACL entries before the mode: closing CACHE_DIR must never lock a CT out
    local hold=0
    if [[ "$acl" == ct-roots ]]; then
        _perm_ctacl "$n" "$p" "$fix" "$m" "$hint"
        hold="$_PERM_HOLD"; bad=$(( bad | _PERM_ACL_BAD ))
        m="$(stat -c %a -- "$p" 2>/dev/null)" || m=0   # setfacl may change the mask (group bits)
        # a dry run did not run setfacl: model the mask it widens to cover the
        # new --x entry, so the plan shows the mode the real fix sets (0705
        # becomes 0715, then 0710; not 0700, which would mask the entry)
        if [[ "${DRY_RUN:-0}" == 1 ]] && (( _PERM_ACL_ADDED )); then m="$(printf '%o' $(( 8#$m | 8#010 )))"; fi
    fi
    # mode
    if ! _perm_mode_ok "$m" "$ms"; then
        _perm_mode_target_r "$m" "$ms"; want="$_PERM_M"
        if (( fix && ! hold )) && [[ "$EUID" == 0 || "$u" == "$EUID" ]] && _perm_set "$p" "$k" mode "$(printf '%04o' $((8#$m)))" "$want" chmod "$want"; then
            [[ "${DRY_RUN:-0}" == 1 ]] || m="${want#0}"
        else
            bad=1
            if [[ "$n" == RESTIC_PASSWORD_FILE ]]; then
                _perm_find warn "$p" "DR key $p is $m, should be ${ms%%/*}$hint"
            elif [[ "$n" == CACHE_DIR && "$acl" == ct-roots ]] && (( 8#$m & 8#007 )); then
                if (( ! _PERM_ACL_BAD )); then
                    local when=""
                    (( hold )) && when=" once each unprivileged CT can pass through an ACL entry (setfacl from package acl, on a filesystem with POSIX ACLs)"
                    _perm_find warn "$p" "CACHE_DIR $p is open to local users (mode $m): a running backup's plaintext archive is readable; the next backup closes it$when$hint"
                fi
            elif [[ "$n" == LOCK_DIR ]] && (( 8#$m & 8#002 )); then
                _perm_find warn "$p" "LOCK_DIR $p is world-writable: a local user can block pbo's locks$hint"
            else
                _perm_find warn "$p" "$p ($n) is mode $(printf '%04o' $((8#$m))), should be $(_perm_mode_desc "$ms"): $why$hint"
            fi
        fi
    fi
    (( bad )) && return 0
    if [[ "$n" == RESTIC_PASSWORD_FILE ]]; then _perm_find ok "$p" "DR key $p ($m)"
    elif [[ "$acl" == ct-roots ]]; then _perm_find ok "$p" "CACHE_DIR closed to local users (mode $m)"
    else _perm_find ok "$p" "$p ($n): mode $(printf '%04o' $((8#$m)))"; fi
    return 0
}

# _perm_ctacl <name> <path> <fix 0|1> <mode> <hint>: the u:<uid>:--x entries for
# every unprivileged CT's mapped root. _PERM_HOLD=1: the directory must stay
# open (an entry is missing and cannot be added); _PERM_ACL_BAD=1: a finding
# was made; _PERM_ACL_ADDED=1: an entry was added (or, in a dry run, would be).
_perm_ctacl() {
    local n="$1" p="$2" fix="$3" m="$4" hint="$5" u acl miss="" nosup=0
    _PERM_HOLD=0; _PERM_ACL_BAD=0; _PERM_ACL_ADDED=0
    _perm_ct_uids
    (( ${#_PERM_CT[@]} )) || return 0
    if ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
        _PERM_HOLD=1
        if ! (( 8#$m & 8#007 )); then
            _PERM_ACL_BAD=1
            _perm_find warn "$p" "CACHE_DIR $p: getfacl/setfacl (package acl) missing, cannot check that the mapped root of unprivileged CT(s) $(_perm_ct_list) can enter it"
        elif [[ "$_PERM_MODE" == fix ]]; then
            # a fix leaves it open: say why (the check pass names it open)
            _PERM_ACL_BAD=1
            _perm_find warn "$p" "CACHE_DIR $p stays open to local users: setfacl/getfacl (package acl) are needed to let unprivileged CTs' vzdump through"
        fi
        return 0
    fi
    acl="$(getfacl -cpn -- "$p" 2>/dev/null)"
    for u in $(printf '%s\n' "${!_PERM_CT[@]}" | sort -n); do
        # only an entry that is in effect counts: getfacl adds "#effective:"
        # when the mask hides bits of it, and a chmod of the directory sets the
        # mask (chmod 700 leaves user:<uid>:--x at #effective:---). setfacl -m
        # below recomputes the mask, so it brings a masked entry back.
        grep -qE "^user:$u:..x([[:space:]]+#effective:..x)?\$" <<<"$acl" && continue
        if (( fix && ! nosup )); then
            if _perm_set "$p" dir acl - "u:$u:--x" acl "u:$u:x"; then _PERM_ACL_ADDED=1; continue; fi
            if [[ "$_PERM_ERR" == *"not supported"* ]]; then
                # no POSIX ACLs on this filesystem (ZFS acltype=off, some NFS):
                # neither the acl package nor another --fix can help
                nosup=1; _PERM_ACL_BAD=1
                PERM_FIX_ERRORS[${#PERM_FIX_ERRORS[@]}-1]="$(_perm_nosup_msg "$p" "setfacl: Operation not supported")"
            else
                PERM_FIX_ERRORS[${#PERM_FIX_ERRORS[@]}-1]="CACHE_DIR $p: could not add the ACL entry for uid $u (vzdump of unprivileged CTs), left open: $_PERM_ERR"
            fi
        fi
        miss+="${miss:+ }${_PERM_CT[$u]}"
    done
    [[ -n "$miss" ]] || return 0
    _PERM_HOLD=1
    if ! (( 8#$m & 8#007 )); then
        _PERM_ACL_BAD=1
        _perm_find fail "$p" "CACHE_DIR $p is closed but has no ACL entry in effect for the mapped root of unprivileged CT(s) $(tr ' ' '\n' <<<"$miss" | sort -nu | paste -sd' ' -): their vzdump fails ('pbo backup <vmid>', the next run-schedule or pbo doctor --fix adds it; a chmod of the directory can mask an entry)"
    elif (( ! fix )) && _perm_acl_unsupported "$p"; then
        # the check pass writes no trial entry: a read-only probe instead
        _PERM_ACL_BAD=1
        _perm_find warn "$p" "$(_perm_nosup_msg "$p" "ZFS acltype=off")"
    fi
    return 0
}

# _perm_nosup_msg <dir> <evidence>: CACHE_DIR cannot be closed on this filesystem.
_perm_nosup_msg() {
    printf 'CACHE_DIR %s stays open to local users: its filesystem does not support POSIX ACLs (%s), so an unprivileged CT could not pass it once closed; enable them (ZFS: zfs set acltype=posixacl <dataset>) or move CACHE_DIR' "$1" "$2"
}

# _perm_acl_unsupported <dir>: its filesystem is known to have no POSIX ACLs.
# Read-only, for the check pass: ZFS with acltype off (its default). Anything
# else counts as supported; the fix finds out for sure from setfacl.
_perm_acl_unsupported() {
    [[ "$(stat -f -c %T -- "$1" 2>/dev/null)" == zfs ]] || return 1
    command -v zfs >/dev/null 2>&1 || return 1
    local t; t="$(zfs get -H -o value acltype "$1" 2>/dev/null)" || return 1
    [[ "$t" == off || "$t" == noacl ]]
}
_perm_ct_list() { printf '%s\n' "${_PERM_CT[@]}" | tr ' ' '\n' | sort -nu | paste -sd' ' -; }

# _perm_traverses <uid> <dir>: that uid may pass <dir> (search permission,
# ACLs included). Root enters the directory and the uid tests "." there, so
# each directory is judged on its own, whatever is above it: one pass finds
# every directory that blocks, not just the first.
_perm_traverses() {
    ( cd -- "$2" 2>/dev/null && exec setpriv --reuid "$1" --regid "$1" --clear-groups -- test -x . ) 2>/dev/null
}

# _perm_parents <name> <path> <class> <why>: every directory above <path> must
# let the mapped root of each unprivileged CT through (tested for real). --fix
# with --fix-parents adds a traverse-only entry u:<uid>:--x where one blocks.
_perm_parents() {
    local n="$1" p="$2" cls="$3" why="$4"
    [[ -d "$p" ]] || return 0
    _perm_ct_uids
    (( ${#_PERM_CT[@]} )) || return 0
    if (( EUID != 0 )) || ! command -v setpriv >/dev/null 2>&1; then
        _perm_find ok "$p" "CACHE_DIR parents: not checked that the mapped root of unprivileged CT(s) $(_perm_ct_list) can pass them (needs root and setpriv)"
        return 0
    fi
    local real; real="$(readlink -e -- "$p")" || return 0   # vzdump walks the real path
    local anc=() d="$real" top="${PBO_PERMS_PARENTS_TOP:-}"
    top="${top%/}"
    while [[ "$d" != / ]]; do
        _perm_dirname_r "$d"; d="$_PERM_D"
        # test hook: the checkout of the test suite sits below a 0700 home
        [[ -n "$top" && "$d/" != "$top"/* ]] && break
        anc=("$d" "${anc[@]+"${anc[@]}"}")
    done
    local fix=0; [[ "$_PERM_MODE" == fix && "$_PERM_PARENTS" == 1 ]] && fix=1
    local u a bad=0
    for u in $(printf '%s\n' "${!_PERM_CT[@]}" | sort -n); do
        for a in "${anc[@]+"${anc[@]}"}"; do
            _perm_traverses "$u" "$a" && continue
            if (( fix )); then
                if ! command -v setfacl >/dev/null 2>&1; then
                    PERM_FIX_ERRORS+=("could not let uid $u pass $a: setfacl (package acl) is needed")
                elif _perm_set "$a" dir acl - "u:$u:--x" acl "u:$u:x"; then
                    [[ "${DRY_RUN:-0}" == 1 ]] || _perm_traverses "$u" "$a" && continue
                    PERM_FIX_ERRORS+=("$a: uid $u still cannot pass it after the ACL entry u:$u:--x (another mechanism blocks it)")
                fi
            fi
            bad=1
            _perm_find warn "$a" "CACHE_DIR parent $a is not traversable by uid $u (the mapped root of unprivileged CT(s) ${_PERM_CT[$u]}): their vzdump fails; 'pbo doctor --fix --fix-parents' adds a traverse-only ACL entry (u:$u:--x)"
        done
    done
    (( bad )) || _perm_find ok "$p" "CACHE_DIR parents: the mapped root of unprivileged CT(s) $(_perm_ct_list) can pass every directory above $p"
    return 0
}

# _perm_files <name> <dir> <owner> <group> <mode> <class> <why>: the regular
# files directly in <dir> (staged archives; the symlinks into the mount are
# left alone).
_perm_files() {
    local n="$1" d="$2" f
    [[ -d "$d" && ! -L "$d" ]] || return 0
    while IFS= read -r -d '' f; do
        _perm_entry "$n" file "$f" "$3" "$4" "$5" - "$6" "$7"
    done < <(find "$d" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
}

# _perm_keys <name> <file>: the cluster-shared config (pmxcfs has its own
# modes): no secret and no exec key, since every node gets a copy.
_perm_keys() {
    local n="$1" f="$2" k bad=""
    [[ -r "$f" ]] || return 0
    declare -F _cs_flag >/dev/null || return 0
    while read -r k; do
        [[ -n "$k" ]] || continue
        if _cs_flag "$k" secret >/dev/null; then bad+="${bad:+, }$k (secret)"
        elif _cs_flag "$k" exec >/dev/null; then bad+="${bad:+, }$k (runs a program)"; fi
    done < <(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=.*/\2/p' "$f" | sort -u)
    if [[ -n "$bad" ]]; then
        _perm_find warn "$f" "cluster-shared config $f sets $bad: pmxcfs copies it to every node; set these in the local config of each node"
    else
        _perm_find ok "$f" "cluster-shared config $f holds no secret or exec key"
    fi
}

# --- the engine ------------------------------------------------------------------
# _perm_apply --check|--fix [--fix-parents] [--only NAME[:KIND]]...: run the
# rule table for this role. Idempotent; never follows a symlink, never recurses
# into a repo, creates nothing. Fills PERM_FINDINGS, PERM_CHANGES,
# PERM_FIX_ERRORS. --fix applies the class fix rules (and ask with
# --fix-parents); DRY_RUN=1 records the changes without making them.
_perm_apply() {
    local mode="" parents=0 only=()
    while (( $# )); do
        case "$1" in
            --check) mode=check ;;
            --fix) mode=fix ;;
            --fix-parents) parents=1 ;;
            --only) [[ $# -ge 2 ]] || return 2; only+=("$2"); shift ;;
            *) return 2 ;;
        esac
        shift
    done
    [[ -n "$mode" ]] || return 2
    PERM_FINDINGS=() PERM_CHANGES=() PERM_FIX_ERRORS=()
    _PERM_MODE="$mode" _PERM_PARENTS="$parents" _PERM_CT_DONE=0
    declare -gA _PERM_IDS=() _PERM_SAID=() _PERM_CT=()
    local n k ow gr ms acl cls why
    while IFS='|' read -r -u 3 n k ow gr ms acl cls why; do
        [[ -n "$n" ]] || continue
        if (( ${#only[@]} )) && [[ " ${only[*]} " != *" $n "* && " ${only[*]} " != *" $n:$k "* ]]; then continue; fi
        _PERM_RULE="$n:$k"
        _perm_path_r "$n"
        [[ -n "$_PERM_P" ]] || continue
        case "$k" in
            dir|file) _perm_entry "$n" "$k" "$_PERM_P" "$ow" "$gr" "$ms" "$acl" "$cls" "$why" ;;
            files)    _perm_files "$n" "$_PERM_P" "$ow" "$gr" "$ms" "$cls" "$why" ;;
            parents)  _perm_parents "$n" "$_PERM_P" "$cls" "$why" ;;
            keys)     _perm_keys "$n" "$_PERM_P" ;;
        esac
    done 3< <(_perm_rules "${PBO_ROLE:-host}")
    return 0
}

# _perm_change_text <change line>: "<path>: mode 0755 -> 0700" (acl: "+u:..").
_perm_change_text() {
    local n p what from to applied
    IFS=$'\t' read -r n p what from to applied <<<"$1"
    if [[ "$what" == acl ]]; then printf '%s: acl +%s' "$p" "$to"
    else printf '%s: %s %s -> %s' "$p" "$what" "$from" "$to"; fi
}

# --- doctor ---------------------------------------------------------------------
# doctor's own flags (_doctor_args), 0 for a caller that never parsed them.
DOCTOR_FIX=0 DOCTOR_FIX_PARENTS=0 DOCTOR_PERMS_ONLY=0 DOCTOR_REPORT=0 DP_CHANGES_JSON=null
# PERM_KEY_MISSING_OK=1 (doctor --perms-only): a DR key that does not exist yet
# is a warning, not a failure. install.sh runs --perms-only before `pbo setup`
# made the key, and no permission fix can create it; full doctor still fails.
PERM_KEY_MISSING_OK=0

# _doctor_args <args...>: doctor's own flags into DOCTOR_FIX, DOCTOR_FIX_PARENTS
# (implies --fix), DOCTOR_PERMS_ONLY, DOCTOR_REPORT (the environment report,
# lib/report.sh: read-only, so not with --fix or --perms-only); --dry-run also
# works after the command. Returns 1 (and DOCTOR_BAD_ARG) on anything else.
_doctor_args() {
    DOCTOR_FIX=0 DOCTOR_FIX_PARENTS=0 DOCTOR_PERMS_ONLY=0 DOCTOR_REPORT=0 DOCTOR_BAD_ARG=""
    while (( $# )); do
        case "$1" in
            --fix) DOCTOR_FIX=1 ;;
            --fix-parents) DOCTOR_FIX=1; DOCTOR_FIX_PARENTS=1 ;;
            --perms-only) DOCTOR_PERMS_ONLY=1 ;;
            --report) DOCTOR_REPORT=1 ;;
            --dry-run) DRY_RUN=1 ;;
            *) DOCTOR_BAD_ARG="$1"; return 1 ;;
        esac
        shift
    done
    if (( DOCTOR_REPORT && (DOCTOR_FIX || DOCTOR_PERMS_ONLY) )); then DOCTOR_BAD_ARG="--report (it changes nothing: not with --fix or --perms-only)"; return 1; fi
    return 0
}

# _perm_root_pass: a janitor started as root drops to JANITOR_USER before it
# writes anything (_role_check), but only root can give a file to JANITOR_USER
# or to root. So `doctor --fix` runs its fix pass here, as root, right before
# the re-exec, and hands the result to the doctor that runs as JANITOR_USER
# (PBO_PERMS_FIX_REPORT), which audits and prints it. PBO_PERMS_FIXED=1 keeps
# that doctor from running the fix pass again. Nothing is logged here: the log
# files are JANITOR_USER's, root does not append to them.
_perm_root_pass() {
    [[ "${PBO_PERMS_FIXED:-0}" == 1 ]] && return 0
    local a seen=0 args=()
    for a in "${PBO_ORIG_ARGS[@]+"${PBO_ORIG_ARGS[@]}"}"; do
        if (( seen )); then args+=("$a"); elif [[ "$a" == doctor ]]; then seen=1; fi
    done
    local dry="${DRY_RUN:-0}"
    _doctor_args "${args[@]+"${args[@]}"}" || return 0   # the re-exec'd doctor says what is wrong
    (( DOCTOR_FIX )) || { DRY_RUN="$dry"; return 0; }
    local fp=(); (( DOCTOR_FIX_PARENTS )) && fp=(--fix-parents)
    _perm_apply --fix "${fp[@]+"${fp[@]}"}"
    local rep="" c
    for c in "${PERM_CHANGES[@]+"${PERM_CHANGES[@]}"}"; do rep+="C"$'\t'"$c"$'\n'; done
    for c in "${PERM_FIX_ERRORS[@]+"${PERM_FIX_ERRORS[@]}"}"; do rep+="E"$'\t'"${c//$'\n'/ }"$'\n'; done
    export PBO_PERMS_FIXED=1 PBO_PERMS_FIX_REPORT="$rep"
    DRY_RUN="$dry"
}

# _doctor_perms OK FAIL WARN: the permission lines for doctor. With --fix the
# fix pass runs first (on a janitor started as root it ran before the re-exec:
# its report is read back), each change made is audit-logged, and the check
# pass then shows the state after it. Sets DP_DR (the DR key line, doctor
# prints it first), DP_LINES, DP_PROBLEMS, DP_WARNS, DP_CHANGES_JSON (null
# without --fix).
_doctor_perms() {
    local ok="$1" bad="$2" warn="$3" c e
    DP_DR=() DP_LINES=() DP_PROBLEMS=0 DP_WARNS=0 DP_CHANGES_JSON=null
    if (( DOCTOR_FIX )); then
        local by=""
        if _is_janitor && [[ "${PBO_PERMS_FIXED:-0}" == 1 ]]; then
            PERM_CHANGES=() PERM_FIX_ERRORS=()
            while IFS=$'\t' read -r e c; do
                case "$e" in C) PERM_CHANGES+=("$c") ;; E) PERM_FIX_ERRORS+=("$c") ;; esac
            done <<<"${PBO_PERMS_FIX_REPORT:-}"
            by=" (as root, before dropping to ${JANITOR_USER:-restic})"
        else
            local fp=(); (( DOCTOR_FIX_PARENTS )) && fp=(--fix-parents)
            _perm_apply --fix "${fp[@]+"${fp[@]}"}"
        fi
        local n p what from to applied
        for c in "${PERM_CHANGES[@]+"${PERM_CHANGES[@]}"}"; do
            IFS=$'\t' read -r n p what from to applied <<<"$c"
            if [[ "$applied" == 1 ]]; then
                if [[ "$what" == acl ]]; then audit_log "perms fix $p acl +$to$by"
                else audit_log "perms fix $p $what $from->$to$by"; fi
                DP_LINES+=("  ${C_G:-}FIXED${C_0:-} $(_perm_change_text "$c")")
            else
                DP_LINES+=("  ${C_Y:-}WOULD FIX${C_0:-} $(_perm_change_text "$c")")
            fi
        done
        for e in "${PERM_FIX_ERRORS[@]+"${PERM_FIX_ERRORS[@]}"}"; do DP_LINES+=("$warn  $e"); DP_WARNS=$((DP_WARNS+1)); done
        DP_CHANGES_JSON="$(printf '%s\n' "${PERM_CHANGES[@]+"${PERM_CHANGES[@]}"}" | jq -R -s -c '
            split("\n") | map(select(length > 0) | split("\t")
              | {name: .[0], path: .[1], change: .[2], from: .[3], to: .[4], applied: (.[5] == "1")})')"
    fi
    _perm_apply --check
    local f lv rule path msg quiet=0
    for f in "${PERM_FINDINGS[@]+"${PERM_FINDINGS[@]}"}"; do
        IFS=$'\t' read -r lv rule path msg <<<"$f"
        case "$lv" in
            ok)
                # the lines doctor always showed (and the ones a reader looks
                # for); the rest is one summary line
                case "$rule" in
                    RESTIC_PASSWORD_FILE:*) DP_DR+=("$ok  $msg") ;;
                    CACHE_DIR:*|config-shared:*) DP_LINES+=("$ok  $msg") ;;
                    *) quiet=$((quiet+1)) ;;
                esac ;;
            fail)
                if [[ "$rule" == RESTIC_PASSWORD_FILE:* ]]; then DP_DR+=("$bad  $msg"); else DP_LINES+=("$bad  $msg"); fi
                DP_PROBLEMS=$((DP_PROBLEMS+1)) ;;
            *)
                if [[ "$rule" == RESTIC_PASSWORD_FILE:* ]]; then DP_DR+=("$warn  $msg"); else DP_LINES+=("$warn  $msg"); fi
                DP_WARNS=$((DP_WARNS+1)) ;;
        esac
    done
    (( quiet == 0 )) || DP_LINES+=("$ok  permissions: $quiet more path(s) as the rule table wants (ADR 0009)")
    return 0
}

# doctor --perms-only: the permission section alone (install.sh runs it with --fix).
_doctor_perms_only() {
    local ok="  ${C_G:-}OK${C_0:-}" bad="  ${C_R:-}FAIL${C_0:-}" warn="  ${C_Y:-}WARN${C_0:-}"
    local PERM_KEY_MISSING_OK=1
    _doctor_perms "$ok" "$bad" "$warn"
    local lines=("${DP_DR[@]+"${DP_DR[@]}"}" "${DP_LINES[@]+"${DP_LINES[@]}"}")
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        _doctor_json "$DP_PROBLEMS" "$DP_WARNS" "${lines[@]+"${lines[@]}"}"
    else
        (( ${#lines[@]} )) && printf '%s\n' "${lines[@]}"
        log_info "doctor (permissions): ${DP_PROBLEMS} problem(s), ${DP_WARNS} warning(s)"
    fi
    (( DP_PROBLEMS == 0 )) || return "$EX_UNAVAILABLE"
    return "$EX_OK"
}
