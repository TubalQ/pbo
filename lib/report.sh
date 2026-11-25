# shellcheck shell=bash
# lib/report.sh: `pbo doctor --report`, the environment report for a bug report.
#
# What differs between installations and explains most "works here, fails
# there" reports: versions (pbo and how it is installed, Proxmox VE, restic,
# kernel, perl, bash, systemd), cluster or single node, the filesystem of
# CACHE_DIR and whether it has POSIX ACLs, the backend TYPE of each repo, the
# integration mode and which optional tools exist. Meant to be pasted into a
# public issue, so it names nothing that identifies the host or reaches it:
# no node or host name, no URL, user, repo path or any other path, no value of
# a secret or of RESTIC_ENV_FILE. Every field is a version, a count, a type
# or a yes/no; a value pbo cannot classify is "other", never echoed.
# tests/portability.sh plants secrets, URLs, a host name and paths in the
# config and checks that none of them appears.

# _report_layout → how this pbo is installed, from where it runs (the path
# itself is not shown): deb (/usr/lib/pbo), install.sh (/usr/local/lib/pbo),
# or source (a checkout).
_report_layout() {
    case "${SELF_DIR:-}" in
        /usr/lib/pbo) printf deb ;;
        /usr/local/lib/pbo) printf install.sh ;;
        *) printf source ;;
    esac
}

# _report_repo_type <repo> → the restic backend type: sftp, rest, s3, b2,
# azure, gs, swift, rclone, local (a path), other; none when empty.
_report_repo_type() {
    local r="$1"
    case "$r" in
        '') printf none ;;
        sftp:*|rest:*|s3:*|b2:*|azure:*|gs:*|swift:*|rclone:*) printf '%s' "${r%%:*}" ;;
        /*) printf local ;;
        *) printf other ;;
    esac
}

# _report_pkg <package> → its installed version (dpkg-query), empty when none.
_report_pkg() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

# _report_clean <text>: a version string as reported, or "other" when it holds
# anything but version characters (it is shown in a public issue).
_report_clean() {
    if [[ "$1" =~ ^[A-Za-z0-9.+~:_-]{1,64}$ ]]; then printf '%s' "$1"
    elif [[ -z "$1" ]]; then printf ''
    else printf other; fi
}

# _report_fs <dir> → "<type>|<acl>": the filesystem type of the directory (or
# of its nearest existing parent) and whether it has POSIX ACLs: yes, no or
# unknown. Read-only: ZFS by its acltype property, the others by their mount
# options (noacl), NFS and CIFS unknown. The dataset or device is not shown.
_report_fs() {
    local d="$1" t acl=unknown opts a
    # a relative path (the dir type takes one) made absolute first: ${d%/*} of
    # a name without a slash is the name itself, and the walk would never end
    [[ "$d" == /* ]] || d="${PWD%/}/$d"
    while [[ -n "$d" && ! -e "$d" ]]; do d="${d%/*}"; done
    [[ -n "$d" ]] || d=/
    t="$(stat -f -c %T -- "$d" 2>/dev/null)" || t=''
    [[ "$t" =~ ^[A-Za-z0-9._/-]{1,32}$ ]] || t=unknown
    case "$t" in
        zfs)
            a="$(zfs get -H -o value acltype "$d" 2>/dev/null)" || a=''
            case "$a" in posix|posixacl) acl=yes ;; off|noacl|nfsv4) acl=no ;; esac ;;
        ext2/ext3|ext4|xfs|btrfs|tmpfs|f2fs)
            opts="$(findmnt -n -o OPTIONS --target "$d" 2>/dev/null | tail -1)" || opts=''
            if [[ -z "$opts" ]]; then acl=unknown
            elif [[ ",$opts," == *,noacl,* ]]; then acl=no
            else acl=yes; fi ;;
    esac
    printf '%s|%s' "$t" "$acl"
}

# _report_cluster → "single node" or "cluster, N nodes, quorate|not quorate",
# from pmxcfs' member list (the node and cluster names are not shown);
# "unknown" without it.
_report_cluster() {
    local m="${PBO_PVE_CFS_DIR:-/etc/pve}/.members" out
    [[ -r "$m" ]] && command -v jq >/dev/null 2>&1 || { printf unknown; return 0; }
    # a node outside a cluster lists itself as a cluster of one
    out="$(jq -r '((.cluster.nodes // 0) | tonumber? // 0) as $n
                 | if $n <= 1 then "single node"
                   else "cluster, \($n) nodes, \(if (.cluster.quorate // 0) == 1 then "quorate" else "not quorate" end)" end' "$m" 2>/dev/null)" || out=''
    [[ "$out" =~ ^(single\ node|cluster,\ [0-9]+\ nodes,\ (not\ )?quorate)$ ]] || out=unknown
    printf '%s' "$out"
}

# The optional tools the report lists, and what each is for.
readonly REPORT_TOOLS='setfacl getfacl setpriv findmnt fusermount3 fusermount systemd-run zfs zpool pvesh pct qm vzdump rclone perl curl zstd jq'

# rdo_doctor_report: the report, as text (key: value) or with --json as
# {status, ok, report:{...}}.
rdo_doctor_report() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for doctor --report"
    local fs fst fsacl tools_have=() tools_missing=() t restic_v perl_v os kern sd envn=0 envst=absent
    fs="$(_report_fs "${CACHE_DIR:-/var/cache/pbo}")"; fst="${fs%%|*}"; fsacl="${fs#*|}"
    for t in $REPORT_TOOLS; do
        if _tool_present "$t"; then tools_have+=("$t"); else tools_missing+=("$t"); fi
    done
    restic_v="$(_restic_version)"
    perl_v="$(perl -e 'printf "%vd", $^V' 2>/dev/null)" || perl_v=''
    kern="$(uname -r 2>/dev/null)" || kern=''
    sd="$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2; exit }')" || sd=''
    os=''
    if [[ -r /etc/os-release ]]; then
        # ID and VERSION_ID only (debian 13): no free-text fields
        os="$(awk -F= '$1 == "ID" || $1 == "VERSION_ID" { gsub(/"/, "", $2); v[$1] = $2 } END { print v["ID"] " " v["VERSION_ID"] }' /etc/os-release 2>/dev/null)" || os=''
        [[ "$os" =~ ^[a-z0-9._-]*\ [0-9.]*$ ]] || os=other
    fi
    if [[ -n "${RENV_ERRORS[0]+x}" ]]; then envst=refused
    elif [[ "${RENV_PRESENT-0}" == 1 ]]; then envst=present; envn="${#RENV_KEYS[@]}"; fi
    local offsite_type cache_type ao=false
    offsite_type=none
    [[ "${OFFSITE_ENABLED:-true}" == true ]] && offsite_type="$(_report_repo_type "${RESTIC_OFFSITE_REPO:-}")"
    cache_type=none
    [[ "${LOCAL_REPO:-true}" == true ]] && cache_type="$(_report_repo_type "${RESTIC_CACHE_REPO:-}")"
    [[ "${OFFSITE_APPEND_ONLY:-false}" == true ]] && ao=true
    local role="${PBO_ROLE:-host}" integ="${PBO_INTEGRATION:-standalone}"
    [[ "$role" == host || "$role" == janitor ]] || role=other
    case "$integ" in standalone|both|integrated) ;; *) integ=other ;; esac
    local out
    out="$(jq -cn \
        --arg pbo "$(_report_clean "${VERSION:-}")" --arg layout "$(_report_layout)" \
        --arg role "$role" --arg integ "$integ" \
        --arg pvem "$(_report_clean "$(_report_pkg pve-manager)")" --arg pves "$(_report_clean "$(_report_pkg libpve-storage-perl)")" \
        --arg qemus "$(_report_clean "$(_report_pkg qemu-server)")" --arg pvec "$(_report_clean "$(_report_pkg pve-container)")" \
        --arg restic "$(_report_clean "$restic_v")" --arg kernel "$(_report_clean "$kern")" --arg perl "$(_report_clean "$perl_v")" \
        --arg bash "$(_report_clean "${BASH_VERSION%%(*}")" --arg systemd "$(_report_clean "$sd")" --arg os "$os" \
        --arg tz "$(date +%:z 2>/dev/null)" \
        --arg cluster "$(_report_cluster)" --arg fst "$fst" --arg fsacl "$fsacl" \
        --arg cache "$cache_type" --arg offsite "$offsite_type" --argjson ao "$ao" \
        --arg envst "$envst" --argjson envn "$envn" \
        --arg have "${tools_have[*]-}" --arg miss "${tools_missing[*]-}" '
        def nz: if . == "" then null else . end;
        def words: split(" ") | map(select(length > 0));
        {status: "ok", ok: true, report: {
            pbo: {version: ($pbo | nz), layout: $layout, role: $role, integration: $integ},
            versions: {pve_manager: ($pvem | nz), libpve_storage_perl: ($pves | nz), qemu_server: ($qemus | nz),
                       pve_container: ($pvec | nz), restic: ($restic | nz), kernel: ($kernel | nz), perl: ($perl | nz),
                       bash: ($bash | nz), systemd: ($systemd | nz), os: ($os | nz)},
            utc_offset: ($tz | nz), cluster: $cluster,
            cache_dir: {filesystem: $fst, posix_acl: $fsacl},
            backends: {cache: $cache, offsite: $offsite, offsite_append_only: $ao},
            restic_env_file: {state: $envst, variables: $envn},
            tools: {present: ($have | words), missing: ($miss | words)} }}')" \
        || die "$EX_SOFTWARE" "doctor --report: could not build the report"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$out"; return "$EX_OK"; fi
    jq -r '.report | [
        "pbo: \(.pbo.version // "?") (\(.pbo.layout)), role \(.pbo.role), integration \(.pbo.integration)",
        "proxmox ve: pve-manager \(.versions.pve_manager // "not installed"), libpve-storage-perl \(.versions.libpve_storage_perl // "-"), qemu-server \(.versions.qemu_server // "-"), pve-container \(.versions.pve_container // "-")",
        "restic: \(.versions.restic // "not found")",
        "os: \(.versions.os // "?"), kernel \(.versions.kernel // "?"), perl \(.versions.perl // "?"), bash \(.versions.bash // "?"), systemd \(.versions.systemd // "?")",
        "time: UTC offset \(.utc_offset // "?")",
        "cluster: \(.cluster)",
        "cache dir: filesystem \(.cache_dir.filesystem), POSIX ACLs \(.cache_dir.posix_acl)",
        "backends: cache \(.backends.cache), offsite \(.backends.offsite)\(if .backends.offsite_append_only then " (append-only)" else "" end)",
        "restic env file: \(.restic_env_file.state)\(if .restic_env_file.state == "present" then ", \(.restic_env_file.variables) variable(s)" else "" end)",
        "tools present: \(.tools.present | join(" "))",
        "tools missing: \(if (.tools.missing | length) == 0 then "none" else (.tools.missing | join(" ")) end)"
      ] | .[]' <<<"$out"
}
